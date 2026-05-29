# Stage A — Texture / Package / Model DECODE

**References:** `linux-wallpaperengine` `TextureParser.cpp`/`Texture.h`/`CTexture.cpp`, `docs/textures/TEXTURE_FORMAT.md`, RePKG/DeepWiki. **Real data:** 9 `.tex` extracted from 3 `scene.pkg` in `431960/` (TEXV0005 / TEXI0001 / TEXB0004), byte-counts validated.

## Checklist

| format/decode point | impl (file:line) | verdict | note |
|---|---|---|---|
| Container magic `TEXV` + trailing-version parse | WPETexDecoder.swift:336-340 | ✅ | Real files all `TEXV0005`; prefix-match correct |
| `TEXI` magic + 7-field header (fmt,flags,texW,texH,imgW,imgH,unk0) | WPETexDecoder.swift:480-486 | ✅ | Field order/types match TextureParser.cpp:164-172 |
| 9-byte NUL-terminated ASCII magic read | WPETexByteReader.swift:48-58 | ✅ | Matches `file.next(magic,9)` |
| TextureFormat enum codes (0/4/6/7/8/9/12/13) | WPETexErrors.swift:8-16 | ✅ | Incl. BC7=12, RGBa1010102=13 |
| Format 0 byte order (named ARGB8888, stored RGBA) | WPETexPixelDecoder.swift:11-25 | ✅ | Reference uploads `GL_RGBA`+UB → passthrough |
| R8 → RGBA(r,r,r,255) | WPETexPixelDecoder.swift:28-56 | ⚠️ | Ignores `AlphaChannelPriority` flag (alpha-in-R) |
| RG88 → RGBA(r,g,0,255) | WPETexPixelDecoder.swift:59-87 | ⚠️ | Ignores `AlphaChannelPriority` flag (alpha-in-G) |
| TEXB v1/v2/v3/v4 dispatch | WPETexDecoder.swift:529-542 | ✅ | imageFormat read for v3/v4; isVideoMp4 for v4 |
| TEXB v4 → degrade to v3 when not video | WPETexDecoder.swift:537-539 | ✅ | Matches reference (FIF!=MP4 ⇒ TEXB0003) |
| TEXB v4 per-mip extra fields before w/h | WPETexDecoder.swift:576-591 | ✅ | Order matches TextureParser.cpp:44-57 |
| compression+decompSize read only v≥2 | WPETexDecoder.swift:595-598 | ✅ | TEXB0001 has no compression fields |
| LZ4 decompression | WPETexDecoder.swift:983-1003 | ✅ | `COMPRESSION_LZ4_RAW` = LZ4 block = `LZ4_decompress_safe` |
| Encoded-image (FreeImage) payload via ImageIO | WPETexDecoder.swift:628-637 | ✅ | src fmt 13 = FIF_PNG, payload `\x89PNG` |
| BC1/2/3/7 → MTLPixelFormat | WPETexMetalTranscoder.swift:246-254 | ✅ | bc1/bc2/bc3/bc7 correct |
| BC block byte sizes (8/16/16/16) | WPETexMetalTranscoder.swift:256-262 | ✅ | DXT1=8, others=16 |
| `expectedByteCount` (bpp & 4×4 block) | WPETexErrors.swift:39-47 | ✅ | Validated vs real R8 + DXT5 byte counts |
| sRGB/gamma intent on upload | WPEMetalTextureFormatMapper.swift:77,90,99,108,117 | ❌ | Defaults `_srgb`; reference uploads linear `GL_RGBA8` |
| RGBA1010102 (fmt 13) rejected | WPEMetalTextureFormatMapper.swift:121-122 | ✅ | Reference also has no GL path |
| Formats 1/2/10/11/14/15 (RGB888/565/RG1616f/R16f/HDR) | WPETexErrors.swift:8-16 | ⚠️ | Enum absent → `.unsupportedFormat` |
| TEXS magic + frameCount + (gifW/H for v3) | WPETexDecoder.swift:413-427 | ✅ | gifW/H v3-only matches |
| TEXS v1 frame (8×int32) | WPETexDecoder.swift:436-446 | ✅ | imageID/time/x/y/w/?/?/h positions match |
| TEXS v2/v3 frame (float x/y/w/w2/h2/h) | WPETexDecoder.swift:447-457 | ✅ | All-float matches parseFrame |
| Animation gate | WPETexDecoder.swift:399 | ⚠️ | Uses imageCount>1‖TEXS≠nil; reference gates on `IsGif` |
| MP4 video sniffing (`ftyp`) | WPETexDecoder.swift:685-691 | ✅ | Supplements TEXB0004 isVideoMp4 |
| PKGV magic + LE u32 index | WallpaperEnginePackage.swift:25-55 | ✅ | Real files PKGV0022/0023 |
| PKG path-traversal / overflow guards | WallpaperEnginePackage.swift:128-135,324-346 | ✅ | Hardened beyond reference |
| MDLV header + version | WPEMdlParser.swift:60-75 | ✅ | `MDLV` prefix + trailing version |
| MDL mesh flags (normal/tangent/uv/uv2/skin) | WPEMdlParser.swift:307-314 | ⚠️ | Bit values unverifiable vs official |
| MDLS skeleton tag scan | WPEMdlParser.swift:263-304 | ➖ | No public spec; reverse-engineered |
| BC transcoder Y-flip in shader UV | WPETexMetalTranscoder.swift:225-230 | ✅* | *Flagged later as suspect GL-ism (see coordinate addendum P1-13) |
| BC sub-rect 4×4 block alignment | WPETexSubRectCropper.swift:164-180 | ✅ | Throws on misaligned crop |

## Deviations

- **❌ Major — sRGB on upload; reference treats pixels as linear.** `WPEMetalTextureFormatMapper.swift:77,90,99,108,117` default `.sRGB`. Reference (`CTexture.cpp`) uses linear `GL_RGBA8`/`GL_R8`/BC and gamma-corrects in shaders → decoding as `_srgb` double-applies gamma (washed-out/over-bright). Encoded-PNG bridge compounds it.
- **⚠️ Major — R8/RG88 ignore `AlphaChannelPriority` (524288).** `Texture.h:95`: that flag means alpha is in the R (R8) / G (RG88) channel. `WPETexPixelDecoder.swift:28-87` never inspects flags → R8/RG88 alpha masks render opaque/wrong.
- **⚠️ Minor — six valid formats absent** (`RGB888=1,RGB565=2,RG1616f=10,R16f=11,RGBA16f=14,RGB16f=15`) → clean rejection but HDR-float/565 scenes fail rather than decode.
- **⚠️ Minor — animation gate differs** (`frames>1 ‖ TEXS≠nil` vs reference `IsGif` flag). Converges in practice.
- **⚠️ Unsure — MDL mesh-flag bits + MDLS layout unverified** (no public spec, no `.mdl` in corpus). Puppet skinning is static-only.

**Non-deviations confirmed correct:** LZ4 = reference's `LZ4_decompress_safe`; Format-0 RGBA passthrough; PKG parser (hardened beyond reference).

Sources: linux-wallpaperengine TEXTURE_FORMAT.md / TextureParser.cpp / Texture.h / CTexture.cpp; RePKG (DeepWiki).
