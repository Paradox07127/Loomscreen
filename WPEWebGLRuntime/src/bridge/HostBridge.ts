/// <reference types="vite/client" />
// Swift ↔ JS message bridge. Mirrors LiveWallpaper/Runtime/WPEWebGLBridge.swift
// and LiveWallpaper/Models/WPEPipelineEnvelope.swift exactly — keep this file
// in sync with the Swift types when extending the protocol.

// Top-level envelope payload — uses camelCase on JS side, but JSON
// arrives with snake_case keys from Swift. Decoder normalizes via a
// thin adapter before constructing typed objects (see `normalizeEnvelope`).
export interface PipelineEnvelope {
  version: number;
  sceneID: string;
  sceneTitle?: string | null;
  assetScheme: AssetSchemeBinding;
  renderGraph?: RenderGraphPayload | null;
}

export interface AssetSchemeBinding {
  nonce: string;
  urlPrefix: string;
}

export interface RenderGraphPayload {
  layers: RenderLayerPayload[];
  sceneSize: { width: number; height: number };
  orthogonalProjection: { width: number; height: number };
}

export interface RenderLayerPayload {
  objectID: string;
  objectName: string;
  imagePath: string;
  materialPath?: string | null;
  compositeA: string;
  compositeB: string;
  parallaxDepth: number;
  localFBOs: RenderFBOPayload[];
  passes: RenderPassPayload[];
}

export interface RenderFBOPayload {
  name: string;
  scale: number;
  format: string;
  unique: boolean;
}

export interface RenderPassPayload {
  id: string;
  shaderName: string;
  vertexSource: string;
  fragmentSource: string;
  isBuiltin: boolean;
  target: TargetReference;
  source: TextureReference;
  textures: Record<number, TextureReference>;
  binds: Record<number, TextureReference>;
  constants: Record<string, ConstantValue>;
  combos: Record<string, number>;
  blending: string;
  cullMode: string;
  depthTest: string;
  depthWrite: string;
}

export interface TargetReference {
  kind: "scene" | "fbo" | "layer_composite";
  name?: string | null;
}

export interface TextureReference {
  kind: "image" | "asset" | "fbo" | "previous";
  value?: string | null;
}

export type ConstantValue =
  | { kind: "bool"; value: boolean }
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "vector"; value: number[] };

// Pool-managed framebuffer with ping-pong companion texture.
export interface PoolFBO {
  framebuffer: WebGLFramebuffer;
  texture: WebGLTexture;
  tempTexture: WebGLTexture;
  width: number;
  height: number;
  format: string;
}

// Normalize the snake_case JSON Swift sends into the camelCase
// interfaces above. Mutates a structured-clone-safe copy in place so
// downstream consumers can stay in TS land.
export function normalizeEnvelope(raw: unknown): PipelineEnvelope {
  const r = raw as Record<string, unknown>;
  return {
    version: r.version as number,
    sceneID: (r.scene_id ?? r.sceneID) as string,
    sceneTitle: (r.scene_title ?? r.sceneTitle ?? null) as string | null,
    assetScheme: normalizeAssetScheme(r.asset_scheme ?? r.assetScheme),
    renderGraph: r.render_graph
      ? normalizeRenderGraph(r.render_graph)
      : r.renderGraph
      ? (r.renderGraph as RenderGraphPayload)
      : null
  };
}

function normalizeAssetScheme(raw: unknown): AssetSchemeBinding {
  const r = raw as Record<string, unknown>;
  return {
    nonce: r.nonce as string,
    urlPrefix: (r.url_prefix ?? r.urlPrefix) as string
  };
}

function normalizeRenderGraph(raw: unknown): RenderGraphPayload {
  const r = raw as Record<string, unknown>;
  const sceneSizeRaw = (r.scene_size ?? r.sceneSize) as Record<string, number>;
  const projectionRaw = (r.orthogonal_projection ?? r.orthogonalProjection) as Record<string, number>;
  const layersRaw = (r.layers ?? []) as unknown[];
  return {
    sceneSize: {
      width: sceneSizeRaw?.width ?? 1920,
      height: sceneSizeRaw?.height ?? 1080
    },
    orthogonalProjection: {
      width: projectionRaw?.width ?? 1920,
      height: projectionRaw?.height ?? 1080
    },
    layers: layersRaw.map(normalizeLayer)
  };
}

function normalizeLayer(raw: unknown): RenderLayerPayload {
  const r = raw as Record<string, unknown>;
  const fbosRaw = (r.local_fbos ?? r.localFBOs ?? []) as unknown[];
  const passesRaw = (r.passes ?? []) as unknown[];
  return {
    objectID: (r.object_id ?? r.objectID) as string,
    objectName: (r.object_name ?? r.objectName) as string,
    imagePath: (r.image_path ?? r.imagePath ?? "") as string,
    materialPath: (r.material_path ?? r.materialPath ?? null) as string | null,
    compositeA: (r.composite_a ?? r.compositeA ?? "") as string,
    compositeB: (r.composite_b ?? r.compositeB ?? "") as string,
    parallaxDepth: (r.parallax_depth ?? r.parallaxDepth ?? 0) as number,
    localFBOs: fbosRaw.map((f) => f as RenderFBOPayload),
    passes: passesRaw.map(normalizePass)
  };
}

