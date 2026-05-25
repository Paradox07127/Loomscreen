import { describe, expect, it } from "vitest";
import { ShaderCompiler } from "./ShaderCompiler";

function preprocessFragment(source: string): string {
  return ShaderCompiler.preprocess(source, true, {});
}

describe("ShaderCompiler GLSL ES compatibility coercions", () => {
  // Mirrors effects/shine_cast.frag — `const int sampleCount`,
  // `const float sampleDrop = sampleCount - 1`, then `i / sampleDrop`
  // and `vec.x * sampleCount` inside a loop. Variable name `sample`
  // is deliberately AVOIDED because `rewriteLine` renames it to
  // `wpe_sample` (GLSL ES 3.00 reserves the identifier as a future
  // qualifier keyword); we use `tap` so the expectations stay focused
  // on coercion, not rename-collision.
  it("coerces shine_cast-style int counts in float expressions", () => {
    const output = preprocessFragment(`
const int sampleCount = 8;

void main() {
  vec2 direction = vec2(1.0);
  float dist = 2.0;
  vec4 tap = vec4(1.0);
  const float sampleDrop = sampleCount - 1;
  direction = direction * dist / sampleDrop;
  for (int i = 0; i < sampleCount; ++i) {
    vec4 albedo = tap * (i / sampleDrop);
    vec4 scaled = tap * sampleCount;
  }
}
`);

    expect(output).toContain("const float sampleDrop = float(float(sampleCount) - 1.0);");
    expect(output).toContain("vec4 albedo = vec4(tap * (float(i) / sampleDrop));");
    expect(output).toContain("vec4 scaled = vec4(tap * float(sampleCount));");
    expect(output).toContain("for (int i = 0; i < sampleCount; ++i)");
  });

  it("coerces ps2_startup_screen-style float comparisons and int-mul-uniform-float", () => {
    const output = preprocessFragment(`
uniform float bootPhase;
const int blocks = 3;

void main() {
  if (bootPhase == 0) {
    float blink = 0;
  }
  float scaled = blocks * bootPhase;
}
`);

    expect(output).toContain("if (bootPhase == 0.0)");
    expect(output).toContain("float blink = float(0);");
    expect(output).toContain("float scaled = float(float(blocks) * bootPhase);");
  });

  it("rewrites fragment input assignment to a local copy", () => {
    const output = preprocessFragment(`
in vec2 v_TexCoord;

void main() {
  v_TexCoord = v_TexCoord * 0.5;
  vec2 uv = v_TexCoord;
}
`);

    expect(output).toContain("in vec2 v_TexCoord;");
    expect(output).toContain("  vec2 v_TexCoord_local = v_TexCoord;");
    expect(output).toContain("  v_TexCoord_local = v_TexCoord_local * 0.5;");
    expect(output).toContain("  vec2 uv = v_TexCoord_local;");
  });

  // Regression guard: shine_cast.frag `sampleIntensity` was still
  // black-screening saber after the first round of coercion because
  // `0.1 * (30 / 8.0)` puts a bare int next to a bare float literal —
  // neither operand is an identifier so Pass 2's existing two regex
  // patterns missed it. Pass 6 wrapped the outer expression in
  // `float(...)` but GLSL types from inside-out, so the inner
  // `int / float` error still fired before the outer cast could
  // promote. Pass 2 now promotes adjacent int/float literal pairs
  // directly.
  it("coerces shine_cast sampleIntensity mixed-literal arithmetic", () => {
    const output = preprocessFragment(`
void main() {
  const float sampleIntensity = 0.1 * (30 / 8.0);
}
`);

    expect(output).toContain("0.1 * (30.0 / 8.0)");
    expect(output).not.toContain("(30 / 8.0)");
  });

  // Symmetric case: float literal on the left, int literal on the right.
  it("coerces mixed-literal arithmetic when the float literal is on the left", () => {
    const output = preprocessFragment(`
void main() {
  float x = 8.0 / 30;
}
`);

    expect(output).toContain("8.0 / 30.0");
    expect(output).not.toContain("8.0 / 30;");
  });

  // Regression guard: before `collectIntegerFunctionParameters` was
  // added, the function-arg `b` was missed by `intVars` and Pass 4
  // rewrote `a < b` into `float(a) < b` (invalid GLSL ES).
  it("preserves integer comparisons between function parameters", () => {
    const output = preprocessFragment(`
bool less(int a, int b) {
  return a < b;
}

void main() {
}
`);

    expect(output).toContain("return a < b;");
    expect(output).not.toContain("return float(a) < b;");
    expect(output).not.toContain("return a < float(b);");
  });

  // Regression guard: shine_gaussian.frag `#include "common_blur.h"`
  // places helper functions above the `uniform sampler2D g_Texture0;`
  // declaration. Desktop GLSL forgives this; GLSL ES 3.00 reports
  // every helper's `g_Texture0` ref as undeclared. Hoist global
  // declarations to the top of the body.
  it("hoists global uniform/varying declarations above helper functions", () => {
    const output = preprocessFragment(`
vec4 blur(vec2 uv) {
  return texture(g_Texture0, uv) + texture(g_Texture0, uv + v_Offset);
}

uniform sampler2D g_Texture0;
varying vec2 v_Offset;

void main() {
  gl_FragColor = blur(vec2(0.5));
}
`);

    const uniformIdx = output.indexOf("uniform sampler2D g_Texture0;");
    const varyingIdx = output.indexOf("in vec2 v_Offset;");
    const blurIdx = output.indexOf("vec4 blur(vec2 uv)");
    expect(uniformIdx).toBeGreaterThan(-1);
    expect(varyingIdx).toBeGreaterThan(-1);
    expect(blurIdx).toBeGreaterThan(-1);
    expect(uniformIdx).toBeLessThan(blurIdx);
    expect(varyingIdx).toBeLessThan(blurIdx);
  });

  it("preserves int loop counter in the for-statement header", () => {
    const output = preprocessFragment(`
void main() {
  float total = 0.0;
  for (int i = 0; i < 4; ++i) {
    total += float(i);
  }
}
`);

    expect(output).toContain("for (int i = 0; i < 4; ++i)");
    expect(output).not.toContain("i < 4.0");
  });

  it("preserves integer arithmetic inside array subscripts", () => {
    const output = preprocessFragment(`
uniform float weights[8];
const int i = 1;

void main() {
  float x = weights[i * 2];
}
`);

    expect(output).toContain("float x = weights[i * 2];");
    expect(output).not.toContain("weights[float(i)");
    expect(output).not.toContain("i * 2.0]");
  });

  it("does not double-wrap an explicit float cast on the RHS", () => {
    const output = preprocessFragment(`
const int x = 1;

void main() {
  float y = float(x);
}
`);

    expect(output).toContain("float y = float(x);");
    expect(output).not.toContain("float y = float(float(x));");
  });
});
