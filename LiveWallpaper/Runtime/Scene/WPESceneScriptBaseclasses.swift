#if !LITE_BUILD
import JavaScriptCore

enum WPESceneScriptBaseclasses {
    static func install(in context: JSContext) {
        _ = context.evaluateScript(Self.prelude)
    }

    private static let prelude = #"""
(function () {
    var root = (typeof globalThis !== "undefined") ? globalThis : this;
    var EPSILON = 1e-8;
    var hasSymbol = typeof Symbol !== "undefined";

    function number(value, fallback) {
        var n = Number(value);
        return isFinite(n) ? n : (fallback || 0);
    }

    function isArrayLike(value) {
        return value && typeof value !== "function" && typeof value.length === "number";
    }

    function component(value, key, index, fallback) {
        if (value == null) { return number(fallback, 0); }
        if (isArrayLike(value)) { return number(value[index], fallback); }
        if (typeof value === "object") {
            if (typeof value[key] !== "undefined") { return number(value[key], fallback); }
            if (typeof value[index] !== "undefined") { return number(value[index], fallback); }
        }
        return number(value, fallback);
    }

    function finiteOr(value, fallback) {
        var n = Number(value);
        return isFinite(n) ? n : fallback;
    }

    function hypot2(x, y) {
        return Math.sqrt(x * x + y * y);
    }

    function hypot3(x, y, z) {
        return Math.sqrt(x * x + y * y + z * z);
    }

    function defineGlobal(name, value) {
        try {
            if (typeof root[name] !== "undefined") { return; }
            Object.defineProperty(root, name, {
                configurable: true,
                writable: true,
                value: value
            });
        } catch (e) {
            try { root[name] = value; } catch (ignored) {}
        }
    }

    function installMethod(target, name, value) {
        if (target == null) { return; }
        try {
            if (typeof target[name] === "undefined") { target[name] = value; }
        } catch (e) {}
    }

    class Vec2 {
        constructor(x, y) {
            if (arguments.length === 0) { x = 0; y = 0; }
            else if (arguments.length === 1) {
                if (isArrayLike(x) || typeof x === "object") {
                    var fallback = component(x, "x", 0, 0);
                    y = component(x, "y", 1, fallback);
                    x = fallback;
                } else { y = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
        }
        clone() { return new Vec2(this.x, this.y); }
        toArray() { return [this.x, this.y]; }
        add(v) { v = new Vec2(v); return new Vec2(this.x + v.x, this.y + v.y); }
        sub(v) { v = new Vec2(v); return new Vec2(this.x - v.x, this.y - v.y); }
        mul(v) { v = new Vec2(v); return new Vec2(this.x * v.x, this.y * v.y); }
        scale(s) { s = number(s, 0); return new Vec2(this.x * s, this.y * s); }
        dot(v) { v = new Vec2(v); return this.x * v.x + this.y * v.y; }
        length() { return hypot2(this.x, this.y); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec2(0); }
        lerp(v, t) { v = new Vec2(v); t = number(t, 0); return this.scale(1 - t).add(v.scale(t)); }
        static add(a, b) { return new Vec2(a).add(b); }
        static sub(a, b) { return new Vec2(a).sub(b); }
        static mul(a, b) { return new Vec2(a).mul(b); }
        static scale(v, s) { return new Vec2(v).scale(s); }
        static dot(a, b) { return new Vec2(a).dot(b); }
        static lerp(a, b, t) { return new Vec2(a).lerp(b, t); }
    }

    class Vec3 {
        constructor(x, y, z) {
            if (arguments.length === 0) { x = 0; y = 0; z = 0; }
            else if (arguments.length === 1) {
                if (isArrayLike(x) || typeof x === "object") {
                    var fallback = component(x, "x", 0, 0);
                    y = component(x, "y", 1, fallback);
                    z = component(x, "z", 2, fallback);
                    x = fallback;
                } else { y = x; z = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
            this.z = number(z, 0);
        }
        clone() { return new Vec3(this.x, this.y, this.z); }
        toArray() { return [this.x, this.y, this.z]; }
        add(v) { v = new Vec3(v); return new Vec3(this.x + v.x, this.y + v.y, this.z + v.z); }
        sub(v) { v = new Vec3(v); return new Vec3(this.x - v.x, this.y - v.y, this.z - v.z); }
        mul(v) { v = new Vec3(v); return new Vec3(this.x * v.x, this.y * v.y, this.z * v.z); }
        scale(s) { s = number(s, 0); return new Vec3(this.x * s, this.y * s, this.z * s); }
        dot(v) { v = new Vec3(v); return this.x * v.x + this.y * v.y + this.z * v.z; }
        cross(v) {
            v = new Vec3(v);
            return new Vec3(
                this.y * v.z - this.z * v.y,
                this.z * v.x - this.x * v.z,
                this.x * v.y - this.y * v.x
            );
        }
        length() { return hypot3(this.x, this.y, this.z); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec3(0); }
        lerp(v, t) { v = new Vec3(v); t = number(t, 0); return this.scale(1 - t).add(v.scale(t)); }
        toSpherical() { return toSpherical(this); }
        refract(normal, eta) { return refract(this, normal, eta); }
        static add(a, b) { return new Vec3(a).add(b); }
        static sub(a, b) { return new Vec3(a).sub(b); }
        static mul(a, b) { return new Vec3(a).mul(b); }
        static scale(v, s) { return new Vec3(v).scale(s); }
        static dot(a, b) { return new Vec3(a).dot(b); }
        static cross(a, b) { return new Vec3(a).cross(b); }
        static lerp(a, b, t) { return new Vec3(a).lerp(b, t); }
    }

    class Vec4 {
        constructor(x, y, z, w) {
            if (arguments.length === 0) { x = 0; y = 0; z = 0; w = 0; }
            else if (arguments.length === 1) {
                if (isArrayLike(x) || typeof x === "object") {
                    var fallback = component(x, "x", 0, 0);
                    y = component(x, "y", 1, fallback);
                    z = component(x, "z", 2, fallback);
                    w = component(x, "w", 3, fallback);
                    x = fallback;
                } else { y = x; z = x; w = x; }
            }
            this.x = number(x, 0);
            this.y = number(y, 0);
            this.z = number(z, 0);
            this.w = number(w, 0);
        }
        clone() { return new Vec4(this.x, this.y, this.z, this.w); }
        toArray() { return [this.x, this.y, this.z, this.w]; }
        add(v) { v = new Vec4(v); return new Vec4(this.x + v.x, this.y + v.y, this.z + v.z, this.w + v.w); }
        sub(v) { v = new Vec4(v); return new Vec4(this.x - v.x, this.y - v.y, this.z - v.z, this.w - v.w); }
        mul(v) { v = new Vec4(v); return new Vec4(this.x * v.x, this.y * v.y, this.z * v.z, this.w * v.w); }
        scale(s) { s = number(s, 0); return new Vec4(this.x * s, this.y * s, this.z * s, this.w * s); }
        dot(v) { v = new Vec4(v); return this.x * v.x + this.y * v.y + this.z * v.z + this.w * v.w; }
        length() { return Math.sqrt(this.dot(this)); }
        normalize() { var l = this.length(); return l > EPSILON ? this.scale(1 / l) : new Vec4(0); }
        lerp(v, t) { v = new Vec4(v); t = number(t, 0); return this.scale(1 - t).add(v.scale(t)); }
        static add(a, b) { return new Vec4(a).add(b); }
        static sub(a, b) { return new Vec4(a).sub(b); }
        static mul(a, b) { return new Vec4(a).mul(b); }
        static scale(v, s) { return new Vec4(v).scale(s); }
        static dot(a, b) { return new Vec4(a).dot(b); }
        static lerp(a, b, t) { return new Vec4(a).lerp(b, t); }
    }

    function readMatrix(values, size, identity) {
        if (values && values.m) { values = values.m; }
        var count = size * size;
        var out = identity.slice();
        if (isArrayLike(values) && values.length >= count) {
            for (var i = 0; i < count; i += 1) { out[i] = number(values[i], identity[i]); }
        }
        return out;
    }

    class Mat3 {
        constructor(values) { this.m = readMatrix(values, 3, Mat3.identityArray()); }
        clone() { return new Mat3(this.m); }
        toArray() { return this.m.slice(); }
        multiply(other) {
            var a = this.m, b = new Mat3(other).m, out = new Array(9);
            for (var c = 0; c < 3; c += 1) {
                for (var r = 0; r < 3; r += 1) {
                    out[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
                }
            }
            return new Mat3(out);
        }
        transpose() {
            var m = this.m;
            return new Mat3([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);
        }
        inverse() {
            var m = this.m;
            var b01 = m[8] * m[4] - m[5] * m[7];
            var b11 = -m[8] * m[3] + m[5] * m[6];
            var b21 = m[7] * m[3] - m[4] * m[6];
            var det = m[0] * b01 + m[1] * b11 + m[2] * b21;
            if (Math.abs(det) <= EPSILON) { return Mat3.identity(); }
            det = 1 / det;
            return new Mat3([
                b01 * det,
                (-m[8] * m[1] + m[2] * m[7]) * det,
                (m[5] * m[1] - m[2] * m[4]) * det,
                b11 * det,
                (m[8] * m[0] - m[2] * m[6]) * det,
                (-m[5] * m[0] + m[2] * m[3]) * det,
                b21 * det,
                (-m[7] * m[0] + m[1] * m[6]) * det,
                (m[4] * m[0] - m[1] * m[3]) * det
            ]);
        }
        static identityArray() { return [1, 0, 0, 0, 1, 0, 0, 0, 1]; }
        static identity() { return new Mat3(); }
        static multiply(a, b) { return new Mat3(a).multiply(b); }
        static transpose(m) { return new Mat3(m).transpose(); }
        static inverse(m) { return new Mat3(m).inverse(); }
        static fromMat4(mat) {
            var m = new Mat4(mat).m;
            return new Mat3([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]);
        }
    }

    class Mat4 {
        constructor(values) { this.m = readMatrix(values, 4, Mat4.identityArray()); }
        clone() { return new Mat4(this.m); }
        toArray() { return this.m.slice(); }
        multiply(other) {
            var a = this.m, b = new Mat4(other).m, out = new Array(16);
            for (var c = 0; c < 4; c += 1) {
                for (var r = 0; r < 4; r += 1) {
                    out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
                }
            }
            return new Mat4(out);
        }
        transpose() {
            var m = this.m;
            return new Mat4([
                m[0], m[4], m[8], m[12],
                m[1], m[5], m[9], m[13],
                m[2], m[6], m[10], m[14],
                m[3], m[7], m[11], m[15]
            ]);
        }
        inverse() {
            var a = this.m;
            var b00 = a[0] * a[5] - a[1] * a[4];
            var b01 = a[0] * a[6] - a[2] * a[4];
            var b02 = a[0] * a[7] - a[3] * a[4];
            var b03 = a[1] * a[6] - a[2] * a[5];
            var b04 = a[1] * a[7] - a[3] * a[5];
            var b05 = a[2] * a[7] - a[3] * a[6];
            var b06 = a[8] * a[13] - a[9] * a[12];
            var b07 = a[8] * a[14] - a[10] * a[12];
            var b08 = a[8] * a[15] - a[11] * a[12];
            var b09 = a[9] * a[14] - a[10] * a[13];
            var b10 = a[9] * a[15] - a[11] * a[13];
            var b11 = a[10] * a[15] - a[11] * a[14];
            var det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
            if (Math.abs(det) <= EPSILON) { return Mat4.identity(); }
            det = 1 / det;
            return new Mat4([
                (a[5] * b11 - a[6] * b10 + a[7] * b09) * det,
                (a[2] * b10 - a[1] * b11 - a[3] * b09) * det,
                (a[13] * b05 - a[14] * b04 + a[15] * b03) * det,
                (a[10] * b04 - a[9] * b05 - a[11] * b03) * det,
                (a[6] * b08 - a[4] * b11 - a[7] * b07) * det,
                (a[0] * b11 - a[2] * b08 + a[3] * b07) * det,
                (a[14] * b02 - a[12] * b05 - a[15] * b01) * det,
                (a[8] * b05 - a[10] * b02 + a[11] * b01) * det,
                (a[4] * b10 - a[5] * b08 + a[7] * b06) * det,
                (a[1] * b08 - a[0] * b10 - a[3] * b06) * det,
                (a[12] * b04 - a[13] * b02 + a[15] * b00) * det,
                (a[9] * b02 - a[8] * b04 - a[11] * b00) * det,
                (a[5] * b07 - a[4] * b09 - a[6] * b06) * det,
                (a[0] * b09 - a[1] * b07 + a[2] * b06) * det,
                (a[13] * b01 - a[12] * b03 - a[14] * b00) * det,
                (a[8] * b03 - a[9] * b01 + a[10] * b00) * det
            ]);
        }
        normalMatrix() {
            var m = this.inverse().m;
            return new Mat3([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]).transpose();
        }
        decompose() {
            var m = this.m;
            var sx = hypot3(m[0], m[1], m[2]) || 1;
            var sy = hypot3(m[4], m[5], m[6]) || 1;
            var sz = hypot3(m[8], m[9], m[10]) || 1;
            var r00 = m[0] / sx, r11 = m[5] / sy, r12 = m[9] / sz;
            var r10 = m[1] / sx, r20 = m[2] / sx, r21 = m[6] / sy, r22 = m[10] / sz;
            var ry = Math.asin(clamp(-r20, -1, 1));
            var cy = Math.cos(ry);
            var rx, rz;
            if (Math.abs(cy) > EPSILON) {
                rx = Math.atan2(r21, r22);
                rz = Math.atan2(r10, r00);
            } else {
                rx = Math.atan2(-r12, r11);
                rz = 0;
            }
            return {
                translation: new Vec3(m[12], m[13], m[14]),
                rotation: new Vec3(rx, ry, rz),
                scale: new Vec3(sx, sy, sz)
            };
        }
        static identityArray() { return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; }
        static identity() { return new Mat4(); }
        static multiply(a, b) { return new Mat4(a).multiply(b); }
        static transpose(m) { return new Mat4(m).transpose(); }
        static inverse(m) { return new Mat4(m).inverse(); }
        static normalMatrix(m) { return new Mat4(m).normalMatrix(); }
        static decompose(m) { return new Mat4(m).decompose(); }
        static fromTranslation(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return new Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, v.x, v.y, v.z, 1]);
        }
        static fromScale(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return new Mat4([v.x, 0, 0, 0, 0, v.y, 0, 0, 0, 0, v.z, 0, 0, 0, 0, 1]);
        }
        static fromScaling(x, y, z) { return Mat4.fromScale.apply(Mat4, arguments); }
        static fromRotationX(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]);
        }
        static fromRotationY(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]);
        }
        static fromRotationZ(r) {
            r = number(r, 0);
            var s = Math.sin(r), c = Math.cos(r);
            return new Mat4([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
        }
        static fromRotationXYZ(x, y, z) {
            var v = arguments.length === 1 ? new Vec3(x) : new Vec3(x, y, z);
            return Mat4.fromRotationZ(v.z).multiply(Mat4.fromRotationY(v.y)).multiply(Mat4.fromRotationX(v.x));
        }
        static perspective(fovy, aspect, near, far) {
            fovy = number(fovy, 0); aspect = number(aspect, 1); near = number(near, 0.1); far = number(far, 1000);
            if (Math.abs(aspect) <= EPSILON || Math.abs(near - far) <= EPSILON) { return Mat4.identity(); }
            var f = 1 / Math.tan(fovy / 2);
            if (!isFinite(f)) { return Mat4.identity(); }
            var nf = 1 / (near - far);
            return new Mat4([f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, (2 * far * near) * nf, 0]);
        }
        static ortho(left, right, bottom, top, near, far) {
            left = number(left, -1); right = number(right, 1); bottom = number(bottom, -1); top = number(top, 1);
            near = number(near, -1); far = number(far, 1);
            if (Math.abs(left - right) <= EPSILON || Math.abs(bottom - top) <= EPSILON || Math.abs(near - far) <= EPSILON) { return Mat4.identity(); }
            var lr = 1 / (left - right), bt = 1 / (bottom - top), nf = 1 / (near - far);
            return new Mat4([-2 * lr, 0, 0, 0, 0, -2 * bt, 0, 0, 0, 0, 2 * nf, 0, (left + right) * lr, (top + bottom) * bt, (far + near) * nf, 1]);
        }
        static lookAt(eye, center, up) {
            eye = new Vec3(eye);
            center = new Vec3(center);
            up = new Vec3(up == null ? [0, 1, 0] : up);
            var z = eye.sub(center).normalize();
            if (z.length() <= EPSILON) { z = new Vec3(0, 0, 1); }
            var x = up.cross(z).normalize();
            if (x.length() <= EPSILON) { x = new Vec3(1, 0, 0); }
            var y = z.cross(x).normalize();
            return new Mat4([
                x.x, y.x, z.x, 0,
                x.y, y.y, z.y, 0,
                x.z, y.z, z.z, 0,
                -x.dot(eye), -y.dot(eye), -z.dot(eye), 1
            ]);
        }
    }

    function mapValue(value, mapper) {
        if (value instanceof Vec2) { return new Vec2(mapper(value.x), mapper(value.y)); }
        if (value instanceof Vec3) { return new Vec3(mapper(value.x), mapper(value.y), mapper(value.z)); }
        if (value instanceof Vec4) { return new Vec4(mapper(value.x), mapper(value.y), mapper(value.z), mapper(value.w)); }
        if (isArrayLike(value)) {
            var out = [];
            for (var i = 0; i < value.length; i += 1) { out.push(mapper(value[i])); }
            return out;
        }
        return mapper(value);
    }

    function clamp(x, minValue, maxValue) {
        minValue = finiteOr(minValue, 0);
        maxValue = finiteOr(maxValue, 1);
        if (minValue > maxValue) { var t = minValue; minValue = maxValue; maxValue = t; }
        return mapValue(x, function (v) { return Math.min(Math.max(number(v, 0), minValue), maxValue); });
    }

    function mix(a, b, t) {
        t = number(t, 0);
        if (a instanceof Vec2) { return new Vec2(a).lerp(b, t); }
        if (a instanceof Vec3) { return new Vec3(a).lerp(b, t); }
        if (a instanceof Vec4) { return new Vec4(a).lerp(b, t); }
        if (isArrayLike(a)) {
            var out = [];
            for (var i = 0; i < a.length; i += 1) { out.push(number(a[i], 0) * (1 - t) + number(b && b[i], 0) * t); }
            return out;
        }
        return number(a, 0) * (1 - t) + number(b, 0) * t;
    }

    function saturate(x) { return clamp(x, 0, 1); }
    function radians(x) { return mapValue(x, function (v) { return number(v, 0) * Math.PI / 180; }); }
    function degrees(x) { return mapValue(x, function (v) { return number(v, 0) * 180 / Math.PI; }); }
    function toSpherical(v) {
        v = new Vec3(v);
        var radius = v.length();
        if (radius <= EPSILON) { return new Vec3(0); }
        return new Vec3(radius, Math.atan2(v.z, v.x), Math.acos(clamp(v.y / radius, -1, 1)));
    }
    function refract(incident, normal, eta) {
        var i = new Vec3(incident).normalize();
        var n = new Vec3(normal).normalize();
        eta = number(eta, 1);
        var d = i.dot(n);
        var k = 1 - eta * eta * (1 - d * d);
        if (k < 0) { return new Vec3(0); }
        return i.scale(eta).sub(n.scale(eta * d + Math.sqrt(k)));
    }

    function safeGet(object, property, fallback) {
        if (hasSymbol && property === Symbol.toPrimitive) { return function (hint) { return hint === "string" ? "" : 0; }; }
        if (hasSymbol && property === Symbol.iterator) { return function () { return { next: function () { return { done: true }; } }; }; }
        if (property === "then") { return undefined; }
        if (property === "toString") { return function () { return ""; }; }
        if (property === "valueOf") { return function () { return 0; }; }
        if (property === "toJSON") { return function () { return null; }; }
        if (property === "length") { return 0; }
        if (property === "x" || property === "y" || property === "z" || property === "w" || property === "width" || property === "height" || property === "alpha" || property === "opacity") { return 0; }
        if (property === "visible" || property === "enabled") { return true; }
        try {
            if (property in object) { return object[property]; }
        } catch (e) {}
        return fallback;
    }

    function createSafeCallable(label) {
        var proxy;
        var target = function () { return proxy || target; };
        target.toString = function () { return ""; };
        target.valueOf = function () { return 0; };
        target.toJSON = function () { return null; };
        if (typeof Proxy === "undefined") { return target; }
        proxy = new Proxy(target, {
            get: function (object, property) { return safeGet(object, property, proxy); },
            set: function () { return true; },
            apply: function () { return proxy; },
            construct: function () { return proxy; },
            has: function () { return true; },
            getOwnPropertyDescriptor: function (object, property) {
                var descriptor = Object.getOwnPropertyDescriptor(object, property);
                return descriptor || { configurable: true, enumerable: false, writable: true, value: proxy };
            }
        });
        return proxy;
    }

    function createSafeObject(label) {
        var nested = createSafeCallable(label + ".noop");
        var target = {};
        if (typeof Proxy === "undefined") { return nested; }
        return new Proxy(target, {
            get: function (object, property) { return safeGet(object, property, nested); },
            set: function () { return true; },
            has: function () { return true; },
            getOwnPropertyDescriptor: function (object, property) {
                var descriptor = Object.getOwnPropertyDescriptor(object, property);
                return descriptor || { configurable: true, enumerable: false, writable: true, value: nested };
            }
        });
    }

    var safeScene = createSafeObject("scene");
    var timerStub = function () { return 0; };
    var modelAccessor = createSafeCallable("modelAccessor");

    defineGlobal("Vec2", Vec2);
    defineGlobal("Vec3", Vec3);
    defineGlobal("Vec4", Vec4);
    defineGlobal("Mat3", Mat3);
    defineGlobal("Mat4", Mat4);
    defineGlobal("clamp", clamp);
    defineGlobal("mix", mix);
    defineGlobal("saturate", saturate);
    defineGlobal("radians", radians);
    defineGlobal("degrees", degrees);
    defineGlobal("toSpherical", toSpherical);
    defineGlobal("refract", refract);
    defineGlobal("setTimeout", timerStub);
    defineGlobal("setInterval", timerStub);
    defineGlobal("clearTimeout", timerStub);
    defineGlobal("clearInterval", timerStub);
    defineGlobal("scene", safeScene);
    defineGlobal("thisScene", safeScene);
    defineGlobal("thisLayer", createSafeObject("thisLayer"));
    defineGlobal("thisProperty", createSafeObject("thisProperty"));
    defineGlobal("IModelData", createSafeCallable("IModelData"));
    defineGlobal("getModel", modelAccessor);
    defineGlobal("getModelData", modelAccessor);
    defineGlobal("getLayer", createSafeCallable("getLayer"));
    defineGlobal("getScene", createSafeCallable("getScene"));

    installMethod(root.engine, "getModel", modelAccessor);
    installMethod(root.engine, "getModelData", modelAccessor);
    installMethod(root.engine, "getLayer", createSafeCallable("engine.getLayer"));
    installMethod(root.engine, "getScene", createSafeCallable("engine.getScene"));
}());
"""#
}
#endif
