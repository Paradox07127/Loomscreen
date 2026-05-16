import Foundation

enum WebGLRainAssets {
    static let bundleName = "webgl-rain"
    static let expectedFiles = [
        "drop-alpha.png",
        "drop-color.png",
        "drop-shine2.png"
    ]

    static var rootURL: URL? {
        candidateBundles.lazy.compactMap {
            $0.url(forResource: bundleName, withExtension: "bundle")
        }.first
    }

    static func dataURL(fileName: String) -> String {
        if let data = data(fileName: fileName) {
            return "data:image/png;base64,\(data.base64EncodedString())"
        }
        return transparentPixelDataURL
    }

    private static func data(fileName: String) -> Data? {
        for bundle in candidateBundles {
            if let root = bundle.url(forResource: bundleName, withExtension: "bundle") {
                let url = root.appendingPathComponent(fileName, isDirectory: false)
                if let data = try? Data(contentsOf: url) {
                    return data
                }
            }

            let nsName = fileName as NSString
            if let url = bundle.url(
                forResource: nsName.deletingPathExtension,
                withExtension: nsName.pathExtension,
                subdirectory: "\(bundleName).bundle"
            ),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private static var candidateBundles: [Bundle] {
        [Bundle.main, Bundle(for: WebGLRainBundleToken.self)]
    }

    private static let transparentPixelDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}

private final class WebGLRainBundleToken {}

enum WebGLRainHTMLTemplate {
    static func html(videoURL: String) -> String {
        let videoLiteral = jsStringLiteral(videoURL)
        let dropAlphaLiteral = jsStringLiteral(WebGLRainAssets.dataURL(fileName: "drop-alpha.png"))
        let dropColorLiteral = jsStringLiteral(WebGLRainAssets.dataURL(fileName: "drop-color.png"))
        let dropShineLiteral = jsStringLiteral(WebGLRainAssets.dataURL(fileName: "drop-shine2.png"))

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
            #container {
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
          <!-- Adapted from Codrops RainEffect by Lucas Bebber. See ThirdPartyNotices.md. -->
          <video id="source-video" muted loop autoplay playsinline crossorigin="anonymous"></video>
          <canvas id="container"></canvas>
          <script>
          var sourceVideoURL = \#(videoLiteral);
          var dropAlphaDataURL = \#(dropAlphaLiteral);
          var dropColorDataURL = \#(dropColorLiteral);
          var dropShineDataURL = \#(dropShineLiteral);
          \#(rendererScript)
          </script>
        </body>
        </html>
        """#
    }

    private static let rendererScript = #"""
          (function () {
            'use strict';

            var dropSize = 64;
            var video = document.getElementById('source-video');
            var canvas = document.getElementById('container');
            var dropAlpha = null;
            var dropColor = null;
            var dropShine = null;
            var raindrops = null;
            var renderer = null;
            var lastFrameTime = performance.now();
            var currentDPR = 1;
            var animationStarted = false;

            video.src = sourceVideoURL;
            video.muted = true;
            video.loop = true;
            video.autoplay = true;
            video.playsInline = true;

            var Drop = {
              x: 0,
              y: 0,
              r: 0,
              spreadX: 0,
              spreadY: 0,
              momentum: 0,
              momentumX: 0,
              lastSpawn: 0,
              nextSpawn: 0,
              parent: null,
              isNew: true,
              killed: false,
              shrink: 0
            };

            var defaultOptions = {
              minR: 12,
              maxR: 46,
              maxDrops: 1100,
              rainChance: 0.36,
              rainLimit: 7,
              dropletsRate: 58,
              dropletsSize: [2.2, 5.8],
              dropletsCleaningRadiusMultiplier: 0.30,
              raining: true,
              globalTimeScale: 0.95,
              trailRate: 1.35,
              autoShrink: true,
              spawnArea: [-0.18, 0.88],
              trailScaleRange: [0.20, 0.42],
              collisionRadius: 0.45,
              collisionRadiusIncrease: 0.002,
              dropFallMultiplier: 0.55,
              collisionBoostMultiplier: 0.045,
              collisionBoost: 0.55
            };

            function createCanvas(width, height) {
              var c = document.createElement('canvas');
              c.width = Math.max(1, Math.floor(width));
              c.height = Math.max(1, Math.floor(height));
              return c;
            }

            function random(from, to, interpolation) {
              if (from == null) {
                from = 0;
                to = 1;
              } else if (to == null) {
                to = from;
                from = 0;
              }
              if (interpolation == null) {
                interpolation = function (n) { return n; };
              }
              return from + interpolation(Math.random()) * (to - from);
            }

            function chance(value) {
              return random() <= value;
            }

            function loadImage(src) {
              return new Promise(function (resolve, reject) {
                var image = new Image();
                image.onload = function () { resolve(image); };
                image.onerror = function () { reject(new Error('Failed to load rain texture')); };
                image.src = src;
              });
            }

            function cloneDrop(options) {
              return Object.assign(Object.create(Drop), options);
            }

            function Raindrops(width, height, scale, dropAlphaImage, dropColorImage, options) {
              this.width = width;
              this.height = height;
              this.scale = scale;
              this.dropAlpha = dropAlphaImage;
              this.dropColor = dropColorImage;
              this.options = Object.assign({}, defaultOptions, options || {});
              this.init();
            }

            Raindrops.prototype = {
              dropColor: null,
              dropAlpha: null,
              canvas: null,
              ctx: null,
              width: 0,
              height: 0,
              scale: 0,
              dropletsPixelDensity: 1,
              droplets: null,
              dropletsCtx: null,
              dropletsCounter: 0,
              drops: null,
              dropsGfx: null,
              clearDropletsGfx: null,
              textureCleaningIterations: 0,
              options: null,

              init: function () {
                this.canvas = createCanvas(this.width, this.height);
                this.ctx = this.canvas.getContext('2d');
                this.droplets = createCanvas(
                  this.width * this.dropletsPixelDensity,
                  this.height * this.dropletsPixelDensity
                );
                this.dropletsCtx = this.droplets.getContext('2d');
                this.drops = [];
                this.dropsGfx = [];
                this.renderDropsGfx();
                this.seedDrops();
              },

              get deltaR() {
                return this.options.maxR - this.options.minR;
              },

              get area() {
                return (this.width * this.height) / Math.max(this.scale, 1);
              },

              get areaMultiplier() {
                return Math.sqrt(this.area / (1024 * 768));
              },

              seedDrops: function () {
                var count = Math.floor(72 * this.areaMultiplier);
                for (var i = 0; i < count; i++) {
                  this.addDrop(this.createDrop({
                    x: random(this.width / this.scale),
                    y: random(this.height / this.scale),
                    r: random(this.options.minR * 0.45, this.options.maxR * 0.70, function (n) { return n * n; }),
                    momentum: random(0, 0.8),
                    spreadX: random(0, 0.7),
                    spreadY: random(0, 0.8)
                  }));
                }
              },

              drawDroplet: function (x, y, r) {
                this.drawDrop(this.dropletsCtx, cloneDrop({
                  x: x * this.dropletsPixelDensity,
                  y: y * this.dropletsPixelDensity,
                  r: r * this.dropletsPixelDensity
                }));
              },

              renderDropsGfx: function () {
                var dropBuffer = createCanvas(dropSize, dropSize);
                var dropBufferCtx = dropBuffer.getContext('2d');
                this.dropsGfx = Array.apply(null, Array(255)).map(function (_, i) {
                  var drop = createCanvas(dropSize, dropSize);
                  var dropCtx = drop.getContext('2d');

                  dropBufferCtx.clearRect(0, 0, dropSize, dropSize);
                  dropBufferCtx.globalCompositeOperation = 'source-over';
                  dropBufferCtx.drawImage(this.dropColor, 0, 0, dropSize, dropSize);
                  dropBufferCtx.globalCompositeOperation = 'screen';
                  dropBufferCtx.fillStyle = 'rgba(0,0,' + i + ',1)';
                  dropBufferCtx.fillRect(0, 0, dropSize, dropSize);

                  dropCtx.globalCompositeOperation = 'source-over';
                  dropCtx.drawImage(this.dropAlpha, 0, 0, dropSize, dropSize);
                  dropCtx.globalCompositeOperation = 'source-in';
                  dropCtx.drawImage(dropBuffer, 0, 0, dropSize, dropSize);
                  return drop;
                }, this);

                this.clearDropletsGfx = createCanvas(128, 128);
                var clearDropletsCtx = this.clearDropletsGfx.getContext('2d');
                clearDropletsCtx.fillStyle = '#000';
                clearDropletsCtx.beginPath();
                clearDropletsCtx.arc(64, 64, 64, 0, Math.PI * 2);
                clearDropletsCtx.fill();
              },

              drawDrop: function (ctx, drop) {
                if (this.dropsGfx.length === 0) { return; }
                var x = drop.x;
                var y = drop.y;
                var r = drop.r;
                var spreadX = drop.spreadX || 0;
                var spreadY = drop.spreadY || 0;
                var scaleX = 1;
                var scaleY = 1.5;
                var d = Math.max(0, Math.min(1, ((r - this.options.minR) / this.deltaR) * 0.9));
                d *= 1 / (((spreadX + spreadY) * 0.5) + 1);

                ctx.globalAlpha = 1;
                ctx.globalCompositeOperation = 'source-over';
                d = Math.floor(d * (this.dropsGfx.length - 1));
                ctx.drawImage(
                  this.dropsGfx[d],
                  (x - (r * scaleX * (spreadX + 1))) * this.scale,
                  (y - (r * scaleY * (spreadY + 1))) * this.scale,
                  (r * 2 * scaleX * (spreadX + 1)) * this.scale,
                  (r * 2 * scaleY * (spreadY + 1)) * this.scale
                );
              },

              clearDroplets: function (x, y, r) {
                r = r || 30;
                this.dropletsCtx.globalCompositeOperation = 'destination-out';
                this.dropletsCtx.drawImage(
                  this.clearDropletsGfx,
                  (x - r) * this.dropletsPixelDensity * this.scale,
                  (y - r) * this.dropletsPixelDensity * this.scale,
                  (r * 2) * this.dropletsPixelDensity * this.scale,
                  (r * 2) * this.dropletsPixelDensity * this.scale * 1.5
                );
              },

              clearCanvas: function () {
                this.ctx.clearRect(0, 0, this.width, this.height);
              },

              createDrop: function (options) {
                if (this.drops.length >= this.options.maxDrops * this.areaMultiplier) { return null; }
                return cloneDrop(options);
              },

              addDrop: function (drop) {
                if (this.drops.length >= this.options.maxDrops * this.areaMultiplier || drop == null) {
                  return false;
                }
                this.drops.push(drop);
                return true;
              },

              updateRain: function (timeScale) {
                var rainDrops = [];
                if (!this.options.raining) { return rainDrops; }
                var limit = this.options.rainLimit * timeScale * this.areaMultiplier;
                var count = 0;
                while (chance(this.options.rainChance * timeScale * this.areaMultiplier) && count < limit) {
                  count++;
                  var r = random(this.options.minR, this.options.maxR, function (n) { return Math.pow(n, 3); });
                  var rainDrop = this.createDrop({
                    x: random(this.width / this.scale),
                    y: random((this.height / this.scale) * this.options.spawnArea[0], (this.height / this.scale) * this.options.spawnArea[1]),
                    r: r,
                    momentum: 1 + ((r - this.options.minR) * 0.1) + random(2),
                    spreadX: 1.5,
                    spreadY: 1.5
                  });
                  if (rainDrop != null) {
                    rainDrops.push(rainDrop);
                  }
                }
                return rainDrops;
              },

              clearTexture: function () {
                this.textureCleaningIterations = 50;
              },

              updateDroplets: function (timeScale) {
                if (this.textureCleaningIterations > 0) {
                  this.textureCleaningIterations -= 1 * timeScale;
                  this.dropletsCtx.globalCompositeOperation = 'destination-out';
                  this.dropletsCtx.fillStyle = 'rgba(0,0,0,' + (0.05 * timeScale) + ')';
                  this.dropletsCtx.fillRect(
                    0,
                    0,
                    this.width * this.dropletsPixelDensity,
                    this.height * this.dropletsPixelDensity
                  );
                }
                if (this.options.raining) {
                  this.dropletsCounter += this.options.dropletsRate * timeScale * this.areaMultiplier;
                  while (this.dropletsCounter >= 1) {
                    this.dropletsCounter--;
                    this.drawDroplet(
                      random(this.width / this.scale),
                      random(this.height / this.scale),
                      random(this.options.dropletsSize[0], this.options.dropletsSize[1], function (n) { return n * n; })
                    );
                  }
                }
                this.ctx.drawImage(this.droplets, 0, 0, this.width, this.height);
              },

              updateDrops: function (timeScale) {
                var newDrops = [];
                this.updateDroplets(timeScale);
                newDrops = newDrops.concat(this.updateRain(timeScale));

                this.drops.sort(function (a, b) {
                  var va = (a.y * (this.width / this.scale)) + a.x;
                  var vb = (b.y * (this.width / this.scale)) + b.x;
                  return va > vb ? 1 : va === vb ? 0 : -1;
                }.bind(this));

                this.drops.forEach(function (drop, i) {
                  if (!drop.killed) {
                    if (chance((drop.r - (this.options.minR * this.options.dropFallMultiplier)) * (0.1 / this.deltaR) * timeScale)) {
                      drop.momentum += random((drop.r / this.options.maxR) * 4);
                    }
                    if (this.options.autoShrink && drop.r <= this.options.minR && chance(0.05 * timeScale)) {
                      drop.shrink += 0.01;
                    }

                    drop.r -= drop.shrink * timeScale;
                    if (drop.r <= 0) { drop.killed = true; }

                    if (this.options.raining) {
                      drop.lastSpawn += drop.momentum * timeScale * this.options.trailRate;
                      if (drop.lastSpawn > drop.nextSpawn) {
                        var trailDrop = this.createDrop({
                          x: drop.x + (random(-drop.r, drop.r) * 0.1),
                          y: drop.y - (drop.r * 0.01),
                          r: drop.r * random(this.options.trailScaleRange[0], this.options.trailScaleRange[1]),
                          spreadY: drop.momentum * 0.1,
                          parent: drop
                        });

                        if (trailDrop != null) {
                          newDrops.push(trailDrop);
                          drop.r *= Math.pow(0.97, timeScale);
                          drop.lastSpawn = 0;
                          drop.nextSpawn = random(this.options.minR, this.options.maxR)
                            - (drop.momentum * 2 * this.options.trailRate)
                            + (this.options.maxR - drop.r);
                        }
                      }
                    }

                    drop.spreadX *= Math.pow(0.4, timeScale);
                    drop.spreadY *= Math.pow(0.7, timeScale);

                    var moved = drop.momentum > 0;
                    if (moved && !drop.killed) {
                      drop.y += drop.momentum * this.options.globalTimeScale;
                      drop.x += drop.momentumX * this.options.globalTimeScale;
                      if (drop.y > (this.height / this.scale) + drop.r) {
                        drop.killed = true;
                      }
                    }

                    var checkCollision = (moved || drop.isNew) && !drop.killed;
                    drop.isNew = false;

                    if (checkCollision) {
                      this.drops.slice(i + 1, i + 70).forEach(function (drop2) {
                        if (
                          drop !== drop2
                          && drop.r > drop2.r
                          && drop.parent !== drop2
                          && drop2.parent !== drop
                          && !drop2.killed
                        ) {
                          var dx = drop2.x - drop.x;
                          var dy = drop2.y - drop.y;
                          var distance = Math.sqrt((dx * dx) + (dy * dy));
                          if (distance < (drop.r + drop2.r) * (
                            this.options.collisionRadius
                            + (drop.momentum * this.options.collisionRadiusIncrease * timeScale)
                          )) {
                            var pi = Math.PI;
                            var r1 = drop.r;
                            var r2 = drop2.r;
                            var a1 = pi * (r1 * r1);
                            var a2 = pi * (r2 * r2);
                            var targetR = Math.sqrt((a1 + (a2 * 0.8)) / pi);
                            if (targetR > this.options.maxR) {
                              targetR = this.options.maxR;
                            }
                            drop.r = targetR;
                            drop.momentumX += dx * 0.1;
                            drop.spreadX = 0;
                            drop.spreadY = 0;
                            drop2.killed = true;
                            drop.momentum = Math.max(
                              drop2.momentum,
                              Math.min(
                                40,
                                drop.momentum
                                  + (targetR * this.options.collisionBoostMultiplier)
                                  + this.options.collisionBoost
                              )
                            );
                          }
                        }
                      }, this);
                    }

                    drop.momentum -= Math.max(1, (this.options.minR * 0.5) - drop.momentum) * 0.1 * timeScale;
                    if (drop.momentum < 0) { drop.momentum = 0; }
                    drop.momentumX *= Math.pow(0.7, timeScale);

                    if (!drop.killed) {
                      newDrops.push(drop);
                      if (moved && this.options.dropletsRate > 0) {
                        this.clearDroplets(drop.x, drop.y, drop.r * this.options.dropletsCleaningRadiusMultiplier);
                      }
                      this.drawDrop(this.ctx, drop);
                    }
                  }
                }, this);

                this.drops = newDrops;
              },

              step: function (dt) {
                this.clearCanvas();
                var timeScale = dt / ((1 / 60) * 1000);
                if (timeScale > 1.1) { timeScale = 1.1; }
                timeScale *= this.options.globalTimeScale;
                this.updateDrops(timeScale);
              }
            };

            var vertShader = [
              'precision mediump float;',
              'attribute vec2 a_position;',
              'void main() {',
              '  gl_Position = vec4(a_position, 0.0, 1.0);',
              '}'
            ].join('\n');

            var fragShader = [
              'precision mediump float;',
              'uniform sampler2D u_waterMap;',
              'uniform sampler2D u_textureShine;',
              'uniform sampler2D u_textureFg;',
              'uniform sampler2D u_textureBg;',
              'uniform vec2 u_resolution;',
              'uniform vec2 u_parallax;',
              'uniform float u_parallaxFg;',
              'uniform float u_parallaxBg;',
              'uniform float u_textureRatio;',
              'uniform bool u_renderShine;',
              'uniform bool u_renderShadow;',
              'uniform float u_minRefraction;',
              'uniform float u_refractionDelta;',
              'uniform float u_brightness;',
              'uniform float u_alphaMultiply;',
              'uniform float u_alphaSubtract;',
              'vec4 blend(vec4 bg, vec4 fg) {',
              '  vec3 bgm = bg.rgb * bg.a;',
              '  vec3 fgm = fg.rgb * fg.a;',
              '  float ia = 1.0 - fg.a;',
              '  float a = fg.a + bg.a * ia;',
              '  vec3 rgb = a != 0.0 ? (fgm + bgm * ia) / a : vec3(0.0);',
              '  return vec4(rgb, a);',
              '}',
              'vec2 pixel() {',
              '  return vec2(1.0, 1.0) / u_resolution;',
              '}',
              'vec2 parallax(float v) {',
              '  return u_parallax * pixel() * v;',
              '}',
              'vec2 texCoord() {',
              '  return vec2(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y) / u_resolution;',
              '}',
              'vec2 scaledTexCoord() {',
              '  float ratio = u_resolution.x / u_resolution.y;',
              '  vec2 scale = vec2(1.0, 1.0);',
              '  vec2 offset = vec2(0.0, 0.0);',
              '  float ratioDelta = ratio - u_textureRatio;',
              '  if (ratioDelta >= 0.0) {',
              '    scale.y = 1.0 + ratioDelta;',
              '    offset.y = ratioDelta / 2.0;',
              '  } else {',
              '    scale.x = 1.0 - ratioDelta;',
              '    offset.x = -ratioDelta / 2.0;',
              '  }',
              '  return (texCoord() + offset) / scale;',
              '}',
              'vec4 fgColor(float x, float y) {',
              '  float p2 = u_parallaxFg * 2.0;',
              '  vec2 scale = vec2((u_resolution.x + p2) / u_resolution.x, (u_resolution.y + p2) / u_resolution.y);',
              '  vec2 scaledCoord = texCoord() / scale;',
              '  vec2 offset = vec2((1.0 - (1.0 / scale.x)) / 2.0, (1.0 - (1.0 / scale.y)) / 2.0);',
              '  return texture2D(u_waterMap, (scaledCoord + offset) + (pixel() * vec2(x, y)) + parallax(u_parallaxFg));',
              '}',
              'void main() {',
              '  vec4 bg = texture2D(u_textureBg, scaledTexCoord() + parallax(u_parallaxBg));',
              '  vec4 cur = fgColor(0.0, 0.0);',
              '  float d = cur.b;',
              '  float x = cur.g;',
              '  float y = cur.r;',
              '  float a = clamp(cur.a * u_alphaMultiply - u_alphaSubtract, 0.0, 1.0);',
              '  vec2 refraction = (vec2(x, y) - 0.5) * 2.0;',
              '  vec2 refractionParallax = parallax(u_parallaxBg - u_parallaxFg);',
              '  vec2 refractionPos = scaledTexCoord()',
              '    + (pixel() * refraction * (u_minRefraction + (d * u_refractionDelta)))',
              '    + refractionParallax;',
              '  vec4 tex = texture2D(u_textureFg, refractionPos);',
              '  if (u_renderShine) {',
              '    float maxShine = 490.0;',
              '    float minShine = maxShine * 0.18;',
              '    vec2 shinePos = vec2(0.5, 0.5) + ((1.0 / 512.0) * refraction) * -(minShine + ((maxShine - minShine) * d));',
              '    vec4 shine = texture2D(u_textureShine, shinePos);',
              '    tex = blend(tex, shine);',
              '  }',
              '  vec4 fg = vec4(tex.rgb * u_brightness, a);',
              '  if (u_renderShadow) {',
              '    float borderAlpha = fgColor(0.0, 0.0 - (d * 6.0)).a;',
              '    borderAlpha = borderAlpha * u_alphaMultiply - (u_alphaSubtract + 0.5);',
              '    borderAlpha = clamp(borderAlpha, 0.0, 1.0) * 0.2;',
              '    fg = blend(vec4(0.0, 0.0, 0.0, borderAlpha), fg);',
              '  }',
              '  gl_FragColor = blend(bg, fg);',
              '}'
            ].join('\n');

            function getContext(targetCanvas, options) {
              return targetCanvas.getContext('webgl', options)
                || targetCanvas.getContext('experimental-webgl', options);
            }

            function createShader(gl, source, type) {
              var shader = gl.createShader(type);
              gl.shaderSource(shader, source);
              gl.compileShader(shader);
              if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
                throw new Error(gl.getShaderInfoLog(shader) || 'Shader compile failed');
              }
              return shader;
            }

            function createProgram(gl, vertexSource, fragmentSource) {
              var program = gl.createProgram();
              gl.attachShader(program, createShader(gl, vertexSource, gl.VERTEX_SHADER));
              gl.attachShader(program, createShader(gl, fragmentSource, gl.FRAGMENT_SHADER));
              gl.linkProgram(program);
              if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
                throw new Error(gl.getProgramInfoLog(program) || 'Program link failed');
              }
              return program;
            }

            function activeTexture(gl, i) {
              gl.activeTexture(gl.TEXTURE0 + i);
            }

            function createTexture(gl, source, i) {
              var texture = gl.createTexture();
              activeTexture(gl, i);
              gl.bindTexture(gl.TEXTURE_2D, texture);
              gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
              gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
              gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
              gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
              if (source == null) {
                gl.texImage2D(
                  gl.TEXTURE_2D,
                  0,
                  gl.RGBA,
                  1,
                  1,
                  0,
                  gl.RGBA,
                  gl.UNSIGNED_BYTE,
                  new Uint8Array([5, 6, 8, 255])
                );
              } else {
                updateTexture(gl, source);
              }
              return texture;
            }

            function updateTexture(gl, source) {
              if (
                source instanceof HTMLVideoElement
                && (source.readyState < 2 || source.videoWidth === 0 || source.videoHeight === 0)
              ) {
                return false;
              }
              try {
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
                return true;
              } catch (error) {
                return false;
              }
            }

            function RainRenderer(targetCanvas, canvasLiquid, imageFg, imageBg, imageShine, options) {
              this.canvas = targetCanvas;
              this.canvasLiquid = canvasLiquid;
              this.imageShine = imageShine;
              this.imageFg = imageFg;
              this.imageBg = imageBg;
              this.options = Object.assign({
                renderShadow: true,
                minRefraction: 145,
                maxRefraction: 520,
                brightness: 1.08,
                alphaMultiply: 7,
                alphaSubtract: 3,
                parallaxBg: 5,
                parallaxFg: 38
              }, options || {});
              this.parallaxX = 0;
              this.parallaxY = 0;
              this.init();
            }

            RainRenderer.prototype = {
              init: function () {
                this.width = this.canvas.width;
                this.height = this.canvas.height;
                this.gl = getContext(this.canvas, {
                  alpha: false,
                  antialias: false,
                  depth: false,
                  stencil: false,
                  preserveDrawingBuffer: false,
                  powerPreference: 'high-performance'
                });
                if (!this.gl) {
                  document.body.classList.add('no-webgl');
                  return;
                }

                var gl = this.gl;
                this.programWater = createProgram(gl, vertShader, fragShader);
                gl.useProgram(this.programWater);

                this.positionBuffer = gl.createBuffer();
                gl.bindBuffer(gl.ARRAY_BUFFER, this.positionBuffer);
                gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
                  -1.0, -1.0,
                   1.0, -1.0,
                  -1.0,  1.0,
                  -1.0,  1.0,
                   1.0, -1.0,
                   1.0,  1.0
                ]), gl.STATIC_DRAW);

                this.positionLocation = gl.getAttribLocation(this.programWater, 'a_position');
                gl.enableVertexAttribArray(this.positionLocation);
                gl.vertexAttribPointer(this.positionLocation, 2, gl.FLOAT, false, 0, 0);

                this.uniforms = {
                  waterMap: gl.getUniformLocation(this.programWater, 'u_waterMap'),
                  textureShine: gl.getUniformLocation(this.programWater, 'u_textureShine'),
                  textureFg: gl.getUniformLocation(this.programWater, 'u_textureFg'),
                  textureBg: gl.getUniformLocation(this.programWater, 'u_textureBg'),
                  resolution: gl.getUniformLocation(this.programWater, 'u_resolution'),
                  parallax: gl.getUniformLocation(this.programWater, 'u_parallax'),
                  parallaxFg: gl.getUniformLocation(this.programWater, 'u_parallaxFg'),
                  parallaxBg: gl.getUniformLocation(this.programWater, 'u_parallaxBg'),
                  textureRatio: gl.getUniformLocation(this.programWater, 'u_textureRatio'),
                  renderShine: gl.getUniformLocation(this.programWater, 'u_renderShine'),
                  renderShadow: gl.getUniformLocation(this.programWater, 'u_renderShadow'),
                  minRefraction: gl.getUniformLocation(this.programWater, 'u_minRefraction'),
                  refractionDelta: gl.getUniformLocation(this.programWater, 'u_refractionDelta'),
                  brightness: gl.getUniformLocation(this.programWater, 'u_brightness'),
                  alphaMultiply: gl.getUniformLocation(this.programWater, 'u_alphaMultiply'),
                  alphaSubtract: gl.getUniformLocation(this.programWater, 'u_alphaSubtract')
                };

                this.textures = [
                  createTexture(gl, this.canvasLiquid, 0),
                  createTexture(gl, this.imageShine, 1),
                  createTexture(gl, this.imageFg, 2),
                  createTexture(gl, this.imageBg, 3)
                ];

                gl.uniform1i(this.uniforms.waterMap, 0);
                gl.uniform1i(this.uniforms.textureShine, 1);
                gl.uniform1i(this.uniforms.textureFg, 2);
                gl.uniform1i(this.uniforms.textureBg, 3);
                gl.uniform1i(this.uniforms.renderShine, this.imageShine == null ? 0 : 1);
                gl.uniform1i(this.uniforms.renderShadow, this.options.renderShadow ? 1 : 0);
                gl.uniform1f(this.uniforms.minRefraction, this.options.minRefraction);
                gl.uniform1f(this.uniforms.refractionDelta, this.options.maxRefraction - this.options.minRefraction);
                gl.uniform1f(this.uniforms.brightness, this.options.brightness);
                gl.uniform1f(this.uniforms.alphaMultiply, this.options.alphaMultiply);
                gl.uniform1f(this.uniforms.alphaSubtract, this.options.alphaSubtract);
                gl.uniform1f(this.uniforms.parallaxBg, this.options.parallaxBg);
                gl.uniform1f(this.uniforms.parallaxFg, this.options.parallaxFg);
                gl.viewport(0, 0, this.width, this.height);
              },

              textureRatio: function () {
                if (this.imageBg instanceof HTMLVideoElement && this.imageBg.videoWidth > 0 && this.imageBg.videoHeight > 0) {
                  return this.imageBg.videoWidth / this.imageBg.videoHeight;
                }
                if (this.imageBg && this.imageBg.width > 0 && this.imageBg.height > 0) {
                  return this.imageBg.width / this.imageBg.height;
                }
                return this.width / Math.max(this.height, 1);
              },

              updateTextures: function () {
                var gl = this.gl;
                activeTexture(gl, 0);
                gl.bindTexture(gl.TEXTURE_2D, this.textures[0]);
                updateTexture(gl, this.canvasLiquid);

                activeTexture(gl, 2);
                gl.bindTexture(gl.TEXTURE_2D, this.textures[2]);
                updateTexture(gl, this.imageFg);

                activeTexture(gl, 3);
                gl.bindTexture(gl.TEXTURE_2D, this.textures[3]);
                updateTexture(gl, this.imageBg);
              },

              draw: function () {
                if (!this.gl) { return; }
                var gl = this.gl;
                gl.useProgram(this.programWater);
                gl.bindBuffer(gl.ARRAY_BUFFER, this.positionBuffer);
                gl.enableVertexAttribArray(this.positionLocation);
                gl.vertexAttribPointer(this.positionLocation, 2, gl.FLOAT, false, 0, 0);
                this.updateTextures();
                gl.uniform2f(this.uniforms.resolution, this.width, this.height);
                gl.uniform2f(this.uniforms.parallax, this.parallaxX, this.parallaxY);
                gl.uniform1f(this.uniforms.textureRatio, this.textureRatio());
                gl.drawArrays(gl.TRIANGLES, 0, 6);
              }
            };

