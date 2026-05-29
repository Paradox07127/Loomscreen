import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// End-to-end coverage for `WPEShaderTranspiler` + `WPESwiftShaderCompiler`
/// against representative WPE effect shader patterns. Each test exercises
/// a real-world structure (single sampler + uniforms + main rewriting
/// gl_FragColor) and verifies that the produced MSL compiles cleanly via
/// `MTLDevice.makeLibrary(source:)`.
struct WPEShaderTranspilerTests {

    @Test("Translates the canonical WPE scroll fragment to MSL that compiles")
    func translatesScrollFragment() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_Scale;
        in vec2 v_TexCoord;
        in vec2 v_Scroll;
        void main() {
            vec2 texCoord = fract((v_TexCoord + v_Scroll) * g_Scale);
            gl_FragColor = texture(g_Texture0, texCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "scroll",
            preprocessedSource: source
        )
        #expect(result.samplers == ["g_Texture0"])
        #expect(result.uniformLayout.contains { $0.name == "g_Scale" && $0.glslType == "vec2" })
        #expect(result.mslSource.contains("g_Texture0.sample(linearSampler"))
        #expect(result.mslSource.contains("out vec4") == false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("texSample2DLod / textureLod translates to a Metal level() sample and compiles")
    func translatesTextureLodFragment() throws {
        // Mirrors the preprocessor output: texSample2DLod( -> textureLod(.
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = textureLod(g_Texture0, v_TexCoord, 2.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "lod",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("textureLod(") == false)
        #expect(result.mslSource.contains("g_Texture0.sample(linearSampler"))
        #expect(result.mslSource.contains("level("))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Translates a tint-style fragment with vec3 uniform")
    func translatesTintFragment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec3 g_TintColor;
        uniform float g_BlendAlpha;
        in vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            albedo.rgb = mix(albedo.rgb, albedo.rgb * g_TintColor, g_BlendAlpha);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "tint",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.count == 2)
        #expect(result.uniformLayout[0].name == "g_TintColor")
        #expect(result.uniformLayout[0].slot == 0)
        #expect(result.uniformLayout[1].name == "g_BlendAlpha")
        #expect(result.uniformLayout[1].slot == 1)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Translated shader uniforms resolve WPE material metadata names and defaults")
    func translatedShaderUniformsResolveMaterialMetadataNamesAndDefaults() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float u_alpha; // {"material":"Opacity","default":1,"range":[0,1]}
        uniform float u_aperture; // {"material":"Aperture","default":1.25}
        uniform float u_ratio; // {"material":"Ratio","default":2.39}
        in vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(albedo.rgb * u_aperture * u_ratio, albedo.a * u_alpha);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "metadata",
            preprocessedSource: source
        )
        let alphaSlot = try #require(result.uniformLayout.first { $0.name == "u_alpha" })
        let apertureSlot = try #require(result.uniformLayout.first { $0.name == "u_aperture" })
        let ratioSlot = try #require(result.uniformLayout.first { $0.name == "u_ratio" })
        #expect(alphaSlot.materialName == "Opacity")
        #expect(alphaSlot.defaultValue?.numberValue == 1)
        #expect(apertureSlot.materialName == "Aperture")
        #expect(ratioSlot.defaultValue?.numberValue == 2.39)