function normalizePass(raw: unknown): RenderPassPayload {
  const r = raw as Record<string, unknown>;
  return {
    id: r.id as string,
    shaderName: (r.shader_name ?? r.shaderName) as string,
    vertexSource: (r.vertex_source ?? r.vertexSource ?? "") as string,
    fragmentSource: (r.fragment_source ?? r.fragmentSource ?? "") as string,
    isBuiltin: ((r.is_builtin ?? r.isBuiltin) as boolean) ?? false,
    target: r.target as TargetReference,
    source: r.source as TextureReference,
    textures: (r.textures ?? {}) as Record<number, TextureReference>,
    binds: (r.binds ?? {}) as Record<number, TextureReference>,
    constants: (r.constants ?? {}) as Record<string, ConstantValue>,
    combos: (r.combos ?? {}) as Record<string, number>,
    blending: (r.blending ?? "Normal") as string,
    cullMode: (r.cull_mode ?? r.cullMode ?? "None") as string,
    depthTest: (r.depth_test ?? r.depthTest ?? "Disabled") as string,
    depthWrite: (r.depth_write ?? r.depthWrite ?? "Disabled") as string
  };
}

export interface RuntimeStatePayload {
  time: number;
  pointer?: { x: number; y: number; click: number; hover: number } | null;
  audioSpectrum?: number[] | null;
  visibility?: "active" | "occluded" | "background" | null;
}

export type OutgoingEvent =
  | { event: "ready"; scene_id?: string }
  | { event: "scene_loaded"; scene_id?: string }
  | { event: "load_failed"; stage: string; pass_id?: string; message: string }
  | { event: "error"; stage: string; pass_id?: string; message: string }
  | { event: "diagnostic"; kind: string; message: string }
  | { event: "frame"; frame_index: number; elapsed_ms: number }
  | { event: "readback"; width: number; height: number; data_b64: string };

interface WebKitMessageHandler {
  postMessage(message: unknown): void;
}

interface WebKitBridge {
  messageHandlers: Record<string, WebKitMessageHandler>;
}

declare global {
  interface Window {
    webkit?: WebKitBridge;
    __wpeHost?: HostBridgeApi;
  }
}

// Swift sends raw JSON objects; consumer code in main.ts must
// normalize via normalizeEnvelope / normalizeRuntimeState before use.
export interface HostBridgeApi {
  loadScene(rawEnvelope: unknown): void;
  pushRuntimeState(rawState: unknown): void;
  unloadCurrentScene(): void;
}

export function normalizeRuntimeState(raw: unknown): RuntimeStatePayload {
  const r = (raw ?? {}) as Record<string, unknown>;
  const pointerRaw = r.pointer as Record<string, number> | undefined | null;
  const audio = r.audio_spectrum ?? r.audioSpectrum;
  return {
    time: (r.time as number) ?? 0,
    pointer: pointerRaw
      ? {
          x: pointerRaw.x ?? 0,
          y: pointerRaw.y ?? 0,
          click: pointerRaw.click ?? 0,
          hover: pointerRaw.hover ?? 0
        }
      : null,
    audioSpectrum: Array.isArray(audio) ? (audio as number[]) : null,
    visibility: (r.visibility as RuntimeStatePayload["visibility"]) ?? null
  };
}

export function send(event: OutgoingEvent): void {
  const handler = window.webkit?.messageHandlers?.wpe;
  if (!handler) {
    if (import.meta.env?.DEV) {
      console.warn("[wpe] no Swift bridge — message dropped:", event);
    }
    return;
  }
  handler.postMessage(event);
}

export function sendError(stage: string, message: string, passID?: string): void {
  const payload: OutgoingEvent = passID
    ? { event: "error", stage, pass_id: passID, message }
    : { event: "error", stage, message };
  send(payload);
}

export function sendDiagnostic(kind: string, message: string): void {
  send({ event: "diagnostic", kind, message });
}

export function sendReady(sceneID?: string): void {
  send(sceneID ? { event: "ready", scene_id: sceneID } : { event: "ready" });
}

export function sendSceneLoaded(sceneID?: string): void {
  send(sceneID ? { event: "scene_loaded", scene_id: sceneID } : { event: "scene_loaded" });
}

export function sendLoadFailed(stage: string, message: string, passID?: string): void {
  const payload: OutgoingEvent = passID
    ? { event: "load_failed", stage, pass_id: passID, message }
    : { event: "load_failed", stage, message };
  send(payload);
}

export function sendFrame(frameIndex: number, elapsedMs: number): void {
  send({ event: "frame", frame_index: frameIndex, elapsed_ms: elapsedMs });
}
