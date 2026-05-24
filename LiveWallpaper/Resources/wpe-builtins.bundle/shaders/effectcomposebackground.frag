// LiveWallpaper clean-room implementation of WPE's
// `effectcomposebackground` fragment stage. The material binds slot 0
// to the live compose target and slot 1 to `_rt_FullFrameBuffer`; the
// default behavior is to surface the background buffer so post-process
// effects see the rendered scene underneath.

uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;

void main() {
    gl_FragColor = texSample2D(g_Texture1, v_TexCoord);
}
