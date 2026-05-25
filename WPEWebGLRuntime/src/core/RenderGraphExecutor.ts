import {
  sendDiagnostic,
  type ConstantValue,
  type PoolFBO,
  type RenderFBOPayload,
  type RenderGraphPayload,
  type RenderPassPayload,
  type TextureReference
} from "../bridge/HostBridge";
import { FramebufferPool } from "../resources/FramebufferPool";
import { ShaderCompiler, type SamplerInfo, type ShaderRequest } from "../resources/ShaderCompiler";
import { TextureManager } from "../resources/TextureManager";

// Reserved texture units. The executor binds the placeholder texture to
// PLACEHOLDER_UNIT once per frame; any sampler uniform the executor
// doesn't explicitly bind gets pointed at this unit so it never samples
// a stale or unrelated texture (Phase 3 audit Medium).
const PLACEHOLDER_UNIT = 14;
const AUDIO_UNIT = 15;
// Frame cadence for sprite-sheet textures sampled by genericimage4-style
// passes. Aligned with Swift's `WPETexAnimationTrack.defaultFrameRate`
// so the WebGL and Metal backends agree. The fragment shader cross-fades
// between consecutive frames via `g_SpriteFrameBlend`, so a 3-frame
// vertical strip animates smoothly at this cadence rather than strobing.
const SPRITESHEET_FRAME_RATE = 25;

interface PreparedPass {
  pass: RenderPassPayload;
  program: WebGLProgram;
  samplers: SamplerInfo[];
}

interface PreparedLayer {
  objectID: string;
  objectName: string;
  parallaxDepth: number;
  localFBOs: RenderFBOPayload[];
  passes: PreparedPass[];
}

interface BoundTexture {
  texture: WebGLTexture | null;
  width: number;
  height: number;
}

export class RenderGraphExecutor {
  private gl: WebGL2RenderingContext;
  private shaderCompiler: ShaderCompiler;
  private fboPool: FramebufferPool;
  private textureManager: TextureManager;

  private graph: RenderGraphPayload | null = null;
  private layers: PreparedLayer[] = [];
  private vao: WebGLVertexArrayObject | null = null;
  private vbo: WebGLBuffer | null = null;
  private placeholderTexture: WebGLTexture | null = null;
  private audioTexture: WebGLTexture | null = null;
  private placeholderAnnounced: Set<string> = new Set();
  private reservedSlotAnnounced: Set<string> = new Set();
  private assetUrlPrefix: string = "";

  constructor(
    gl: WebGL2RenderingContext,
    shaderCompiler: ShaderCompiler,
    fboPool: FramebufferPool,
    textureManager: TextureManager
  ) {
    this.gl = gl;
    this.shaderCompiler = shaderCompiler;
    this.fboPool = fboPool;
    this.textureManager = textureManager;
    this.initFullscreenQuad();
  }

  async load(graph: RenderGraphPayload, assetUrlPrefix: string): Promise<{ ok: boolean; error?: string }> {
    this.assetUrlPrefix = assetUrlPrefix;
    this.graph = graph;
    const prepared: PreparedLayer[] = [];
    const textureURLs = new Set<string>();
    for (const layer of graph.layers) {
      const passes: PreparedPass[] = [];
      for (const pass of layer.passes) {
        if (pass.isBuiltin && !pass.vertexSource && !pass.fragmentSource) {
          continue;
        }
        const request: ShaderRequest = {
          vertexSource: pass.vertexSource,
          fragmentSource: pass.fragmentSource,
          combos: pass.combos ?? {}
        };
        const compiled = this.shaderCompiler.getCompiled(pass.id, request);
        if (!compiled) {
          return {
            ok: false,
            error: `Shader compile failed for pass ${pass.id} in layer ${layer.objectName}`
          };
        }
        passes.push({ pass, program: compiled.program, samplers: compiled.samplers });

        this.collectTextureURLs(pass.source, textureURLs);
        for (const ref of Object.values(pass.textures ?? {})) {
          this.collectTextureURLs(ref, textureURLs);
        }
      }
      prepared.push({
        objectID: layer.objectID,
        objectName: layer.objectName,
        parallaxDepth: layer.parallaxDepth,
        localFBOs: layer.localFBOs,
        passes
      });
    }
    this.layers = prepared;

    const result = await this.textureManager.preloadAll(textureURLs);
    if (result.failed.length > 0) {
      sendDiagnostic(
        "texture-preload",
        `${result.loaded} loaded, ${result.failed.length} failed; will fall back to placeholders.`
      );
    }
    return { ok: true };
  }

