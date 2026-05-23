// LiveWallpaper clean-room implementation of WPE's
// `effectcomposebackground` vertex stage. The companion material
// (materials/util/effectcomposebackground.json) binds a single
// `_rt_FullFrameBuffer` sampler at slot 1 and uses the standard
// fullscreen-pass MVP transform, so the shader only needs to forward
// the quad position and UV.

uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;

void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
