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
    // Reset the preprocessor line counter so GLSL compile errors report
    // line numbers relative to the user's shader body, not the injected
    // version / precision / combo header above. Keeps the rich error
    // messages in the corpus report directly clickable.
    return `${headerParts.join("\n")}\n#line 1\n${body}`;
  }

  // Swift's WPEShaderSourceLoader already emits compatibility prelude
  // (`#define attribute in`, `#define varying out/in`, `out vec4 out_FragColor;`).
  // We must NOT re-run `attribute → in` over those `#define` lines (it
  // would produce `#define in in`). We also unify the fragment out
  // variable name onto wpe_FragColor so the header declaration matches.
  private static rewriteBody(source: string, isFragment: boolean): string {
    const intVars = collectIntegerVariables(source);
    return source
      .split("\n")
      .map((line) => ShaderCompiler.rewriteLine(line, isFragment, intVars))
      .filter((line): line is string => line !== null)
      .join("\n");
  }

  private static rewriteLine(line: string, isFragment: boolean, intVars: Set<string>): string | null {
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
      .replace(/\btextureCube\b/g, "texture")
      // GLSL ES 3.00 reserves `sample` as a future keyword. WPE workshop
      // shaders (notably blur/downsample helpers) commonly use it as a
      // local variable. Word-boundary rename so identifiers like
      // `texSample2D`, `sampler2D`, `sampleCount` stay intact.
      .replace(/\bsample\b/g, "wpe_sample");

    if (isFragment) {
      rewritten = rewritten.replace(/\bvarying\b/g, "in");
      rewritten = rewritten.replace(/\bgl_FragColor\b/g, "wpe_FragColor");
      rewritten = rewritten.replace(/\bout_FragColor\b/g, "wpe_FragColor");
    } else {
      rewritten = rewritten.replace(/\battribute\b/g, "in");
      rewritten = rewritten.replace(/\bvarying\b/g, "out");
    }

    rewritten = applyGLSLEsCompat(rewritten, intVars);
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

// GLSL ES 3.00 has no implicit int → float promotion and forbids
// overloading built-in functions (so we can't ship a `max(int, float)`
// shim). WPE workshop shaders are written for desktop GLSL / HLSL where
// `max(0, baseSize)`, `M_PI * 2`, `1 - mDist`, `fragLV %= 2`,
// `out_var = 0;` are all accepted. We apply four surgical rewrites:
//
//   1. `%=` (float modulo-assign idiom) → `var = mod(var, float(rhs))`
//   2. `<int> [+\-*/] <id|(>` and `<id|)|0-9]> [+\-*/] <int>` → cast int
//      side to float. The extended digit lookbehind catches chained
//      expressions like `pointer * 2 - 1` (after Pass 2a casts `2`,
//      the trailing `- 1` still sees a digit on the left).
//   3. `<float_var>(.swizzle)? = <int>;` → `.0` suffix. `intVars` tells
//      us which identifiers were declared `int`/`uint`/`ivec*`/`uvec*`
//      so we skip integer-typed destinations.
//   4. Inside calls to whitelisted float-only built-ins (`max`, `min`,
//      `clamp`, `mix`, `mod`, etc.), cast bare int literal args to
//      float so `max(0, x)` resolves to `max(float, float)`.
//
// Skipped at the line level: `#` directives, `//` comments, `for(...)`
// headers, integer-typed declarations (`int n = 4;`).
function applyGLSLEsCompat(line: string, intVars: Set<string>): string {
  const trimmed = line.trimStart();
  if (trimmed.startsWith("#") || trimmed.startsWith("//")) return line;
  if (/^for\s*\(/.test(trimmed)) return line;
  if (/^(const\s+)?(int|uint|ivec[234]|uvec[234])\s+[A-Za-z_]/.test(trimmed)) return line;

  let out = line;

  out = out.replace(
    /(\b[A-Za-z_][\w.]*)\s*%=\s*([^;]+);/g,
    (_match, lhs: string, rhs: string) => `${lhs} = mod(${lhs}, float(${rhs.trim()}));`
  );

  out = castIntsInArithmetic(out);

  out = castFloatVarAssignments(out, intVars);

  out = castIntArgsInFloatCalls(out);

  return out;
}

// `out_color = 0;`, `v_TexCoord.x = 0;`, `frag = 1;` — bare-int RHS in
// assignments to float-typed vars/swizzles. Skip when the LHS root name
// was declared int/uint/ivec*/uvec* elsewhere in the shader.
function castFloatVarAssignments(line: string, intVars: Set<string>): string {
  return line.replace(
    /(^|[^\w.])([A-Za-z_]\w*)((?:\.[xyzwrgbastpq]+)?)\s*=\s*(-?\d+)(?![\w.])(\s*;)/g,
    (match, prefix: string, base: string, swizzle: string, num: string, tail: string) => {
      if (intVars.has(base)) return match;
      return `${prefix}${base}${swizzle} = ${num}.0${tail}`;
    }
  );
}

// Apply the arithmetic int → float cast outside of contexts where ints
// must stay int: array subscripts (`arr[i * 2]`) and runtime condition
// parens (`if (n > 0)`, `while (count > 0)`). Casting inside those
// would break `int < int` comparisons or float-typed subscripts.
function castIntsInArithmetic(line: string): string {
  let out = "";
  let buffer = "";
  const flush = () => {
    if (!buffer) return;
    let s = buffer;
    s = s.replace(
      /(^|[^\w.])(\d+)(\s*[+\-*/]\s*)(?=[A-Za-z_(])/g,
      (_m, pre: string, num: string, op: string) => `${pre}${num}.0${op}`
    );
    s = s.replace(
      /(?<=[A-Za-z_)\]])(\s*[+\-*/]\s*)(\d+)(?![\w.])/g,
      (_m, op: string, num: string) => `${op}${num}.0`
    );
    // Chained vector-scale: after the previous pass cast `2` to `2.0`
    // in expressions like `vec.x * 2 - 1`, the trailing `- 1` is no
    // longer adjacent to an alpha char. Catch this narrow pattern
    // without broadening the global lookbehind (which would also
    // corrupt legitimate int arithmetic like `count = 4 - 1`).
    s = s.replace(
      /(\b[A-Za-z_]\w*(?:\.[xyzwrgbastpq]+)?\s*[*/]\s*\d+\.0)(\s*[+\-]\s*)(\d+)(?![\w.])/g,
      (_m, left: string, op: string, num: string) => `${left}${op}${num}.0`
    );
    out += s;
    buffer = "";
  };
  let i = 0;
  while (i < line.length) {
    const ch: string = line[i] ?? "";
    if (ch === "[") {
      flush();
      const close = matchClose(line, i, "[", "]");
      out += line.substring(i, close + 1);
      i = close + 1;
      continue;
    }
    const condHead = /^(if|while|switch)\s*\(/.exec(line.substring(i));
    if (condHead) {
      flush();
      const parenIdx = i + condHead[0].length - 1;
      const close = matchClose(line, parenIdx, "(", ")");
      out += line.substring(i, close + 1);
      i = close + 1;
      continue;
    }
    buffer += ch;
    i++;
  }
  flush();
  return out;
}

const FLOAT_BUILT_INS = new Set([
  "max", "min", "clamp", "mix", "smoothstep", "step", "abs", "sign",
  "pow", "exp", "exp2", "log", "log2", "sqrt", "inversesqrt",
  "floor", "ceil", "fract", "trunc", "round", "roundEven", "mod",
  "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
  "length", "distance", "dot", "cross", "normalize",
  "reflect", "refract", "faceforward",
  "radians", "degrees"
]);

function castIntArgsInFloatCalls(line: string): string {
  const callRe = /\b([A-Za-z_]\w*)\s*\(/g;
  const slices: Array<{ start: number; end: number; replacement: string }> = [];
  let match: RegExpExecArray | null;
  while ((match = callRe.exec(line)) !== null) {
    const funcName = match[1] ?? "";
    if (!FLOAT_BUILT_INS.has(funcName)) continue;
    const openIdx = match.index + match[0].length - 1;
    const closeIdx = matchClose(line, openIdx, "(", ")");
    if (closeIdx <= openIdx) continue;
    // The arg walker handles nested calls implicitly (it casts every
    // bare int literal it sees). Skipping nested float-built-ins keeps
    // the slice list non-overlapping so the reverse-order rewrite is
    // safe.
    if (slices.some((s) => match!.index >= s.start && closeIdx <= s.end)) continue;
    const args = line.substring(openIdx + 1, closeIdx);
    const rewritten = castBareIntLiterals(args);
    if (rewritten !== args) {
      slices.push({ start: openIdx + 1, end: closeIdx, replacement: rewritten });
    }
  }
  for (let i = slices.length - 1; i >= 0; i--) {
    const slice = slices[i]!;
    line = line.substring(0, slice.start) + slice.replacement + line.substring(slice.end);
  }
  return line;
}

// Walk `text` character-by-character, casting bare integer literals to
// floats. Used to process arguments inside a single function call; the
// caller has already established that we are in a float-accepting
// context, so we still skip int-typed contexts (subscripts, int ctors).
function castBareIntLiterals(text: string): string {
  let out = "";
  let i = 0;
  const len = text.length;
  while (i < len) {
    const ch: string = text[i] ?? "";
    if (ch === "[") {
      const close = matchClose(text, i, "[", "]");
      out += text.substring(i, close + 1);
      i = close + 1;
      continue;
    }
    const intCtor = /^(int|uint|ivec[234]|uvec[234])(\s*)\(/.exec(text.substring(i));
    if (intCtor) {
      const parenIdx = i + intCtor[0].length - 1;
      const close = matchClose(text, parenIdx, "(", ")");
      out += text.substring(i, close + 1);
      i = close + 1;
      continue;
    }
    // `.5`, `.03e-2` etc. are valid GLSL float literals starting with a
    // dot. The digit branch below would otherwise see `5`/`03` as bare
    // ints and emit `.5.0` (invalid). Capture the whole dot-float here.
    if (ch === ".") {
      const dotFloat = /^\.\d+(?:[eE][+-]?\d+)?[fF]?/.exec(text.substring(i));
      if (dotFloat) {
        out += dotFloat[0];
        i += dotFloat[0].length;
        continue;
      }
    }
    if (ch >= "0" && ch <= "9") {
      const rest = text.substring(i);
      const hex = /^0[xX][0-9a-fA-F]+[uU]?/.exec(rest);
      if (hex) { out += hex[0]; i += hex[0].length; continue; }
      const float = /^(\d+\.\d*(?:[eE][+-]?\d+)?[fF]?|\d+[eE][+-]?\d+[fF]?|\d+[fF])/.exec(rest);
      if (float) { out += float[0]; i += float[0].length; continue; }
      const uintLit = /^\d+[uU]/.exec(rest);
      if (uintLit) { out += uintLit[0]; i += uintLit[0].length; continue; }
      const intLit = /^\d+/.exec(rest)!;
      const prev: string = out.length > 0 ? out[out.length - 1] ?? "" : "";
      // Skip casting when the digits continue an identifier (`vec3`) or
      // form the fractional part of a float just past `.` (belt-and-
      // suspenders alongside the dot-float capture above).
      if (/[A-Za-z_]/.test(prev) || prev === ".") {
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

// Scan the (post-include-expansion) shader source for integer-typed
// declarations so the float-assignment cast doesn't promote ints. The
// declaration regex is intentionally permissive — false positives only
// cost a missed cast (the underlying compile error is preserved), while
// false negatives would turn a working `int x = 0;` reassignment into
// `int x = 0.0;`.
function collectIntegerVariables(source: string): Set<string> {
  const intVars = new Set<string>();
  // Capture everything up to the terminating `;` so we see all
  // declarators in `int a = 0, b = 1;` (the previous regex stopped at
  // the first `=` and missed `b`). Constructor commas inside parens are
  // skipped by tracking paren depth in the split step below.
  const declRe = /\b(?:const\s+)?(?:(?:flat|smooth|noperspective|centroid|sample|uniform|in|out|inout|highp|mediump|lowp)\s+)*(?:int|uint|ivec[234]|uvec[234])\s+([^;]+)/g;
  let match: RegExpExecArray | null;
  while ((match = declRe.exec(source)) !== null) {
    const body = match[1] ?? "";
    for (const declarator of splitDeclarators(body)) {
      const name = /^\s*([A-Za-z_]\w*)/.exec(declarator)?.[1];
      if (name) intVars.add(name);
    }
  }
  return intVars;
}

function splitDeclarators(body: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of body) {
    if (ch === "(" || ch === "[" || ch === "{") {
      depth += 1;
      current += ch;
    } else if (ch === ")" || ch === "]" || ch === "}") {
      depth -= 1;
      current += ch;
    } else if (ch === "," && depth === 0) {
      out.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  if (current.trim()) out.push(current);
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
