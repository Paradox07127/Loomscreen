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
    // Engine assets ship with Windows CRLF endings; downstream regex
    // passes anchor on `$` and assume `.*` does not need to swallow a
    // trailing `\r`. Normalize at the entry so every pass sees clean
    // `\n`-terminated lines.
    let body = source.replace(/\r\n?/g, "\n").replace(/^[ \t]*#version[^\n]*\n?/m, "");

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
    const fragmentInputs = isFragment
      ? collectFragmentInputVariables(source)
      : new Map<string, string>();

    let lines = source
      .split("\n")
      .map((line) => ShaderCompiler.rewriteLine(line, isFragment, intVars))
      .filter((line): line is string => line !== null);

    if (isFragment && fragmentInputs.size > 0) {
      lines = rewriteFragmentInputAssignments(lines, fragmentInputs);
    }

    return hoistGlobalDeclarations(lines).join("\n");
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
// `out_var = 0;` are all accepted. We apply seven surgical rewrites:
//
//   1. `%=` (float modulo-assign idiom) → `var = mod(var, float(rhs))`.
//   2. `<int> [+\-*/] <id|(>` and `<id|)|0-9]> [+\-*/] <int>` → cast int
//      LITERAL side to float. The extended digit lookbehind catches
//      chained expressions like `pointer * 2 - 1` (after Pass 2a casts
//      `2`, the trailing `- 1` still sees a digit on the left).
//   3. Float-context comparisons (`time == 0`, `bootPhase < 1`) → cast
//      the bare int literal. We deliberately allow this inside `if(...)`
//      heads because the `castIntsInArithmetic` skip-list was protecting
//      `int < int` arithmetic, not float-vs-int boolean tests. Still
//      skipped: known-int operands (`i == 4` stays int-typed).
//   4. Known int VARIABLES in float arithmetic (`i / sampleDrop`,
//      `vec.x * count`) → `float(intVar)`. Triggered only when the
//      adjacent operand is visibly float-like (float literal, float
//      built-in result, or an identifier NOT in `intVars`). False
//      negatives preserve the original error; false positives are the
//      real risk and are kept narrow on purpose.
//   5. Inside calls to whitelisted float-only built-ins (`max`, `min`,
//      `clamp`, `mix`, `mod`, etc.), cast bare int literal args to
//      float so `max(0, x)` resolves to `max(float, float)`.
//   6. `(const)? (float|vec*|mat*) X = <expr>;` whose RHS still mentions
//      an int literal or int variable → wrap the RHS with `float(...)` /
//      `vecN(...)` / `matN(...)`. Safety net: even if passes 2-4 missed
//      a coercion inside the expression, the constructor coerces the
//      whole thing on assignment. Already-explicit constructors
//      (`float x = float(a);`) are left alone.
//   7. `<float_var>(.swizzle)? = <int>;` → `.0` suffix. `intVars` tells
//      us which identifiers were declared `int`/`uint`/`ivec*`/`uvec*`
//      so we skip integer-typed destinations.
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
  out = castIntLiteralsInFloatComparisons(out, intVars);
  out = castIntVarsInFloatExpressions(out, intVars);
  out = castIntArgsInFloatCalls(out);
  out = castFloatDeclarationInitializers(out, intVars);
  out = castFloatVarAssignments(out, intVars);

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
    // Mixed numeric literals: `(30 / 8.0)`, `0.1 * (30 - 5.0)`, etc.
    // The two passes above only fire when one operand is an identifier
    // or paren/bracket — they miss bare int adjacent to bare float.
    // `castFloatDeclarationInitializers` later wraps the outer
    // expression with `float(...)`, but GLSL types from inside-out so
    // the inner `int / float` still errors before the outer cast can
    // promote. Promote the int literal directly when the neighbor is
    // a float literal.
    s = s.replace(
      /(^|[^\w.])(\d+)(\s*[+\-*/]\s*)((?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?)/g,
      (_m, pre: string, num: string, op: string, floatLit: string) =>
        `${pre}${num}.0${op}${floatLit}`
    );
    s = s.replace(
      /((?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?)(\s*[+\-*/]\s*)(\d+)(?![\w.])/g,
      (_m, floatLit: string, op: string, num: string) =>
        `${floatLit}${op}${num}.0`
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
      addIntegerVariableName(intVars, name);
    }
  }
  collectIntegerFunctionParameters(source, intVars);
  return intVars;
}

// `(int a, int b)` is captured by `collectIntegerVariables` as a single
// declarator chain `a, int b)` — splitDeclarators yields `a` and
// `int b)`, so only the FIRST parameter name reaches `intVars`. The
// second extraction picks up `int` (the type keyword itself); without
// the keyword-filter in `addIntegerVariableName` we would then treat
// `int < int` as `float(int) < int`. Walk function signatures explicitly
// so every integer parameter is registered.
function collectIntegerFunctionParameters(source: string, intVars: Set<string>): void {
  const functionRe = /\b([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\(/g;
  let match: RegExpExecArray | null;
  while ((match = functionRe.exec(source)) !== null) {
    const returnType = match[1] ?? "";
    if (/^(?:if|for|while|switch|return)$/.test(returnType)) continue;

    const openIdx = match.index + match[0].length - 1;
    const closeIdx = matchClose(source, openIdx, "(", ")");
    const after = source.substring(closeIdx + 1).trimStart()[0] ?? "";
    if (after !== "{" && after !== ";") continue;

    const params = source.substring(openIdx + 1, closeIdx);
    for (const param of splitDeclarators(params)) {
      const name = /^(?:(?:const|in|out|inout|highp|mediump|lowp)\s+)*(?:int|uint|ivec[234]|uvec[234])\s+([A-Za-z_]\w*)\b/.exec(param.trim())?.[1];
      addIntegerVariableName(intVars, name);
    }
    functionRe.lastIndex = closeIdx + 1;
  }
}

function addIntegerVariableName(intVars: Set<string>, name: string | undefined): void {
  if (!name) return;
  if (/^(?:void|bool|int|uint|float|[biu]?vec[234]|mat[234])$/.test(name)) return;
  intVars.add(name);
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

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Pass 3 in `applyGLSLEsCompat`: float comparison int-literal coercion.
// Sits outside `castIntsInArithmetic` because that pass skips `if(...)`
// heads to protect `if (i < count)` integer comparisons. Here we re-enter
// those contexts under stricter operand checks.
function castIntLiteralsInFloatComparisons(line: string, intVars: Set<string>): string {
  return rewriteOutsideArraySubscripts(line, (segment) => {
    let out = segment.replace(
      /(\b[A-Za-z_]\w*(?:\.[xyzwrgbastpq]+)?|(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?)(\s*(?:==|!=|<=|>=|<|>)\s*)(-?\d+)(?![\w.])/g,
      (match, left: string, op: string, num: string) => {
        if (!isFloatLikeOperandText(left, intVars)) return match;
        return `${left}${op}${num}.0`;
      }
    );
    out = out.replace(
      /(^|[^\w.])(-?\d+)(\s*(?:==|!=|<=|>=|<|>)\s*)(\b[A-Za-z_]\w*(?:\.[xyzwrgbastpq]+)?|(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?)/g,
      (match, prefix: string, num: string, op: string, right: string) => {
        if (!isFloatLikeOperandText(right, intVars)) return match;
        return `${prefix}${num}.0${op}${right}`;
      }
    );
    return out;
  });
}

// Pass 4: known int VARIABLES adjacent to float-like operands → wrap
// with `float(...)`. Heuristic, not a type-checker: we only look one
// operator left and one right, and only fire when that neighbor reads
// as float (literal, float built-in result, or identifier not in
// `intVars`). False negatives keep the original GLSL error; false
// positives would corrupt working integer math, so the cast is gated
// behind the operand check and skipped when the int var is already
// wrapped (`float(i)`) or used as a swizzle base (`foo.x`).
function castIntVarsInFloatExpressions(line: string, intVars: Set<string>): string {
  if (intVars.size === 0) return line;
  const names = [...intVars]
    .filter((name) => /^[A-Za-z_]\w*$/.test(name))
    .sort((a, b) => b.length - a.length);
  if (names.length === 0) return line;

  const intVarRe = new RegExp(`\\b(${names.map(escapeRegExp).join("|")})\\b`, "g");
  return rewriteOutsideArraySubscripts(line, (segment) => {
    let out = "";
    let last = 0;
    let match: RegExpExecArray | null;
    while ((match = intVarRe.exec(segment)) !== null) {
      const name = match[1] ?? "";
      const start = match.index;
      const end = start + name.length;
      out += segment.substring(last, start);
      if (
        segment[start - 1] === "." ||
        segment[end] === "." ||
        isWrappedByFloatCall(segment, start) ||
        !shouldCastIntVarOperand(segment, start, end, intVars)
      ) {
        out += name;
      } else {
        out += `float(${name})`;
      }
      last = end;
    }
    out += segment.substring(last);
    return out;
  });
}

// Pass 6: `(const)? (float|vec*|mat*) X = <expr>;` whose RHS still
// references int literals or int vars → wrap with `glslType(...)`. This
// is the safety net for cases where passes 2-4 missed an inner operand.
// Multi-declarator (`float a = 0, b = 1;`) is intentionally a false
// negative — splitting per-declarator would need a type-aware split and
// the simpler workshop pattern is one decl per line.
function castFloatDeclarationInitializers(line: string, intVars: Set<string>): string {
  return line.replace(
    /^(\s*(?:const\s+)?(float|vec[234]|mat[234])\s+[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*=\s*)([^;]+)(\s*;.*)$/,
    (match, prefix: string, glslType: string, expr: string, tail: string) => {
      const trimmed = expr.trim();
      if (!trimmed || hasTopLevelComma(trimmed) || isWholeExplicitFloatConstructor(trimmed)) {
        return match;
      }
      if (!containsIntCoercionSource(trimmed, intVars)) return match;
      const leading = expr.match(/^\s*/)?.[0] ?? "";
      const trailing = expr.match(/\s*$/)?.[0] ?? "";
      return `${prefix}${leading}${glslType}(${trimmed})${trailing}${tail}`;
    }
  );
}

// Fragment `in`/`varying` variables are immutable in GLSL ES — workshop
// shaders authored against desktop GLSL routinely write to them
// (`v_TexCoord = v_TexCoord * 0.5;`). We rewrite the first assignment
// into a local copy and re-target all subsequent reads.
//
// Limitation: the local copy is inserted immediately before the first
// assignment. If that assignment lives inside a nested scope (`if/for`
// block), references outside that scope still point at `<name>_local`,
// which won't exist. We accept this as a known false-positive class —
// it matches the workshop pattern of writing to varyings at the top of
// `main()`, and tightening it would require true brace-aware scope
// tracking.
function rewriteFragmentInputAssignments(
  lines: string[],
  fragmentInputs: Map<string, string>
): string[] {
  const assignedInputs = collectAssignedFragmentInputs(lines, fragmentInputs);
  if (assignedInputs.size === 0) return lines;

  const out: string[] = [];
  const activeLocals = new Set<string>();
  for (const line of lines) {
    const trimmed = line.trimStart();
    if (
      trimmed.startsWith("#") ||
      trimmed.startsWith("//") ||
      isFragmentInputDeclaration(line, assignedInputs)
    ) {
      out.push(line);
      continue;
    }

    const newlyAssigned = [...assignedInputs].filter(
      ([name]) => !activeLocals.has(name) && lineAssignsToInput(line, name)
    );
    for (const [name, glslType] of newlyAssigned) {
      activeLocals.add(name);
      const indent = line.match(/^\s*/)?.[0] ?? "";
      out.push(`${indent}${glslType} ${name}_local = ${name};`);
    }

    let rewritten = line;
    for (const name of activeLocals) {
      rewritten = replaceIdentifierInCode(rewritten, name, `${name}_local`);
    }
    out.push(rewritten);
  }
  return out;
}

// WPE workshop shaders routinely use `#include "common_*.h"` at the top
// of the source, which after Swift-side expansion places helper
// functions above the `uniform sampler2D g_Texture0;` / `varying ...`
// declarations that those helpers reference. Desktop GLSL is permissive
// about declaration order for globals, but GLSL ES 3.00 is not —
// WebGL2 reports `'g_Texture0' : undeclared identifier` at every helper
// call site. Move single-line global declarations to the top of the
// body so helpers below see them. Function bodies and multi-line
// declarations are left alone (anchored regex requires `;` end).
function hoistGlobalDeclarations(lines: string[]): string[] {
  const declRe =
    /^\s*(?:layout\s*\([^)]*\)\s*)?(?:uniform|in|out|attribute|varying)\s+(?:(?:highp|mediump|lowp)\s+)?[A-Za-z_]\w*\s+[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*;\s*(?:\/\/.*)?$/;
  const decls: string[] = [];
  const rest: string[] = [];
  for (const line of lines) {
    if (declRe.test(line)) {
      decls.push(line);
    } else {
      rest.push(line);
    }
  }
  if (decls.length === 0) return lines;
  return [...decls, ...rest];
}

function collectFragmentInputVariables(source: string): Map<string, string> {
  const inputs = new Map<string, string>();
  const declRe =
    /^\s*(?:(?:flat|smooth|noperspective|centroid|sample)\s+)*(?:in|varying)\s+(?:(?:highp|mediump|lowp)\s+)?([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*(?:\[[^\]]+\])?\s*;/gm;
  let match: RegExpExecArray | null;
  while ((match = declRe.exec(source)) !== null) {
    const glslType = match[1] ?? "";
    const name = match[2] ?? "";
    if (glslType && name) inputs.set(name, glslType);
  }
  return inputs;
}

function collectAssignedFragmentInputs(
  lines: string[],
  fragmentInputs: Map<string, string>
): Map<string, string> {
  const assigned = new Map<string, string>();
  for (const [name, glslType] of fragmentInputs) {
    if (lines.some((line) => lineAssignsToInput(line, name))) {
      assigned.set(name, glslType);
    }
  }
  return assigned;
}

function lineAssignsToInput(line: string, name: string): boolean {
  const code = splitLineComment(line).code;
  const re = new RegExp(
    `(^|[^\\w.])${escapeRegExp(name)}(?:\\s*\\.[xyzwrgbastpq]+)?\\s*(?:[+\\-*/%]?=)(?!=)`
  );
  return re.test(code);
}

function isFragmentInputDeclaration(line: string, inputs: Map<string, string>): boolean {
  for (const [name, glslType] of inputs) {
    const re = new RegExp(
      `^\\s*(?:(?:flat|smooth|noperspective|centroid|sample)\\s+)*(?:in|varying)\\s+(?:(?:highp|mediump|lowp)\\s+)?${escapeRegExp(glslType)}\\s+${escapeRegExp(name)}\\s*(?:\\[[^\\]]+\\])?\\s*;`
    );
    if (re.test(line)) return true;
  }
  return false;
}

function replaceIdentifierInCode(line: string, name: string, replacement: string): string {
  const { code, comment } = splitLineComment(line);
  return code.replace(new RegExp(`\\b${escapeRegExp(name)}\\b`, "g"), replacement) + comment;
}

// Shared by passes 3 and 4: rewrite only the parts of `line` that are
// OUTSIDE `[...]` subscripts, so integer-typed indices stay int. Caller
// supplies a per-segment rewriter; bracket contents are forwarded
// verbatim.
function rewriteOutsideArraySubscripts(
  line: string,
  rewrite: (segment: string) => string
): string {
  let out = "";
  let buffer = "";
  const flush = () => {
    if (!buffer) return;
    out += rewrite(buffer);
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
    buffer += ch;
    i++;
  }
  flush();
  return out;
}

function shouldCastIntVarOperand(
  text: string,
  start: number,
  end: number,
  intVars: Set<string>
): boolean {
  const nextOp = readOperatorAfter(text, end);
  if (nextOp && isFloatLikeOperandText(readOperandAfter(text, nextOp.end), intVars)) {
    return true;
  }
  const prevOp = readOperatorBefore(text, start);
  if (prevOp && isFloatLikeOperandText(readOperandBefore(text, prevOp.start), intVars)) {
    return true;
  }
  return false;
}

function readOperatorAfter(text: string, index: number): { start: number; end: number } | null {
  const i = skipWhitespaceForward(text, index);
  const two = text.substring(i, i + 2);
  if (["++", "--", "+=", "-=", "*=", "/=", "%="].includes(two)) return null;
  if (["==", "!=", "<=", ">="].includes(two)) return { start: i, end: i + 2 };
  if ("+-*/<>".includes(text[i] ?? "")) return { start: i, end: i + 1 };
  return null;
}

function readOperatorBefore(text: string, index: number): { start: number; end: number } | null {
  const i = skipWhitespaceBackward(text, index - 1);
  const two = text.substring(i - 1, i + 1);
  if (["++", "--", "+=", "-=", "*=", "/=", "%="].includes(two)) return null;
  if (["==", "!=", "<=", ">="].includes(two)) return { start: i - 1, end: i + 1 };
  if ("+-*/<>".includes(text[i] ?? "")) return { start: i, end: i + 1 };
  return null;
}

function readOperandAfter(text: string, index: number): string {
  const start = skipWhitespaceForward(text, index);
  let depth = 0;
  let i = start;
  while (i < text.length) {
    const ch = text[i] ?? "";
    if (
      depth === 0 &&
      (ch === ";" || ch === "," || ch === ")" || ch === "{" || ch === "}" || isExpressionOperator(text, i))
    ) {
      break;
    }
    if (ch === "(" || ch === "[") depth += 1;
    else if (ch === ")" || ch === "]") depth -= 1;
    i++;
  }
  return stripLeadingStatementKeywords(text.substring(start, i).trim());
}

function readOperandBefore(text: string, index: number): string {
  const end = skipWhitespaceBackward(text, index - 1) + 1;
  let depth = 0;
  let i = end - 1;
  while (i >= 0) {
    const ch = text[i] ?? "";
    if (
      depth === 0 &&
      (ch === ";" || ch === "," || ch === "(" || ch === "{" || ch === "}" || isExpressionOperator(text, i))
    ) {
      break;
    }
    if (ch === ")" || ch === "]") depth += 1;
    else if (ch === "(" || ch === "[") depth -= 1;
    i--;
  }
  return stripLeadingStatementKeywords(text.substring(i + 1, end).trim());
}

// `return a < b` — when we walk backward from `<`, no `;` precedes
// `return`, so the operand window grows all the way to the line start
// and `expressionContainsFloatCue` then sees `return` as a non-int
// identifier and counts it as a float cue. Strip leading GLSL
// statement-introducing keywords so the operand collapses back to the
// actual expression token (`a`).
function stripLeadingStatementKeywords(operand: string): string {
  return operand.replace(
    /^(?:return|if|else|while|for|do|switch|case|default|break|continue|discard)\b\s*/,
    ""
  );
}

function isFloatLikeOperandText(operand: string, intVars: Set<string>): boolean {
  const text = stripOuterParens(operand.trim());
  if (!text) return false;
  if (/^[+-]?(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?$/.test(text)) return true;

  const call = /^([A-Za-z_]\w*)\s*\(/.exec(text);
  if (call) {
    const name = call[1] ?? "";
    return FLOAT_BUILT_INS.has(name) || /^(float|vec[234]|mat[234])$/.test(name);
  }

  const ident = /^([A-Za-z_]\w*)(?:\.[xyzwrgbastpq]+)?$/.exec(text);
  if (ident) return !intVars.has(ident[1] ?? "");

  return expressionContainsFloatCue(text, intVars);
}

function containsIntCoercionSource(expr: string, intVars: Set<string>): boolean {
  const text = stripBracketContents(expr);
  if (hasBareIntLiteral(text)) return true;
  for (const intVar of intVars) {
    if (new RegExp(`\\b${escapeRegExp(intVar)}\\b`).test(text)) return true;
  }
  return false;
}

function expressionContainsFloatCue(expr: string, intVars: Set<string>): boolean {
  const text = stripBracketContents(expr);
  if (/(^|[^\w.])(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?(?![\w.])/.test(text)) return true;
  const identRe = /\b([A-Za-z_]\w*)\b/g;
  let match: RegExpExecArray | null;
  while ((match = identRe.exec(text)) !== null) {
    const name = match[1] ?? "";
    if (intVars.has(name) || isGLSLNonValueKeyword(name)) continue;
    return true;
  }
  return false;
}

// Identifiers that aren't variables: GLSL primitive types, control-flow
// keywords, storage qualifiers. Treating them as "float cues" makes
// `castIntVarsInFloatExpressions` spuriously wrap int neighbors. Type
// keywords also live in `addIntegerVariableName`'s filter; the two
// lists overlap on purpose so each pass stays self-contained.
function isGLSLNonValueKeyword(name: string): boolean {
  return /^(?:void|bool|int|uint|float|[biu]?vec[234]|mat[234]|return|if|else|while|for|do|switch|case|default|break|continue|discard|const|in|out|inout|uniform|varying|attribute|highp|mediump|lowp|precision|layout|flat|smooth|noperspective|centroid|sample|true|false)$/.test(name);
}

function hasBareIntLiteral(text: string): boolean {
  let i = 0;
  while (i < text.length) {
    const rest = text.substring(i);
    const float = /^(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+)[fF]?/.exec(rest);
    if (float) {
      i += float[0].length;
      continue;
    }
    const hexOrUint = /^(?:0[xX][0-9a-fA-F]+|\d+[uU])/.exec(rest);
    if (hexOrUint) {
      i += hexOrUint[0].length;
      continue;
    }
    const intLit = /^-?\d+/.exec(rest);
    if (intLit) {
      const prev = text[i - 1] ?? "";
      const next = text[i + intLit[0].length] ?? "";
      if (!/[\w.]/.test(prev) && !/[\w.]/.test(next)) return true;
      i += intLit[0].length;
      continue;
    }
    i++;
  }
  return false;
}

function isWholeExplicitFloatConstructor(expr: string): boolean {
  const call = /^(float|vec[234]|mat[234])\s*\(/.exec(expr);
  if (!call) return false;
  const open = expr.indexOf("(");
  return matchClose(expr, open, "(", ")") === expr.length - 1;
}

function isWrappedByFloatCall(text: string, start: number): boolean {
  const open = skipWhitespaceBackward(text, start - 1);
  if (text[open] !== "(") return false;
  const wordEnd = skipWhitespaceBackward(text, open - 1) + 1;
  let wordStart = wordEnd - 1;
  while (wordStart >= 0 && /\w/.test(text[wordStart] ?? "")) wordStart--;
  return text.substring(wordStart + 1, wordEnd) === "float";
}

function hasTopLevelComma(text: string): boolean {
  let depth = 0;
  for (const ch of text) {
    if (ch === "(" || ch === "[" || ch === "{") depth += 1;
    else if (ch === ")" || ch === "]" || ch === "}") depth -= 1;
    else if (ch === "," && depth === 0) return true;
  }
  return false;
}

function stripOuterParens(text: string): string {
  if (!text.startsWith("(")) return text;
  const close = matchClose(text, 0, "(", ")");
  return close === text.length - 1 ? text.substring(1, close).trim() : text;
}

function stripBracketContents(text: string): string {
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] === "[") {
      const close = matchClose(text, i, "[", "]");
      out += " ";
      i = close + 1;
      continue;
    }
    out += text[i] ?? "";
    i++;
  }
  return out;
}

function splitLineComment(line: string): { code: string; comment: string } {
  const idx = line.indexOf("//");
  return idx === -1 ? { code: line, comment: "" } : { code: line.substring(0, idx), comment: line.substring(idx) };
}

function skipWhitespaceForward(text: string, index: number): number {
  let i = index;
  while (i < text.length && /\s/.test(text[i] ?? "")) i++;
  return i;
}

function skipWhitespaceBackward(text: string, index: number): number {
  let i = index;
  while (i >= 0 && /\s/.test(text[i] ?? "")) i--;
  return i;
}

function isExpressionOperator(text: string, index: number): boolean {
  return /[+\-*/<>!=]/.test(text[index] ?? "");
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
