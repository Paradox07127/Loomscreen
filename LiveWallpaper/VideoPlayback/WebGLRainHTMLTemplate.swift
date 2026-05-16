import Foundation

enum WebGLRainHTMLTemplate {
    static func html(videoURL: String) -> String {
        let videoLiteral = jsStringLiteral(videoURL)
        return #"""
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: #050608;
            }
            #source-video {
              position: fixed;
              width: 1px;
              height: 1px;
              left: -10px;
              top: -10px;
              opacity: 0;
              pointer-events: none;
            }
            #gl {
              position: fixed;
              inset: 0;
              width: 100vw;
              height: 100vh;
              display: block;
              background: #050608;
            }
          </style>
        </head>
        <body>
          <!-- Inspired by Codrops RainEffect by Lucas Bebber. See ThirdPartyNotices.md. -->
          <video id="source-video" muted loop autoplay playsinline crossorigin="anonymous"></video>
          <canvas id="gl"></canvas>
          <script>
          (function () {
            'use strict';

            var video = document.getElementById('source-video');
            var canvas = document.getElementById('gl');
            var gl = canvas.getContext('webgl', {
              alpha: false,
              antialias: false,
              depth: false,
              stencil: false,
              preserveDrawingBuffer: false,
              powerPreference: 'high-performance'
            }) || canvas.getContext('experimental-webgl');

            if (!gl) {
              document.body.style.background = '#050608';
              return;
            }

            video.src = \#(videoLiteral);
            video.muted = true;
            video.loop = true;
            video.autoplay = true;
            video.playsInline = true;

            var waterCanvas = document.createElement('canvas');
            waterCanvas.width = 512;
            waterCanvas.height = 288;
            var waterCtx = waterCanvas.getContext('2d', { alpha: false });
            waterCtx.fillStyle = 'black';
            waterCtx.fillRect(0, 0, waterCanvas.width, waterCanvas.height);

            var drops = [];
            var streaks = [];
            var spawnDrip = 0;
            var spawnStreak = 0;
            var lastTime = performance.now();

            function rand(min, max) {
              return min + Math.random() * (max - min);
            }

            function makeDrop(x, y, radius, life, drift) {
              drops.push({
                x: x,
                y: y,
                r: radius,
                age: 0,
                life: life,
                vx: drift || rand(-3, 3),
                vy: rand(1, 9),
                wobble: rand(0, Math.PI * 2)
              });
            }

            function makeStreak(x) {
              var radius = rand(2.5, 7.5);
              streaks.push({
                x: x,
                y: rand(-70, 0),
                r: radius,
                vy: rand(55, 155),
                length: rand(38, 150),
                age: 0,
                life: rand(2.4, 6.0),
                wiggle: rand(0, Math.PI * 2)
              });
            }

            function seedWater() {
              for (var i = 0; i < 220; i++) {
                makeDrop(
                  rand(0, waterCanvas.width),
                  rand(0, waterCanvas.height),
                  rand(1.2, 5.2),
                  rand(4.0, 13.0),
                  rand(-1.2, 1.2)
                );
              }
              for (var j = 0; j < 34; j++) {
                makeStreak(rand(0, waterCanvas.width));
                streaks[j].y = rand(0, waterCanvas.height);
              }
            }

            function drawDrop(ctx, drop, alpha) {
              var g = ctx.createRadialGradient(
                drop.x - drop.r * 0.35,
                drop.y - drop.r * 0.45,
                drop.r * 0.12,
                drop.x,
                drop.y,
                drop.r * 1.25
              );
              g.addColorStop(0.00, 'rgba(255,255,255,' + (0.95 * alpha) + ')');
              g.addColorStop(0.28, 'rgba(220,238,255,' + (0.52 * alpha) + ')');
              g.addColorStop(0.64, 'rgba(90,150,210,' + (0.26 * alpha) + ')');
              g.addColorStop(1.00, 'rgba(0,0,0,0)');
              ctx.fillStyle = g;
              ctx.beginPath();
              ctx.ellipse(drop.x, drop.y, drop.r * 0.82, drop.r * 1.18, 0, 0, Math.PI * 2);
              ctx.fill();

              ctx.strokeStyle = 'rgba(255,255,255,' + (0.22 * alpha) + ')';
              ctx.lineWidth = Math.max(0.7, drop.r * 0.16);
              ctx.beginPath();
              ctx.arc(drop.x - drop.r * 0.18, drop.y - drop.r * 0.20, drop.r * 0.58, Math.PI * 1.12, Math.PI * 1.82);
              ctx.stroke();
            }

            function drawStreak(ctx, streak, alpha) {
              var tail = streak.length;
              var x = streak.x + Math.sin(streak.age * 2.1 + streak.wiggle) * streak.r * 0.7;
              var y = streak.y;
              var grad = ctx.createLinearGradient(x, y - tail, x, y + streak.r);
              grad.addColorStop(0.00, 'rgba(0,0,0,0)');
              grad.addColorStop(0.18, 'rgba(120,170,220,' + (0.09 * alpha) + ')');
              grad.addColorStop(0.70, 'rgba(230,245,255,' + (0.25 * alpha) + ')');
              grad.addColorStop(1.00, 'rgba(255,255,255,' + (0.62 * alpha) + ')');
              ctx.strokeStyle = grad;
              ctx.lineWidth = Math.max(1.2, streak.r * 0.42);
              ctx.lineCap = 'round';
              ctx.beginPath();
              ctx.moveTo(x, y - tail);
              ctx.quadraticCurveTo(x + Math.sin(streak.age * 4.0) * streak.r, y - tail * 0.38, x, y);
              ctx.stroke();

              drawDrop(ctx, { x: x, y: y, r: streak.r }, alpha);
            }

            function updateWater(dt) {
              waterCtx.globalCompositeOperation = 'source-over';
              waterCtx.fillStyle = 'rgba(0,0,0,0.145)';
              waterCtx.fillRect(0, 0, waterCanvas.width, waterCanvas.height);

              spawnDrip += dt * 70.0;
              while (spawnDrip > 1.0) {
                spawnDrip -= 1.0;
                var heavy = Math.random() > 0.72;
                makeDrop(
                  rand(0, waterCanvas.width),
                  rand(-8, waterCanvas.height * 0.82),
                  heavy ? rand(4.0, 10.0) : rand(1.0, 3.9),
                  heavy ? rand(2.7, 6.2) : rand(4.5, 11.0),
                  rand(-2.0, 2.0)
                );
              }

              spawnStreak += dt * 18.0;
              while (spawnStreak > 1.0) {
                spawnStreak -= 1.0;
                makeStreak(rand(0, waterCanvas.width));
              }

              waterCtx.globalCompositeOperation = 'lighter';

              for (var i = drops.length - 1; i >= 0; i--) {
                var d = drops[i];
                d.age += dt;
                var lifeRatio = d.age / d.life;
                if (lifeRatio >= 1.0 || d.y > waterCanvas.height + 16) {
                  drops.splice(i, 1);
                  continue;
                }
                var fade = Math.sin(Math.min(1, lifeRatio) * Math.PI);
                d.x += (d.vx + Math.sin(d.age * 3.2 + d.wobble) * 0.45) * dt;
                d.y += d.vy * dt;
                drawDrop(waterCtx, d, Math.max(0.18, fade));
              }

              for (var j = streaks.length - 1; j >= 0; j--) {
                var s = streaks[j];
                s.age += dt;
                var ratio = s.age / s.life;
                s.y += s.vy * dt;
                if (ratio >= 1.0 || s.y - s.length > waterCanvas.height + 20) {
                  streaks.splice(j, 1);
                  continue;
                }
                var a = Math.min(1.0, Math.sin(Math.min(1, ratio) * Math.PI) + 0.2);
                drawStreak(waterCtx, s, a);
              }

              waterCtx.globalCompositeOperation = 'source-over';
              waterCtx.fillStyle = 'rgba(255,255,255,0.018)';
              for (var k = 0; k < 30; k++) {
                var px = (k * 97 + performance.now() * 0.004) % waterCanvas.width;
                var py = (k * 53 + performance.now() * 0.011) % waterCanvas.height;
                waterCtx.fillRect(px, py, 0.8, 0.8);
              }
            }

            var vertexSource =
              "attribute vec2 a_pos;\n" +
              "varying vec2 v_uv;\n" +
              "void main(){\n" +
              "  v_uv = (a_pos + 1.0) * 0.5;\n" +
              "  gl_Position = vec4(a_pos, 0.0, 1.0);\n" +
              "}\n";

            var fragmentSource =
              "precision mediump float;\n" +
              "varying vec2 v_uv;\n" +
              "uniform sampler2D u_video;\n" +
              "uniform sampler2D u_water;\n" +
              "uniform vec2 u_resolution;\n" +
              "uniform vec2 u_videoSize;\n" +
              "uniform vec2 u_texel;\n" +
              "uniform float u_time;\n" +
              "vec2 coverUV(vec2 uv){\n" +
              "  float screenAspect = u_resolution.x / max(u_resolution.y, 1.0);\n" +
              "  float videoAspect = u_videoSize.x / max(u_videoSize.y, 1.0);\n" +
              "  vec2 scale = screenAspect < videoAspect ? vec2(screenAspect / videoAspect, 1.0) : vec2(1.0, videoAspect / screenAspect);\n" +
              "  return (uv - 0.5) * scale + 0.5;\n" +
              "}\n" +
              "float sampleWater(vec2 uv){ return texture2D(u_water, clamp(uv, 0.0, 1.0)).r; }\n" +
              "void main(){\n" +
              "  vec2 uv = v_uv;\n" +
              "  float h = sampleWater(uv);\n" +
              "  float hx = sampleWater(uv + vec2(u_texel.x, 0.0));\n" +
              "  float hy = sampleWater(uv + vec2(0.0, u_texel.y));\n" +
              "  vec2 normal = vec2(h - hx, h - hy);\n" +
              "  vec2 slowGlass = vec2(sin(uv.y * 42.0 + u_time * 0.33), cos(uv.x * 31.0 - u_time * 0.27)) * 0.0018;\n" +
              "  float mask = smoothstep(0.035, 0.70, h);\n" +
              "  vec2 refractUV = uv + normal * (0.105 + h * 0.035) + slowGlass;\n" +
              "  vec2 baseUV = coverUV(refractUV);\n" +
              "  vec3 color = texture2D(u_video, baseUV).rgb;\n" +
              "  vec3 soft = (\n" +
              "    texture2D(u_video, coverUV(uv + vec2( 0.0025, 0.0000))).rgb +\n" +
              "    texture2D(u_video, coverUV(uv + vec2(-0.0025, 0.0000))).rgb +\n" +
              "    texture2D(u_video, coverUV(uv + vec2( 0.0000, 0.0025))).rgb +\n" +
              "    texture2D(u_video, coverUV(uv + vec2( 0.0000,-0.0025))).rgb\n" +
              "  ) * 0.25;\n" +
              "  color = mix(soft * 0.82, color, 0.72 + mask * 0.28);\n" +
              "  vec3 lightDir = normalize(vec3(-0.45, 0.55, 0.72));\n" +
              "  vec3 n = normalize(vec3(normal * 18.0, 1.0));\n" +
              "  float spec = pow(max(dot(n, lightDir), 0.0), 22.0) * (0.35 + h * 1.9);\n" +
              "  float rim = smoothstep(0.08, 0.55, length(normal) * 20.0) * mask;\n" +
              "  float shadow = smoothstep(0.18, 0.92, h) * 0.12;\n" +
              "  color -= shadow;\n" +
              "  color += vec3(0.72, 0.88, 1.0) * spec;\n" +
              "  color += vec3(0.30, 0.46, 0.64) * rim * 0.16;\n" +
              "  color *= vec3(0.92, 0.96, 1.02);\n" +
              "  color = pow(max(color, vec3(0.0)), vec3(0.94));\n" +
              "  gl_FragColor = vec4(color, 1.0);\n" +
              "}\n";

            function compile(type, source) {
              var shader = gl.createShader(type);
              gl.shaderSource(shader, source);
              gl.compileShader(shader);
              if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                throw new Error(gl.getShaderInfoLog(shader) || 'shader compile failed');
              }
              return shader;
            }

            var program = gl.createProgram();
            gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
            gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
            gl.linkProgram(program);
            if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
              throw new Error(gl.getProgramInfoLog(program) || 'program link failed');
            }
            gl.useProgram(program);

            var buffer = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
              -1, -1,
               1, -1,
              -1,  1,
              -1,  1,
               1, -1,
               1,  1
            ]), gl.STATIC_DRAW);

            var aPos = gl.getAttribLocation(program, 'a_pos');
            gl.enableVertexAttribArray(aPos);
            gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

            var uVideo = gl.getUniformLocation(program, 'u_video');
            var uWater = gl.getUniformLocation(program, 'u_water');
            var uResolution = gl.getUniformLocation(program, 'u_resolution');
            var uVideoSize = gl.getUniformLocation(program, 'u_videoSize');
            var uTexel = gl.getUniformLocation(program, 'u_texel');
            var uTime = gl.getUniformLocation(program, 'u_time');

            var videoTexture = gl.createTexture();
            gl.activeTexture(gl.TEXTURE0);
            gl.bindTexture(gl.TEXTURE_2D, videoTexture);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([5, 6, 8, 255]));

            var waterTexture = gl.createTexture();
            gl.activeTexture(gl.TEXTURE1);
            gl.bindTexture(gl.TEXTURE_2D, waterTexture);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, waterCanvas);

            gl.uniform1i(uVideo, 0);
            gl.uniform1i(uWater, 1);
            gl.uniform2f(uTexel, 1 / waterCanvas.width, 1 / waterCanvas.height);

            function resize() {
              var dpr = Math.min(window.devicePixelRatio || 1, 2);
              var width = Math.max(1, Math.floor(window.innerWidth * dpr));
              var height = Math.max(1, Math.floor(window.innerHeight * dpr));
              if (canvas.width !== width || canvas.height !== height) {
                canvas.width = width;
                canvas.height = height;
                gl.viewport(0, 0, width, height);
              }
            }

            function updateVideoTexture() {
              if (video.readyState < 2 || video.videoWidth === 0 || video.videoHeight === 0) {
                return;
              }
              gl.activeTexture(gl.TEXTURE0);
              gl.bindTexture(gl.TEXTURE_2D, videoTexture);
              try {
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
              } catch (e) {
                // WKWebView can throw during the first CORS negotiation frame.
              }
            }

            function frame(now) {
              resize();
              var dt = Math.min(0.04, Math.max(0.001, (now - lastTime) / 1000));
              lastTime = now;
              updateWater(dt);
              updateVideoTexture();

              gl.activeTexture(gl.TEXTURE1);
              gl.bindTexture(gl.TEXTURE_2D, waterTexture);
              gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, waterCanvas);

              gl.uniform2f(uResolution, canvas.width, canvas.height);
              gl.uniform2f(uVideoSize, video.videoWidth || canvas.width, video.videoHeight || canvas.height);
              gl.uniform1f(uTime, now / 1000);
              gl.drawArrays(gl.TRIANGLES, 0, 6);
              requestAnimationFrame(frame);
            }

            function nudgePlayback() {
              var p = video.play();
              if (p && typeof p.catch === 'function') {
                p.catch(function () {});
              }
            }

            seedWater();
            resize();
            window.addEventListener('resize', resize);
            document.addEventListener('visibilitychange', nudgePlayback);
            video.addEventListener('canplay', nudgePlayback);
            nudgePlayback();
            requestAnimationFrame(frame);
          })();
          </script>
        </body>
        </html>
        """#
    }

    private static func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data
            .flatMap { String(data: $0, encoding: .utf8) }?
            .replacingOccurrences(of: "\\/", with: "/") ?? "\"\""
    }
}