  private collectTextureURLs(ref: TextureReference, out: Set<string>): void {
    if ((ref.kind === "image" || ref.kind === "asset") && ref.value) {
      out.add(this.assetUrl(ref.value));
    }
  }

  // Per-component percent-encoding so filenames with spaces / unicode /
  // `#` / `?` / `%` survive the round-trip to Swift's
  // `removingPercentEncoding` decoder.
  private assetUrl(relativePath: string): string {
    const segments = relativePath.split("/").map((s) => encodeURIComponent(s));
    return this.assetUrlPrefix + segments.join("/");
  }

  drawFrame(time: number, runtimeUniforms: { pointer?: { x: number; y: number; click: number; hover: number }; audioSpectrum?: number[] }): void {
    const gl = this.gl;
    const graph = this.graph;
    if (!graph || !this.vao) return;

    const sceneSize = graph.sceneSize;
    let currentSceneFBO: PoolFBO | null = null;

    // Phase 6: pump each video texture's `<video>` element so the
    // texture reflects the current frame before any pass samples it.
    this.textureManager.refreshVideoFrames();

    gl.bindVertexArray(this.vao);

    // Phase 5: reserved placeholder unit so unmapped sampler uniforms
    // never accidentally sample whatever was last bound to TEXTURE0.
    gl.activeTexture(gl.TEXTURE0 + PLACEHOLDER_UNIT);
    gl.bindTexture(gl.TEXTURE_2D, this.getOrCreatePlaceholderTexture());

    for (const layer of this.layers) {
      for (const prepared of layer.passes) {
        const pass = prepared.pass;
        const program = prepared.program;
        const boundSamplers = new Set<string>();

        const targetFBO = this.fboPool.resolveTarget(
          layer.objectID,
          pass.target,
          sceneSize,
          layer.localFBOs
        );

        gl.useProgram(program);
        this.applyBlending(pass.blending);
        this.applyCullMode(pass.cullMode);
        this.applyDepth(pass.depthTest, pass.depthWrite);

        this.uploadBuiltinUniforms(program, time, runtimeUniforms, layer.parallaxDepth);
        this.uploadConstants(program, pass.constants ?? {});

        // Swift `WPERenderPipelineBuilder.textureBindings(for:defaults:)`
        // already folds `effect.bind[0]` overrides on top of `pass.source`
        // and emits the result into `pass.textures[0]` — which means
        // `shine_combine`'s `bind: [{name:"_rt_HalfCompoBuffer2", index:0},
        // {name:"previous", index:1}]` ends up with `textures[0]` pointing
        // at the blur ring buffer instead of the raw effect source. If we
        // sample `pass.source` here, we drop that override and the final
        // composite samples the layer state for both g_Texture0 AND
        // g_Texture1 — under the default BLENDMODE the screen turns black.
        // Prefer the resolved binding; fall back to `pass.source` for
        // graphs that don't ship a `textures[0]`.
        const textures = pass.textures ?? {};
        const slot0Ref = textures[0] ?? pass.source;
        const sourceResolved = this.resolveBoundTexture(layer.objectID, slot0Ref, currentSceneFBO, sceneSize);
        this.bindTextureSlot(program, 0, sourceResolved.texture, "g_Texture0", { width: sourceResolved.width, height: sourceResolved.height });
        this.uploadSpriteSheetUniforms(program, sourceResolved, sceneSize, time);
        boundSamplers.add("g_Texture0");

        for (const slotStr of Object.keys(textures)) {
          const slot = Number(slotStr);
          if (!Number.isInteger(slot) || slot === 0) continue;
          if (slot === PLACEHOLDER_UNIT || slot === AUDIO_UNIT) {
            const key = `${pass.id}:${slot}`;
            if (!this.reservedSlotAnnounced.has(key)) {
              this.reservedSlotAnnounced.add(key);
              sendDiagnostic("texture-slot-reserved", `Pass ${pass.id} requested reserved texture unit ${slot}; skipped (sampler falls back to placeholder).`);
            }
            continue;
          }
          const ref = textures[slot];
          if (!ref) continue;
          const { texture, width, height } = this.resolveBoundTexture(layer.objectID, ref, currentSceneFBO, sceneSize);
          const name = `g_Texture${slot}`;
          this.bindTextureSlot(program, slot, texture, name, { width, height });
          boundSamplers.add(name);
        }

        for (const sampler of prepared.samplers) {
          if (boundSamplers.has(sampler.name)) continue;
          if (sampler.name === "g_AudioSpectrum") continue;
          gl.uniform1i(sampler.location, PLACEHOLDER_UNIT);
        }

        gl.drawArrays(gl.TRIANGLES, 0, 6);

        // `previous` references resolve to `currentSceneFBO`. WPE's
        // semantics for `previous` inside an effect pass is "the layer-
        // composite state before this effect ran", NOT "the most recent
        // FBO write". Shine's pipeline writes intermediate blur results
        // to `_rt_HalfCompoBuffer*` (kind = "fbo") between layer-
        // composite ping-pongs (kind = "layer_composite"); if we update
        // `currentSceneFBO` on every FBO write, `shine_combine`'s
        // `bind: [{name: "_rt_HalfCompoBuffer2"}, {name: "previous"}]`
        // resolves slot 1 to the blur buffer instead of the original
        // albedo and the screen goes black. Only refresh from
        // layer_composite or canvas writes.
        if (targetFBO && pass.target.kind === "layer_composite") {
          currentSceneFBO = targetFBO;
        }
      }
    }

    gl.bindVertexArray(null);
  }

