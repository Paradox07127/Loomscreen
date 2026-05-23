import { sendLoadFailed } from "../bridge/HostBridge";

export interface ShaderRequest {
  vertexSource: string;
  fragmentSource: string;
  combos: Record<string, number>;
}

export interface SamplerInfo {
  name: string;
  location: WebGLUniformLocation;
}

export interface CompiledProgram {
  program: WebGLProgram;
  samplers: SamplerInfo[];
}

interface CacheEntry {
  compiled: CompiledProgram | null;
}

export class ShaderCompiler {
  private gl: WebGL2RenderingContext;
  private cache: Map<string, CacheEntry> = new Map();

  constructor(gl: WebGL2RenderingContext) {
    this.gl = gl;
  }

  getCompiled(passKey: string, request: ShaderRequest): CompiledProgram | null {
    const cacheKey = this.cacheKey(passKey, request);
    const cached = this.cache.get(cacheKey);
    if (cached) {
      return cached.compiled;
    }
    const compiled = this.compileAndLink(passKey, request);
    this.cache.set(cacheKey, { compiled });
    return compiled;
  }

  getProgram(passKey: string, request: ShaderRequest): WebGLProgram | null {
    return this.getCompiled(passKey, request)?.program ?? null;
  }

  private cacheKey(passKey: string, request: ShaderRequest): string {
    const comboKeys = Object.keys(request.combos).sort();
    const combosStr = comboKeys.map((k) => `${k}=${request.combos[k]}`).join(",");
    // Source content is part of the cache key so a scene reload that
    // changed a shader picks up the new program automatically.
    return `${passKey}|${combosStr}|${hashString(request.vertexSource)}|${hashString(request.fragmentSource)}`;
  }

  private compileAndLink(passKey: string, request: ShaderRequest): CompiledProgram | null {
    const gl = this.gl;
    const vsSource = ShaderCompiler.preprocess(request.vertexSource, false, request.combos);
    const fsSource = ShaderCompiler.preprocess(request.fragmentSource, true, request.combos);

    const vs = compileShader(gl, gl.VERTEX_SHADER, vsSource, passKey, "vertex");
    if (!vs) return null;
    const fs = compileShader(gl, gl.FRAGMENT_SHADER, fsSource, passKey, "fragment");
    if (!fs) {
      gl.deleteShader(vs);
      return null;
    }

    const program = gl.createProgram();
    if (!program) {
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return null;
    }

    gl.bindAttribLocation(program, 0, "a_Position");
    gl.bindAttribLocation(program, 1, "a_TexCoord");
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const info = gl.getProgramInfoLog(program) ?? "(no info log)";
      sendLoadFailed("shader-link", `Program link failed for pass ${passKey}: ${info}`, passKey);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      gl.deleteProgram(program);
      return null;
    }

    gl.detachShader(program, vs);
    gl.detachShader(program, fs);
    gl.deleteShader(vs);
    gl.deleteShader(fs);