            function backingScale() {
              return Math.min(Math.max(window.devicePixelRatio || 1, 1), 2);
            }

            function rebuildScene() {
              if (!dropAlpha || !dropColor || !dropShine) { return; }
              currentDPR = backingScale();
              var width = Math.max(2, Math.floor(window.innerWidth * currentDPR));
              var height = Math.max(2, Math.floor(window.innerHeight * currentDPR));
              canvas.width = width;
              canvas.height = height;
              canvas.style.width = window.innerWidth + 'px';
              canvas.style.height = window.innerHeight + 'px';

              raindrops = new Raindrops(width, height, currentDPR, dropAlpha, dropColor, {
                minR: 14,
                maxR: 50,
                rainChance: 0.38,
                rainLimit: 8,
                dropletsRate: 64,
                dropletsSize: [2.2, 6.2],
                trailRate: 1.45,
                trailScaleRange: [0.20, 0.42],
                collisionRadius: 0.45,
                collisionRadiusIncrease: 0.0025,
                dropletsCleaningRadiusMultiplier: 0.30,
                dropFallMultiplier: 0.48,
                collisionBoost: 0.6,
                collisionBoostMultiplier: 0.045
              });

              renderer = new RainRenderer(canvas, raindrops.canvas, video, video, dropShine, {
                renderShadow: true,
                brightness: 1.08,
                alphaMultiply: 7,
                alphaSubtract: 3,
                minRefraction: 145,
                maxRefraction: 520,
                parallaxBg: 5,
                parallaxFg: 40
              });
            }

