// Public C interface for the WPE shader toolchain XCFramework.
// Swift consumes only these symbols; the underlying glslang + SPIRV-Tools
// + SPIRV-Cross C++ bodies stay hidden inside the static archive.

#ifndef WPE_SHADER_TOOLCHAIN_H
#define WPE_SHADER_TOOLCHAIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Compile a single-pass WPE fragment shader pair through glslang's GLSL
// frontend, producing a SPIR-V module. On success, `*out_spirv_words` is
// a heap-allocated buffer of `*out_spirv_count` uint32_t words owned by
// the caller — release with `wpe_shader_free_spirv`. On failure, returns
// non-zero and writes a diagnostic message into `*out_diag` (caller
// frees with `free`).
//
// `vertex_glsl` may be null when only the fragment stage matters; the
// canonical fullscreen-quad vertex stage is implied in that case.
int wpe_shader_glsl_to_spirv(
    const char *vertex_glsl,
    const char *fragment_glsl,
    uint32_t   **out_spirv_words,
    size_t     *out_spirv_count,
    char      **out_diag
);

void wpe_shader_free_spirv(uint32_t *spirv_words);

// Translate a SPIR-V module to Metal Shading Language. The resulting
// `*out_msl` is a null-terminated UTF-8 string allocated with `malloc`;
// the caller releases via `free`. On failure, returns non-zero and
// writes a diagnostic into `*out_diag`.
int wpe_shader_spirv_to_msl(
    const uint32_t *spirv_words,
    size_t          spirv_count,
    char          **out_msl,
    char          **out_diag
);

// Reflection: enumerate uniform buffers, texture bindings, and sampler
// slots in the SPIR-V module. The Swift wrapper uses this to populate
// `WPEShaderCompileResult.uniformLayout` and `samplerNames` without
// re-parsing the MSL string.
typedef struct {
    char    *name;     // owned by toolchain; free with wpe_shader_free_reflection
    int32_t  binding;
    int32_t  size_bytes;
} wpe_shader_reflection_binding;

typedef struct {
    wpe_shader_reflection_binding *uniforms;
    size_t                          uniform_count;
    wpe_shader_reflection_binding *samplers;
    size_t                          sampler_count;
} wpe_shader_reflection_result;

int wpe_shader_reflect_spirv(
    const uint32_t              *spirv_words,
    size_t                       spirv_count,
    wpe_shader_reflection_result *out_result,
    char                       **out_diag
);

void wpe_shader_free_reflection(wpe_shader_reflection_result *result);

// Library version. Bumps whenever a pinned upstream tag changes — Swift
// can log this for cache invalidation when the toolchain bumps.
const char *wpe_shader_toolchain_version(void);

#ifdef __cplusplus
}
#endif

#endif // WPE_SHADER_TOOLCHAIN_H
