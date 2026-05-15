#!/usr/bin/env python3
"""
Generates the three noise textures the Wallpaper Engine water-effect
shaders read by relative path. These are FUNCTIONAL noise patterns (the
water shaders care about local gradient + tileability, not exact pixel
values), so we author our own seeded multi-octave Perlin variants and
ship the resulting PNGs at `LiveWallpaper/Resources/wpe-builtins.bundle/` —
clean-room, no WPE bytes in the repo.

Run once after pulling the repo, OR whenever the noise parameters change.
Re-running is idempotent because the seed is fixed.

Output paths (relative to repo root):
  LiveWallpaper/Resources/wpe-builtins.bundle/materials/effects/waterripplenormal.png  (256×256)
  LiveWallpaper/Resources/wpe-builtins.bundle/materials/effects/refractnormal.png      (256×256)
  LiveWallpaper/Resources/wpe-builtins.bundle/materials/effects/waterflowphase.png     (32×32)

Dependencies: stdlib only (no PIL/numpy). The PNG encoder is hand-rolled
so anyone can run this without `pip install`.
"""
from __future__ import annotations
import math
import os
import struct
import zlib
from pathlib import Path


# --- Seeded gradient-noise primitive (Perlin-style) ---

class GradientNoise:
    def __init__(self, seed: int):
        rng = _LCG(seed)
        # 256-entry permutation table (Ken Perlin's recipe).
        perm = list(range(256))
        for i in range(255, 0, -1):
            j = rng.randint(0, i)
            perm[i], perm[j] = perm[j], perm[i]
        self._perm = perm + perm  # duplicated so we can index without mod

    def at(self, x: float, y: float) -> float:
        """Returns a value in approximately [-1, 1]."""
        xi, yi = int(math.floor(x)) & 255, int(math.floor(y)) & 255
        xf, yf = x - math.floor(x), y - math.floor(y)
        u, v = _fade(xf), _fade(yf)
        a = self._perm[xi] + yi
        b = self._perm[xi + 1] + yi
        return _lerp(
            _lerp(_grad(self._perm[a], xf, yf), _grad(self._perm[b], xf - 1, yf), u),
            _lerp(_grad(self._perm[a + 1], xf, yf - 1), _grad(self._perm[b + 1], xf - 1, yf - 1), u),
            v,
        )


class _LCG:
    def __init__(self, seed: int):
        self._state = seed & 0xFFFFFFFF

    def randint(self, lo: int, hi: int) -> int:
        # Park-Miller minimal standard.
        self._state = (self._state * 48271) % 0x7FFFFFFF
        span = hi - lo + 1
        return lo + (self._state % span)


def _fade(t: float) -> float:
    return t * t * t * (t * (t * 6 - 15) + 10)


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _grad(hash_: int, x: float, y: float) -> float:
    # 8 directions chosen so gradients are tileable.
    angle = (hash_ & 7) * (math.pi / 4)
    return x * math.cos(angle) + y * math.sin(angle)


def tileable_octave_noise(noise: GradientNoise, width: int, height: int,
                          frequency: float, octaves: int, persistence: float) -> list[list[float]]:
    """Sums octaves; warps coordinates so the result is tileable at (width, height)."""
    out = [[0.0] * width for _ in range(height)]
    amplitude_sum = 0.0
    for octave in range(octaves):
        freq = frequency * (2 ** octave)
        amplitude = persistence ** octave
        amplitude_sum += amplitude
        for y in range(height):
            for x in range(width):
                # Wrap UV into [0, freq) and sample. Adding (octave * 137.7)
                # offsets per-octave so they don't reinforce at the same
                # phase.
                u = (x / width) * freq
                v = (y / height) * freq
                # Tileability: sample on a 2D torus → cos/sin lookup at
                # (u, v) gives a 4D coordinate that loops every `freq`.
                tx = math.cos(2 * math.pi * u / freq) * freq / (2 * math.pi)
                ty = math.sin(2 * math.pi * u / freq) * freq / (2 * math.pi)
                tz = math.cos(2 * math.pi * v / freq) * freq / (2 * math.pi)
                tw = math.sin(2 * math.pi * v / freq) * freq / (2 * math.pi)
                # Combine two perpendicular noise samples for 4D coverage.
                value = noise.at(tx + octave * 137.7, ty) * 0.5 \
                      + noise.at(tz, tw + octave * 91.3) * 0.5
                out[y][x] += value * amplitude
    # Normalize so the result lives in [-1, 1].
    return [[cell / amplitude_sum for cell in row] for row in out]


