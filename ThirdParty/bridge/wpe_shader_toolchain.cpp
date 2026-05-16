// LiveWallpaper bridge: glslang + SPIRV-Cross behind a stable C ABI.
//
// Swift consumers see only WPEShaderToolchain.h. This .cpp body links
// statically against glslang and SPIRV-Cross and is bundled into the
// XCFramework alongside those static libraries.

#include "WPEShaderToolchain.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <glslang/Public/ShaderLang.h>
#include <glslang/SPIRV/GlslangToSpv.h>
#include <spirv_cross/spirv_msl.hpp>
#include <spirv_cross/spirv_reflect.hpp>

namespace {

const TBuiltInResource kDefaultResources = {
    /* MaxLights */ 32,
    /* MaxClipPlanes */ 6,
    /* MaxTextureUnits */ 32,
    /* MaxTextureCoords */ 32,
    /* MaxVertexAttribs */ 64,
    /* MaxVertexUniformComponents */ 4096,
    /* MaxVaryingFloats */ 64,
    /* MaxVertexTextureImageUnits */ 32,
    /* MaxCombinedTextureImageUnits */ 80,
    /* MaxTextureImageUnits */ 32,
    /* MaxFragmentUniformComponents */ 4096,
    /* MaxDrawBuffers */ 32,
    // SPIRV-Cross-compatible defaults; full enumeration omitted for brevity.
    // Augment with the rest of TBuiltInResource here when wiring up.
};

char *dupString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out) {
        std::memcpy(out, s.data(), s.size());
        out[s.size()] = '\0';
    }
    return out;
}

void writeDiag(char **slot, const std::string &message) {
    if (!slot) return;
    *slot = dupString(message);
}

} // namespace

extern "C" {

int wpe_shader_glsl_to_spirv(
    const char *vertex_glsl,
    const char *fragment_glsl,
    uint32_t   **out_spirv_words,
    size_t     *out_spirv_count,
    char      **out_diag
) {
    if (!fragment_glsl || !out_spirv_words || !out_spirv_count) {
        writeDiag(out_diag, "wpe_shader_glsl_to_spirv: null required argument");
        return 1;
    }

    glslang::InitializeProcess();

    const char *vertSource = vertex_glsl ? vertex_glsl :
        "#version 410 core\n"
        "layout(location = 0) in vec3 a_Position;\n"
        "layout(location = 1) in vec2 a_TexCoord;\n"
        "out vec2 v_TexCoord;\n"
        "void main() {\n"
        "    gl_Position = vec4(a_Position, 1.0);\n"
        "    v_TexCoord = a_TexCoord;\n"
        "}\n";

    glslang::TShader vertex(EShLangVertex);
    glslang::TShader fragment(EShLangFragment);
    vertex.setStrings(&vertSource, 1);
    fragment.setStrings(&fragment_glsl, 1);

    // WPE shaders are OpenGL-flavoured: no explicit `layout(location=N)` or
    // `layout(binding=N)` qualifiers. Configure glslang for the OpenGL
    // client + SPIR-V target so the missing layout decorations don't fail
    // parsing; SPIRV-Cross consumes the resulting OpenGL-flavoured SPIR-V
    // and translates to MSL the same way.
    vertex.setEnvInput(glslang::EShSourceGlsl,   EShLangVertex,   glslang::EShClientOpenGL, 410);
    vertex.setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    vertex.setEnvTarget(glslang::EShTargetSpv,    glslang::EShTargetSpv_1_0);
    fragment.setEnvInput(glslang::EShSourceGlsl, EShLangFragment, glslang::EShClientOpenGL, 410);
    fragment.setEnvClient(glslang::EShClientOpenGL, glslang::EShTargetOpenGL_450);
    fragment.setEnvTarget(glslang::EShTargetSpv,   glslang::EShTargetSpv_1_0);

    // Auto-assign locations/bindings — WPE shader source carries neither.
    // Without these, glslang's SPIR-V target rejects `in vec2 v_TexCoord;`
    // with "SPIR-V requires location for user input/output".
    vertex.setAutoMapLocations(true);
    vertex.setAutoMapBindings(true);
    fragment.setAutoMapLocations(true);
    fragment.setAutoMapBindings(true);

    EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules);
    bool vertOK = vertex.parse(&kDefaultResources, 410, false, messages);
    bool fragOK = fragment.parse(&kDefaultResources, 410, false, messages);
    if (!vertOK || !fragOK) {
        std::string diag = "glslang parse failed:\n";
        diag += vertex.getInfoLog();
        diag += fragment.getInfoLog();
        writeDiag(out_diag, diag);
        glslang::FinalizeProcess();
        return 2;
    }

    glslang::TProgram program;
    program.addShader(&vertex);
    program.addShader(&fragment);
    if (!program.link(messages)) {
        writeDiag(out_diag, std::string("glslang link failed: ") + program.getInfoLog());
        glslang::FinalizeProcess();
        return 3;
    }
    // Run mapIO after link so the auto-map flags actually assign slots —
    // GlslangToSpv reads the assignments from each intermediate.
    if (!program.mapIO()) {
        writeDiag(out_diag, std::string("glslang mapIO failed: ") + program.getInfoLog());
        glslang::FinalizeProcess();
        return 3;
    }

    std::vector<uint32_t> spirv;
    glslang::GlslangToSpv(*program.getIntermediate(EShLangFragment), spirv);

    auto buffer = static_cast<uint32_t *>(std::malloc(spirv.size() * sizeof(uint32_t)));
    if (!buffer) {
        writeDiag(out_diag, "allocation failed");
        glslang::FinalizeProcess();
        return 4;
    }
    std::memcpy(buffer, spirv.data(), spirv.size() * sizeof(uint32_t));
    *out_spirv_words = buffer;
    *out_spirv_count = spirv.size();

    glslang::FinalizeProcess();
    return 0;
}