    const samplers = ShaderCompiler.collectSamplers(gl, program);
    return { program, samplers };
  }

  private static collectSamplers(gl: WebGL2RenderingContext, program: WebGLProgram): SamplerInfo[] {
    const result: SamplerInfo[] = [];
    const count = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS) as number;
    for (let i = 0; i < count; i++) {
      const info = gl.getActiveUniform(program, i);
      if (!info) continue;
      if (info.type !== gl.SAMPLER_2D && info.type !== gl.SAMPLER_CUBE) continue;
      // Strip GLSL array suffix `name[0]` → `name`.
      const baseName = info.name.replace(/\[\d+\]$/, "");
      const location = gl.getUniformLocation(program, baseName);
      if (!location) continue;
      result.push({ name: baseName, location });
    }
    return result;
  }

  // GLSL ES 1.00 → 3.00 translation. WPE custom shaders are spec'd
  // against GLSL ES 3.00 but most omit the version directive and use
  // legacy syntax (gl_FragColor, texture2D, attribute/varying). We strip
  // any existing #version, then emit a clean header + body.
  static preprocess(source: string, isFragment: boolean, combos: Record<string, number>): string {
    let body = source.replace(/^[ \t]*#version[^\n]*\n?/m, "");

    const headerParts: string[] = ["#version 300 es"];
    const sortedCombos = Object.keys(combos).sort();
    for (const key of sortedCombos) {
      const value = combos[key];
      if (value === undefined) continue;
      headerParts.push(`#define COMBO_${key} ${value}`);
    }
    if (!/^[ \t]*precision[ \t]+\w+[ \t]+float[ \t]*;/m.test(body)) {
      headerParts.push("precision highp float;");
      if (isFragment) {
        headerParts.push("precision highp int;");
      }
    }
    if (isFragment) {
      headerParts.push("out vec4 wpe_FragColor;");
    }

    body = ShaderCompiler.rewriteBody(body, isFragment);
    return `${headerParts.join("\n")}\n${body}`;
  }

  // Swift's WPEShaderSourceLoader already emits compatibility prelude
  // (`#define attribute in`, `#define varying out/in`, `out vec4 out_FragColor;`).
  // We must NOT re-run `attribute → in` over those `#define` lines (it
  // would produce `#define in in`). We also unify the fragment out
  // variable name onto wpe_FragColor so the header declaration matches.
  private static rewriteBody(source: string, isFragment: boolean): string {
    return source
      .split("\n")
      .map((line) => ShaderCompiler.rewriteLine(line, isFragment))
      .filter((line): line is string => line !== null)
      .join("\n");
  }

  private static rewriteLine(line: string, isFragment: boolean): string | null {
    const trimmed = line.trimStart();

    if (/^#define\s+(attribute|varying)\b/.test(trimmed)) {
      return null;
    }
    if (trimmed.startsWith("#")) {
      return line;
    }
    if (
      isFragment &&
      /^\s*(?:layout\s*\([^)]*\)\s*)?out\s+vec4\s+(?:out_FragColor|wpe_FragColor)\s*;\s*$/.test(line)
    ) {
      return null;
    }

    let rewritten = line
      .replace(/\btexture2DProj\b/g, "textureProj")
      .replace(/\btexture2D\b/g, "texture")
      .replace(/\btextureCube\b/g, "texture");

    if (isFragment) {
      rewritten = rewritten.replace(/\bvarying\b/g, "in");
      rewritten = rewritten.replace(/\bgl_FragColor\b/g, "wpe_FragColor");
      rewritten = rewritten.replace(/\bout_FragColor\b/g, "wpe_FragColor");
    } else {
      rewritten = rewritten.replace(/\battribute\b/g, "in");
      rewritten = rewritten.replace(/\bvarying\b/g, "out");
    }

    rewritten = rewriteModAssign(rewritten);
    rewritten = coerceIntLiteralsToFloat(rewritten);
    return rewritten;
  }

  dispose(): void {
    for (const entry of this.cache.values()) {
      if (entry.compiled) {
        this.gl.deleteProgram(entry.compiled.program);
      }
    }
    this.cache.clear();
  }
}

function compileShader(
  gl: WebGL2RenderingContext,
  type: number,
  source: string,
  passKey: string,
  stage: "vertex" | "fragment"
): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const info = gl.getShaderInfoLog(shader) ?? "(no info log)";
    sendLoadFailed(`shader-${stage}`, `${stage} shader compile failed for pass ${passKey}: ${info}`, passKey);
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}

// `fragLV %= 2;` is a desktop-GLSL idiom that doesn't exist in GLSL ES
// 3.00 — `%=` applies only to integer types there. WPE workshop shaders
// commonly use it on floats, so rewrite to `var = mod(var, float(rhs))`.
function rewriteModAssign(line: string): string {
  return line.replace(
    /(\b[A-Za-z_][\w.]*)\s*%=\s*([^;]+);/g,
    (_match, lhs: string, rhs: string) => `${lhs} = mod(${lhs}, float(${rhs.trim()}));`
  );
}

