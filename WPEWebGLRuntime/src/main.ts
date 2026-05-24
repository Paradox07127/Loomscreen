import { createWebGL2Context, probeContextLossExtension, resizeToDisplay } from "./core/WebGLContext";
import { RenderGraphExecutor } from "./core/RenderGraphExecutor";
import { ShaderCompiler } from "./resources/ShaderCompiler";
import { FramebufferPool } from "./resources/FramebufferPool";
import { TextureManager } from "./resources/TextureManager";
import {
  normalizeEnvelope,
  normalizeRuntimeState,
  type HostBridgeApi,
  type PipelineEnvelope,
  type RuntimeStatePayload,
  sendDiagnostic,
  sendError,
  sendLoadFailed,
  sendReady,
  sendSceneLoaded
} from "./bridge/HostBridge";

interface RuntimeState {
  envelope: PipelineEnvelope | null;
  state: RuntimeStatePayload | null;
  rafHandle: number | null;
  timerHandle: number | null;
  isRunning: boolean;
  startedAt: number;
}

function bootstrap(): void {
  const canvasEl = document.getElementById("wpe-canvas") as HTMLCanvasElement | null;
  if (!canvasEl) {
    sendError("bootstrap", "missing #wpe-canvas element");
    return;
  }
  const canvas: HTMLCanvasElement = canvasEl;

  const glOrNull = createWebGL2Context(canvas);
  if (!glOrNull) {
    sendError("bootstrap", "WebGL2 unavailable in WKWebView");
    return;
  }
  const gl: WebGL2RenderingContext = glOrNull;

  resizeToDisplay(canvas, gl);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);

  const loseContext = probeContextLossExtension(gl);

  const shaderCompiler = new ShaderCompiler(gl);
  const fboPool = new FramebufferPool(gl);
  let textureManager = new TextureManager(gl);
  let executor: RenderGraphExecutor | null = new RenderGraphExecutor(gl, shaderCompiler, fboPool, textureManager);

  const runtime: RuntimeState = {
    envelope: null,
    state: null,
    rafHandle: null,
    timerHandle: null,
    isRunning: false,
    startedAt: performance.now()
  };

  const api: HostBridgeApi = {
    loadScene(rawEnvelope) {
      void loadSceneAsync(rawEnvelope);
    },
    pushRuntimeState(rawState) {
      const state = normalizeRuntimeState(rawState);
      runtime.state = state;
      cancelScheduled();
      switch (state.visibility) {
        case "background":
          runtime.isRunning = false;
          break;
        case "active":
        case "occluded":
        case null:
        case undefined:
          runtime.isRunning = true;
          schedule();
          break;
      }
    },
    unloadCurrentScene() {
      runtime.envelope = null;
      runtime.isRunning = false;
      cancelScheduled();
      if (executor) {
        executor.dispose();
        executor = null;
      }
      fboPool.releaseAll();
      textureManager.dispose();
      textureManager = new TextureManager(gl);
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
    }
  };

  window.__wpeHost = api;

  async function loadSceneAsync(rawEnvelope: unknown): Promise<void> {
    try {
      const envelope = normalizeEnvelope(rawEnvelope);
      runtime.envelope = envelope;

      if (executor) executor.dispose();
      fboPool.releaseAll();
      textureManager.dispose();
      textureManager = new TextureManager(gl);
      executor = new RenderGraphExecutor(gl, shaderCompiler, fboPool, textureManager);

      if (envelope.renderGraph) {
        const res = await executor.load(envelope.renderGraph, envelope.assetScheme.urlPrefix);
        if (!res.ok) {
          sendLoadFailed("render-graph-load", res.error ?? "Unknown render-graph load error");
          return;
        }
      } else {
        sendDiagnostic("scene", `Envelope for scene ${envelope.sceneID} has no render graph; canvas will stay cleared.`);
      }

      runtime.isRunning = true;
      runtime.startedAt = performance.now();
      sendDiagnostic("scene", `Scene ${envelope.sceneID} loaded with ${envelope.renderGraph?.layers.length ?? 0} layers.`);
      schedule();
      sendSceneLoaded(envelope.sceneID);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      sendLoadFailed("loadScene", message);
    }
  }

  canvas.addEventListener("webglcontextlost", (event) => {
    event.preventDefault();
    runtime.isRunning = false;
    cancelScheduled();
    sendError("context", "WebGL2 context lost");
  });

  canvas.addEventListener("webglcontextrestored", () => {
    sendDiagnostic("context", "WebGL2 context restored");
    if (runtime.envelope) {
      runtime.isRunning = true;
      schedule();
    }
  });

  function cancelScheduled(): void {
    if (runtime.rafHandle !== null) {
      cancelAnimationFrame(runtime.rafHandle);
      runtime.rafHandle = null;
    }
    if (runtime.timerHandle !== null) {
      clearTimeout(runtime.timerHandle);
      runtime.timerHandle = null;
    }
  }

  function schedule(): void {
    if (!runtime.isRunning) return;
    if (runtime.rafHandle !== null || runtime.timerHandle !== null) return;
    if (runtime.state?.visibility === "occluded") {
      runtime.timerHandle = window.setTimeout(tick, 1000);
    } else {
      runtime.rafHandle = requestAnimationFrame(tick);
    }
  }

  function tick(): void {
    runtime.rafHandle = null;
    runtime.timerHandle = null;
    if (!runtime.isRunning) return;
    resizeToDisplay(canvas, gl);

    const t = runtime.state?.time ?? ((performance.now() - runtime.startedAt) / 1000);
    const pointer = runtime.state?.pointer ?? undefined;
    const audioSpectrum = runtime.state?.audioSpectrum ?? undefined;

    if (executor) {
      executor.drawFrame(t, { pointer, audioSpectrum });
    } else {
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
    }

    schedule();
  }

  sendReady();
  void loseContext;
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrap, { once: true });
} else {
  bootstrap();
}