        let pass = WPERenderPass(
            id: "metadata.0",
            phase: .effect(file: "effects/metadata/effect.json"),
            shader: "workshop/metadata",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let preparedPass = WPEPreparedRenderPass(
            pass: pass,
            shader: WPEShaderProgram(
                name: "workshop/metadata",
                vertexSource: "",
                fragmentSource: source,
                isBuiltin: false
            ),
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [
                "Opacity": .number(0.25),
                "Aperture": .number(2.5)
            ]
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let slots = executor.packTranslatedUniforms(
            for: preparedPass,
            layout: result.uniformLayout
        )

        #expect(abs(slots[alphaSlot.slot].x - 0.25) < 0.0001)
        #expect(abs(slots[apertureSlot.slot].x - 2.5) < 0.0001)
        #expect(abs(slots[ratioSlot.slot].x - 2.39) < 0.0001)
    }

    @Test("Type substitutions cover vec/mat families")
    func typeSubstitutions() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform mat3 g_Rotation;
        in vec2 v_TexCoord;
        void main() {
            vec3 p = vec3(v_TexCoord, 0.0);
            vec3 r = g_Rotation * p;
            gl_FragColor = vec4(r, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "spin",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float3 p = float3"))
        #expect(result.mslSource.contains("float4(r, 1.0)"))
        #expect(result.uniformLayout[0].slotCount == 3)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Multi-sampler input declares textures in slot order")
    func multiSamplerOrdering() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        in vec2 v_TexCoord;
        void main() {
            vec4 a = texture(g_Texture0, v_TexCoord);
            vec4 b = texture(g_Texture1, v_TexCoord);
            gl_FragColor = mix(a, b, 0.5);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "blend",
            preprocessedSource: source
        )
        #expect(result.samplers == ["g_Texture0", "g_Texture1"])
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A lone non-zero sampler slot aliases to its actual texture index")
    func sparseSamplerSlotBindsToActualSlot() throws {
        // The custom-shader dispatcher binds textures by raw slot
        // (setFragmentTexture(index: slot), slot 0..<4), so g_Texture2's texture
        // lands at [[texture(2)]]. The MSL alias must read tex2, not tex0.
        let source = """
        #version 410 core
        uniform sampler2D g_Texture2;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture2, v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "mask_only",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("auto g_Texture2 = tex2;"))
        #expect(!result.mslSource.contains("auto g_Texture2 = tex0;"))
    }

    @Test("Non-contiguous sampler slots each alias to their actual texture index")
    func nonContiguousSamplersBindToActualSlots() throws {
        // g_Texture0 + g_Texture2 (gap at slot 1). The dispatcher binds the
        // slot-2 texture at [[texture(2)]], so g_Texture2 must read tex2 — under
        // the old enumeration order it incorrectly read tex1.
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture2;
        in vec2 v_TexCoord;
        void main() {
            vec4 base = texture(g_Texture0, v_TexCoord);
            vec4 mask = texture(g_Texture2, v_TexCoord);
            gl_FragColor = base * mask.a;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "masked_base",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("auto g_Texture0 = tex0;"))
        #expect(result.mslSource.contains("auto g_Texture2 = tex2;"))
    }

    @Test("Contiguous sampler slots keep their identity mapping (regression guard)")
    func contiguousSamplersKeepIdentityMapping() throws {
        // Proves the actual-slot aliasing does NOT change the common contiguous
        // case (enumeration index already equals the slot).
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        in vec2 v_TexCoord;
        void main() {
            vec4 a = texture(g_Texture0, v_TexCoord);
            vec4 b = texture(g_Texture1, v_TexCoord);
            gl_FragColor = mix(a, b, 0.5);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "contiguous_blend",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("auto g_Texture0 = tex0;"))
        #expect(result.mslSource.contains("auto g_Texture1 = tex1;"))
    }

    @Test("Sampler slots above the supported 0–3 range are rejected, not mis-emitted")
    func rejectsTextureSlotsAboveSupportedRange() throws {
        // WPE allows g_Texture0–g_Texture7, but this pipeline only binds tex0–tex3.
        // A slot ≥ 4 must fail cleanly rather than alias to an undeclared texN.
        let source = """
        #version 410 core
        uniform sampler2D g_Texture5;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture5, v_TexCoord);
        }
        """
        #expect(throws: WPEShaderCompilerError.self) {
            try WPEShaderTranspiler.translateFragment(
                shaderName: "slot_overflow",
                preprocessedSource: source
            )
        }
    }

    @Test("End-to-end via WPESwiftShaderCompiler builds MTLLibrary")
    func endToEndViaSwiftCompiler() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "opacity_inline",
            processedVertexSource: "// not used by transpiler",
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform float g_Opacity;
            in vec2 v_TexCoord;
            void main() {
                vec4 c = texture(g_Texture0, v_TexCoord);
                gl_FragColor = vec4(c.rgb * g_Opacity, c.a * g_Opacity);
            }
            """,
            sourceHash: "opacity-test",
            comboValues: [:],
            textureBindings: [:]
        )
        let result = try compiler.compile(request)
        #expect(result.fragmentFunctionName == "wpe_translated_fragment")
        #expect(!result.uniformLayout.isEmpty)
        #expect(result.library.makeFunction(name: "wpe_translated_fragment") != nil)
    }

