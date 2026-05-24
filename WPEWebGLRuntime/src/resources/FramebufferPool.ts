import {
  sendDiagnostic,
  type PoolFBO,
  type RenderFBOPayload,
  type TargetReference,
  type TextureReference
} from "../bridge/HostBridge";

export class FramebufferPool {
  private gl: WebGL2RenderingContext;
  private fbos: Map<string, PoolFBO> = new Map();
  private currentTargetKey: string | null = null;
  private swappedCurrentTargets: Set<string> = new Set();
  private reportedUnknownFormats: Set<string> = new Set();

  constructor(gl: WebGL2RenderingContext) {
    this.gl = gl;
  }

  resolveTarget(
    layerID: string,
    target: TargetReference,
    sceneSize: { width: number; height: number },
    localFBOs: RenderFBOPayload[]
  ): PoolFBO | null {
    // "scene" → bind canvas; "fbo" + "layer_composite" → bind a pool entry.
    // The layer_composite kind is a layer-scoped name-keyed allocation (the
    // compositeA/compositeB ping-pong buffers WPE materials emit into) — it
    // shares the (layerID, name) key space with explicit named FBOs.
    if ((target.kind !== "fbo" && target.kind !== "layer_composite") || !target.name) {
      const gl = this.gl;
      this.currentTargetKey = null;
      this.swappedCurrentTargets.clear();
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      // Reset viewport — the previous FBO bind set it to (0,0,fbo.w,fbo.h);
      // canvas writes must restore the drawing-buffer dimensions or the
      // scene pass will render at the stale FBO size.
      gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
      return null;
    }

    const key = `${layerID}:${target.name}`;
    this.currentTargetKey = key;
    this.swappedCurrentTargets.delete(key);

    const config = localFBOs.find((f) => f.name === target.name) ?? {
      name: target.name,
      scale: 1.0,
      format: "RGBA8",
      unique: false
    };
    const w = Math.max(1, Math.round(sceneSize.width * config.scale));
    const h = Math.max(1, Math.round(sceneSize.height * config.scale));

    let fbo = this.fbos.get(key);
    if (!fbo || fbo.width !== w || fbo.height !== h || fbo.format !== config.format) {
      if (fbo) {
        this.deleteFBO(fbo);
      }
      fbo = this.createFBO(w, h, config.format);
      this.fbos.set(key, fbo);
    }

    this.gl.bindFramebuffer(this.gl.FRAMEBUFFER, fbo.framebuffer);
    this.gl.viewport(0, 0, w, h);
    return fbo;
  }

  // Ping-pong: when source and target are the same FBO, swap the active
  // colour attachment with the companion `tempTexture` so the shader can
  // sample the previous contents while writing fresh pixels.
  resolveSource(
    layerID: string,
    source: TextureReference,
    currentScene: PoolFBO | null
  ): WebGLTexture | null {
    if (source.kind === "fbo" && source.value) {
      const key = `${layerID}:${source.value}`;
      const fbo = this.fbos.get(key);
      if (!fbo) return null;
      return this.readTextureForKey(key, fbo);
    }
    if (source.kind === "previous" && currentScene) {
      return currentScene.texture;
    }
    return null;
  }

  getFBO(layerID: string, name: string): PoolFBO | null {
    return this.fbos.get(`${layerID}:${name}`) ?? null;
  }

  // Same ping-pong-aware read path as `resolveSource`, but exposed as
  // a query so multi-texture-slot consumers (e.g. RenderGraphExecutor's
  // bound textures map) can read from an FBO that may currently be the
  // active render target without creating a feedback loop.
  readTexture(layerID: string, name: string): { texture: WebGLTexture; width: number; height: number } | null {
    const key = `${layerID}:${name}`;
    const fbo = this.fbos.get(key);
    if (!fbo) return null;
    const texture = this.readTextureForKey(key, fbo);
    return { texture, width: fbo.width, height: fbo.height };
  }

  releaseAll(): void {
    for (const fbo of this.fbos.values()) {
      this.deleteFBO(fbo);
    }
    this.fbos.clear();
    this.currentTargetKey = null;
    this.swappedCurrentTargets.clear();
  }

  private readTextureForKey(key: string, fbo: PoolFBO): WebGLTexture {
    if (this.currentTargetKey !== key) {
      return fbo.texture;
    }
    if (!this.swappedCurrentTargets.has(key)) {
      const gl = this.gl;
      const previousTexture = fbo.texture;
      const newWriteTexture = fbo.tempTexture;
      gl.framebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0,
        gl.TEXTURE_2D,
        newWriteTexture,
        0
      );
      fbo.texture = newWriteTexture;
      fbo.tempTexture = previousTexture;
      this.swappedCurrentTargets.add(key);
    }
    return fbo.tempTexture;
  }

  private createFBO(width: number, height: number, format: string): PoolFBO {
    const gl = this.gl;
    const { internalFormat, format: glFormat, type } = this.mapFormat(format);

    const framebuffer = gl.createFramebuffer();
    if (!framebuffer) {
      throw new Error("FramebufferPool: createFramebuffer returned null");
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);

    const texture = this.allocTexture(width, height, internalFormat, glFormat, type);
    const tempTexture = this.allocTexture(width, height, internalFormat, glFormat, type);
    if (!texture || !tempTexture) {
      if (texture) gl.deleteTexture(texture);
      if (tempTexture) gl.deleteTexture(tempTexture);
      gl.deleteFramebuffer(framebuffer);
      throw new Error("FramebufferPool: texture allocation failed");
    }

    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);

    return {
      framebuffer,
      texture,
      tempTexture,
      width,
      height,
      format
    };
  }

  private allocTexture(
    width: number,
    height: number,
    internalFormat: number,
    format: number,
    type: number
  ): WebGLTexture | null {
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) return null;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, internalFormat, width, height, 0, format, type, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return tex;
  }

  private deleteFBO(fbo: PoolFBO): void {
    const gl = this.gl;
    gl.deleteFramebuffer(fbo.framebuffer);
    gl.deleteTexture(fbo.texture);
    gl.deleteTexture(fbo.tempTexture);
  }

  private mapFormat(formatStr: string): { internalFormat: number; format: number; type: number } {
    const gl = this.gl;
    const fmt = formatStr.toUpperCase();
    switch (fmt) {
      case "":
      case "RGBA8":
        return { internalFormat: gl.RGBA8, format: gl.RGBA, type: gl.UNSIGNED_BYTE };
      case "R8":
        return { internalFormat: gl.R8, format: gl.RED, type: gl.UNSIGNED_BYTE };
      case "RGBA16F":
        return { internalFormat: gl.RGBA16F, format: gl.RGBA, type: gl.HALF_FLOAT };
      default:
        if (!this.reportedUnknownFormats.has(fmt)) {
          this.reportedUnknownFormats.add(fmt);
          sendDiagnostic("fbo-format-fallback", `Unknown FBO format "${formatStr}" — falling back to RGBA8.`);
        }
        return { internalFormat: gl.RGBA8, format: gl.RGBA, type: gl.UNSIGNED_BYTE };
    }
  }
}
