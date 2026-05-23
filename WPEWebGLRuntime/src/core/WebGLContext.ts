// Wraps WebGL2 context creation with the precise attributes Phase 1 needs.
// Phase 3 will extend this with state caching (lastBoundProgram, lastFBO, etc.)
// to avoid redundant GL calls per pass.

export interface WebGLContextProbeResult {
  ok: boolean;
  reason?: string;
  contextAttributes?: WebGLContextAttributes;
  extensions?: string[];
}

export function createWebGL2Context(canvas: HTMLCanvasElement): WebGL2RenderingContext | null {
  const attributes: WebGLContextAttributes = {
    alpha: false,
    antialias: false,
    depth: true,
    stencil: false,
    premultipliedAlpha: false,
    preserveDrawingBuffer: false,
    powerPreference: "high-performance",
    failIfMajorPerformanceCaveat: false
  };
  return canvas.getContext("webgl2", attributes);
}

export function resizeToDisplay(canvas: HTMLCanvasElement, gl: WebGL2RenderingContext): boolean {
  const dpr = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth;
  const cssHeight = canvas.clientHeight;
  const targetWidth = Math.max(1, Math.round(cssWidth * dpr));
  const targetHeight = Math.max(1, Math.round(cssHeight * dpr));
  if (canvas.width !== targetWidth || canvas.height !== targetHeight) {
    canvas.width = targetWidth;
    canvas.height = targetHeight;
    gl.viewport(0, 0, targetWidth, targetHeight);
    return true;
  }
  return false;
}

export function probeContextLossExtension(gl: WebGL2RenderingContext): WEBGL_lose_context | null {
  return gl.getExtension("WEBGL_lose_context") as WEBGL_lose_context | null;
}