void wpe_shader_free_spirv(uint32_t *spirv_words) {
    std::free(spirv_words);
}

int wpe_shader_spirv_to_msl(
    const uint32_t *spirv_words,
    size_t          spirv_count,
    char          **out_msl,
    char          **out_diag
) {
    if (!spirv_words || spirv_count == 0 || !out_msl) {
        writeDiag(out_diag, "wpe_shader_spirv_to_msl: null required argument");
        return 1;
    }

    try {
        spirv_cross::CompilerMSL compiler(spirv_words, spirv_count);
        spirv_cross::CompilerMSL::Options options;
        options.platform = spirv_cross::CompilerMSL::Options::macOS;
        options.msl_version = spirv_cross::CompilerMSL::Options::make_msl_version(3, 0);
        compiler.set_msl_options(options);

        std::string msl = compiler.compile();
        *out_msl = dupString(msl);
        return 0;
    } catch (const std::exception &e) {
        writeDiag(out_diag, std::string("SPIRV-Cross failed: ") + e.what());
        return 2;
    } catch (...) {
        writeDiag(out_diag, "SPIRV-Cross failed: unknown error");
        return 3;
    }
}

int wpe_shader_reflect_spirv(
    const uint32_t              *spirv_words,
    size_t                       spirv_count,
    wpe_shader_reflection_result *out_result,
    char                       **out_diag
) {
    if (!spirv_words || spirv_count == 0 || !out_result) {
        writeDiag(out_diag, "wpe_shader_reflect_spirv: null required argument");
        return 1;
    }
    std::memset(out_result, 0, sizeof(*out_result));

    try {
        spirv_cross::CompilerReflection reflector(spirv_words, spirv_count);
        const auto resources = reflector.get_shader_resources();

        out_result->uniform_count = resources.uniform_buffers.size();
        out_result->sampler_count = resources.sampled_images.size();
        if (out_result->uniform_count) {
            out_result->uniforms = static_cast<wpe_shader_reflection_binding *>(
                std::calloc(out_result->uniform_count, sizeof(wpe_shader_reflection_binding))
            );
        }
        if (out_result->sampler_count) {
            out_result->samplers = static_cast<wpe_shader_reflection_binding *>(
                std::calloc(out_result->sampler_count, sizeof(wpe_shader_reflection_binding))
            );
        }

        size_t i = 0;
        for (const auto &r : resources.uniform_buffers) {
            out_result->uniforms[i].name = dupString(r.name);
            out_result->uniforms[i].binding = static_cast<int32_t>(
                reflector.get_decoration(r.id, spv::DecorationBinding)
            );
            out_result->uniforms[i].size_bytes = static_cast<int32_t>(
                reflector.get_declared_struct_size(reflector.get_type(r.base_type_id))
            );
            ++i;
        }
        i = 0;
        for (const auto &r : resources.sampled_images) {
            out_result->samplers[i].name = dupString(r.name);
            out_result->samplers[i].binding = static_cast<int32_t>(
                reflector.get_decoration(r.id, spv::DecorationBinding)
            );
            out_result->samplers[i].size_bytes = 0;
            ++i;
        }
        return 0;
    } catch (const std::exception &e) {
        writeDiag(out_diag, std::string("reflection failed: ") + e.what());
        return 2;
    } catch (...) {
        writeDiag(out_diag, "reflection failed: unknown error");
        return 3;
    }
}

void wpe_shader_free_reflection(wpe_shader_reflection_result *result) {
    if (!result) return;
    for (size_t i = 0; i < result->uniform_count; ++i) std::free(result->uniforms[i].name);
    for (size_t i = 0; i < result->sampler_count; ++i) std::free(result->samplers[i].name);
    std::free(result->uniforms);
    std::free(result->samplers);
    std::memset(result, 0, sizeof(*result));
}

const char *wpe_shader_toolchain_version(void) {
    return "1.0.0 (glslang+SPIRV-Cross, pin via Scripts/build_spirv_cross_xcframework.sh)";
}

} // extern "C"
