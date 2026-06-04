#!/usr/bin/env python3
"""Diff a Windows WPE trace against a Mac Metal trace (both wpe.trace.v1).

Phase B of the divergence pipeline: structure / uniform-by-name / topology /
texture-binding / RT-lineage diffing with DP pass alignment and bucketed
first-divergence pinpointing. No SSIM, no corpus orchestration, no HTML — those
are later phases. Pure stdlib so it runs anywhere the Windows parser does.

    python3 diff_traces.py --windows windows/trace.json --mac mac/trace.json \
        --out diff/divergence-summary.json

The contract emitted is `wpe.diff.v1` (see the plan's §四). Uniform packing
differences (WPE g_bufStatic/g_bufDynamic split vs our flat slot array) are
reconciled by NAME and are NOT reported as divergence.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

EPSILON = 1.0e-4
BUCKETS = ("transpiler", "FBO", "asset", "puppet+particle")
# Uniforms whose values legitimately differ between two captures (wall-clock time,
# frame counters, RNG). Comparing them by value yields a guaranteed false-positive
# that would mask real divergences, so they are skipped until Phase D-1 constant
# replay feeds WPE's decoded values back into our packing. Names are lowercased.
VOLATILE_UNIFORMS = {
    "g_time", "time", "u_time", "utime", "itime", "g_daytime", "daytime",
    "g_framecount", "framecount", "frametime", "g_frame", "random", "g_random",
}
# DP costs.
DELETE_QUAD = 2.0          # deleting a WPE quad pass is expensive (real gap)
DELETE_POINTLIST = 0.35    # deleting a WPE particle pass is cheap (expected gap)
INSERT = 2.0               # inserting an unmatched Mac pass


# --------------------------------------------------------------------------- #
# Normalized model
# --------------------------------------------------------------------------- #
@dataclass
class Uniform:
    name: str
    value: Any
    stage: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class TextureBinding:
    slot: int
    name: Optional[str]
    resource: Optional[str]
    fallback: bool = False
    width: Optional[int] = None
    height: Optional[int] = None
    fmt: Optional[str] = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class NormalizedPass:
    side: str
    ordinal: int
    pass_id: Optional[str]
    shader_name: Optional[str]
    topology: str
    draw: dict[str, Any]
    uniforms: dict[str, Uniform]
    textures: dict[int, TextureBinding]
    shader_sig: dict[str, Any]
    rt_lineage: list[str]
    blend: Any
    output_hash: Optional[str]
    raw: dict[str, Any]

    @property
    def is_pointlist(self) -> bool:
        return self.topology == "pointlist"


# --------------------------------------------------------------------------- #
# IO
# --------------------------------------------------------------------------- #
def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


# --------------------------------------------------------------------------- #
# Normalization
# --------------------------------------------------------------------------- #
def normalize_trace(trace: dict[str, Any], side: str) -> list[NormalizedPass]:
    resources = trace.get("resources", {}) or {}
    shaders = resources.get("shaders", {}) or {}
    textures = resources.get("textures", {}) or {}
    out: list[NormalizedPass] = []
    for raw_pass in trace.get("passes", []) or []:
        if not isinstance(raw_pass, dict):
            continue
        draw = raw_pass.get("draw", {}) or {}
        uniforms = normalize_uniforms(raw_pass)
        texture_bindings = normalize_textures(raw_pass, textures)
        out.append(NormalizedPass(
            side=side,
            ordinal=safe_int(raw_pass.get("ordinal"), len(out)),
            pass_id=raw_pass.get("passId"),
            shader_name=raw_pass.get("shaderName"),
            topology=canonical_topology(draw),
            draw=draw,
            uniforms=uniforms,
            textures=texture_bindings,
            shader_sig=normalize_shader_sig(raw_pass, shaders, uniforms, texture_bindings),
            rt_lineage=normalize_rt_lineage(raw_pass),
            blend=(raw_pass.get("state") or {}).get("blend"),
            output_hash=(raw_pass.get("output") or {}).get("sha256"),
            raw=raw_pass,
        ))
    return out


def safe_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def canonical_topology(draw: dict[str, Any]) -> str:
    """Collapse to a small, comparable vocabulary.

    Both WPE (D3D ``TRIANGLELIST`` 6-index quad / ``TRIANGLESTRIP`` 4-vertex) and
    Mac (``fullscreen-quad`` / ``object-quad``) effect passes are screen quads, so
    they all canonicalize to ``"quad"`` and align. The only non-quad WPE passes in
    the effect corpus are the particle ``POINTLIST`` draws, which stay distinct so
    they fall out of the alignment into the puppet+particle bucket.
    """
    topology = str(draw.get("topology") or "").lower()
    if "pointlist" in topology:
        return "pointlist"
    if "linelist" in topology or "linestrip" in topology:
        return "line"
    if any(token in topology for token in ("quad", "triangle")):
        return "quad"
    if not topology:
        return "unknown"
    return topology


def normalize_uniforms(raw_pass: dict[str, Any]) -> dict[str, Uniform]:
    uniforms: dict[str, Uniform] = {}
    for cbuffer in raw_pass.get("constantBuffers", []) or []:
        stage = cbuffer.get("stage")
        for variable in cbuffer.get("variables", []) or []:
            name = variable.get("name")
            if not name:
                continue
            uniforms[name] = Uniform(
                name=name,
                value=preferred_uniform_value(variable),
                stage=stage,
                raw=variable,
            )
    return uniforms


def preferred_uniform_value(variable: dict[str, Any]) -> Any:
    for key in ("matrix4x4RowMajor", "matrix4x4"):
        if key in variable and variable[key] is not None:
            return variable[key]
    if "value" in variable:
        return variable["value"]
    return variable.get("rawSlotFloats")


def normalize_textures(raw_pass: dict[str, Any], texture_resources: dict[str, Any]) -> dict[int, TextureBinding]:
    out: dict[int, TextureBinding] = {}
    for item in raw_pass.get("textures", []) or []:
        try:
            slot = int(item.get("slot", len(out)))
        except (TypeError, ValueError):
            slot = len(out)
        resource = item.get("resource")
        desc = texture_resources.get(resource or "", {}) or {}
        out[slot] = TextureBinding(
            slot=slot,
            name=item.get("name"),
            resource=resource,
            fallback=bool(item.get("fallback")),
            width=item.get("width") or desc.get("width"),
            height=item.get("height") or desc.get("height"),
            fmt=item.get("format") or item.get("pixelFormat") or desc.get("format"),
            raw=item,
        )
    return out


def normalize_shader_sig(
    raw_pass: dict[str, Any],
    shader_resources: dict[str, Any],
    uniforms: dict[str, Uniform],
    textures: dict[int, TextureBinding],
) -> dict[str, Any]:
    refs = raw_pass.get("shaders", {}) or {}
    reflected_uniforms: set[str] = set()
    samplers: set[str] = set()
    varyings: set[str] = set()
    shader_ids: list[str] = []
    for shader_id in (refs.get("vs"), refs.get("fs")):
        if not shader_id:
            continue
        shader_ids.append(shader_id)
        reflection = (shader_resources.get(shader_id) or {}).get("reflection") or {}
        for uniform in reflection.get("uniforms", []) or []:
            if uniform.get("name"):
                reflected_uniforms.add(uniform["name"])
        for sampler in reflection.get("samplers", []) or []:
            if sampler.get("name"):
                samplers.add(sampler["name"])
        for key in ("inputSignature", "outputSignature"):
            for param in reflection.get(key, []) or []:
                semantic = param.get("semanticName")
                if semantic:
                    varyings.add(f"{semantic}{param.get('semanticIndex', 0)}")
    if not reflected_uniforms:
        reflected_uniforms = set(uniforms)
    if not samplers:
        samplers = {b.name for b in textures.values() if b.name}
    return {
        "shaderIds": shader_ids,
        "uniformNames": sorted(reflected_uniforms),
        "samplers": sorted(samplers),
        "varyings": sorted(varyings),
    }


def normalize_rt_lineage(raw_pass: dict[str, Any]) -> list[str]:
    color = (raw_pass.get("targets", {}) or {}).get("color") or []
    return [str(item.get("resource")) for item in color if item.get("resource")]


# --------------------------------------------------------------------------- #
# DP alignment
# --------------------------------------------------------------------------- #
def align_passes(wpe: list[NormalizedPass], mac: list[NormalizedPass]) -> list[dict[str, Any]]:
    rows, cols = len(wpe) + 1, len(mac) + 1
    dp = [[0.0] * cols for _ in range(rows)]
    back: list[list[Optional[tuple[str, int, int]]]] = [[None] * cols for _ in range(rows)]
    for i in range(1, rows):
        dp[i][0] = dp[i - 1][0] + delete_cost(wpe[i - 1])
        back[i][0] = ("delete", i - 1, -1)
    for j in range(1, cols):
        dp[0][j] = dp[0][j - 1] + INSERT
        back[0][j] = ("insert", -1, j - 1)
    for i in range(1, rows):
        for j in range(1, cols):
            cost, choice = min(
                (
                    (dp[i - 1][j - 1] + substitute_cost(wpe[i - 1], mac[j - 1]), ("match", i - 1, j - 1)),
                    (dp[i - 1][j] + delete_cost(wpe[i - 1]), ("delete", i - 1, -1)),
                    (dp[i][j - 1] + INSERT, ("insert", -1, j - 1)),
                ),
                key=lambda item: item[0],
            )
            dp[i][j] = cost
            back[i][j] = choice

    i, j = len(wpe), len(mac)
    alignment: list[dict[str, Any]] = []
    while i > 0 or j > 0:
        choice = back[i][j]
        if choice is None:
            break
        op, wi, mj = choice
        if op == "match":
            alignment.append({"wpe": wi, "mac": mj, "status": "aligned", "cost": round(substitute_cost(wpe[wi], mac[mj]), 4)})
            i, j = i - 1, j - 1
        elif op == "delete":
            entry = {"wpe": wi, "mac": None, "status": "deleted", "cost": round(delete_cost(wpe[wi]), 4)}
            if wpe[wi].is_pointlist:
                entry["bucket"] = "puppet+particle"
            alignment.append(entry)
            i -= 1
        else:
            alignment.append({"wpe": None, "mac": mj, "status": "inserted", "cost": INSERT})
            j -= 1
    alignment.reverse()
    return alignment


def delete_cost(pass_: NormalizedPass) -> float:
    return DELETE_POINTLIST if pass_.is_pointlist else DELETE_QUAD


def substitute_cost(wpe: NormalizedPass, mac: NormalizedPass) -> float:
    cost = 0.0
    if wpe.topology != mac.topology:
        cost += 3.0 if (wpe.is_pointlist or mac.is_pointlist) else 1.0
    cost += 1.0 - jaccard(set(wpe.uniforms), set(mac.uniforms))
    cost += 0.75 * (1.0 - jaccard(set(texture_names(wpe)), set(texture_names(mac))))
    cost += 0.75 * (1.0 - jaccard(set(wpe.shader_sig.get("samplers", [])), set(mac.shader_sig.get("samplers", []))))
    if len(wpe.rt_lineage) != len(mac.rt_lineage):
        cost += 0.25
    return cost


def texture_names(pass_: NormalizedPass) -> list[str]:
    return [b.name or f"slot{slot}" for slot, b in sorted(pass_.textures.items())]


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    union = a | b
    return len(a & b) / len(union) if union else 1.0


# --------------------------------------------------------------------------- #
# Ordered comparison + bucketing
# --------------------------------------------------------------------------- #
def compare_alignment(
    wpe: list[NormalizedPass],
    mac: list[NormalizedPass],
    alignment: list[dict[str, Any]],
    mac_trace: dict[str, Any],
) -> tuple[list[dict[str, Any]], Optional[dict[str, Any]], dict[str, int], list[dict[str, Any]], list[str]]:
    pass_summaries: list[dict[str, Any]] = []
    first: Optional[dict[str, Any]] = None
    findings: list[dict[str, Any]] = []
    histogram = {bucket: 0 for bucket in BUCKETS}
    notes: list[str] = []

    if has_static_dynamic_split(wpe) and has_mac_flat_slots(mac):
        notes.append(
            "WPE g_bufStatic/g_bufDynamic and Mac mac_flat_slots reconciled by uniform name; "
            "packing-layout differences are not treated as divergence."
        )

    # Resolution failures are a structural asset signal independent of alignment.
    unresolved = resolution_missing_count(mac_trace)
    if unresolved:
        findings.append({
            "macPassIndex": None,
            "wpePassOrdinal": None,
            "bucket": "asset",
            "suppressed": False,
            "pinpoint": {
                "type": "texture",
                "name": "resolutionSummary.missing",
                "wpe": None,
                "metal": unresolved,
                "varianceType": "missing",
            },
            "responsibleSite": "LiveWallpaper/Infrastructure/SceneResourceResolver.swift",
        })
        histogram["asset"] += 1

    # Cascade model: only an ALIGNED-PAIR divergence corrupts the downstream RT
    # chain, so only those set `after_first`. A deleted/inserted pass is a
    # structural coverage gap (Mac never traced/rendered it) — reported and
    # bucketed, but it does NOT suppress the independent pair comparisons.
    after_first = False
    for index, entry in enumerate(alignment):
        wi, mj = entry.get("wpe"), entry.get("mac")
        if wi is not None and mj is not None:
            divergence = compare_pair(wpe[wi], mac[mj])
            if divergence is None:
                pass_summaries.append({"index": index, "wpe": wi, "mac": mj, "status": "matched", "ssim": None, "reason": ""})
                continue
            suppressed = after_first
            divergence["suppressed"] = suppressed
            findings.append(divergence)
            if suppressed:
                status = "unverified"          # downstream cascade — reported, not counted
            else:
                status = "diverged"
                histogram[divergence["bucket"]] += 1
                first, after_first = divergence, True
            pass_summaries.append({
                "index": index, "wpe": wi, "mac": mj, "status": status, "ssim": None,
                "reason": divergence["pinpoint"]["varianceType"],
            })
        elif wi is not None:
            divergence = deleted_wpe_pass(wpe[wi])
            divergence["suppressed"] = False
            findings.append(divergence)
            histogram[divergence["bucket"]] += 1
            pass_summaries.append({
                "index": index, "wpe": wi, "mac": None, "status": "skipped_on_mac",
                "ssim": None, "reason": divergence["pinpoint"]["varianceType"],
            })
        else:
            divergence = inserted_mac_pass(mac[mj])
            divergence["suppressed"] = False
            findings.append(divergence)
            histogram["transpiler"] += 1
            pass_summaries.append({
                "index": index, "wpe": None, "mac": mj, "status": "inserted",
                "ssim": None, "reason": "extra-mac-pass",
            })
    return pass_summaries, first, histogram, findings, notes


def compare_pair(wpe: NormalizedPass, mac: NormalizedPass) -> Optional[dict[str, Any]]:
    if wpe.topology != mac.topology:
        bucket = "puppet+particle" if "pointlist" in (wpe.topology, mac.topology) else "transpiler"
        return divergence(wpe, mac, bucket, "topology", "draw.topology", wpe.topology, mac.topology, "mismatch")

    shader_delta = compare_shader_interface(wpe, mac)
    if shader_delta is not None:
        return divergence(wpe, mac, "transpiler", "shader-interface",
                          shader_delta["name"], shader_delta["wpe"], shader_delta["metal"], shader_delta["varianceType"])

    rt_delta = compare_rt_lineage(wpe, mac)
    if rt_delta is not None:
        return divergence(wpe, mac, "FBO", "rt", "targets.color", rt_delta["wpe"], rt_delta["metal"], rt_delta["varianceType"])

    texture_delta = compare_textures(wpe, mac)
    if texture_delta is not None:
        return divergence(wpe, mac, texture_delta["bucket"], "texture",
                          texture_delta["name"], texture_delta["wpe"], texture_delta["metal"], texture_delta["varianceType"])

    uniform_delta = compare_uniforms(wpe, mac)
    if uniform_delta is not None:
        bucket = "puppet+particle" if looks_like_matrix_or_bone(uniform_delta["name"]) else "transpiler"
        return divergence(wpe, mac, bucket, "uniform",
                          uniform_delta["name"], uniform_delta["wpe"], uniform_delta["metal"], uniform_delta["varianceType"])

    if wpe.output_hash and mac.output_hash and wpe.output_hash != mac.output_hash:
        return divergence(wpe, mac, "FBO", "rt", "output.sha256", wpe.output_hash, mac.output_hash, "hash")

    return None


def compare_shader_interface(wpe: NormalizedPass, mac: NormalizedPass) -> Optional[dict[str, Any]]:
    # Compare the logical uniform-name set only. Sampler *names* are NOT compared:
    # D3D RDEF names samplers separately (g_Sampler*) from textures, while our MSL
    # uses a combined g_Texture* sampler convention — comparing them is apples to
    # oranges. Texture-binding divergences are caught per-slot in compare_textures.
    w_uniforms = set(wpe.shader_sig.get("uniformNames", [])) or set(wpe.uniforms)
    m_uniforms = set(mac.shader_sig.get("uniformNames", [])) or set(mac.uniforms)
    if w_uniforms and m_uniforms and jaccard(w_uniforms, m_uniforms) < 0.15:
        return {"name": "uniform-name-set", "wpe": sorted(w_uniforms), "metal": sorted(m_uniforms), "varianceType": "name-set"}
    return None


def compare_rt_lineage(wpe: NormalizedPass, mac: NormalizedPass) -> Optional[dict[str, Any]]:
    if not wpe.rt_lineage or not mac.rt_lineage:
        return None
    if len(wpe.rt_lineage) != len(mac.rt_lineage):
        return {"wpe": wpe.rt_lineage, "metal": mac.rt_lineage, "varianceType": "target-count"}
    return None


def compare_textures(wpe: NormalizedPass, mac: NormalizedPass) -> Optional[dict[str, Any]]:
    for slot, metal in sorted(mac.textures.items()):
        # Only a fallback on a *declared* sampler slot (the shader actually reads
        # it) is a real under-binding. Beyond-declared slots that fall back to the
        # primary texture are benign — the shader never samples them.
        if metal.fallback and metal.name:
            return {
                "bucket": "asset", "name": metal.name or f"slot{slot}",
                "wpe": texture_to_json(wpe.textures.get(slot)), "metal": texture_to_json(metal),
                "varianceType": "fallback",
            }
    for slot in sorted(set(wpe.textures) & set(mac.textures)):
        wt, mt = wpe.textures[slot], mac.textures[slot]
        if wt.name and mt.name and normalize_texture_name(wt.name) != normalize_texture_name(mt.name):
            return {"bucket": "asset", "name": f"slot{slot}", "wpe": texture_to_json(wt), "metal": texture_to_json(mt), "varianceType": "name"}
        if wt.width and mt.width and wt.height and mt.height and (wt.width, wt.height) != (mt.width, mt.height):
            return {"bucket": "asset", "name": wt.name or mt.name or f"slot{slot}", "wpe": texture_to_json(wt), "metal": texture_to_json(mt), "varianceType": "dimensions"}
    missing = sorted(set(wpe.textures) - set(mac.textures))
    if missing:
        slot = missing[0]
        return {"bucket": "asset", "name": wpe.textures[slot].name or f"slot{slot}", "wpe": texture_to_json(wpe.textures[slot]), "metal": None, "varianceType": "missing"}
    return None


def compare_uniforms(wpe: NormalizedPass, mac: NormalizedPass) -> Optional[dict[str, Any]]:
    for name in sorted(set(wpe.uniforms) & set(mac.uniforms)):
        if name.lower() in VOLATILE_UNIFORMS:
            continue
        wv, mv = wpe.uniforms[name].value, mac.uniforms[name].value
        if wv is None or mv is None:
            continue
        if not values_close(wv, mv):
            return {
                "name": name,
                "wpe": value_summary(wv, wpe.uniforms[name].raw),
                "metal": value_summary(mv, mac.uniforms[name].raw),
                "varianceType": matrix_variance_type(name, wv, mv),
            }
    return None


# --------------------------------------------------------------------------- #
# Value helpers
# --------------------------------------------------------------------------- #
def values_close(a: Any, b: Any, eps: float = EPSILON) -> bool:
    av, bv = flatten_numbers(a), flatten_numbers(b)
    if not av or not bv:
        return a == b
    if len(av) != len(bv):
        return False
    return all(abs(x - y) <= eps for x, y in zip(av, bv))


def flatten_numbers(value: Any) -> list[float]:
    if isinstance(value, bool):
        return [1.0 if value else 0.0]
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, list):
        out: list[float] = []
        for item in value:
            out.extend(flatten_numbers(item))
        return out
    return []


def matrix_variance_type(name: str, wv: Any, mv: Any) -> str:
    if looks_like_matrix_or_bone(name):
        wf, mf = flatten_numbers(wv), flatten_numbers(mv)
        if len(wf) == len(mf) == 16 and values_close(transpose4(wf), mf):
            return "transpose"
        return "matrix"
    return "value"


def transpose4(values: list[float]) -> list[float]:
    return [values[c * 4 + r] for r in range(4) for c in range(4)]


def looks_like_matrix_or_bone(name: str) -> bool:
    lowered = name.lower()
    return "matrix" in lowered or "bone" in lowered


def value_summary(value: Any, raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "value": value,
        "slot": raw.get("slot"),
        "offsetBytes": raw.get("startOffset") or raw.get("offsetBytes"),
        "matrixMajor": raw.get("matrixMajor"),
    }


def texture_to_json(binding: Optional[TextureBinding]) -> Optional[dict[str, Any]]:
    if binding is None:
        return None
    return {
        "slot": binding.slot, "name": binding.name, "resource": binding.resource,
        "fallback": binding.fallback, "width": binding.width, "height": binding.height, "format": binding.fmt,
    }


def normalize_texture_name(name: str) -> str:
    lowered = name.lower()
    if lowered.startswith("g_texture"):
        return lowered
    if lowered.startswith("texture"):
        return "g_" + lowered
    return lowered


def deleted_wpe_pass(pass_: NormalizedPass) -> dict[str, Any]:
    is_particle = pass_.is_pointlist
    return {
        "macPassIndex": None,
        "wpePassOrdinal": pass_.ordinal,
        "passId": pass_.pass_id,
        "shaderName": pass_.shader_name,
        "bucket": "puppet+particle" if is_particle else "transpiler",
        "pinpoint": {
            "type": "topology",
            "name": pass_.topology,
            "wpe": {"ordinal": pass_.ordinal, "topology": pass_.topology, "draw": pass_.draw},
            "metal": None,
            "varianceType": "missing-pointlist-particle-pass" if is_particle else "missing-wpe-pass",
        },
        "responsibleSite": "LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift (fragment-only: no particle/pointlist path)"
        if is_particle else "LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift",
    }


def inserted_mac_pass(pass_: NormalizedPass) -> dict[str, Any]:
    return {
        "macPassIndex": pass_.ordinal,
        "wpePassOrdinal": None,
        "passId": pass_.pass_id,
        "shaderName": pass_.shader_name,
        "bucket": "transpiler",
        "pinpoint": {"type": "topology", "name": pass_.topology, "wpe": None, "metal": pass_.topology, "varianceType": "extra-mac-pass"},
        "responsibleSite": "LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift",
    }


def divergence(wpe: NormalizedPass, mac: NormalizedPass, bucket: str, type_: str,
               name: str, wpe_value: Any, metal_value: Any, variance_type: str) -> dict[str, Any]:
    return {
        "macPassIndex": mac.ordinal,
        "wpePassOrdinal": wpe.ordinal,
        "passId": mac.pass_id or wpe.pass_id,
        "shaderName": mac.shader_name or wpe.shader_name,
        "bucket": bucket,
        "pinpoint": {"type": type_, "name": name, "wpe": wpe_value, "metal": metal_value, "varianceType": variance_type},
        "responsibleSite": responsible_site(bucket, type_),
    }


def responsible_site(bucket: str, type_: str) -> str:
    if bucket == "asset":
        return "LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift"
    if bucket == "FBO":
        return "LiveWallpaper/Runtime/WPEMetalRenderExecutor.swift"
    if bucket == "puppet+particle":
        return "LiveWallpaper/Runtime/WPEMetalShaderDispatcher.swift"
    return "LiveWallpaper/Runtime/WPEShaderTranspiler.swift"


def has_static_dynamic_split(passes: list[NormalizedPass]) -> bool:
    names = {cb.get("name") for p in passes for cb in (p.raw.get("constantBuffers") or [])}
    return "g_bufStatic" in names and "g_bufDynamic" in names


def has_mac_flat_slots(passes: list[NormalizedPass]) -> bool:
    return any(cb.get("name") == "mac_flat_slots" for p in passes for cb in (p.raw.get("constantBuffers") or []))


def resolution_missing_count(trace: dict[str, Any]) -> int:
    summary = (trace.get("capture") or {}).get("resolutionSummary") or {}
    try:
        return int(summary.get("missing") or 0)
    except (TypeError, ValueError):
        return 0


# --------------------------------------------------------------------------- #
# Summary assembly
# --------------------------------------------------------------------------- #
def build_summary(windows_trace: dict[str, Any], mac_trace: dict[str, Any],
                  windows_path: Path, mac_path: Path, out_path: Path) -> dict[str, Any]:
    wpe = normalize_trace(windows_trace, "windows-wpe")
    mac = normalize_trace(mac_trace, "mac-metal")
    alignment = align_passes(wpe, mac)
    passes, first, histogram, findings, notes = compare_alignment(wpe, mac, alignment, mac_trace)

    status = "matched" if (first is None and not findings) else "diverged"
    primary_bucket = first.get("bucket") if first else primary_from_findings(findings)

    alignment_json: list[dict[str, Any]] = []
    for item in alignment:
        entry = dict(item)
        if entry.get("wpe") is not None:
            entry["wpePassOrdinal"] = wpe[entry["wpe"]].ordinal
            entry["wpeTopology"] = wpe[entry["wpe"]].topology
        if entry.get("mac") is not None:
            entry["macPassIndex"] = mac[entry["mac"]].ordinal
            entry["macTopology"] = mac[entry["mac"]].topology
        alignment_json.append(entry)

    pointlist_deletions = sum(
        1 for item in alignment_json
        if item.get("status") == "deleted" and item.get("bucket") == "puppet+particle"
    )
    histogram["puppet+particle"] = max(histogram["puppet+particle"], pointlist_deletions)

    scene = windows_trace.get("scene") or mac_trace.get("scene") or {}
    return {
        "schema": "wpe.diff.v1",
        "sceneId": str(scene.get("workshopId") or ""),
        "status": status,
        "confidence": confidence_score(alignment_json, first, findings),
        "primaryBucket": primary_bucket,
        "ssimFinal": None,
        "firstDivergence": first,
        "alignment": alignment_json,
        "passes": passes,
        "bucketHistogram": histogram,
        "findings": findings,
        "normalizationNotes": notes,
        "artifactRefs": {
            "windowsTrace": str(windows_path),
            "macTrace": str(mac_path),
            "diffSummary": str(out_path),
            "report": None,
            "gputrace": None,
        },
    }


def primary_from_findings(findings: list[dict[str, Any]]) -> Optional[str]:
    """When no aligned-pair divergence is the cascade source, pick the most
    fundamental structural bucket: asset (resources never loaded) dominates."""
    priority = ("asset", "puppet+particle", "FBO", "transpiler")
    present = {f["bucket"] for f in findings if not f.get("suppressed")}
    for bucket in priority:
        if bucket in present:
            return bucket
    return None


def confidence_score(alignment: list[dict[str, Any]], first: Optional[dict[str, Any]], findings: list[dict[str, Any]]) -> float:
    if not alignment:
        return 0.0
    aligned = sum(1 for item in alignment if item.get("status") == "aligned")
    base = aligned / len(alignment)
    if first and first.get("bucket") == "puppet+particle":
        base = max(base, 0.9)
    if any(f.get("pinpoint", {}).get("varianceType") == "fallback" for f in findings):
        base = max(base, 0.75)
    return round(min(max(base, 0.0), 1.0), 3)


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--windows", type=Path, required=True, help="Windows WPE wpe.trace.v1 JSON.")
    parser.add_argument("--mac", type=Path, required=True, help="Mac Metal wpe.trace.v1 JSON.")
    parser.add_argument("--out", type=Path, required=True, help="Output divergence-summary.json (wpe.diff.v1).")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    summary = build_summary(load_json(args.windows), load_json(args.mac), args.windows, args.mac, args.out)
    write_json(args.out, summary)
    fd = summary["firstDivergence"]
    print(f"wrote {args.out}")
    print(f"  status={summary['status']} primaryBucket={summary['primaryBucket']} "
          f"confidence={summary['confidence']}")
    if fd:
        pp = fd["pinpoint"]
        print(f"  firstDivergence: pass mac#{fd['macPassIndex']}/wpe#{fd['wpePassOrdinal']} "
              f"shader={fd.get('shaderName')} passId={fd.get('passId')}")
        print(f"    {fd['bucket']} :: {pp['type']}/{pp['name']} ({pp['varianceType']}) -> {fd['responsibleSite']}")
    else:
        print("  firstDivergence: none")
    print(f"  buckets={summary['bucketHistogram']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