# --- Normal-map encoding ---

def heightfield_to_normal(field: list[list[float]], strength: float) -> list[list[tuple[int, int, int]]]:
    """Central-difference Sobel on the heightfield → tangent-space normal."""
    height = len(field)
    width = len(field[0])
    out = [[(0, 0, 0)] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            # Tileable wrap: %.
            l = field[y][(x - 1) % width]
            r = field[y][(x + 1) % width]
            u = field[(y - 1) % height][x]
            d = field[(y + 1) % height][x]
            dx = (r - l) * strength
            dy = (d - u) * strength
            # Normal = normalize(-dx, -dy, 1).
            nx, ny, nz = -dx, -dy, 1.0
            length = math.sqrt(nx * nx + ny * ny + nz * nz)
            nx, ny, nz = nx / length, ny / length, nz / length
            # Pack to [0, 255] (standard tangent-space normal map convention).
            r_byte = int(round((nx * 0.5 + 0.5) * 255))
            g_byte = int(round((ny * 0.5 + 0.5) * 255))
            b_byte = int(round((nz * 0.5 + 0.5) * 255))
            out[y][x] = (r_byte, g_byte, b_byte)
    return out


# --- Minimal PNG writer (RGB, no alpha) ---

def write_png_rgb(path: Path, pixels: list[list[tuple[int, int, int]]]) -> None:
    height = len(pixels)
    width = len(pixels[0])
    # IHDR
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit, color type 2 = RGB
    # IDAT: filter byte 0 (None) + RGB bytes per row.
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b in row:
            raw.append(r & 0xFF)
            raw.append(g & 0xFF)
            raw.append(b & 0xFF)
    idat_data = zlib.compress(bytes(raw), 9)

    def chunk(kind: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr_data))
        f.write(chunk(b"IDAT", idat_data))
        f.write(chunk(b"IEND", b""))


def write_png_grayscale(path: Path, pixels: list[list[int]]) -> None:
    height = len(pixels)
    width = len(pixels[0])
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)  # 8-bit grayscale
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for value in row:
            raw.append(value & 0xFF)
    idat_data = zlib.compress(bytes(raw), 9)

    def chunk(kind: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr_data))
        f.write(chunk(b"IDAT", idat_data))
        f.write(chunk(b"IEND", b""))


# --- Per-texture authoring ---

def make_water_ripple_normal(out_path: Path) -> None:
    """High-frequency tileable normal map for WPE waterripple effect."""
    noise = GradientNoise(seed=0x7A7E)
    field = tileable_octave_noise(noise, 256, 256, frequency=8.0, octaves=4, persistence=0.5)
    normals = heightfield_to_normal(field, strength=1.5)
    write_png_rgb(out_path, normals)


def make_refract_normal(out_path: Path) -> None:
    """Lower-frequency tileable normal map for WPE refraction effect."""
    noise = GradientNoise(seed=0xCAFE)
    field = tileable_octave_noise(noise, 256, 256, frequency=4.0, octaves=5, persistence=0.55)
    normals = heightfield_to_normal(field, strength=1.0)
    write_png_rgb(out_path, normals)


def make_waterflow_phase(out_path: Path) -> None:
    """Small grayscale phase texture for WPE waterflow effect."""
    noise = GradientNoise(seed=0xBEEF)
    field = tileable_octave_noise(noise, 32, 32, frequency=2.0, octaves=2, persistence=0.6)
    pixels = [[int(round((cell * 0.5 + 0.5) * 255)) for cell in row] for row in field]
    write_png_grayscale(out_path, pixels)


def main():
    here = Path(__file__).resolve().parent
    out_dir = here.parent / "LiveWallpaper" / "Resources" / "wpe-builtins.bundle" / "materials" / "effects"
    out_dir.mkdir(parents=True, exist_ok=True)

    make_water_ripple_normal(out_dir / "waterripplenormal.png")
    make_refract_normal(out_dir / "refractnormal.png")
    make_waterflow_phase(out_dir / "waterflowphase.png")
    print("Generated:")
    for name in ("waterripplenormal.png", "refractnormal.png", "waterflowphase.png"):
        p = out_dir / name
        print(f"  {p}  ({p.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