  dispose(): void {
    const gl = this.gl;
    if (this.vao) gl.deleteVertexArray(this.vao);
    if (this.vbo) gl.deleteBuffer(this.vbo);
    if (this.placeholderTexture) gl.deleteTexture(this.placeholderTexture);
    if (this.audioTexture) gl.deleteTexture(this.audioTexture);
    this.vao = null;
    this.vbo = null;
    this.placeholderTexture = null;
    this.audioTexture = null;
    this.graph = null;
    this.layers = [];
    this.placeholderAnnounced.clear();
    this.reservedSlotAnnounced.clear();
  }

  private initFullscreenQuad(): void {
    const gl = this.gl;
    this.vao = gl.createVertexArray();
    this.vbo = gl.createBuffer();
    if (!this.vao || !this.vbo) {
      throw new Error("RenderGraphExecutor: VAO/VBO allocation failed");
    }

    // a_Position.xy (clip space), a_TexCoord.xy
    const vertices = new Float32Array([
      -1, -1, 0, 0,
       1, -1, 1, 0,
      -1,  1, 0, 1,
      -1,  1, 0, 1,
       1, -1, 1, 0,
       1,  1, 1, 1
    ]);

    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.vbo);
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 16, 8);
    gl.bindVertexArray(null);
  }

  private applyBlending(mode: string): void {
    const gl = this.gl;
    const m = mode.toLowerCase();
    if (m === "disabled" || m === "none") {
      gl.disable(gl.BLEND);
      return;
    }
    gl.enable(gl.BLEND);
    switch (m) {
      case "additive":
      case "add":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE, gl.ONE, gl.ONE);
        break;
      case "multiply":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.DST_COLOR, gl.ZERO, gl.ZERO, gl.ONE);
        break;
      case "subtract":
        gl.blendEquation(gl.FUNC_REVERSE_SUBTRACT);
        gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE, gl.ONE, gl.ONE);
        break;
      case "translucent":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        break;
      case "negative":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.ONE_MINUS_DST_COLOR, gl.ONE_MINUS_SRC_COLOR, gl.ONE, gl.ONE);
        break;
      case "darken":
        gl.blendEquation(gl.MIN);
        gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE);
        break;
      case "lighten":
        gl.blendEquation(gl.MAX);
        gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE);
        break;
      case "premultiplied":
      case "pre-multiplied":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        break;
      case "oneoneone":
      case "one_one_one":
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ONE, gl.ONE);
        break;
      case "normal":
      default:
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        break;
    }
  }

  private applyCullMode(mode: string): void {
    const gl = this.gl;
    const m = mode.toLowerCase();
    if (m === "none" || m === "disabled") {
      gl.disable(gl.CULL_FACE);
      return;
    }
    gl.enable(gl.CULL_FACE);
    gl.cullFace(m === "front" ? gl.FRONT : gl.BACK);
  }

  private applyDepth(depthTest: string, depthWrite: string): void {
    const gl = this.gl;
    const tNormalized = depthTest.toLowerCase();
    if (tNormalized === "disabled" || tNormalized === "none" || tNormalized === "false") {
      gl.disable(gl.DEPTH_TEST);
    } else {
      gl.enable(gl.DEPTH_TEST);
      gl.depthFunc(gl.LEQUAL);
    }
    const wNormalized = depthWrite.toLowerCase();
    gl.depthMask(!(wNormalized === "disabled" || wNormalized === "none" || wNormalized === "false"));
  }

  private uploadBuiltinUniforms(
    program: WebGLProgram,
    time: number,
    runtime: { pointer?: { x: number; y: number; click: number; hover: number }; audioSpectrum?: number[] },
    layerParallax: number
  ): void {
    const gl = this.gl;
    const timeLoc = gl.getUniformLocation(program, "g_Time");
    if (timeLoc) gl.uniform1f(timeLoc, time);

    const pointerLoc = gl.getUniformLocation(program, "g_Pointer");
    if (pointerLoc) {
      const p = runtime.pointer ?? { x: 0, y: 0, click: 0, hover: 0 };
      gl.uniform4f(pointerLoc, p.x, p.y, p.click, p.hover);
    }

    const pointerPosLoc = gl.getUniformLocation(program, "g_PointerPosition");
    if (pointerPosLoc) {
      const p = runtime.pointer ?? { x: 0.5, y: 0.5, click: 0, hover: 0 };
      gl.uniform2f(pointerPosLoc, p.x, p.y);
    }

    const parallaxLoc = gl.getUniformLocation(program, "g_ParallaxDepth");
    if (parallaxLoc) gl.uniform1f(parallaxLoc, layerParallax);

    const audioLoc = gl.getUniformLocation(program, "g_AudioSpectrum");
    if (audioLoc) {
      const tex = this.getOrCreateAudioTexture();
      gl.activeTexture(gl.TEXTURE0 + AUDIO_UNIT);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      if (runtime.audioSpectrum && runtime.audioSpectrum.length > 0) {
        const data = new Float32Array(256);
        const spec = runtime.audioSpectrum;
        const limit = Math.min(spec.length, 256);
        for (let i = 0; i < limit; i++) {
          data[i] = spec[i] ?? 0;
        }
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 256, 1, gl.RED, gl.FLOAT, data);
      }
      gl.uniform1i(audioLoc, AUDIO_UNIT);
    }
  }

  // WPE's SPRITESHEET-combo shaders read UVs through `g_Texture0Translation`
  // and `g_Texture0Rotation`. Compute the frame layout from the bound
  // source texture vs the scene's render target — for vertical strips
  // (the dominant WPE convention) framesY = round(texH / sceneH); a
  // horizontal strip falls through to framesX. The uniform names mirror
  // genericimage.vert in /assets/shaders so the existing WPE shader
  // sources work unmodified.
  private uploadSpriteSheetUniforms(
    program: WebGLProgram,
    sourceTex: BoundTexture | null,
    sceneSize: { width: number; height: number },
    time: number
  ): void {
    const gl = this.gl;
    const translationLoc = gl.getUniformLocation(program, "g_Texture0Translation");
    const translationNextLoc = gl.getUniformLocation(program, "g_Texture0TranslationNext");
    const rotationLoc = gl.getUniformLocation(program, "g_Texture0Rotation");
    const blendLoc = gl.getUniformLocation(program, "g_SpriteFrameBlend");
    if (!translationLoc && !rotationLoc && !translationNextLoc && !blendLoc) return;

    const uploadIdentity = (): void => {
      if (translationLoc) gl.uniform2f(translationLoc, 0, 0);
      if (translationNextLoc) gl.uniform2f(translationNextLoc, 0, 0);
      if (rotationLoc) gl.uniform4f(rotationLoc, 1, 0, 0, 1);
      if (blendLoc) gl.uniform1f(blendLoc, 0);
    };

    if (
      !sourceTex ||
      !sourceTex.texture ||
      sourceTex.width <= 0 ||
      sourceTex.height <= 0 ||
      sceneSize.width <= 0 ||
      sceneSize.height <= 0
    ) {
      uploadIdentity();
      return;
    }

    const framesX = Math.max(1, Math.round(sourceTex.width / sceneSize.width));
    const framesY = Math.max(1, Math.round(sourceTex.height / sceneSize.height));
    if (framesX === 1 && framesY === 1) {
      uploadIdentity();
      return;
    }

    const frameCount = framesY > 1 ? framesY : framesX;
    const subFrame = Math.max(0, time) * SPRITESHEET_FRAME_RATE;
    const current = ((Math.floor(subFrame) % frameCount) + frameCount) % frameCount;
    const next = (current + 1) % frameCount;
    const blend = subFrame - Math.floor(subFrame);

    if (framesY > 1) {
      // ImageBitmap is pre-flipped via createImageBitmap({imageOrientation:
      // "flipY"}), so v = 0 reads the original image's bottom row. Sprite
      // sheets store frame 0 at the source image top, so frame F lives in
      // texture v ∈ [(N-1-F)/N, (N-F)/N]. Both the current and next
      // translations follow the same offset formula; the wrap from frame
      // N-1 → 0 happens via the `current/next` modulo above so the
      // crossfade is continuous across the loop boundary.
      if (translationLoc) gl.uniform2f(translationLoc, 0, (framesY - 1 - current) / framesY);
      if (translationNextLoc) gl.uniform2f(translationNextLoc, 0, (framesY - 1 - next) / framesY);
      if (rotationLoc) gl.uniform4f(rotationLoc, 1, 0, 0, 1 / framesY);
      if (blendLoc) gl.uniform1f(blendLoc, blend);
      return;
    }

    if (translationLoc) gl.uniform2f(translationLoc, current / framesX, 0);
    if (translationNextLoc) gl.uniform2f(translationNextLoc, next / framesX, 0);
    if (rotationLoc) gl.uniform4f(rotationLoc, 1 / framesX, 0, 0, 1);
    if (blendLoc) gl.uniform1f(blendLoc, blend);
  }