// GLSL ES 3.00 has no implicit int → float promotion and forbids
// overloading built-in functions (so we can't ship a `max(int, float)`
// shim). WPE workshop shaders are written for desktop GLSL / HLSL where
// `max(0, baseSize)`, `M_PI * 2`, `1 - mDist`, etc. are accepted, so we
// rewrite bare integer literals to floats in every expression context.
//
// Skipped contexts (where int literals must stay int):
//   - preprocessor lines (`#define X 5`, `#if (DEBUG == 1)`)
//   - for-loop headers (`for (int i = 0; i < 10; i++)`)
//   - integer-typed declarations (`int n = 4;`, `ivec2 sz = ivec2(8, 8);`)
//   - array subscripts (`arr[2]`)
//   - integer-typed constructors (`int(...)`, `uint(...)`, `ivec*(...)`,
//     `uvec*(...)`) so they keep receiving int args
//   - line comments (`// ...`)
//
// Runtime `int == int` comparisons in non-declaration lines will become
// `int == float` and fail — that pattern is rare in WPE shaders (the
// engine uses `#if` for combo dispatch) and would already be broken by
// any conversion strategy. We accept it as a known limitation.
function coerceIntLiteralsToFloat(line: string): string {
  const trimmed = line.trimStart();
  if (trimmed.startsWith("#") || trimmed.startsWith("//")) return line;
  if (/^for\s*\(/.test(trimmed)) return line;
  if (/^(const\s+)?(int|uint|ivec[234]|uvec[234])\s+[A-Za-z_]/.test(trimmed)) return line;

  let out = "";
  let i = 0;
  const len = line.length;

  while (i < len) {
    const ch: string = line[i] ?? "";

    if (ch === "/" && line[i + 1] === "/") {
      out += line.substring(i);
      break;
    }

    if (ch === "[") {
      const close = matchClose(line, i, "[", "]");
      out += line.substring(i, close + 1);
      i = close + 1;
      continue;
    }

    const intCtor = /^(int|uint|ivec[234]|uvec[234])(\s*)\(/.exec(line.substring(i));
    if (intCtor) {
      const parenIdx = i + intCtor[0].length - 1;
      const close = matchClose(line, parenIdx, "(", ")");
      out += line.substring(i, close + 1);
      i = close + 1;
      continue;
    }

    if (ch >= "0" && ch <= "9") {
      const rest = line.substring(i);
      const hex = /^0[xX][0-9a-fA-F]+[uU]?/.exec(rest);
      if (hex) {
        out += hex[0];
        i += hex[0].length;
        continue;
      }
      const float = /^(\d+\.\d*(?:[eE][+-]?\d+)?[fF]?|\d+[eE][+-]?\d+[fF]?|\d+[fF])/.exec(rest);
      if (float) {
        out += float[0];
        i += float[0].length;
        continue;
      }
      const uintLit = /^\d+[uU]/.exec(rest);
      if (uintLit) {
        out += uintLit[0];
        i += uintLit[0].length;
        continue;
      }
      const intLit = /^\d+/.exec(rest)!;
      // Don't cast when the literal is part of an identifier (e.g. `vec3`)
      // — only happens when previous emitted char is a letter / underscore /
      // digit (identifier continuation).
      const prev: string = out.length > 0 ? out[out.length - 1] ?? "" : "";
      if (/[A-Za-z_]/.test(prev)) {
        out += intLit[0];
      } else {
        out += `${intLit[0]}.0`;
      }
      i += intLit[0].length;
      continue;
    }

    out += ch;
    i++;
  }

  return out;
}

function matchClose(s: string, start: number, open: string, close: string): number {
  let depth = 0;
  for (let i = start; i < s.length; i++) {
    if (s[i] === open) depth++;
    else if (s[i] === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return s.length - 1;
}

function hashString(s: string): string {
  // FNV-1a 32-bit, hex. Fast enough for cache keys on shader sources.
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h.toString(16);
}