    @Test("Project scroll shader uses vertex-computed scroll varying")
    func projectScrollShaderUsesVertexComputedScrollVarying() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/scroll",
            processedVertexSource: """
            #version 410 core
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform float g_ScrollX;
            uniform float g_ScrollY;
            uniform float g_Time;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec2 v_TexCoord;
            out vec2 v_Scroll;
            void main() {
                v_TexCoord = a_TexCoord;
                v_Scroll = sign(vec2(g_ScrollX, g_ScrollY)) * pow(abs(vec2(g_ScrollX, g_ScrollY)), vec2(2.0)) * g_Time;
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform vec2 g_Scale;
            in vec2 v_TexCoord;
            in vec2 v_Scroll;
            void main() {
                vec2 texCoord = fract((v_TexCoord + v_Scroll) * g_Scale);
                gl_FragColor = texture(g_Texture0, texCoord);
            }
            """,
            sourceHash: "scroll-varying-test",
            comboValues: [:],
            textureBindings: [:]
        )

        let result = try compiler.compile(request)

        #expect(result.uniformLayout.contains { $0.name == "g_ScrollX" })
        #expect(result.uniformLayout.contains { $0.name == "g_ScrollY" })
        #expect(result.uniformLayout.contains { $0.name == "g_Time" })
        #expect(!result.mslSource.contains("float2 v_Scroll = in.uv"))
        #expect(result.mslSource.contains("wpe_scroll_vector(g_ScrollX, g_ScrollY, g_Time)"))
    }

    @Test("Project waterwaves shader uses vertex-computed direction and mask UV")
    func projectWaterwavesShaderUsesVertexComputedDirectionAndMaskUV() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/waterwaves",
            processedVertexSource: """
            #version 410 core
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec4 g_Texture1Resolution;
            uniform float g_Direction;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec4 v_TexCoord;
            out vec2 v_Direction;
            void main() {
                v_TexCoord.xy = a_TexCoord;
                v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
                                     v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
                v_Direction = rotateVec2(vec2(0, 1), g_Direction);
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            uniform float g_Time;
            uniform float g_Speed;
            uniform float g_Scale;
            uniform float g_Strength;
            in vec4 v_TexCoord;
            in vec2 v_Direction;
            void main() {
                float mask = texture(g_Texture1, v_TexCoord.zw).r;
                vec2 texCoord = v_TexCoord.xy;
                float distance = g_Time * g_Speed + dot(texCoord, v_Direction) * g_Scale;
                texCoord += sin(distance) * vec2(v_Direction.y, -v_Direction.x) * g_Strength * mask;
                gl_FragColor = texture(g_Texture0, texCoord);
            }
            """,
            sourceHash: "waterwaves-varying-test",
            comboValues: [:],
            textureBindings: [:]
        )

        let result = try compiler.compile(request)

        #expect(result.uniformLayout.contains { $0.name == "g_Direction" })
        #expect(result.uniformLayout.contains { $0.name == "g_Texture1Resolution" })
        #expect(!result.mslSource.contains("float2 v_Direction = in.uv"))
        #expect(result.mslSource.contains("wpe_rotate_vec2(float2(0.0, 1.0), g_Direction)"))
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
    }

    @Test("Project foliage UV shader uses vertex-computed noise varyings")
    func projectFoliageUVShaderUsesVertexComputedNoiseVaryings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/foliagesway",
            processedVertexSource: """
            #version 410 core
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform float g_Strength;
            uniform float g_NoiseScale;
            uniform float g_Ratio;
            uniform float g_Direction;
            uniform vec4 g_Texture0Resolution;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec4 v_TexCoordNoise;
            out vec3 v_Params;
            out vec4 v_TexCoord;
            void main() {
                float aspect = g_Texture0Resolution.z / g_Texture0Resolution.w * g_Ratio;
                v_TexCoordNoise.zw = rotateVec2(vec2(1.0 / aspect, aspect), g_Direction);
                v_TexCoordNoise.xy = a_TexCoord.xy * g_NoiseScale;
                v_Params.xy = rotateVec2(a_TexCoord.xy, g_Direction);
                v_Params.z = g_Strength * g_Strength * 0.005;
                v_TexCoord.xy = a_TexCoord;
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2;
            uniform float g_Time;
            uniform float g_Speed;
            uniform float g_Power;
            uniform float g_Phase;
            in vec4 v_TexCoordNoise;
            in vec3 v_Params;
            in vec4 v_TexCoord;
            void main() {
                vec3 noise = texture(g_Texture2, v_TexCoordNoise.xy).rgb;
                float phase = (noise.g * 3.14159265 * 2.0 + v_Params.x * 10.0 + v_Params.y * 5.0) * g_Phase;
                vec2 offset = vec2(v_TexCoordNoise.z, v_TexCoordNoise.w) * sin(phase + g_Time * g_Speed) * v_Params.z;
                gl_FragColor = texture(g_Texture0, offset + v_TexCoord.xy);
            }
            """,
            sourceHash: "foliage-varying-test",
            comboValues: [:],
            textureBindings: [:]
        )

        let result = try compiler.compile(request)

        #expect(result.uniformLayout.contains { $0.name == "g_Texture0Resolution" })
        #expect(result.uniformLayout.contains { $0.name == "g_NoiseScale" })
        #expect(!result.mslSource.contains("float4 v_TexCoordNoise = float4(in.uv, in.uv)"))
        #expect(!result.mslSource.contains("float3 v_Params = float3(in.uv, 0.0)"))
        #expect(result.mslSource.contains("wpe_foliage_texcoord_noise(in.uv"))
        #expect(result.mslSource.contains("wpe_foliage_params(in.uv"))
    }

    @Test("Rejects perspective vertex varyings instead of synthesizing z=0")
    func rejectsPerspectiveVertexVaryings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/lightshafts",
            processedVertexSource: """
            #version 410 core
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec3 v_TexCoordFx;
            void main() {
                v_TexCoordFx = vec3(a_TexCoord, 1.0);
                gl_Position = vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            in vec3 v_TexCoordFx;
            void main() {
                vec2 fxCoord = v_TexCoordFx.xy / v_TexCoordFx.z;
                gl_FragColor = vec4(fxCoord, 0.0, 1.0);
            }
            """,
            sourceHash: "perspective-varying-test",
            comboValues: [:],
            textureBindings: [:]
        )

        #expect(throws: WPEShaderCompilerError.self) {
            _ = try compiler.compile(request)
        }
    }

    @Test("Translates audio-spectrum shader with uniform float array to MSL")
    func translatesAudioSpectrumArray() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float g_AudioSpectrum32Left[32];
        uniform float u_BarCount;
        in vec2 v_TexCoord;
        void main() {
            int idx = int(v_TexCoord.x * u_BarCount);
            float bar = g_AudioSpectrum32Left[idx];
            gl_FragColor = vec4(bar, bar, bar, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "audio_bars",
            preprocessedSource: source
        )
        let spectrum = try #require(result.uniformLayout.first { $0.name == "g_AudioSpectrum32Left" })
        #expect(spectrum.arrayLength == 32)
        #expect(spectrum.slotCount == 32)
        #expect(spectrum.slot == 0)
        let barCount = try #require(result.uniformLayout.first { $0.name == "u_BarCount" })
        #expect(barCount.slot == 32)

        #expect(result.mslSource.contains("float g_AudioSpectrum32Left[32];"))
        #expect(result.mslSource.contains("g_AudioSpectrum32Left[0] = u.vals[0].x;"))
        #expect(result.mslSource.contains("g_AudioSpectrum32Left[31] = u.vals[31].x;"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Audio runtime publishes spectrum slices for each resolution")
    func audioRuntimePublishesSpectrumSlices() {
        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.5,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            audioSpectrum: (0..<64).map { Double($0) / 63.0 }
        )
        let values = runtime.uniformValues
        guard case .vector(let s32) = values["g_AudioSpectrum32Left"] else {
            #expect(Bool(false), "Missing g_AudioSpectrum32Left"); return
        }
        guard case .vector(let s64) = values["g_AudioSpectrum64Left"] else {
            #expect(Bool(false), "Missing g_AudioSpectrum64Left"); return
        }
        #expect(s32.count == 32)
        #expect(s64.count == 64)
        #expect(abs(s32[0] - (s64[0] + s64[1]) * 0.5) < 1e-9)
    }

    @Test("Rejects shaders with no main entry point")
    func rejectsShadersWithoutMain() {
        let source = """
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        // no main function
        """
        #expect(throws: WPEShaderCompilerError.self) {
            _ = try WPEShaderTranspiler.translateFragment(
                shaderName: "broken",
                preprocessedSource: source
            )
        }
    }

    @Test("Strips GLSL 'in' parameter qualifiers so MSL accepts helper signatures")
    func stripsInParameterQualifier() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        float3 ApplyBlending(const int blendMode, in float3 A, in float3 B, in float opacity) {
            float3 result = B;
            if (blendMode == 1) { result = A; }
            return mix(A, result, opacity);
        }
        void main() {
            vec4 c = texture(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(ApplyBlending(0, c.rgb, c.rgb, 1.0), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "blend-in-quals",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("in float3 A"))
        #expect(!result.mslSource.contains("in float3 B"))
        #expect(!result.mslSource.contains("in float opacity"))
        #expect(result.mslSource.contains("float3 A"))
        #expect(!result.mslSource.contains("thread in"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("In-qualifier strip leaves top-level vertex inputs untouched")
    func inQualifierIgnoresTopLevelInputs() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec3 v_Normal;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * vec4(v_Normal, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "in-top-level",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("WPEStageIn"))
        #expect(!result.mslSource.contains("in vec2 v_TexCoord;"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Fragment out_FragColor scrub catches all variants")
    func fragmentOutScrubCatchesAllVariants() {
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 out_FragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out float4 out_FragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 wpe_fragColor;").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let mixed = WPEShaderTranspiler.scrubFragmentOutDeclarations("precision highp float; out vec4 out_FragColor;")
        #expect(!mixed.contains("out_FragColor"))
        #expect(mixed.contains("precision highp float"))
        let withComment = WPEShaderTranspiler.scrubFragmentOutDeclarations("out vec4 out_FragColor; // injected by prelude\n#define M_PI 3.14")
        #expect(!withComment.contains("out_FragColor"))
        #expect(withComment.contains("#define M_PI"))
        let unrelated = "void foo(out float3 col) { col = float3(0); }"
        #expect(WPEShaderTranspiler.scrubFragmentOutDeclarations(unrelated) == unrelated)
    }

    @Test("End-to-end: shader with prelude out_FragColor compiles cleanly")
    func endToEndPreludeOutFragColor() throws {
        let source = """
        // LiveWallpaper WPE shader prelude
        #define GLSL 1
        #define mul(x, y) ((y) * (x))
        #define CAST3(x) (vec3(x))
        out vec4 out_FragColor;
        #define varying in

        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            out_FragColor = texture(g_Texture0, v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "out_fragcolor_smoke",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("out float4 out_FragColor"))
        #expect(!result.mslSource.contains("out vec4 out_FragColor"))
        #expect(result.mslSource.contains("out_color"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("linearSampler is declared at file scope so helpers can use it")
    func linearSamplerAtFileScope() throws {
        let source = """
        #version 410 core
        in vec2 v_TexCoord;
        // Helper using only the sampler (texture passed as arg externally).
        float computeAngle(float2 uv) {
            return uv.x + uv.y;
        }
        void main() {
            gl_FragColor = vec4(computeAngle(v_TexCoord), 0.0, 0.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "filescope_sampler",
            preprocessedSource: source
        )
        let mslSource = result.mslSource
        let samplerRange = try #require(mslSource.range(of: "constexpr sampler linearSampler"))
        let helperRange = try #require(mslSource.range(of: "float computeAngle("))
        #expect(samplerRange.lowerBound < helperRange.lowerBound, "linearSampler must precede the helper")
        let mainStart = try #require(mslSource.range(of: "wpe_translated_fragment"))
        let mainBodyRest = mslSource[mainStart.upperBound...]
        #expect(!mainBodyRest.contains("constexpr sampler linearSampler"), "no duplicate declaration inside main()")

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: mslSource, options: opts)
    }

    @Test("Generated resource aliases are warning-clean when unused")
    func generatedResourceAliasesAreWarningCleanWhenUnused() throws {
        let source = """
        #version 410 core
        #define M_PI_F 3.14159265358979323846f
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform float g_Time;
        in vec2 v_TexCoord;
        in vec4 v_TexCoordMask;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "unused_generated_aliases",
            preprocessedSource: source
        )

        #expect(result.mslSource.contains("[[maybe_unused]] auto g_Texture1 = tex1;"))
        #expect(result.mslSource.contains("[[maybe_unused]] float g_Time = u.vals[0].x;"))
        #expect(result.mslSource.contains("[[maybe_unused]] float4 v_TexCoordMask = float4(in.uv, in.uv);"))
        #expect(!result.mslSource.contains("#define M_PI_F"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Generated linear sampler is warning-clean when unused")
    func generatedLinearSamplerIsWarningCleanWhenUnused() throws {
        let source = """
        #version 410 core
        void main() {
            gl_FragColor = vec4(1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "unused_linear_sampler",
            preprocessedSource: source
        )

        #expect(result.mslSource.contains("[[maybe_unused]] constexpr sampler linearSampler"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }
}