private uploadConstants(program: WebGLProgram, constants: Record<string, ConstantValue>): void {
    const gl = this.gl;
    for (const key of Object.keys(constants)) {
      const value = constants[key];
      if (!value) continue;
      const loc = gl.getUniformLocation(program, key);
      if (!loc) continue;
      switch (value.kind) {
        case "bool":
          gl.uniform1i(loc, value.value ? 1 : 0);
          break;
        case "number":
          gl.uniform1f(loc, value.value);
          break;
        case "vector":
          switch (value.value.length) {
            case 1: gl.uniform1fv(loc, value.value); break;
            case 2: gl.uniform2fv(loc, value.value); break;
            case 3: gl.uniform3fv(loc, value.value); break;
            case 4: gl.uniform4fv(loc, value.value); break;
            default: break;
          }
          break;
        case "string":
          // Strings aren't uniform-compatible; ignored at upload time.
          break;
      }
    }
  }

  private resolveBoundTexture(
    layerID: string,
    ref: TextureReference,
    currentScene: PoolFBO | null,
    sceneSize: { width: number; height: number }
  ): BoundTexture {
    if (ref.kind === "image" || ref.kind === "asset") {
      const key = ref.value ?? "(unnamed)";
      if (key !== "(unnamed)") {
        const entry = this.textureManager.get(this.assetUrl(key));
        if (entry) {
          return { texture: entry.texture, width: entry.width, height: entry.height };
        }
      }
      if (!this.placeholderAnnounced.has(key)) {
        this.placeholderAnnounced.add(key);
        sendDiagnostic("texture-placeholder", `Using placeholder texture for ${key} (asset missing or failed to load).`);
      }
      return { texture: this.getOrCreatePlaceholderTexture(), width: 1, height: 1 };
    }
    if (ref.kind === "fbo" && ref.value) {
      const resolved = this.fboPool.readTexture(layerID, ref.value);
      if (resolved) return resolved;
    }
    if (ref.kind === "previous" && currentScene) {
      return { texture: currentScene.texture, width: currentScene.width, height: currentScene.height };
    }
    return { texture: this.getOrCreatePlaceholderTexture(), width: sceneSize.width, height: sceneSize.height };
  }

  private bindTextureSlot(
    program: WebGLProgram,
    slot: number,
    texture: WebGLTexture | null,
    samplerName: string,
    resolution: { width: number; height: number }
  ): void {
    const gl = this.gl;
    gl.activeTexture(gl.TEXTURE0 + slot);
    gl.bindTexture(gl.TEXTURE_2D, texture ?? this.getOrCreatePlaceholderTexture());

    const samplerLoc = gl.getUniformLocation(program, samplerName);
    if (samplerLoc) gl.uniform1i(samplerLoc, slot);

    const resLoc = gl.getUniformLocation(program, `${samplerName}Resolution`);
    if (resLoc) {
      const w = Math.max(1, resolution.width);
      const h = Math.max(1, resolution.height);
      gl.uniform4f(resLoc, w, h, 1 / w, 1 / h);
    }
  }

  private getOrCreatePlaceholderTexture(): WebGLTexture {
    if (this.placeholderTexture) return this.placeholderTexture;
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) throw new Error("RenderGraphExecutor: placeholder texture allocation failed");
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(
      gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
      new Uint8Array([255, 0, 255, 255])
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    this.placeholderTexture = tex;
    return tex;
  }

  private getOrCreateAudioTexture(): WebGLTexture {
    if (this.audioTexture) return this.audioTexture;
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) throw new Error("RenderGraphExecutor: audio texture allocation failed");
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(
      gl.TEXTURE_2D, 0, gl.R32F, 256, 1, 0, gl.RED, gl.FLOAT,
      new Float32Array(256)
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.audioTexture = tex;
    return tex;
  }
}
