#!/usr/bin/env python3
"""Offline replay of WPEParticleSystem's spawn+tick velocity model, used to
test candidate fixes for the leaf "fall speed / direction" divergence against
the Windows WPE oracle WITHOUT a device rebuild.

Ground truth (saber 3526278753, decoded from WPE's particle vertex buffer,
TEXCOORD1 = velocity): vx ~= -136, vy ~= -169, |vy/vx| ~= 1.83.

Preset (scene.pkg particles/presets/leaves2.json, post 1.59 speed override):
  velocityrandom min=(-159,-159,0) max=(-79.5,-23.85,0)  -> base |vy/vx| 0.77
  turbulentvelocityrandom speed=[55.65,159] scale=0.5  (NO mask = isotropic)
  movement operator gravity = "0 0 0"   (author EXPLICITLY zeroed gravity)

Findings (run this file):
  H0 current (no-flip, isotropic turb)  -> |vy/vx| 0.84   (Y too small)
  H_flip (Y-flip velocity)              -> vy POSITIVE     (leaves rise: FALSIFIED)
  H_grav g~=30                          -> |vy/vx| 1.82    (matches oracle)
  H_turbAccum                           -> 0.83            (zero-mean: no effect)

So the gap is a Y-only additive term ~ g 30 px/s^2 / Y x1.85, sourced from
WPE's turbulence (gravity is 0), NOT a Y-axis flip. Any real fix must drive
this model's instantaneous |vy/vx| to ~1.83 while keeping vy NEGATIVE.
"""
import math
import random
import statistics as st

VEL_MIN = (-159.0, -159.0, 0.0)
VEL_MAX = (-79.5, -23.85, 0.0)
TURB_SPEED = (55.65, 159.0)
TURB_SCALE = 0.5
MASK = (1.0, 1.0, 1.0)
LIFE = (6.0, 7.5)
ORIGIN = (0.0, 750.0)
DISP = (0.0, 750.0)
DIR_MASK = (1.0, 0.1, 1.0)
RATE = 3.8
MAXCOUNT = 32
DT = 1.0 / 60.0

# Oracle target (decoded WPE particle vertex buffer)
WPE_VX, WPE_VY, WPE_RATIO = -136.0, -169.0, 1.83


def _noise(x, y, t):
    nx = math.sin(x * 0.10 + t * 0.5) + math.cos(y * 0.13 + t * 0.7)
    ny = math.sin(x * 0.17 + t * 0.3) + math.cos(y * 0.09 + t * 0.4)
    return nx * 0.25, ny * 0.25


def _spawn(rng):
    th = rng.uniform(0, 2 * math.pi)
    ph = rng.uniform(0, math.pi)
    r = rng.uniform(*DISP)
    px = ORIGIN[0] + r * math.sin(ph) * math.cos(th) * DIR_MASK[0]
    py = ORIGIN[1] + r * math.sin(ph) * math.sin(th) * DIR_MASK[1]
    return dict(px=px, py=py,
                vx=rng.uniform(VEL_MIN[0], VEL_MAX[0]),
                vy=rng.uniform(VEL_MIN[1], VEL_MAX[1]),
                ts=rng.uniform(*TURB_SPEED), ph=rng.uniform(0, 2 * math.pi),
                age=0.0, life=rng.uniform(*LIFE))


def run(gravity=0.0, vyscale=1.0, flip=False, turb_accum=False, secs=14.0, seed=42):
    """Returns (mean_vx, mean_vy, mean_|vy/vx|) of instantaneous velocity at
    steady state. `gravity` is a downward accel (px/s^2) added to vy."""
    rng = random.Random(seed)
    parts, acc = [], 0.0
    samples = []
    steps = int(secs / DT)
    for s in range(steps):
        t = s * DT
        for p in parts:
            if p['age'] >= p['life']:
                continue
            p['age'] += DT
            vx = p['vx']
            vy = p['vy'] * vyscale * (-1 if flip else 1)
            nx, ny = _noise(p['px'] * TURB_SCALE, p['py'] * TURB_SCALE,
                            t + 3.0 + p['ph'])
            stepx = vx + nx * p['ts'] * MASK[0]
            stepy = vy + ny * p['ts'] * MASK[1] - gravity * p['age']
            if turb_accum:
                p['vx'] += nx * p['ts'] * MASK[0] * DT
                p['vy'] += ny * p['ts'] * MASK[1] * DT
            p['px'] += stepx * DT
            p['py'] += stepy * DT
            if s > steps - 120:
                samples.append((stepx, stepy))
        acc += DT * RATE
        while acc >= 1:
            acc -= 1
            alive = [p for p in parts if p['age'] < p['life']]
            if len(alive) < MAXCOUNT:
                dead = [p for p in parts if p['age'] >= p['life']]
                if dead:
                    parts.remove(dead[0])
                parts.append(_spawn(rng))
    mvx = st.mean(a for a, _ in samples)
    mvy = st.mean(b for _, b in samples)
    ratio = st.mean(abs(b) / abs(a) for a, b in samples if abs(a) > 1)
    return mvx, mvy, ratio


if __name__ == "__main__":
    print(f"WPE oracle: vx={WPE_VX} vy={WPE_VY} |vy/vx|={WPE_RATIO}\n")
    cases = [
        ("H0 current (no-flip, isotropic turb)", {}),
        ("H_flip (Y-flip velocity)", dict(flip=True)),
        ("H_grav g=30", dict(gravity=30.0)),
        ("H_vyscale x1.85", dict(vyscale=1.85)),
        ("H_turbAccum", dict(turb_accum=True)),
    ]
    for name, kw in cases:
        vx, vy, ratio = run(**kw)
        print(f"{name:40s}: vx={vx:7.1f} vy={vy:7.1f} |vy/vx|={ratio:.2f}")
