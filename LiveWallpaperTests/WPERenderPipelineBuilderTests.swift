import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE render pipeline builder")
struct WPERenderPipelineBuilderTests {

    @Test("Normalizes built-in shader aliases consistently")
    func normalizesBuiltinShaderAliasesConsistently() {
        #expect(WPEBuiltinShaderName.normalized("materials/util/solidlayer.json") == "solidlayer")
        #expect(WPEBuiltinShaderName.normalized("materials/effects/blur/blur.json") == "effect_blur")
        #expect(WPEBuiltinShaderName.normalized("composelayer") == "compose")
        #expect(WPEBuiltinShaderName.normalized("materials/util/composelayer.json") == "compose")
        #expect(WPEBuiltinShaderName.normalized("effects/distort/distort") == "effect_water")
        #expect(WPEBuiltinShaderName.normalized("genericimage2") == "genericimage2")
        #expect(WPEBuiltinShaderName.normalized("generic4") == "genericimage4")
        #expect(WPEBuiltinShaderName.normalized("genericimage2", genericImageAsCopy: true) == "copy")
        #expect(WPEBuiltinShaderName.normalized("genericimage_custom", genericImageAsCopy: true) == "genericimage_custom")
    }

    @Test("Script-driven alpha/transform rewrites keep shape:quad points")
    func scriptAlphaAndTransformRewritesKeepShapeQuadPoints() throws {
        // applyingAlpha/applyingTransform rebuild the geometry per script tick;
        // like the attachment-follow rewrite, they must carry shapePoints or a
        // scripted quad layer loses its perspective corners at runtime.
        let points = [
            SIMD2<Double>(0.4, 0.25),
            SIMD2<Double>(0.6, 0.25),
            SIMD2<Double>(0.94451, 0.83623),
            SIMD2<Double>(0.09498, 0.88795)
        ]
        let layer = WPERenderLayer(
            objectID: "96",
            objectName: "beam",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(100, 200, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 200, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1,
                shapePoints: points
            ),
            compositeA: "_rt_imageLayerComposite_96_a",
            compositeB: "_rt_imageLayerComposite_96_b",
            localFBOs: [],
            passes: []
        )

        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])

        let faded = try #require(pipeline.applyingLayerAlpha(["96": 0.5]).layers.first).graphLayer
        #expect(faded.geometry.alpha == 0.5)
        #expect(faded.geometry.shapePoints == points)

        let moved = try #require(pipeline.applyingLayerTransforms(
            origins: ["96": SIMD3<Double>(150, 250, 0)],
            scales: [:],
            angles: [:]
        ).layers.first).graphLayer
        #expect(moved.geometry.origin == SIMD3<Double>(150, 250, 0))
        #expect(moved.geometry.shapePoints == points)
    }

    @Test("Builds prepared shader programs from render graph passes")
    func buildsPreparedShaderProgramsFromGraphPasses() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            // [COMBO] {"combo":"KERNEL","default":1}
            #include "common.h"
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "7.1",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .fbo("_rt_imageLayerComposite_7_a"),
                        target: .scene,
                        textures: [:],
                        binds: [0: .previous],
                        constants: [:],
                        combos: ["KERNEL": 2],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let layer = try #require(pipeline.layers.first)

        #expect(layer.passes.map(\.pass.shader) == ["genericimage2", "effects/custom"])
        #expect(layer.passes[0].shader?.isBuiltin == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#define KERNEL 2") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("wpe_common_included") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#include") == false)
        #expect(layer.passes[1].shader?.fragmentSource.contains("#define texSample2D") == true)
    }

    @Test("Texture-declared combo (MASK) auto-enables when its sampler slot is bound")
    func textureDeclaredComboEnablesWhenSamplerSlotBound() throws {
        // Mirrors waterwaves.frag: the opacity-mask sampler g_Texture1 declares
        // `"combo":"MASK"`, gating the displacement mask behind `#if MASK`. WPE
        // auto-enables MASK when the slot is bound (scene ships textures[1] but
        // no explicit combos). If MASK stays off, `mask = 1.0` and the WHOLE
        // layer displaces — the "ghost / stacked layers" artifact.
        let fixture = try makeFixture(files: [
            "shaders/effects/masked.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/masked.frag": """
            uniform sampler2D g_Texture0; // {"hidden":true}
            uniform sampler2D g_Texture1; // {"mode":"opacitymask","combo":"MASK"}
            void main() {
            #if MASK
                float mask = texSample2D(g_Texture1, vec2(0.5)).r;
            #else
                float mask = 1.0;
            #endif
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * mask;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "9",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_9_a",
                compositeB: "_rt_imageLayerComposite_9_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "9.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_9_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "9.1",
                        phase: .effect(file: "effects/masked/effect.json"),
                        shader: "effects/masked",
                        source: .fbo("_rt_imageLayerComposite_9_a"),
                        target: .scene,
                        // Mask bound to slot 1; MASK combo deliberately NOT set
                        // explicitly — it must be derived from the bound slot.
                        textures: [1: .asset("masks/waterwaves_mask")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let effect = try #require(pipeline.layers.first?.passes.last?.shader)
        #expect(effect.fragmentSource.contains("#define MASK 1"))
    }

    @Test("Loads puppet model from render graph layer path")
    func loadsPuppetModelFromRenderGraphLayerPath() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": makeSingleTrianglePuppetMDL()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.parts == [WPEPuppetMeshPart(id: 7, start: 0, count: 3)])
    }

    @Test("A pre-v19 puppet generation refuses the whole scene instead of rendering it misaligned")
    func legacyPuppetGenerationRefusesScene() throws {
        // A parseable puppet tagged MDLV0017 (a generation below the verified character-sheet floor).
        // loadPuppetModel must throw so the scene is skipped + warned, not silently degraded.
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": makeLegacyPuppetMDLBelow19()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])

        #expect {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        } throws: { error in
            guard case SceneRenderingError.metalRendererUnsupported(let reason) = error else { return false }
            return reason.contains("MDLV0017")
        }
    }

    @Test("An MDLV0019 character-sheet puppet loads (it is assembled by skinning, not refused)")
    func mdlv19PuppetLoadsInsteadOfRefusing() throws {
        // The v19 exploded character-sheet is recovered by skinning through the MDLA pose, so the
        // pipeline must now accept it (regression for the old `version >= 21` refusal).
        var mdl = makeSingleTrianglePuppetMDL()
        mdl.replaceSubrange(0..<8, with: "MDLV0019".utf8)
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": mdl
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)
        #expect(model.version == 19)
    }

    private func puppetLayer() -> WPERenderLayer {
        WPERenderLayer(
            objectID: "7",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: "materials/layer.json",
            puppetPath: "models/layer_puppet.mdl",
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_7_a",
            compositeB: "_rt_imageLayerComposite_7_b",
            localFBOs: [],
            passes: [
                WPERenderPass(
                    id: "7.0",
                    phase: .material,
                    shader: "generic4",
                    source: .image("materials/layer.png"),
                    target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )
            ]
        )
    }

    @Test("MDLV16 direct scene model loads as static mesh instead of legacy puppet")
    func mdlv16DirectSceneModelLoadsAsStaticMesh() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/ring.mdl": makeSingleTriangleMDLV16SceneModel()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "ring",
                objectName: "Ring",
                imagePath: "models/ring.mdl",
                materialPath: "materials/ring.json",
                puppetPath: "models/ring.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_ring_a",
                compositeB: "_rt_imageLayerComposite_ring_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "ring.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("models/ring.mdl"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "enabled",
                        depthWrite: "enabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)

        #expect(model.version == 16)
        #expect(model.meshes.first?.materialPath == "materials/models/Hollow Cylinder/diffuse_0.json")
    }

    @Test("Loads puppet model through dependency mounts")
    func loadsPuppetModelThroughDependencyMounts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let dependencyRoot = fixture.root.appendingPathComponent("dependency-123", isDirectory: true)
        let modelURL = dependencyRoot.appendingPathComponent("models/layer_puppet.mdl")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeSingleTrianglePuppetMDL().write(to: modelURL)

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "../123/models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(
            cacheRootURL: fixture.root,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: dependencyRoot)]
        ).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test("Shader annotation numeric defaults stay numeric")
    func shaderAnnotationNumericDefaultsStayNumeric() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            uniform float u_alpha; // {"material":"Opacity","default":1,"range":[0,1]}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * u_alpha; }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let alpha = try #require(pipeline.layers.first?.passes.first?.uniformValues["u_alpha"])

        #expect(alpha.numberValue == 1)
    }

    @Test("WPE shader prelude defines M_PI_2 as full turn")
    func shaderPreludeDefinesMPI2AsFullTurn() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/shake.frag": """
            #include "common.h"
            uniform float g_Time;
            void main() {
                float offset = sin(frac(g_Time / M_PI_2) * M_PI_2);
                gl_FragColor = vec4(offset);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragment = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragment.contains("#define M_PI_2 6.28318530717958647692"))
    }

    @Test("Missing shader source is reported with the pass shader name")
    func missingShaderSourceReportsName() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/missing/effect.json"),
            shader: "effects/missing",
            source: .image("materials/base.png"),
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
        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [pass]
            )
        ])

        #expect(throws: WPERenderPipelineError.self) {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        }
    }

    @Test("Expands WPE composite helper include used by blur combine shaders")
    func expandsCompositeHelperInclude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_combine.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_combine.frag": """
            // [COMBO] {"combo":"COMPOSITE","default":0}
            #include "common_composite.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Texture0Resolution;
            void main() {
                vec2 uv = ApplyCompositeOffset(vec2(0.5), g_Texture0Resolution.xy);
                gl_FragColor = ApplyComposite(vec4(0.0), texSample2D(g_Texture0, uv));
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: "effects/blur_combine",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_composite_included"))
        #expect(fragmentSource.contains("vec2 ApplyCompositeOffset"))
        #expect(fragmentSource.contains("vec4 ApplyComposite"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_blur.h provides radial blur helpers used by blur_radial_gaussian")
    func commonBlurProvidesRadialBlurHelpers() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_radial_gaussian.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_radial_gaussian.frag": """
            // [COMBO] {"combo":"KERNEL","default":0}
            #include "common_blur.h"
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            uniform float u_Scale;
            uniform vec2 u_Center;
            void main() {
            #if KERNEL == 0
                vec4 albedo = blurRadial13a(v_TexCoord.xy, u_Center, u_Scale);
            #endif
                gl_FragColor = albedo;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur_radial/effect.json"),
                        shader: "effects/blur_radial_gaussian",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )

        #expect(result.mslSource.contains("blurRadial13a"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Expands common_fragment.h ConvertSampleR8 used by WPE 2.8 font.frag")
    func expandsCommonFragmentConvertSampleR8() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/font_like.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/font_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Color4;
            void main() {
                float a = ConvertSampleR8(texSample2D(g_Texture0, vec2(0.5)));
                gl_FragColor = vec4(g_Color4.rgb, a * g_Color4.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/font/effect.json"),
                        shader: "effects/font_like",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_fragment_included"))
        #expect(fragmentSource.contains("float ConvertSampleR8"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_fragment.h FORMAT_* constants keep formatcombo branches off the R8 path")
    func commonFragmentFormatConstantsKeepFormatcomboBranchesOffR8() throws {
        // lightshafts.frag (and every `formatcombo` shader) branches on
        // `#if TEX2FORMAT == FORMAT_R8 || TEX2FORMAT == FORMAT_RG88` to pick
        // `.rrr` replication for single/dual-channel gradient maps. Before the
        // stub carried WPE's FORMAT_* table, implicitConditionalDefines zeroed
        // FORMAT_R8/FORMAT_RG88 alongside the missing TEXnFORMAT, so `0 == 0`
        // forced the grayscale branch and RGBA gradients rendered white.
        let fixture = try makeFixture(files: [
            "shaders/effects/shafts_like.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shafts_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture2; // {"default":"gradient/gradient_iridescent","formatcombo":true}
            void main() {
            #if TEX2FORMAT == FORMAT_R8 || TEX2FORMAT == FORMAT_RG88
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rrr;
            #else
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rgb;
            #endif
                gl_FragColor = vec4(gradColor, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shafts/effect.json"),
                        shader: "effects/shafts_like",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let fragmentSource = try #require(pass.shader?.fragmentSource)

        // The stub supplies WPE's real enum values …
        #expect(fragmentSource.contains("#define FORMAT_R8 9"))
        #expect(fragmentSource.contains("#define FORMAT_RG88 8"))
        // … so the auto-define pass must not zero them anymore.
        #expect(fragmentSource.contains("#define FORMAT_R8 0") == false)
        #expect(fragmentSource.contains("#define FORMAT_RG88 0") == false)
        // The missing per-slot format combo still auto-defines to 0, which is
        // FORMAT_RGBA8888 — the layout the texture loader uploads.
        #expect(fragmentSource.contains("#define TEX2FORMAT 0"))
        // And the unbound slot still resolves the shader-declared default.
        #expect(pass.textureBindings[2] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Treats generic image shader variants as builtins")
    func treatsGenericImageShaderVariantsAsBuiltins() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "generic4")
        #expect(shader.isBuiltin)
    }

    @Test("Dynamic transform on a non-rendered parent propagates to child geometry")
    func dynamicParentTransformPropagatesToChildGeometry() {
        let childGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(10, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let graphLayer = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: childGeometry,
            localGeometry: childGeometry,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
        ])

        let transformed = pipeline.applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, 0, Double.pi / 2)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(0, 0, 0),
                    scale: SIMD3<Double>(1, 1, 1),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        )
        let geometry = transformed.layers[0].graphLayer.geometry

        #expect(abs(geometry.origin.x) < 0.0001)
        #expect(abs(geometry.origin.y - 10) < 0.0001)
        #expect(abs(geometry.angles.z - Double.pi / 2) < 0.0001)
    }

    @Test("Dynamic parent transform rotates child origin around X and Y")
    func dynamicParentTransformRotatesChildOriginAroundXAndY() {
        func makePipeline(childOrigin: SIMD3<Double>) -> WPEPreparedRenderPipeline {
            let childGeometry = WPERenderLayerGeometry(
                origin: childOrigin,
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 10, height: 10),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
            let graphLayer = WPERenderLayer(
                objectID: "child",
                objectName: "Child",
                imagePath: "materials/base.png",
                materialPath: nil,
                parentObjectID: "group",
                geometry: childGeometry,
                localGeometry: childGeometry,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: []
            )
            return WPEPreparedRenderPipeline(layers: [
                WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
            ])
        }

        let xRotated = makePipeline(childOrigin: SIMD3<Double>(0, 1, 0)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(Double.pi / 2, 0, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(xRotated.origin.x - 1) < 0.0001)
        #expect(abs(xRotated.origin.y - 2) < 0.0001)
        #expect(abs(xRotated.origin.z - 6) < 0.0001)
        #expect(abs(xRotated.angles.x - Double.pi / 2) < 0.0001)

        let yRotated = makePipeline(childOrigin: SIMD3<Double>(0, 0, 1)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, Double.pi / 2, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(yRotated.origin.x - 5) < 0.0001)
        #expect(abs(yRotated.origin.y - 2) < 0.0001)
        #expect(abs(yRotated.origin.z - 3) < 0.0001)
        #expect(abs(yRotated.angles.y - Double.pi / 2) < 0.0001)
    }

    @Test("Live alpha override also updates a composelayer-group child's group-local alpha")
    func liveAlphaOverrideUpdatesGroupLocalGeometry() {
        func geometry(alpha: Double) -> WPERenderLayerGeometry {
            WPERenderLayerGeometry(
                origin: SIMD3<Double>(5, 7, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 40, height: 30),
                alpha: alpha,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        }
        // A composelayer-group child: its group-buffer pass is drawn from
        // groupLocalGeometry, so a live fade must land there too (the executor
        // otherwise draws the child at its authored alpha inside the group).
        let child = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: geometry(alpha: 1),
            localGeometry: geometry(alpha: 1),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [],
            groupRenderTarget: "_rt_layerGroup_group",
            groupLocalGeometry: geometry(alpha: 1)
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: child, passes: [])
        ])

        let faded = pipeline.applyingLayerAlpha(["child": 0.25]).layers[0].graphLayer
        #expect(abs(faded.geometry.alpha - 0.25) < 0.0001)
        #expect(abs((faded.groupLocalGeometry?.alpha ?? -1) - 0.25) < 0.0001)
        #expect(faded.groupLocalGeometry?.alphaAnimation == nil)
        // Non-alpha fields of the group-local geometry are preserved.
        #expect(faded.groupLocalGeometry?.origin == SIMD3<Double>(5, 7, 0))
    }

    @Test("Prefers scene-provided source for WPE effect aliases")
    func prefersSceneProvidedSourceForWPEEffectAliases() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            void main() {
                vec4 sampled = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = sampled + vec4(0.123, 0.0, 0.0, 0.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin == false)
        #expect(shader.fragmentSource.contains("0.123"))
    }

    @Test("Expands WPE imageblending mode 31 as additive blending")
    func expandsWPEImageBlendingMode31AsAdditiveBlending() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/lightblend.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/lightblend.frag": """
            // [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31}
            #include "common_blending.h"
            uniform sampler2D g_Texture0;
            void main() {
                vec4 albedo = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = vec4(ApplyBlending(BLENDMODE, albedo.rgb, vec3(0.25), 1.0), albedo.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/lightblend/effect.json"),
                        shader: "effects/lightblend",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)

        #expect(pass.comboValues["BLENDMODE"] == 31)
        #expect(shader.fragmentSource.contains("#define BLENDMODE 31"))
        #expect(shader.fragmentSource.contains("blendMode == 31"))
        #expect(shader.fragmentSource.contains("vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, vec3 opacity)"))
        #expect(shader.fragmentSource.contains("#include") == false)
    }

    @Test("Builds built-in solid color shader")
    func buildsBuiltinSolidColorShader() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Solid",
                imagePath: "models/util/solidlayer.json",
                materialPath: "models/util/solidlayer.json",
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "solidcolor",
                        source: .image("models/util/solidlayer.json"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: ["g_Color": .vector([1, 0, 0, 1])],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "solidcolor")
        #expect(shader.isBuiltin)
        #expect(shader.fragmentSource.contains("uniform vec4 g_Color"))
    }

    @Test("Builds executable copy command passes")
    func buildsExecutableCopyCommandPasses() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .command(file: "effects/copy/effect.json"),
                        shader: "commands/copy",
                        source: .fbo("_rt_Previous"),
                        target: .fbo(name: "_rt_Target"),
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.shader?.name == "commands/copy")
        #expect(pass.shader?.isBuiltin == true)
        #expect(pass.textureBindings[0] == .fbo("_rt_Source"))
    }

    @Test("Merges shader annotation defaults into prepared pass metadata")
    func mergesShaderAnnotationDefaultsIntoPreparedPassMetadata() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/annotated.vert": """
            // [COMBO] {"combo":"QUALITY","default":2}
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/annotated.frag": """
            uniform sampler2D g_Texture1; // {"material":"noise","default":"util/noise","hidden":true}
            uniform sampler2D g_Texture2; // {"material":"flow","combo":"FLOWMASK"}
            uniform float u_Strength; // {"material":"strength","default":0.2}
            void main() { gl_FragColor = texSample2D(g_Texture1, vec2(u_Strength)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/annotated/effect.json"),
                        shader: "effects/annotated",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [2: .asset("masks/flow")],
                        binds: [:],
                        constants: ["strength": .number(0.75)],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.comboValues["QUALITY"] == 2)
        #expect(pass.comboValues["FLOWMASK"] == 1)
        #expect(pass.textureBindings[0] == .image("materials/base.png"))
        #expect(pass.textureBindings[1] == .asset("util/noise"))
        #expect(pass.textureBindings[2] == .asset("masks/flow"))
        #expect(pass.uniformValues["u_Strength"]?.numberValue == 0.75)
    }

    @Test("shake/pulse opacity mask slot 2 defaults to white unless explicitly bound")
    func effectOpacityMaskSlot2DefaultsToWhite() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2; // {"default":"util/black"}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        func builtPass(textures: [Int: WPETextureReference]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "161",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "161.1",
                            phase: .effect(file: "effects/shake/effect.json"),
                            shader: "effects/shake",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: textures,
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        // Unbound slot 2 → white (full effect); a black/unbound mask silently
        // disables the effect (oracle: 3554161528 cloud bands froze).
        let defaulted = try builtPass(textures: [:])
        #expect(defaulted.textureBindings[2] == .asset("util/white"))

        let explicit = try builtPass(textures: [2: .asset("masks/pulse__mask_9913c181")])
        #expect(explicit.textureBindings[2] == .asset("masks/pulse__mask_9913c181"))
    }

    @Test("Sampler defaults honor shader require conditions")
    func samplerDefaultsHonorShaderRequireConditions() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/conditional.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/conditional.frag": """
            // [COMBO] {"combo":"RENDERING","default":0}
            uniform sampler2D g_Texture1; // {"default":"gradient/gradient_iridescent","require":{"RENDERING":1}}
            void main() { gl_FragColor = vec4(1.0); }
            """
        ])
        defer { fixture.cleanup() }

        func buildPass(combos: [String: Int]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "1",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "1.0",
                            phase: .effect(file: "effects/conditional/effect.json"),
                            shader: "effects/conditional",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: [:],
                            binds: [:],
                            constants: [:],
                            combos: combos,
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        let inactivePass = try buildPass(combos: [:])
        #expect(inactivePass.comboValues["RENDERING"] == 0)
        #expect(inactivePass.textureBindings[1] == nil)

        let activePass = try buildPass(combos: ["RENDERING": 1])
        #expect(activePass.comboValues["RENDERING"] == 1)
        #expect(activePass.textureBindings[1] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Comments require directives and emits WPE compatibility prelude")
    func commentsRequireDirectivesAndEmitsCompatibilityPrelude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/compat.vert": """
            #require SOME_FEATURE
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/compat.frag": """
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = lerp(vec4(0.0), vec4(1.0), 0.5); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/compat/effect.json"),
                        shader: "effects/compat",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.vertexSource.contains("#require") == false)
        #expect(shader.vertexSource.contains("#define attribute in"))
        #expect(shader.fragmentSource.contains("out vec4 out_FragColor"))
        #expect(shader.fragmentSource.contains("gl_FragColor") == false)
        #expect(shader.fragmentSource.contains("#define texSample2DLod textureLod"))
        #expect(shader.fragmentSource.contains("#define lerp mix"))
    }

    @Test("Compatibility prelude keeps GLSL atan2 compiling through Metal")
    func compatibilityPreludeAtan2CompilesThroughMetal() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/atan.vert": """
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 1.0);
                v_TexCoord = a_Position.xy;
            }
            """,
            "shaders/effects/atan.frag": """
            varying vec2 v_TexCoord;
            void main() {
                float angle = atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5);
                gl_FragColor = vec4(angle, 0.0, 0.0, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/atan/effect.json"),
                        shader: "effects/atan",
                        source: .image("materials/base.png"),
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
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/atan",
            preprocessedSource: fragmentSource
        )

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test(
        "Recognises Phase 2D-C effect aliases under bare, effects/, and materials/ paths",
        arguments: [
            "blur",
            "effects/blur",
            "effects/blur/blur",
            "materials/effects/blur/blur",
            "materials/effects/blur/blur.json",
            "MATERIALS/Effects/Blur/Blur.JSON"
        ]
    )
    func recognisesEffectAliasesAcrossPathStyles(shaderName: String) throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: shaderName,
                        source: .fbo("_rt_Source"),
                        target: .scene,
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin)
        #expect(shader.name == shaderName)
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        files: [String: String] = [:],
        dataFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderPipelineBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }
        for (relativePath, contents) in dataFiles {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL)
        }
        return Fixture(root: root)
    }

    private func makeSingleTrianglePuppetMDL() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(-10))
        data.appendLE(Float(-20))
        data.appendLE(Float(0))
        data.appendLE(Float(10))
        data.appendLE(Float(20))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))

        return data
    }

    /// A parseable puppet below the verified MDLV0019 character-sheet floor. Uses the pre-v19 header
    /// layout (`u32 flags, u32, u32 meshCount`) with a v17+ 24-byte bbox so the parser succeeds and the
    /// version guard — not a parse failure — is what refuses the scene.
    private func makeLegacyPuppetMDLBelow19() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0017".utf8))
        data.appendLE(UInt32(0x180000f))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(0, 0, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(0))

        return data
    }

    private func makeSingleTriangleMDLV16SceneModel() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x00000f00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/models/Hollow Cylinder/diffuse_0.json")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0x0000000f))

        var vertices = Data()
        vertices.appendSceneModelVertex(position: SIMD3<Float>(-1, -1, 0), uv: SIMD2<Float>(0, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(1, -1, 0), uv: SIMD2<Float>(1, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(0, 1, 0), uv: SIMD2<Float>(0.5, 0))
        data.appendLE(UInt32(vertices.count))
        data.append(vertices)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    static func puppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLE(vertex.position.x)
            data.appendLE(vertex.position.y)
            data.appendLE(vertex.position.z)
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(vertex.uv.x)
            data.appendLE(vertex.uv.y)
        }
        return data
    }

    mutating func appendSceneModelVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        appendLE(position.x)
        appendLE(position.y)
        appendLE(position.z)
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(Float(1))
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(uv.x)
        appendLE(uv.y)
    }
}
