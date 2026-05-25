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
  sendFrame,
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
  frameIndex: number;
  lastFrameReportAt: number;
}

// Heartbeat cadence for the `frame` host event. The Swift inspector only
// needs the first frame to flip `hasPresentedFrame`; subsequent reports keep
// the corpus harness FPS estimate fresh without flooding the WK bridge.
const FRAME_REPORT_INTERVAL_MS = 1000;

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
    startedAt: performance.now(),
    frameIndex: 0,
    lastFrameReportAt: 0
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
      runtime.frameIndex = 0;
      runtime.lastFrameReportAt = 0;
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

    runtime.frameIndex += 1;
    const now = performance.now();
    // First frame must report so the Swift inspector flips
    // `hasPresentedFrame` and exits the loading spinner. Subsequent reports
    // are throttled to ~1Hz to keep the WK message bridge quiet.
    if (
      runtime.frameIndex === 1 ||
      now - runtime.lastFrameReportAt >= FRAME_REPORT_INTERVAL_MS
    ) {
      sendFrame(runtime.frameIndex, now - runtime.startedAt);
      runtime.lastFrameReportAt = now;
    }
    if (runtime.frameIndex === 1) {
      // Black-screen forensics: surface canvas + drawing-buffer
      // dimensions on the first tick so we can tell a zero-sized canvas
      // ("loaded but invisible") apart from a real output bug ("loaded
      // and ticking but pixels wrong"). Logs once per session.
      sendDiagnostic(
        "canvas",
        `first-tick canvas=${canvas.width}x${canvas.height} ` +
        `drawing=${gl.drawingBufferWidth}x${gl.drawingBufferHeight} ` +
        `client=${canvas.clientWidth}x${canvas.clientHeight}`
      );
      // Read the center pixel of the default framebuffer. This is the
      // GROUND-TRUTH for what the GPU actually output — distinguishes
      // "shader produced black pixels" from "everything works but
      // something composites the canvas away".
      try {
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        const px = new Uint8Array(4);
        const cx = Math.floor(gl.drawingBufferWidth / 2);
        const cy = Math.floor(gl.drawingBufferHeight / 2);
        gl.readPixels(cx, cy, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
        sendDiagnostic(
          "canvas-pixel",
          `first-tick center=(${cx},${cy}) rgba=(${px[0]},${px[1]},${px[2]},${px[3]})`
        );
      } catch (e) {
        sendDiagnostic("canvas-pixel", `readPixels failed: ${e instanceof Error ? e.message : String(e)}`);
      }
      // Per-FBO center pixels — the canvas-pixel above only tells us
      // the final composite. To isolate WHICH pass produced black we
      // dump every live pool FBO's center pixel. The first non-black
      // intermediate identifies where the chain is still healthy;
      // everything after is the suspect.
      try {
        executor?.dumpFBOCenterPixels();
      } catch (e) {
        sendDiagnostic("fbo-pixel", `dumpFBOCenterPixels failed: ${e instanceof Error ? e.message : String(e)}`);
      }
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
