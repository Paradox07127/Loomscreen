import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

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
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("out vec4") == false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Perspective + dual-wave varyings reconstruct to faithful MSL that compiles")
    func reconstructsPerspectiveAndDualWaveVaryings() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_Point0;
        uniform vec2 g_Point1;
        uniform vec2 g_Point2;
        uniform vec2 g_Point3;
        uniform float g_Direction2;
        in vec2 v_TexCoord;
        in vec2 v_Direction2;
        in vec3 v_TexCoordPerspective;
        void main() {
            vec2 motion = v_TexCoordPerspective.xy / v_TexCoordPerspective.z;
            vec2 offset = vec2(v_Direction2.y, -v_Direction2.x);
            gl_FragColor = texture(g_Texture0, motion + offset + v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "waterwaves",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_perspective_texcoord(in.uv, g_Point0, g_Point1, g_Point2, g_Point3)"))
        #expect(result.mslSource.contains("wpe_rotate_vec2(float2(0.0, 1.0), g_Direction2)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Array varying with a #define-sized dimension ([RESOLUTION]) emits compilable MSL")
    func reconstructsSymbolicArrayVarying() throws {
        let source = """
        // stage: fragment
        #version 410 core
        #define RESOLUTION 64
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec4 audioValue[RESOLUTION];
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) + audioValue[0];
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "audio_responsive_oscilloscope",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("audioValue[RESOLUTION] = {};"))
        #expect(result.mslSource.contains("audioValue[RESOLUTION] = float4") == false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Audio oscilloscope perspective/view varyings keep valid homogeneous z")
    func reconstructsAudioOscilloscopePerspectiveAndViewVaryings() throws {
        let source = """
        // stage: fragment
        #version 410 core
        #define RESOLUTION 32
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture2;
        uniform vec2 g_Point0;
        uniform vec2 g_Point1;
        uniform vec2 g_Point2;
        uniform vec2 g_Point3;
        uniform float u_ampExponent;
        uniform float u_FreqBalance;
        uniform float u_LRBalance;
        uniform float g_AudioSpectrum32Left[32];
        uniform float g_AudioSpectrum32Right[32];
        in vec2 v_TexCoord;
        in vec3 v_PerspCoord;
        in vec3 v_ViewCoord;
        in vec4 audioValue[RESOLUTION];
        void main() {
            vec2 perspCoord = v_PerspCoord.xy / max(0.001, v_PerspCoord.z);
            vec2 viewCoord = v_ViewCoord.xy / v_ViewCoord.z * 0.5 + 0.5;
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            albedo.rgb += texture(g_Texture2, viewCoord).rgb * audioValue[0].x;
            albedo.a = mix(albedo.a, 1.0, step(0.0, v_PerspCoord.z));
            gl_FragColor = albedo + vec4(perspCoord, 0.0, 0.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2799421411/effects/audio_responsive_oscilloscope",
            preprocessedSource: source,
            comboValues: ["RESOLUTION": 32, "PERSPECTIVE": 0, "EQUALIZE": 0]
        )
        #expect(result.mslSource.contains("v_PerspCoord = float3(in.uv, 1.0)"))
        #expect(result.mslSource.contains("v_ViewCoord = float3(in.uv * 2.0 - 1.0, 1.0)"))
        #expect(result.mslSource.contains("audioValue[wpeAudioIndex / 4] = float4("))
        #expect(result.mslSource.contains("wpe_audio_oscilloscope_value(g_AudioSpectrum32Left"))
        #expect(!result.mslSource.contains("v_PerspCoord = float3(in.uv, 0.0)"))
        #expect(!result.mslSource.contains("v_ViewCoord = float3(in.uv, 0.0)"))
        #expect(!result.mslSource.contains("WPE-DIAGNOSTIC: varying 'v_PerspCoord'"))
        #expect(!result.mslSource.contains("WPE-DIAGNOSTIC: varying 'v_ViewCoord'"))
        #expect(!result.mslSource.contains("WPE-DIAGNOSTIC: varying 'audioValue'"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("waterflow v_Cycles / v_Blend varyings reconstruct from time uniforms (not screen UV)")
    func reconstructsWaterflowFlowVaryings() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture1Resolution;
        uniform float g_FlowAmp;
        uniform float g_FlowSpeed;
        uniform float g_PhaseFeather;
        uniform float g_Time;
        in vec4 v_TexCoord;
        in vec4 v_Cycles;
        in vec2 v_Blend;
        void main() {
            vec2 flowMask = (texture(g_Texture1, v_TexCoord.zw).rg - vec2(0.498)) * 2.0;
            vec4 off = vec4(flowMask.xyxy * g_FlowAmp * 0.1) * v_Cycles.xxyy;
            vec4 a = mix(texture(g_Texture0, v_TexCoord.xy + off.xy),
                         texture(g_Texture0, v_TexCoord.xy + off.zw), v_Blend.x);
            gl_FragColor = mix(texture(g_Texture0, v_TexCoord.xy), a, length(flowMask));
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterflow",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_waterflow_cycles(g_Time, g_FlowSpeed)"))
        #expect(result.mslSource.contains("wpe_waterflow_blend(g_Time, g_FlowSpeed, g_PhaseFeather)"))
        #expect(!result.mslSource.contains("v_Cycles = float4(in.uv, in.uv)"))
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
        #expect(result.mslSource.contains("v_TexCoord.zw"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_AudioShift reconstructs the audio response (rest = 0), not the in.uv.x default")
    func reconstructsAudioShiftVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float u_rOffset;
        uniform float u_gOffset;
        uniform float u_bOffset;
        uniform float g_AudioSpectrum16Left[16];
        uniform float g_AudioSpectrum16Right[16];
        uniform float g_AudioFrequencyMin;
        uniform float g_AudioFrequencyMax;
        uniform float g_AudioPower;
        uniform vec2 g_AudioBounds;
        uniform float g_AudioMultiply;
        in vec4 v_TexCoord;
        in float v_AudioShift;
        void main() {
            vec4 rValue = texture(g_Texture0, v_TexCoord.xy - (u_rOffset * v_AudioShift));
            vec4 gValue = texture(g_Texture0, v_TexCoord.xy - (u_gOffset * v_AudioShift));
            vec4 bValue = texture(g_Texture0, v_TexCoord.xy - (u_bOffset * v_AudioShift));
            gl_FragColor = vec4(rValue.r, gValue.g, bValue.b, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2423877731/effects/chromatic_aberration",
            preprocessedSource: source,
            comboValues: ["AUDIOPROCESSING": 2]
        )
        #expect(result.mslSource.contains(
            "wpe_audio_response16(g_AudioSpectrum16Left, g_AudioSpectrum16Right, 2,"
        ))
        #expect(!result.mslSource.contains("v_AudioShift = in.uv.x"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("filmgrain v_TexCoordNoise tiles by g_NoiseScale/time, not raw screen UV")
    func reconstructsFilmgrainNoiseVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture0Resolution;
        uniform float g_Time;
        uniform float g_NoiseScale;
        uniform float g_NoiseAlpha;
        uniform float g_NoisePower;
        in vec4 v_TexCoord;
        in vec4 v_TexCoordNoise;
        void main() {
            vec3 noise = texture(g_Texture1, v_TexCoordNoise.xy).rgb;
            vec3 noise2 = texture(g_Texture1, v_TexCoordNoise.zw).gbr;
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            albedo.rgb = mix(albedo.rgb, noise * noise2, g_NoiseAlpha * g_NoisePower);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/filmgrain",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains(
            "wpe_filmgrain_texcoord_noise(in.uv, g_Time, g_NoiseScale, g_Texture0Resolution)"
        ))
        #expect(!result.mslSource.contains("v_TexCoordNoise = float4(in.uv, in.uv)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Each texture read emits its own per-slot sampler (wrap bound at runtime)")
    func noiseTextureUsesRepeatSampler() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_noise","default":"util/noise"}
        uniform vec4 g_Texture0Resolution;
        uniform float g_Time;
        uniform float g_NoiseScale;
        uniform float g_NoiseAlpha;
        in vec4 v_TexCoord;
        in vec4 v_TexCoordNoise;
        void main() {
            vec3 noise = texture(g_Texture1, v_TexCoordNoise.xy).rgb;
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            albedo.rgb = mix(albedo.rgb, noise, g_NoiseAlpha);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/filmgrain",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("sampler wpeSampler1 [[sampler(1)]]"))
        #expect(result.mslSource.contains("g_Texture1.sample(wpeSampler1, v_TexCoordNoise.xy)"))
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0, v_TexCoord.xy)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Mask and framebuffer reads also map to their per-slot samplers")
    func nonNoiseTexturesKeepClampSampler() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1; // {"material":"opacity_mask"}
        in vec4 v_TexCoord;
        void main() {
            float m = texture(g_Texture1, v_TexCoord.xy).r;
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy) * m;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/genericmask",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("g_Texture1.sample(wpeSampler1, v_TexCoord.xy)"))
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0, v_TexCoord.xy)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_equalScaleFactor reconstructs the aspect factor, not screen UV")
    func reconstructsEqualScaleFactorVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        in vec4 v_TexCoord;
        in vec2 v_equalScaleFactor;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy * v_equalScaleFactor);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/3206438810/effects/multistage_wave",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("max(1.0, wpe_safe_ratio(g_Texture0Resolution.x, g_Texture0Resolution.y))"))
        #expect(!result.mslSource.contains("v_equalScaleFactor = in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_Pulse reconstructs the time/audio pulse scalar, not in.uv.x")
    func reconstructsPulseVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float g_Time;
        uniform vec2 g_PulseThresholds;
        uniform float g_PulseSpeed;
        uniform float g_PulsePhase;
        uniform float g_PulseAmount;
        in vec4 v_TexCoord;
        in float v_Pulse;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            gl_FragColor = albedo * v_Pulse;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/pulse",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_pulse_response(g_Time, g_PulseThresholds, g_PulseSpeed, g_PulsePhase, g_PulseAmount)"))
        #expect(!result.mslSource.contains("v_Pulse = in.uv.x"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_ParallaxOffset reconstructs from g_ParallaxPosition (neutral at rest), not screen UV")
    func reconstructsParallaxOffsetVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_ParallaxPosition;
        in vec4 v_TexCoord;
        in vec2 v_ParallaxOffset;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + (v_ParallaxOffset - 0.5) * 0.1);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/depthparallax",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float2 v_ParallaxOffset = g_ParallaxPosition;"))
        #expect(!result.mslSource.contains("v_ParallaxOffset = in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("ivec/bvec uniforms unpack all components, not just .x")
    func unpacksIntAndBoolVectorUniforms() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform ivec2 g_Grid;
        uniform ivec3 g_Triple;
        uniform ivec4 g_Quad;
        uniform bvec2 g_Flags;
        in vec2 v_TexCoord;
        void main() {
            vec2 t = v_TexCoord + vec2(float(g_Grid.x + g_Grid.y), float(g_Triple.z + g_Quad.w));
            if (g_Flags.y) { t += 0.001; }
            gl_FragColor = texture(g_Texture0, t);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "ivecbvec",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("int2 g_Grid = int2(u.vals[0].xy)"))
        #expect(result.mslSource.contains("int3 g_Triple = int3(u.vals[1].xyz)"))
        #expect(result.mslSource.contains("bool2 g_Flags = u.vals[3].xy > float2(0.5)"))
        #expect(!result.mslSource.contains("int2 g_Grid = u.vals[0].x"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("multistage_wave v_DirectionN reconstructs from g_SpinCenter deltas, not screen UV")
    func reconstructsMultistageWaveDirections() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_SpinCenter1;
        uniform vec2 g_SpinCenter2;
        uniform vec2 g_SpinCenter3;
        uniform float g_DirectionOffset;
        in vec4 v_TexCoord;
        in vec2 v_Direction1;
        in vec4 v_Direction2;
        void main() {
            vec2 d = v_Direction1 + v_Direction2.xy + v_Direction2.zw;
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + d * 0.001);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/3206438810/effects/multistage_wave",
            preprocessedSource: source,
            comboValues: ["GLOBAL_ROTATION": 1]
        )
        #expect(result.mslSource.contains("float2 v_Direction1 = wpe_safe_normalize(g_SpinCenter2 - g_SpinCenter1)"))
        #expect(result.mslSource.contains("wpe_rotate_vec2(wpe_safe_normalize(g_SpinCenter3 - g_SpinCenter2), g_DirectionOffset)"))
        #expect(!result.mslSource.contains("v_Direction1 = in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_DirectionN vec4 does not rotate .zw without the GLOBAL_ROTATION combo")
    func multistageDirectionVec4WithoutGlobalRotation() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_SpinCenter1;
        uniform vec2 g_SpinCenter2;
        uniform float g_DirectionOffset;
        in vec2 v_TexCoord;
        in vec4 v_Direction1;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord + v_Direction1.zw * 0.001);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/3206438810/effects/multistage_wave",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float4 v_Direction1 = float4(wpe_safe_normalize(g_SpinCenter2 - g_SpinCenter1), wpe_safe_normalize(g_SpinCenter2 - g_SpinCenter1))"))
        #expect(!result.mslSource.contains("wpe_rotate_vec2(wpe_safe_normalize"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_AudioPulse stays 0.0 when no audio spectrum uniforms are present")
    func audioPulseFallsBackToZeroWithoutAudio() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in float v_AudioPulse;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * (1.0 + v_AudioPulse);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/shake",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float v_AudioPulse = 0.0;"))
        #expect(!result.mslSource.contains("v_AudioPulse = in.uv.x"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("v_AudioPulse reconstructs the audio response when spectrum uniforms exist")
    func reconstructsAudioPulseVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float g_AudioSpectrum16Left[16];
        uniform float g_AudioSpectrum16Right[16];
        uniform float g_AudioFrequencyMin;
        uniform float g_AudioFrequencyMax;
        uniform float g_AudioPower;
        uniform vec2 g_AudioBounds;
        uniform float g_AudioMultiply;
        in vec2 v_TexCoord;
        in float v_AudioPulse;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * (1.0 + v_AudioPulse);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/shake",
            preprocessedSource: source,
            comboValues: ["AUDIOPROCESSING": 3]
        )
        #expect(result.mslSource.contains("wpe_audio_response16(g_AudioSpectrum16Left, g_AudioSpectrum16Right, 3,"))
        #expect(!result.mslSource.contains("v_AudioPulse = in.uv.x"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A used varying with no reconstruction rule emits a diagnostic marker (not silent)")
    func emitsDiagnosticForUnreconstructedVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec2 v_MysteryOffset;
        in vec2 v_UnusedThing;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord + v_MysteryOffset * 0.01);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/unknown",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("WPE-DIAGNOSTIC: varying 'v_MysteryOffset'"))
        #expect(!result.mslSource.contains("v_UnusedThing'"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("shake preserves v_TexCoord.zw (flow-map UV) instead of downgrading to .xy")
    func preservesShakeFlowTexCoordZW() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform sampler2D g_Texture2;
        uniform vec4 g_Texture1Resolution;
        in vec4 v_TexCoord;
        void main() {
            float flowPhase = texture(g_Texture2, v_TexCoord.zw).r;
            vec2 flowColors = texture(g_Texture1, v_TexCoord.zw).rg;
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + flowColors * flowPhase * 0.01);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2125458920/effects/shake",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
        #expect(result.mslSource.contains("g_Texture2.sample(wpeSampler2, v_TexCoord.zw)"))
        #expect(result.mslSource.contains("g_Texture1.sample(wpeSampler1, v_TexCoord.zw)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("non-vouched effects still downgrade v_TexCoord.zw to .xy (historical)")
    func nonWhitelistedEffectDowngradesTexCoordZW() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture1Resolution;
        in vec4 v_TexCoord;
        void main() {
            vec2 mask = texture(g_Texture1, v_TexCoord.zw).rg;
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + mask * 0.01);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/someotherglitch",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("v_TexCoord.zw"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("reflection MASK samples the opacity mask at v_TexCoord.zw (aspect-scaled), not .xy")
    func reflectionMaskSamplesAspectScaledZW() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture1Resolution;
        uniform float g_ReflectionAlpha;
        in vec4 v_TexCoord;
        in vec2 v_ReflectedCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            float mask = texture(g_Texture1, v_TexCoord.zw).r;
            vec4 reflected = texture(g_Texture0, v_ReflectedCoord);
            gl_FragColor = mix(albedo, reflected, mask * g_ReflectionAlpha);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/reflection",
            preprocessedSource: source,
            comboValues: ["MASK": 1, "PERSPECTIVE": 0]
        )
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
        #expect(result.mslSource.contains("g_Texture1.sample(wpeSampler1, v_TexCoord.zw)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("vhs MASK scales v_TexCoord.zw by g_Texture2Resolution (mask binds slot 2, not 1)")
    func vhsMaskUsesSlotTwoResolution() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform sampler2D g_Texture2;
        uniform vec4 g_Texture1Resolution;
        uniform vec4 g_Texture2Resolution;
        in vec4 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            float vhsBlend = texture(g_Texture1, v_TexCoord.xy).r;
            vhsBlend *= texture(g_Texture2, v_TexCoord.zw).r;
            gl_FragColor = albedo * vhsBlend;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/12345/effects/vhs",
            preprocessedSource: source,
            comboValues: ["MASK": 1]
        )
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture2Resolution)"))
        #expect(result.mslSource.contains("g_Texture2.sample(wpeSampler2, v_TexCoord.zw)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("lightshafts MASK scales v_TexCoord.zw by g_Texture3Resolution")
    func lightshaftsMaskUsesSlotThreeResolution() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture3;
        uniform vec4 g_Texture1Resolution;
        uniform vec4 g_Texture3Resolution;
        in vec4 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            float maskSample = texture(g_Texture3, v_TexCoord.zw).r;
            gl_FragColor = albedo * maskSample;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/lightshafts",
            preprocessedSource: source,
            comboValues: ["MASK": 1]
        )
        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture3Resolution)"))
        #expect(result.mslSource.contains("g_Texture3.sample(wpeSampler3, v_TexCoord.zw)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("a recognized family with its exact resolution slot missing never scales by another slot")
    func missingExactSlotDoesNotFallBackToWrongResolution() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture3;
        uniform vec4 g_Texture1Resolution;
        in vec4 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
            float maskSample = texture(g_Texture3, v_TexCoord.zw).r;
            gl_FragColor = albedo * maskSample;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/lightshafts",
            preprocessedSource: source,
            comboValues: ["MASK": 1]
        )
        #expect(!result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("swing rebuilds v_TexCoord.zw as aspect (res.x/.y) + sine phase, even under MASK")
    func swingRebuildsAspectAndSinePhase() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture0Resolution;
        uniform vec4 g_Texture1Resolution;
        uniform float g_Time;
        uniform float g_Speed;
        uniform float g_Phase;
        uniform float g_Amount;
        in vec4 v_TexCoord;
        in vec2 v_TexCoordMask;
        void main() {
            vec2 texCoord = v_TexCoord.xy;
            float aspect = v_TexCoord.z;
            texCoord.x *= aspect;
            float anim = v_TexCoord.w;
            texCoord += anim * 0.01;
            texCoord.x /= aspect;
            float mask = texture(g_Texture1, v_TexCoordMask).r;
            gl_FragColor = texture(g_Texture0, texCoord) * mask;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/swing",
            preprocessedSource: source,
            comboValues: ["MASK": 1]
        )
        #expect(result.mslSource.contains("wpe_swing_texcoord(in.uv, g_Texture0Resolution.xy, g_Time, g_Speed, g_Phase, g_Amount)"))
        #expect(!result.mslSource.contains("wpe_texcoord_with_resolution(in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("twirl rebuilds v_TexCoord.zw with the res.z/.w aspect (workshop path form)")
    func twirlRebuildsAspectFromZWComponents() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        uniform vec2 g_SpinCenter;
        uniform float g_Time;
        uniform float g_Speed;
        uniform float g_Phase;
        uniform float g_Amount;
        in vec4 v_TexCoord;
        void main() {
            float aspect = v_TexCoord.z;
            vec2 texCoord = v_TexCoord.xy - g_SpinCenter;
            texCoord.x *= aspect;
            float anim = v_TexCoord.w * length(texCoord);
            texCoord.x /= aspect;
            texCoord += g_SpinCenter + anim * 0.01;
            gl_FragColor = texture(g_Texture0, texCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/12345/effects/twirl",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_swing_texcoord(in.uv, g_Texture0Resolution.zw, g_Time, g_Speed, g_Phase, g_Amount)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("swing with the vert-only uniforms missing keeps the historical fallback")
    func swingWithoutVertUniformsFallsBack() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        uniform float g_Time;
        in vec4 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord.xy + v_TexCoord.zw * 0.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/swing",
            preprocessedSource: source
        )
        #expect(!result.mslSource.contains("wpe_swing_texcoord(in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("blend preserves v_TexCoord.zw only without TRANSFORMUV")
    func blendPreservesZWOnlyWithoutTransformUV() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Texture1Resolution;
        in vec4 v_TexCoord;
        void main() {
            vec2 blendUV = v_TexCoord.zw;
            vec4 blendColor = texture(g_Texture1, blendUV);
            gl_FragColor = mix(texture(g_Texture0, v_TexCoord.xy), blendColor, blendColor.a);
        }
        """
        let plain = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/blend",
            preprocessedSource: source,
            comboValues: ["TRANSFORMUV": 0]
        )
        #expect(plain.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
        #expect(plain.mslSource.contains("v_TexCoord.zw"))

        let transformed = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/blend",
            preprocessedSource: source,
            comboValues: ["TRANSFORMUV": 1]
        )
        #expect(!transformed.mslSource.contains("v_TexCoord.zw"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: plain.mslSource, options: opts)
        _ = try device.makeLibrary(source: transformed.mslSource, options: opts)
    }

    @Test("clipping mask narrows float4 v_TexCoord in vec2 transform arithmetic")
    func clippingMaskNarrowsTexCoordInVector2Arithmetic() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec2 u_textureScale;
        uniform vec2 u_textureOffset;
        uniform vec2 u_maskScale;
        uniform vec2 u_maskOffset;
        uniform vec2 texScaleCenter;
        uniform vec2 maskScaleCenter;
        uniform vec2 ratioDiff;
        in vec4 v_TexCoord;
        void main() {
            vec2 uvTex = ((v_TexCoord * 2.0 - 1.0 - texScaleCenter) / ratioDiff / u_textureScale + 1.0 + texScaleCenter) / 2.0 - u_textureOffset;
            vec2 uvMask = ((v_TexCoord * 2.0 - 1.0 - maskScaleCenter) / u_maskScale + 1.0 + maskScaleCenter) / 2.0 - u_maskOffset;
            gl_FragColor = texture(g_Texture0, uvTex) * texture(g_Texture1, uvMask).a;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2800594362/effects/clipping_mask",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("v_TexCoord.xy * 2.0"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("unused clipping mask UV locals are emitted warning-clean")
    func unusedClippingMaskUVLocalsAreWarningClean() throws {
        let source = """
        #version 410 core
        uniform vec2 u_textureScale;
        uniform vec2 u_textureOffset;
        uniform vec2 u_maskScale;
        uniform vec2 u_maskOffset;
        uniform vec2 texScaleCenter;
        uniform vec2 maskScaleCenter;
        uniform vec2 ratioDiff;
        in vec4 v_TexCoord;
        void main() {
            vec2 uvTex = ((v_TexCoord * 2.0 - 1.0 - texScaleCenter) / ratioDiff / u_textureScale + 1.0 + texScaleCenter) / 2.0 - u_textureOffset;
            vec2 uvMask = ((v_TexCoord * 2.0 - 1.0 - maskScaleCenter) / u_maskScale + 1.0 + maskScaleCenter) / 2.0 - u_maskOffset;
            gl_FragColor = vec4(1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2800594362/effects/clipping_mask",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("[[maybe_unused]] float2 uvTex ="))
        #expect(result.mslSource.contains("[[maybe_unused]] float2 uvMask ="))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("texSample2DLod / textureLod translates to a Metal level() sample and compiles")
    func translatesTextureLodFragment() throws {
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
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("level("))
        #expect(result.mslSource.contains("v_TexCoord.xy"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Nested textureLod is fully rewritten (no textureLod survives) and compiles")
    func translatesNestedTextureLodFragment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = textureLod(g_Texture0, textureLod(g_Texture0, v_TexCoord, 1.0).xy, 2.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "nestedlod",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("textureLod(") == false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("ddx/ddy (GLSL dFdx/dFdy) translate to MSL dfdx/dfdy and compile")
    func translatesDerivativeFragment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            vec2 dx = dFdx(v_TexCoord);
            vec2 dy = dFdy(v_TexCoord);
            gl_FragColor = texture(g_Texture0, v_TexCoord + dx + dy);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "deriv",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("dFdx(") == false)
        #expect(result.mslSource.contains("dFdy(") == false)
        #expect(result.mslSource.contains("dfdx("))
        #expect(result.mslSource.contains("dfdy("))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("CAST2X2/CAST4X4 matrix-cast macros translate to MSL float matrices and compile")
    func translatesMatrixCastMacros() throws {
        let source = """
        #version 410 core
        #define CAST2X2(x) (mat2(x))
        #define CAST4X4(x) (mat4(x))
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() {
            mat2 a = CAST2X2(1.0);
            mat4 b = CAST4X4(1.0);
            vec4 c = texture(g_Texture0, v_TexCoord);
            gl_FragColor = b * c + vec4(a[0], 0.0, 0.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "matcast",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("float4x4"))
        #expect(result.mslSource.contains("float2x2"))
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

    @Test("Sampler slot 7 (g_Texture0–g_Texture7) compiles and aliases tex7")
    func samplerSlot7CompilesAndAliasesTex7() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture7;
        in vec2 v_TexCoord;
        void main() {
            vec4 base = texture(g_Texture0, v_TexCoord);
            vec4 hi = texture(g_Texture7, v_TexCoord);
            gl_FragColor = base * hi.a;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "slot7",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("auto g_Texture7 = tex7;"))
        #expect(result.mslSource.contains("texture2d<float> tex7"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Sampler slots above the supported 0–7 range are rejected, not mis-emitted")
    func rejectsTextureSlotsAboveSupportedRange() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture8;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture8, v_TexCoord);
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

    @Test("auto_sway v2 varyings reconstruct vertex sway state (not screen-UV) and compile")
    func autoSwayV2VaryingsReconstructAndCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "workshop/3235948233/effects/auto_sway",
            processedVertexSource: """
            #define AA_VERSION 2
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform float g_GlobalTimeOffset; // {"material":"timeoffset","default":0}
            uniform float g_Speed; // {"material":"speed","default":0.75}
            uniform float g_Inertia; // {"material":"inertia","default":0.3}
            uniform float g_SigmentCount; // {"material":"sigment","default":1}
            in vec3 a_Position;
            in vec2 a_TexCoord;
            void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); }
            """,
            processedFragmentSource: """
            #define AA_VERSION 2
            #define NODE_COUNT 2
            uniform sampler2D g_Texture0;
            uniform vec4 g_Texture0Resolution;
            uniform float g_Time;
            uniform vec2 g_SpinCenter1; // {"material":"center1","position":true}
            uniform vec2 g_SpinCenter2; // {"material":"center2","position":true}
            uniform float g_WindDirection2; // {"material":"angle2","default":-1.57075}
            uniform float g_GlobalWindOffset; // {"material":"windDirectionOffset","default":0}
            uniform float g_SmoothDistance; // {"material":"smoothDistance","default":1}
            uniform float g_DirectionalCompensation; // {"material":"directionalCompensation","default":0}
            #if AA_VERSION == 1
            uniform float g_Speed; // {"material":"speed","default":0.75}
            uniform float g_Inertia; // {"material":"inertia","default":0.3}
            uniform float g_SigmentCount; // {"material":"sigment","default":1}
            uniform float g_GlobalTimeOffset; // {"material":"timeoffset","default":0}
            #endif
            varying vec4 v_TexCoord;
            varying float v_aspect;
            varying float v_reciprocalAspect;
            varying float v_Len1;
            varying vec2 v_Direction1;
            varying float v_EndpointLen1;
            varying vec2 v_EndpointDirection1;
            varying float v_PosX1;
            varying float v_EndpointPosX1;
            varying float v_MotionRadian1;
            void main() {
                vec2 uv = v_TexCoord.xy;
                uv += v_Direction1 * v_MotionRadian1 * 0.01 * v_Len1 * v_EndpointLen1;
                uv += v_EndpointDirection1 * (v_PosX1 + v_EndpointPosX1) * 0.001;
                uv.x *= v_reciprocalAspect;
                gl_FragColor = texture(g_Texture0, uv) * v_aspect;
            }
            """,
            sourceHash: "auto-sway-v2-test",
            comboValues: ["AA_VERSION": 2, "NODE_COUNT": 2],
            textureBindings: [:]
        )
        let result = try compiler.compile(request)
        let msl = result.mslSource
        #expect(msl.contains("v_MotionRadian1 = wpeAS_thisRad - wpeAS_prevRad"))
        #expect(msl.contains("v_TexCoord = float4(in.uv.x * v_aspect, in.uv.y, in.uv.x * v_aspect, in.uv.y)"))
        #expect(!msl.contains("WPE-DIAGNOSTIC: varying 'v_MotionRadian1'"))
        #expect(result.uniformLayout.contains { $0.name == "g_Speed" })
        #expect(result.uniformLayout.contains { $0.name == "g_SigmentCount" })
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

    @Test("Waterwaves TIMEOFFSET combo scales v_TexCoord.zw by g_Texture2Resolution")
    func waterwavesTimeOffsetUsesTexture2Resolution() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "effects/waterwaves",
            processedVertexSource: """
            #version 410 core
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec4 g_Texture1Resolution;
            uniform vec4 g_Texture2Resolution;
            uniform float g_Direction;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            out vec4 v_TexCoord;
            out vec2 v_Direction;
            void main() {
                v_TexCoord.xy = a_TexCoord;
                v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture2Resolution.z / g_Texture2Resolution.x,
                                     v_TexCoord.y * g_Texture2Resolution.w / g_Texture2Resolution.y);
                v_Direction = rotateVec2(vec2(0, 1), g_Direction);
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            }
            """,
            processedFragmentSource: """
            #version 410 core
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2;
            uniform float g_Time;
            uniform float g_Speed;
            uniform float g_Scale;
            uniform float g_Strength;
            in vec4 v_TexCoord;
            in vec2 v_Direction;
            void main() {
                float timeOffset = texture(g_Texture2, v_TexCoord.zw).r;
                vec2 texCoord = v_TexCoord.xy;
                float distance = g_Time * g_Speed + dot(texCoord, v_Direction) * g_Scale + timeOffset;
                texCoord += sin(distance) * vec2(v_Direction.y, -v_Direction.x) * g_Strength;
                gl_FragColor = texture(g_Texture0, texCoord);
            }
            """,
            sourceHash: "waterwaves-timeoffset-test",
            comboValues: ["TIMEOFFSET": 1],
            textureBindings: [:]
        )

        let result = try compiler.compile(request)

        #expect(result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture2Resolution)"))
        #expect(!result.mslSource.contains("wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)"))
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

    @Test("lightshafts v_TexCoordFx perspective varying reconstructs to faithful MSL that compiles")
    func reconstructsLightshaftsPerspectiveVarying() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_Point0;
        uniform vec2 g_Point1;
        uniform vec2 g_Point2;
        uniform vec2 g_Point3;
        in vec2 v_TexCoord;
        in vec3 v_TexCoordFx;
        void main() {
            vec2 fxCoord = v_TexCoordFx.xy / v_TexCoordFx.z;
            float mask = step(0.0, v_TexCoordFx.z);
            gl_FragColor = texture(g_Texture0, fxCoord) * mask;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/lightshafts",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("wpe_perspective_texcoord(in.uv, g_Point0, g_Point1, g_Point2, g_Point3)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("ContrastSaturationBrightness (common_blending.h) translates to compilable MSL")
    func translatesContrastSaturationBrightness() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        vec3 ContrastSaturationBrightness(vec3 color, float brt, float sat, float con) {
            const vec3 LumCoeff = vec3(0.2125, 0.7154, 0.0721);
            vec3 AvgLumin = vec3(0.5);
            vec3 brtColor = color * brt;
            vec3 intensity = vec3(dot(brtColor, LumCoeff));
            vec3 satColor = mix(intensity, brtColor, sat);
            vec3 conColor = mix(AvgLumin, satColor, con);
            return conColor;
        }
        void main() {
            vec3 albedo = texture(g_Texture0, v_TexCoord).rgb;
            albedo = ContrastSaturationBrightness(albedo, 1.1, 1.2, 0.9);
            gl_FragColor = vec4(albedo, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "color_grading",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("ContrastSaturationBrightness"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Helper parameters shadowing global uniforms are not threaded again")
    func helperParameterShadowingGlobalUniform() throws {
        let source = """
        // stage: fragment
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float sectorCount;
        uniform float seed;
        in vec2 v_TexCoord;
        float sectors(float pos, float sectorCount, float seed) {
            float d = floor(pos * sectorCount) / sectorCount;
            return d + seed;
        }
        void main() {
            float s = sectors(v_TexCoord.x, sectorCount, seed);
            gl_FragColor = vec4(vec3(s), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "tech_circle_barcode",
            preprocessedSource: source
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
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

    @Test("A block-commented `void main` above the real entry point is ignored")
    func ignoresBlockCommentedMain() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        in vec2 v_TexCoord;
        /* void main() { gl_FragColor = commented_out_do_not_use(); } */
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "block_commented_main",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("out_color") && result.mslSource.contains("g_Tint"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A line-commented `void main` above the real entry point is ignored")
    func ignoresLineCommentedMain() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        in vec2 v_TexCoord;
        // void main() { gl_FragColor = commented_out_do_not_use(); }
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "line_commented_main",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("out_color") && result.mslSource.contains("g_Tint"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("`/*/` opens a block comment — the opener's `*` is not its own terminator")
    func slashStarSlashOpensBlockComment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        in vec2 v_TexCoord;
        /*/ void main() { gl_FragColor = commented_out_do_not_use(); } /* same comment */
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "slash_star_slash_comment",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("out_color") && result.mslSource.contains("g_Tint"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A `#if` on its own line inside a block comment is not treated as a live directive")
    func ignoresPreprocessorDirectiveInsideBlockComment() throws {
        let source = """
        #version 410 core
        /*
         The uniforms below were previously guarded by
         #if 0
         during an old rework; they are unconditional now.
        */
        uniform sampler2D g_Texture0;
        uniform vec4 g_Tint;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "directive_in_block_comment",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.uniformLayout.contains { $0.name == "g_Tint" })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A `}` inside a helper-body comment does not truncate the parsed body")
    func helperBodyCommentBraceDoesNotTruncateResourceThreading() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        vec4 sampleTinted(vec2 uv) {
            float k = 0.5;
            // end of the old early-out block was here: }
            return texture(g_Texture0, uv) * k;
        }
        void main() {
            gl_FragColor = sampleTinted(v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "helper_comment_brace",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("sampleTinted(v_TexCoord, g_Texture0, wpeSampler0)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Arithmetic/bitwise `#if` conditions evaluate with correct precedence")
    func evaluatesArithmeticPreprocessorConditions() throws {
        let source = """
        #version 410 core
        #define A 1
        #define B 1
        #define FLAGS 6
        uniform sampler2D g_Texture0;
        #if A + B > 1
        uniform vec4 g_Tint;
        #endif
        #if (FLAGS & 2) == 2 && 8 >> 1 == 4
        uniform float g_Extra;
        #endif
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Tint * g_Extra;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "arithmetic_preprocessor",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.contains { $0.name == "g_Tint" })
        #expect(result.uniformLayout.contains { $0.name == "g_Extra" })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Nested regular texture() is fully rewritten (no texture() survives) and compiles")
    func translatesNestedRegularTextureFragment() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, texture(g_Texture1, v_TexCoord).xy);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "nested_texture",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("texture(g_Texture") == false)
        #expect(result.mslSource.contains("g_Texture0.sample(wpeSampler0"))
        #expect(result.mslSource.contains("g_Texture1.sample(wpeSampler1"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("A backslash-continued macro body threads its texture into helper scope")
    func helperMacroWithBackslashContinuationThreadsResources() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        #define SAMPLE(uv) \\
            texture(g_Texture0, uv)
        vec4 blur(vec2 uv) {
            return SAMPLE(uv);
        }
        void main() {
            gl_FragColor = blur(v_TexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "macro_continuation_helper",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("blur(v_TexCoord, g_Texture0, wpeSampler0)"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Comma-separated uniform declarations become separate uniforms")
    func parsesCommaSeparatedUniformDeclarations() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform float u_a, u_b;
        in vec2 v_TexCoord;
        void main() {
            gl_FragColor = texture(g_Texture0, v_TexCoord) * (u_a + u_b);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "comma_uniforms",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.contains { $0.name == "u_a" && $0.glslType == "float" })
        #expect(result.uniformLayout.contains { $0.name == "u_b" && $0.glslType == "float" })
        let slotA = try #require(result.uniformLayout.first { $0.name == "u_a" })
        let slotB = try #require(result.uniformLayout.first { $0.name == "u_b" })
        #expect(slotA.slot != slotB.slot, "each declarator occupies its own slot")
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("apply/up_sample v_StepSize reconstructs the box-blur step, not screen UV")
    func reconstructsStepSizeVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        in vec2 v_TexCoord;
        in vec4 v_StepSize;
        void main() {
            vec3 albedo = texture(g_Texture0, v_TexCoord).rgb;
            albedo += texture(g_Texture0, v_TexCoord + v_StepSize.xy).rgb;
            albedo += texture(g_Texture0, v_TexCoord + v_StepSize.zy).rgb;
            albedo += texture(g_Texture0, v_TexCoord + v_StepSize.xw).rgb;
            albedo += texture(g_Texture0, v_TexCoord + v_StepSize.zw).rgb;
            gl_FragColor = vec4(albedo * 0.2, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2822917890/effects/up_sample",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains(
            "v_StepSize = 1.0 / float4(-g_Texture0Resolution.xy, g_Texture0Resolution.xy);"
        ))
        #expect(!result.mslSource.contains("v_StepSize = float4(in.uv, in.uv)"))
        #expect(!result.mslSource.contains("WPE-DIAGNOSTIC: varying 'v_StepSize'"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("blur_gaussian v_SizeMultiplier reconstructs the blur texel scale, not screen UV")
    func reconstructsSizeMultiplierVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_TexelSize;
        uniform vec4 g_Texture0Resolution;
        uniform float u_radius; // {"material":"radius","default":4}
        uniform float u_strength; // {"material":"strength","default":1}
        uniform float u_ratio; // {"material":"ratio","default":2.39}
        in vec2 v_TexCoord;
        in vec2 v_SizeMultiplier;
        void main() {
            vec3 albedo = vec3(0.0);
            vec2 offset = vec2(0.0);
            for (int i = -2; i <= 2; i++) {
                offset.x = float(i) * v_SizeMultiplier.x;
                albedo += texture(g_Texture0, v_TexCoord + offset).rgb * u_strength;
            }
            gl_FragColor = vec4(albedo / 5.0, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2822917890/effects/blur_gaussian",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains(
            "v_SizeMultiplier = float2(1.0, 1.0) * (u_radius + u_radius) * 1.5 * (1.0 / g_Texture0Resolution.xy);"
        ))
        #expect(!result.mslSource.contains("v_SizeMultiplier = in.uv"))
        #expect(!result.mslSource.contains("WPE-DIAGNOSTIC: varying 'v_SizeMultiplier'"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)

        let anamorphic = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2822917890/effects/blur_gaussian",
            preprocessedSource: source,
            comboValues: ["ANAMORPHIC": 1, "HIGH_QUALITY": 1]
        )
        #expect(anamorphic.mslSource.contains(
            "v_SizeMultiplier = float2(u_ratio, 1.0) * (u_radius + u_radius) * 0.675 * (1.0 / g_Texture0Resolution.xy);"
        ))
        _ = try device.makeLibrary(source: anamorphic.mslSource, options: opts)
    }

    @Test("down_sample/light_map v_TexCoord[4] reconstructs 4 distinct box-filter taps")
    func reconstructsTexCoordBoxFilterArrayVarying() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        in vec2 v_TexCoord[4];
        void main() {
            float weight = 0.0;
            vec3 result = vec3(0.0);
            for (int i = 0; i < 4; ++i) {
                vec4 s = texture(g_Texture0, v_TexCoord[i]);
                result += s.rgb * s.a;
                weight += s.a;
            }
            gl_FragColor = vec4(result / max(0.001, weight), 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "workshop/2822917890/effects/down_sample",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains(
            "v_TexCoord[4] = { in.uv - (1.0 / g_Texture0Resolution.xy), " +
            "in.uv + float2(1.0 / g_Texture0Resolution.x, -1.0 / g_Texture0Resolution.y), " +
            "in.uv + float2(-1.0 / g_Texture0Resolution.x, 1.0 / g_Texture0Resolution.y), " +
            "in.uv + (1.0 / g_Texture0Resolution.xy) };"
        ))
        #expect(!result.mslSource.contains("v_TexCoord[4] = { in.uv, in.uv, in.uv, in.uv };"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("apply.vert's v_StepSize compiles end-to-end when g_Texture0Resolution is vertex-only")
    func stepSizeReconstructsFromVertexOnlyResolutionUniformAndCompiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "workshop/2822917890/effects/apply",
            processedVertexSource: """
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec4 g_Texture0Resolution;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            void main() {
                gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
                v_StepSize = 1.0 / vec4(-g_Texture0Resolution.xy, g_Texture0Resolution.xy);
            }
            """,
            processedFragmentSource: """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2;
            uniform float u_alpha; // {"material":"opacity","default":1}
            in vec2 v_TexCoord;
            in vec4 v_StepSize;
            void main() {
                vec4 baseAlbedo = texture(g_Texture2, v_TexCoord);
                vec3 albedo = texture(g_Texture0, v_TexCoord).rgb;
                albedo += texture(g_Texture0, v_TexCoord + v_StepSize.xy).rgb;
                albedo += texture(g_Texture0, v_TexCoord + v_StepSize.zy).rgb;
                albedo += texture(g_Texture0, v_TexCoord + v_StepSize.xw).rgb;
                albedo += texture(g_Texture0, v_TexCoord + v_StepSize.zw).rgb;
                albedo *= 0.4 * u_alpha;
                gl_FragColor = vec4(albedo, baseAlbedo.a);
            }
            """,
            sourceHash: "bloom-apply-stepsize-test",
            comboValues: [:],
            textureBindings: [:]
        )
        let result = try compiler.compile(request)
        #expect(result.mslSource.contains(
            "v_StepSize = 1.0 / float4(-g_Texture0Resolution.xy, g_Texture0Resolution.xy);"
        ))
        #expect(result.uniformLayout.contains { $0.name == "g_Texture0Resolution" })
        #expect(result.library.makeFunction(name: "wpe_translated_fragment") != nil)
    }

    @Test("down_sample.vert's v_TexCoord[4] compiles end-to-end when g_Texture0Resolution is vertex-only")
    func texCoordArrayReconstructsFromVertexOnlyResolutionUniformAndCompiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = WPESwiftShaderCompiler(device: device)
        let request = WPEShaderCompileRequest(
            shaderName: "workshop/2822917890/effects/down_sample",
            processedVertexSource: """
            uniform vec4 g_Texture0Resolution;
            in vec3 a_Position;
            in vec2 a_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 1.0);
                vec2 offsets = 1.0 / g_Texture0Resolution.xy;
                v_TexCoord[0] = a_TexCoord - offsets;
                v_TexCoord[1] = a_TexCoord + vec2(offsets.x, -offsets.y);
                v_TexCoord[2] = a_TexCoord + vec2(-offsets.x, offsets.y);
                v_TexCoord[3] = a_TexCoord + offsets;
            }
            """,
            processedFragmentSource: """
            uniform sampler2D g_Texture0;
            in vec2 v_TexCoord[4];
            void main() {
                float weight = 0.0;
                vec3 result = vec3(0.0);
                for (int i = 0; i < 4; ++i) {
                    vec4 s = texture(g_Texture0, v_TexCoord[i]);
                    result += s.rgb * s.a;
                    weight += s.a;
                }
                gl_FragColor = vec4(result / max(0.001, weight), 1.0);
            }
            """,
            sourceHash: "bloom-downsample-texcoord-array-test",
            comboValues: [:],
            textureBindings: [:]
        )
        let result = try compiler.compile(request)
        #expect(result.mslSource.contains(
            "v_TexCoord[4] = { in.uv - (1.0 / g_Texture0Resolution.xy), " +
            "in.uv + float2(1.0 / g_Texture0Resolution.x, -1.0 / g_Texture0Resolution.y), " +
            "in.uv + float2(-1.0 / g_Texture0Resolution.x, 1.0 / g_Texture0Resolution.y), " +
            "in.uv + (1.0 / g_Texture0Resolution.xy) };"
        ))
        #expect(result.uniformLayout.contains { $0.name == "g_Texture0Resolution" })
        #expect(result.library.makeFunction(name: "wpe_translated_fragment") != nil)
    }
}
