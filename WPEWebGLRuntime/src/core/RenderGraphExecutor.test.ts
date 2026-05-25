import { describe, expect, it } from "vitest";
import { RenderGraphExecutor } from "./RenderGraphExecutor";

describe("RenderGraphExecutor", () => {
  it("uploads an identity model-view-projection matrix for custom fullscreen vertex shaders", () => {
    const uploaded: Array<{ name: string; transpose: boolean; values: number[] }> = [];
    const program = {};
    const gl = {
      getUniformLocation: (_program: unknown, name: string) =>
        name === "g_ModelViewProjectionMatrix" ? { name } : null,
      uniform1f: () => {},
      uniform2f: () => {},
      uniform4f: () => {},
      uniformMatrix4fv: (location: { name: string }, transpose: boolean, values: Float32Array) => {
        uploaded.push({ name: location.name, transpose, values: Array.from(values) });
      }
    };

    (RenderGraphExecutor.prototype as unknown as {
      uploadBuiltinUniforms(
        this: { gl: typeof gl },
        program: unknown,
        time: number,
        runtime: { pointer?: { x: number; y: number; click: number; hover: number }; audioSpectrum?: number[] },
        layerParallax: number
      ): void;
    }).uploadBuiltinUniforms.call({ gl }, program, 0, {}, 0);

    expect(uploaded).toContainEqual({
      name: "g_ModelViewProjectionMatrix",
      transpose: false,
      values: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
      ]
    });
  });

  it("uploads WPE texture resolution xyzw as dimensions for shader UV math", () => {
    const uploaded: Array<{ name: string; values: number[] }> = [];
    const samplerBindings: Array<{ name: string; slot: number }> = [];
    const program = {};
    const texture = {};
    const gl = {
      TEXTURE0: 33984,
      TEXTURE_2D: 3553,
      activeTexture: () => {},
      bindTexture: () => {},
      getUniformLocation: (_program: unknown, name: string) =>
        name === "g_Texture1" || name === "g_Texture1Resolution" ? { name } : null,
      uniform1i: (location: { name: string }, slot: number) => {
        samplerBindings.push({ name: location.name, slot });
      },
      uniform4f: (location: { name: string }, x: number, y: number, z: number, w: number) => {
        uploaded.push({ name: location.name, values: [x, y, z, w] });
      }
    };

    (RenderGraphExecutor.prototype as unknown as {
      bindTextureSlot(
        this: { gl: typeof gl; getOrCreatePlaceholderTexture(): unknown },
        program: unknown,
        slot: number,
        texture: unknown,
        samplerName: string,
        resolution: { width: number; height: number }
      ): void;
    }).bindTextureSlot.call(
      { gl, getOrCreatePlaceholderTexture: () => ({}) },
      program,
      1,
      texture,
      "g_Texture1",
      { width: 1920, height: 1080 }
    );

    expect(samplerBindings).toContainEqual({ name: "g_Texture1", slot: 1 });
    expect(uploaded).toContainEqual({
      name: "g_Texture1Resolution",
      values: [1920, 1080, 1920, 1080]
    });
  });
});