            function resizeIfNeeded() {
              if (!animationStarted) { return; }
              var scale = backingScale();
              var width = Math.max(2, Math.floor(window.innerWidth * scale));
              var height = Math.max(2, Math.floor(window.innerHeight * scale));
              if (!renderer || canvas.width !== width || canvas.height !== height || currentDPR !== scale) {
                rebuildScene();
              }
            }

            function nudgePlayback() {
              var promise = video.play();
              if (promise && typeof promise.catch === 'function') {
                promise.catch(function () {});
              }
            }

            function frame(now) {
              resizeIfNeeded();
              var dt = Math.min(50, Math.max(1, now - lastFrameTime));
              lastFrameTime = now;
              if (raindrops && renderer) {
                raindrops.step(dt);
                renderer.draw();
              }
              requestAnimationFrame(frame);
            }

            function startAnimation() {
              if (animationStarted) { return; }
              animationStarted = true;
              rebuildScene();
              lastFrameTime = performance.now();
              requestAnimationFrame(frame);
            }

            Promise.all([
              loadImage(dropAlphaDataURL),
              loadImage(dropColorDataURL),
              loadImage(dropShineDataURL)
            ]).then(function (images) {
              dropAlpha = images[0];
              dropColor = images[1];
              dropShine = images[2];
              startAnimation();
              nudgePlayback();
            }).catch(function (error) {
              console.error(error);
            });

            window.addEventListener('resize', resizeIfNeeded);
            document.addEventListener('visibilitychange', nudgePlayback);
            video.addEventListener('canplay', nudgePlayback);
            video.addEventListener('loadedmetadata', nudgePlayback);
            canvas.addEventListener('webglcontextlost', function (event) {
              event.preventDefault();
            });
            canvas.addEventListener('webglcontextrestored', function () {
              rebuildScene();
            });
            nudgePlayback();
          })();
        """#

    private static func jsStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data
            .flatMap { String(data: $0, encoding: .utf8) }?
            .replacingOccurrences(of: "\\/", with: "/") ?? "\"\""
    }
}
