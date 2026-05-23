import { sendDiagnostic } from "../bridge/HostBridge";

interface TextureEntry {
  texture: WebGLTexture;
  width: number;
  height: number;
  bytes: number;
}

interface VideoEntry {
  texture: WebGLTexture;
  width: number;
  height: number;
  bytes: number;
  video: HTMLVideoElement;
  url: string;
  /// Set once `loadedmetadata` fires so refresh() knows the texture
  /// dimensions are valid. Before that, the texture is a 1×1 placeholder.
  dimensionsReady: boolean;
  /// Monotonic stamp of the latest uploaded frame, used to dedupe
  /// per-frame uploads when the `<video>` hasn't advanced.
  lastFrameStamp: number;
}

// LRU cap on resident GPU texture memory.
const DEFAULT_BYTE_BUDGET = 256 * 1024 * 1024;

const VIDEO_EXTENSIONS = new Set(["mp4", "webm", "mov", "m4v"]);

function isVideoURL(url: string): boolean {
  const dotIndex = url.lastIndexOf(".");
  if (dotIndex < 0) return false;
  const ext = url.slice(dotIndex + 1).toLowerCase().split(/[?#]/)[0] ?? "";
  return VIDEO_EXTENSIONS.has(ext);
}

export class TextureManager {
  private gl: WebGL2RenderingContext;
  // Static images. Map preserves insertion order; re-insert on access for LRU.
  private cache: Map<string, TextureEntry> = new Map();
  // Video-backed textures. Not LRU-managed (capped by scene lifetime).
  private videos: Map<string, VideoEntry> = new Map();
  private failedURLs: Set<string> = new Set();
  // In-flight Promise dedup so two concurrent ensureLoaded calls for
  // the same URL don't double-upload (Phase 5 audit Medium).
  private pending: Map<string, Promise<TextureEntry | null>> = new Map();
  private totalBytes: number = 0;
  private byteBudget: number;

  constructor(gl: WebGL2RenderingContext, byteBudget: number = DEFAULT_BYTE_BUDGET) {
    this.gl = gl;
    this.byteBudget = byteBudget;
  }

  async ensureLoaded(url: string): Promise<TextureEntry | null> {
    const existing = this.cache.get(url);
    if (existing) {
      this.touchLRU(url, existing);
      return existing;
    }
    const videoEntry = this.videos.get(url);
    if (videoEntry) {
      return this.entryFromVideo(videoEntry);
    }
    if (this.failedURLs.has(url)) return null;
    const inflight = this.pending.get(url);
    if (inflight) return inflight;

    const promise = (async () => {
      try {
        if (isVideoURL(url)) {
          return this.loadVideo(url);
        }
        return await this.loadImage(url);
      } finally {
        this.pending.delete(url);
      }
    })();
    this.pending.set(url, promise);
    return promise;
  }

  async preloadAll(urls: Iterable<string>): Promise<{ loaded: number; failed: string[] }> {
    const unique = Array.from(new Set(urls));
    const results = await Promise.allSettled(unique.map((u) => this.ensureLoaded(u)));
    const failed: string[] = [];
    let loaded = 0;
    for (let i = 0; i < results.length; i++) {
      const r = results[i];
      const url = unique[i] ?? "";
      if (r && r.status === "fulfilled" && r.value !== null) {
        loaded++;
      } else if (url) {
        failed.push(url);
      }
    }
    return { loaded, failed };
  }

  get(url: string): TextureEntry | null {
    const entry = this.cache.get(url);
    if (entry) {
      this.touchLRU(url, entry);
      return entry;
    }
    const video = this.videos.get(url);
    if (video) return this.entryFromVideo(video);
    return null;
  }

  // Walks every video entry once per frame. Each `<video>` advances its
  // own playback head; we sample the current frame into the texture if
  // it's actually changed since the last upload.
  refreshVideoFrames(): void {
    if (this.videos.size === 0) return;
    const gl = this.gl;
    for (const entry of this.videos.values()) {
      const v = entry.video;
      if (v.readyState < v.HAVE_CURRENT_DATA) continue;
      if (!entry.dimensionsReady && v.videoWidth > 0 && v.videoHeight > 0) {
        entry.width = v.videoWidth;
        entry.height = v.videoHeight;
        entry.bytes = v.videoWidth * v.videoHeight * 4;
        entry.dimensionsReady = true;
      }
      const stamp = v.currentTime;
      if (stamp === entry.lastFrameStamp) continue;
      entry.lastFrameStamp = stamp;
      gl.bindTexture(gl.TEXTURE_2D, entry.texture);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, v);
    }
  }

  dispose(): void {
    const gl = this.gl;
    for (const entry of this.cache.values()) {
      gl.deleteTexture(entry.texture);
    }
    this.cache.clear();
    for (const entry of this.videos.values()) {
      gl.deleteTexture(entry.texture);
      entry.video.onerror = null;
      try { entry.video.pause(); } catch { /* noop */ }
      entry.video.removeAttribute("src");
      entry.video.load();
      entry.video.remove();
    }
    this.videos.clear();
    this.failedURLs.clear();
    this.pending.clear();
    this.totalBytes = 0;
  }

  private async loadImage(url: string): Promise<TextureEntry | null> {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        this.failedURLs.add(url);
        sendDiagnostic("texture-fetch-failed", `HTTP ${response.status} for ${url}`);
        return null;
      }
      // WPE `.tex` files can wrap an animated MP4. Swift lifts the MP4
      // bytes and serves them with `video/mp4` even when the URL has no
      // `.mp4` suffix, so check the response MIME and route to the
      // `<video>` pipeline using a blob URL (avoids a second fetch
      // through the scheme handler).
      const mimeType = (response.headers.get("content-type") || "").toLowerCase();
      if (mimeType.startsWith("video/")) {
        const blob = await response.blob();
        const blobURL = URL.createObjectURL(blob);
        return this.loadVideo(url, blobURL);
      }
      const blob = await response.blob();
      const bitmap = await createImageBitmap(blob, { colorSpaceConversion: "none" });
      const entry = this.uploadBitmap(bitmap);
      bitmap.close();
      this.insertWithEviction(url, entry);
      return entry;
    } catch (err) {
      this.failedURLs.add(url);
      const message = err instanceof Error ? err.message : String(err);
      sendDiagnostic("texture-load-failed", `${url}: ${message}`);
      return null;
    }
  }

  // Creates a hidden `<video>` element, starts muted-looped playback,
  // and returns a 1×1 placeholder entry immediately. refreshVideoFrames
  // upgrades dimensions + uploads the first real frame as soon as
  // metadata + frames are available. Returning a placeholder keeps
  // `executor.load()` from blocking on video decode (which can take
  // hundreds of ms in WebKit).
  //
  // `srcOverride` lets `loadImage` reuse already-fetched MP4 bytes via a
  // blob URL instead of letting the `<video>` element re-fetch through
  // the wpe-asset scheme handler.
  private loadVideo(url: string, srcOverride?: string): TextureEntry {
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) {
      this.failedURLs.add(url);
      sendDiagnostic("video-load-failed", `Failed to allocate texture for ${url}`);
      return { texture: this.makePlaceholder(), width: 1, height: 1, bytes: 4 };
    }
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(
      gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
      new Uint8Array([0, 0, 0, 255])
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    const video = document.createElement("video");
    video.crossOrigin = "anonymous";
    video.muted = true;
    video.loop = true;
    video.playsInline = true;
    video.preload = "auto";
    video.style.position = "fixed";
    video.style.width = "1px";
    video.style.height = "1px";
    video.style.left = "-1px";
    video.style.top = "-1px";
    video.style.opacity = "0";
    video.style.pointerEvents = "none";
    document.body.appendChild(video);

    const entry: VideoEntry = {
      texture: tex,
      width: 1,
      height: 1,
      bytes: 4,
      video,
      url,
      dimensionsReady: false,
      lastFrameStamp: -1
    };
    this.videos.set(url, entry);

    // Using `onerror` (not addEventListener) so dispose() can clear the
    // handler without retaining the function or accidentally firing on a
    // detached element.
    video.onerror = () => {
      this.failedURLs.add(url);
      const code = video.error?.code ?? -1;
      sendDiagnostic("video-load-failed", `<video> error ${code} for ${url}`);
    };
    video.src = srcOverride ?? url;
    void video.play().catch((err) => {
      sendDiagnostic("video-play-blocked", `${url}: ${err instanceof Error ? err.message : String(err)}`);
    });

    return this.entryFromVideo(entry);
  }

  private entryFromVideo(entry: VideoEntry): TextureEntry {
    return {
      texture: entry.texture,
      width: entry.dimensionsReady ? entry.width : 1,
      height: entry.dimensionsReady ? entry.height : 1,
      bytes: entry.bytes
    };
  }

  private touchLRU(url: string, entry: TextureEntry): void {
    this.cache.delete(url);
    this.cache.set(url, entry);
  }

  private insertWithEviction(url: string, entry: TextureEntry): void {
    this.cache.set(url, entry);
    this.totalBytes += entry.bytes;
    while (this.totalBytes > this.byteBudget && this.cache.size > 1) {
      const oldest = this.cache.keys().next().value;
      if (oldest === url || oldest === undefined) break;
      const victim = this.cache.get(oldest);
      if (!victim) {
        this.cache.delete(oldest);
        continue;
      }
      this.gl.deleteTexture(victim.texture);
      this.totalBytes -= victim.bytes;
      this.cache.delete(oldest);
      sendDiagnostic("texture-evicted", `LRU evicted ${oldest} (${(victim.bytes / 1024 / 1024).toFixed(1)} MB)`);
    }
  }

  private uploadBitmap(bitmap: ImageBitmap): TextureEntry {
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) throw new Error("TextureManager: createTexture returned null");
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
    const isPoT = isPowerOfTwo(bitmap.width) && isPowerOfTwo(bitmap.height);
    if (isPoT) {
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    } else {
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    }
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    const baseBytes = bitmap.width * bitmap.height * 4;
    const bytes = isPoT ? Math.round(baseBytes * 1.333) : baseBytes;
    return {
      texture: tex,
      width: bitmap.width,
      height: bitmap.height,
      bytes
    };
  }

  private makePlaceholder(): WebGLTexture {
    const gl = this.gl;
    const tex = gl.createTexture();
    if (!tex) throw new Error("TextureManager: placeholder allocation failed");
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(
      gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
      new Uint8Array([255, 0, 255, 255])
    );
    return tex;
  }
}

function isPowerOfTwo(n: number): boolean {
  return n > 0 && (n & (n - 1)) === 0;
}
