#!/usr/bin/env python3
"""Export a shader-first WPE RenderDoc capture as wpe.trace.v1.

Runs in RenderDoc's Python environment (`renderdoccmd python` or the
RenderDoc UI Python shell). Dependencies are stdlib + `renderdoc` only.

This tool is intentionally best-effort across RenderDoc versions: all API
access is wrapped, missing HLSL source is accepted, and DXBC disassembly plus
reflection are treated as the minimum shader oracle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

try:
    import renderdoc as rd
except Exception as exc:  # pragma: no cover - only meaningful inside RenderDoc.
    rd = None
    RENDERDOC_IMPORT_ERROR = exc
else:
    RENDERDOC_IMPORT_ERROR = None


STAGE_DEFS = (
    ("vs", "vertex", "Vertex"),
    ("fs", "fragment", "Pixel"),
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return sha256_bytes(text.encode("utf-8", errors="replace"))


def sha256_file(path: Path) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8", errors="replace")


def safe_name(value: str | None, fallback: str = "unnamed") -> str:
    if not value:
        value = fallback
    value = value.replace("\\", "/").split("/")[-1]
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value)
    return value[:96] or fallback


def enum_name(value: Any) -> str | None:
    if value is None:
        return None
    name = getattr(value, "name", None)
    if isinstance(name, str):
        return name
    try:
        return str(value)
    except Exception:
        return type(value).__name__


def get_attr(obj: Any, *names: str, default: Any = None) -> Any:
    for name in names:
        try:
            if hasattr(obj, name):
                value = getattr(obj, name)
                if value is not None:
                    return value
        except Exception:
            continue
    return default


def call(obj: Any, name: str, *args: Any) -> Any:
    fn = getattr(obj, name, None)
    if fn is None:
        return None
    try:
        return fn(*args)
    except Exception:
        return None


def call_any(obj: Any, names: Iterable[str], *args: Any) -> Any:
    for name in names:
        value = call(obj, name, *args)
        if value is not None:
            return value
    return None


def rid_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    try:
        return str(value)
    except Exception:
        return None


def is_null_rid(value: Any) -> bool:
    text = (rid_text(value) or "").strip().lower()
    return text in ("", "0", "null", "resourceid()", "resourceid::null()")


def extract_rid(obj: Any) -> Any:
    if obj is None:
        return None
    for name in ("resourceId", "resource", "id"):
        value = get_attr(obj, name)
        if value is not None and not is_null_rid(value):
            return value
    descriptor = get_attr(obj, "descriptor")
    if descriptor is not None:
        return extract_rid(descriptor)
    return None


def resource_key(prefix: str, rid: Any) -> str:
    text = rid_text(rid) or "unknown"
    digest = sha256_text(text)[:16]
    return f"{prefix}-{digest}"


def simple_value(value: Any, depth: int = 0) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if depth > 3:
        return enum_name(value)
    if isinstance(value, (list, tuple)):
        return [simple_value(v, depth + 1) for v in list(value)[:64]]
    if isinstance(value, dict):
        return {str(k): simple_value(v, depth + 1) for k, v in value.items()}
    if hasattr(value, "__iter__") and not isinstance(value, (bytes, bytearray)):
        try:
            return [simple_value(v, depth + 1) for v in list(value)[:64]]
        except Exception:
            pass
    return enum_name(value)


def public_fields(obj: Any, *, max_fields: int = 64) -> dict[str, Any] | None:
    if obj is None:
        return None
    out: dict[str, Any] = {}
    for name in dir(obj):
        if name.startswith("_"):
            continue
        if name[0].isupper():
            continue
        try:
            value = getattr(obj, name)
        except Exception:
            continue
        if callable(value):
            continue
        if len(out) >= max_fields:
            out["_truncated"] = True
            break
        out[name] = simple_value(value)
    return out


def renderdoc_version() -> str | None:
    if rd is None:
        return None
    for name in ("GetVersionString", "GetVersion"):
        fn = getattr(rd, name, None)
        if fn is None:
            continue
        try:
            return str(fn())
        except Exception:
            continue
    return None


def stage_enum(stage_key: str) -> Any:
    if rd is None:
        return None
    shader_stage = getattr(rd, "ShaderStage", None)
    if shader_stage is None:
        return None
    candidates = {
        "vs": ("Vertex", "VS"),
        "fs": ("Pixel", "Fragment", "PS"),
    }[stage_key]
    for name in candidates:
        if hasattr(shader_stage, name):
            return getattr(shader_stage, name)
    return None


def draw_flags_enum(name: str) -> Any:
    if rd is None:
        return None
    flags = getattr(rd, "DrawFlags", None)
    if flags is None:
        return None
    return getattr(flags, name, None)


def open_capture(path: Path) -> tuple[Any, Any]:
    if rd is None:
        raise RuntimeError(f"RenderDoc Python module unavailable: {RENDERDOC_IMPORT_ERROR}")
    try:
        rd.InitialiseReplay(rd.GlobalEnvironment(), [])
    except Exception:
        pass

    cap = rd.OpenCaptureFile()
    result = cap.OpenFile(str(path), "", None)
    succeeded = getattr(rd.ResultCode, "Succeeded", None)
    if succeeded is not None and result != succeeded:
        raise RuntimeError(f"RenderDoc OpenFile failed for {path}: {result}")
    if hasattr(cap, "LocalReplaySupport") and not cap.LocalReplaySupport():
        raise RuntimeError(f"RenderDoc local replay unsupported for {path}")
    result, controller = cap.OpenCapture(rd.ReplayOptions(), None)
    if succeeded is not None and result != succeeded:
        raise RuntimeError(f"RenderDoc OpenCapture failed for {path}: {result}")
    return cap, controller


def shutdown_capture(cap: Any, controller: Any) -> None:
    try:
        controller.Shutdown()
    except Exception:
        pass
    try:
        cap.Shutdown()
    except Exception:
        pass
    try:
        rd.ShutdownReplay()
    except Exception:
        pass


def capture_with_renderdoccmd(renderdoccmd: Path, target: Path, rdc: Path, working_dir: Path | None) -> None:
    rdc.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(renderdoccmd),
        "capture",
        "--capture-file",
        str(rdc),
    ]
    if working_dir is not None:
        cmd.extend(["--working-dir", str(working_dir)])
    cmd.append(str(target))
    subprocess.run(cmd, check=True)


def root_actions(controller: Any) -> list[Any]:
    actions = call(controller, "GetRootActions")
    if actions is None:
        actions = call(controller, "GetDrawcalls")
    return list(actions or [])


def walk_actions(actions: Iterable[Any]) -> Iterable[Any]:
    for action in actions:
        yield action
        children = get_attr(action, "children", default=[]) or []
        yield from walk_actions(children)


def action_name(controller: Any, action: Any) -> str | None:
    structured = call(controller, "GetStructuredFile")
    name_fn = getattr(action, "GetName", None)
    if name_fn is not None:
        try:
            return name_fn(structured)
        except Exception:
            pass
    return get_attr(action, "customName", "name")


def is_draw_action(action: Any) -> bool:
    flags_value = get_attr(action, "flags")
    drawcall_flag = draw_flags_enum("Drawcall")
    if flags_value is not None and drawcall_flag is not None:
        try:
            return bool(flags_value & drawcall_flag)
        except Exception:
            pass
    num_indices = get_attr(action, "numIndices", default=0) or 0
    num_vertices = get_attr(action, "numVertices", default=0) or 0
    return bool(num_indices or num_vertices)


def texture_description(controller: Any, rid: Any) -> dict[str, Any]:
    desc = call(controller, "GetTexture", rid)
    if desc is None:
        return {"width": None, "height": None, "format": None, "mips": None}
    fmt = get_attr(desc, "format")
    fmt_name = call(fmt, "Name") if fmt is not None else None
    return {
        "width": get_attr(desc, "width", "Width"),
        "height": get_attr(desc, "height", "Height"),
        "format": fmt_name or enum_name(fmt),
        "mips": get_attr(desc, "mips", "mipLevels", "mipCount"),
    }


def resource_names(controller: Any) -> dict[str, str]:
    out: dict[str, str] = {}
    resources = call(controller, "GetResources") or []
    for resource in resources:
        rid = extract_rid(resource)
        if is_null_rid(rid):
            continue
        name = get_attr(resource, "name")
        if name:
            out[rid_text(rid) or ""] = str(name)
    return out


def record_texture(resources: dict[str, Any], controller: Any, names: dict[str, str], rid: Any, png: str | None = None) -> str:
    key = resource_key("tex", rid)
    desc = texture_description(controller, rid)
    resources["textures"].setdefault(key, {
        "label": names.get(rid_text(rid) or "", rid_text(rid)),
        "sourcePath": None,
        "width": desc["width"],
        "height": desc["height"],
        "format": desc["format"],
        "mips": desc["mips"],
        "sha256": None,
        "png": png,
    })
    if png and not resources["textures"][key].get("png"):
        resources["textures"][key]["png"] = png
    return key


def record_render_target(resources: dict[str, Any], controller: Any, names: dict[str, str], rid: Any, event_label: str) -> str:
    key = resource_key("rt", rid)
    desc = texture_description(controller, rid)
    existing = resources["renderTargets"].setdefault(key, {
        "label": names.get(rid_text(rid) or "", rid_text(rid)),
        "width": desc["width"],
        "height": desc["height"],
        "format": desc["format"],
        "lineage": [],
    })
    if event_label not in existing["lineage"]:
        existing["lineage"].append(event_label)
    return key


def record_buffer(resources: dict[str, Any], rid: Any, label: str | None, byte_length: int | None = None) -> str:
    key = resource_key("buf", rid)
    resources["buffers"].setdefault(key, {
        "label": label or rid_text(rid),
        "byteLength": byte_length,
        "sha256": None,
    })
    return key


def save_texture_png(controller: Any, rid: Any, path: Path) -> str | None:
    if rd is None or is_null_rid(rid):
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    texsave = rd.TextureSave()
    texsave.resourceId = rid
    texsave.mip = 0
    try:
        texsave.slice.sliceIndex = 0
    except Exception:
        pass
    try:
        texsave.alpha = rd.AlphaMapping.Preserve
    except Exception:
        pass
    try:
        texsave.destType = rd.FileType.PNG
    except Exception:
        pass
    try:
        controller.SaveTexture(texsave, str(path))
    except Exception as exc:
        write_text(path.with_suffix(".error.txt"), f"SaveTexture failed: {exc}\n")
        return None
    return str(path.as_posix())


def reflect_binding(item: Any, fallback_slot: int | None = None) -> dict[str, Any]:
    return {
        "name": str(get_attr(item, "name", default="")),
        "slot": get_attr(item, "fixedBindNumber", "bindPoint", "reg", default=fallback_slot),
        "type": enum_name(get_attr(item, "type", "resType", "variableType")),
    }


def reflect_list(items: Iterable[Any] | None) -> list[dict[str, Any]]:
    return [reflect_binding(item, i) for i, item in enumerate(list(items or []))]


def variable_shape(var: Any) -> tuple[Any, Any]:
    # Modern RenderDoc exposes rows/columns on the ShaderVariable itself;
    # older builds carry them on var.type. Prefer the variable, fall back to type.
    typ = get_attr(var, "type")
    rows = get_attr(var, "rows", default=get_attr(typ, "rows") if typ is not None else None)
    cols = get_attr(
        var,
        "columns",
        "cols",
        default=get_attr(typ, "columns", "cols") if typ is not None else None,
    )
    return rows, cols


def shader_type_name(var: Any) -> str | None:
    typ = get_attr(var, "type")
    if typ is None:
        return None
    base = get_attr(typ, "name", "baseType", "type")
    rows, cols = variable_shape(var)
    elements = get_attr(typ, "elements")
    suffix = ""
    if rows and cols:
        suffix = f"{rows}x{cols}"
    if elements and elements != 1:
        suffix = f"{suffix}[{elements}]" if suffix else f"[{elements}]"
    return f"{enum_name(base)}{suffix}" if base is not None else suffix or enum_name(typ)


def numeric_values_from_shader_variable(var: Any) -> list[float | int]:
    value = get_attr(var, "value")
    if value is None:
        return []
    for attr in ("f32v", "f64v", "s32v", "u32v", "fv", "dv", "iv", "uv"):
        raw = get_attr(value, attr)
        if raw is None:
            continue
        try:
            values = list(raw)
        except Exception:
            continue
        if values:
            return [v for v in values if isinstance(v, (int, float))]
    return []


def variable_to_json(var: Any, prefix: str | None = None) -> list[dict[str, Any]]:
    raw_name = str(get_attr(var, "name", default=""))
    name = raw_name
    if prefix:
        if raw_name.startswith("["):
            name = prefix + raw_name
        elif raw_name:
            name = prefix + "." + raw_name
        else:
            name = prefix
    if not name:
        name = "unnamed"

    members = list(get_attr(var, "members", default=[]) or [])
    values = numeric_values_from_shader_variable(var)
    if members and not values:
        flattened: list[dict[str, Any]] = []
        for member in members:
            flattened.extend(variable_to_json(member, name))
        return flattened

    out: dict[str, Any] = {
        "name": name,
        "type": shader_type_name(var),
    }
    if values:
        out["value"] = values[0] if len(values) == 1 else values
        rows, cols = variable_shape(var)
        if len(values) >= 16 and (rows == 4 and cols == 4 or "bone" in name.lower() or "bones" in name.lower()):
            out["matrix4x4"] = [float(v) for v in values[:16]]
    if members:
        child_members: list[dict[str, Any]] = []
        for member in members:
            child_members.extend(variable_to_json(member, name))
        out["members"] = child_members
    return [out]


def collect_constant_buffers(
    controller: Any,
    pipe: Any,
    resources: dict[str, Any],
    stage_key: str,
    stage_label: str,
    stage: Any,
    reflection: Any,
) -> list[dict[str, Any]]:
    if reflection is None:
        return []
    pso = call(pipe, "GetGraphicsPipelineObject")
    entry = call(pipe, "GetShaderEntryPoint", stage) or ""
    shader_rid = get_attr(reflection, "resourceId")
    blocks = list(get_attr(reflection, "constantBlocks", default=[]) or [])
    out: list[dict[str, Any]] = []

    for index, block_reflection in enumerate(blocks):
        slot = get_attr(block_reflection, "fixedBindNumber", "bindPoint", default=index)
        bound = call(pipe, "GetConstantBlock", stage, slot, 0)
        descriptor = get_attr(bound, "descriptor", default=bound)
        rid = extract_rid(descriptor)
        label = get_attr(block_reflection, "name", default=f"{stage_key}_cbuffer_{slot}")
        byte_length = get_attr(descriptor, "byteSize", "byteLength", "size")
        buffer_key = record_buffer(resources, rid or f"{stage_key}:{slot}:{label}", label, byte_length)

        variables: list[dict[str, Any]] = []
        error = None
        if rid is not None and shader_rid is not None:
            try:
                raw_variables = controller.GetCBufferVariableContents(
                    pso,
                    shader_rid,
                    stage,
                    entry,
                    slot,
                    rid,
                    0,
                    0,
                )
                for variable in raw_variables:
                    variables.extend(variable_to_json(variable))
            except Exception as exc:
                error = str(exc)

        cbuffer = {
            "name": str(label) if label is not None else None,
            "stage": stage_label,
            "slot": slot,
            "resource": buffer_key,
            "rawBytesSha256": None,
            "variables": variables,
        }
        if error:
            cbuffer["extractionError"] = error
        out.append(cbuffer)
    return out


def disassemble_shader(controller: Any, pipe: Any, reflection: Any) -> str:
    if reflection is None:
        return ""
    targets = call(controller, "GetDisassemblyTargets", True) or call(controller, "GetDisassemblyTargets", False) or []
    targets = list(targets)
    target = None
    for candidate in targets:
        if "dxbc" in str(candidate).lower():
            target = candidate
            break
    if target is None and targets:
        target = targets[0]
    if target is None:
        target = "dxbc"
    pso = call(pipe, "GetGraphicsPipelineObject")
    try:
        return controller.DisassembleShader(pso, reflection, target) or ""
    except Exception as exc:
        return f"; DisassembleShader failed: {exc}\n"


def collect_shader(
    controller: Any,
    pipe: Any,
    resources: dict[str, Any],
    out_dir: Path,
    ordinal: int,
    stage_key: str,
    stage_label: str,
) -> tuple[str | None, list[dict[str, Any]]]:
    stage = stage_enum(stage_key)
    if stage is None:
        return None, []
    reflection = call(pipe, "GetShaderReflection", stage)
    if reflection is None:
        return None, []
    shader_rid = get_attr(reflection, "resourceId")
    if is_null_rid(shader_rid):
        return None, []

    entry = call(pipe, "GetShaderEntryPoint", stage)
    disasm = disassemble_shader(controller, pipe, reflection)
    disasm_hash = sha256_text(disasm)
    shader_id = f"shader-{stage_key}-{disasm_hash[:16]}"
    disasm_path = out_dir / "shaders" / f"{ordinal:04d}-{stage_key}-{safe_name(entry, 'main')}-{disasm_hash[:12]}.dxbc.txt"
    write_text(disasm_path, disasm)

    constant_buffers = collect_constant_buffers(controller, pipe, resources, stage_key, stage_label, stage, reflection)
    reflection_json = {
        "samplers": reflect_list(get_attr(reflection, "samplers")),
        "textures": reflect_list(get_attr(reflection, "readOnlyResources", "readOnlyResourceBindings")),
        "constantBlocks": reflect_list(get_attr(reflection, "constantBlocks")),
        "uniforms": [v for cb in constant_buffers for v in cb.get("variables", [])],
    }
    resources["shaders"].setdefault(shader_id, {
        "stage": stage_label,
        "sourceLanguage": "DXBC",
        "entryPoint": str(entry) if entry is not None else None,
        "sourcePath": None,
        "sourceSha256": None,
        "disassembly": {
            "path": str(disasm_path.as_posix()),
            "sha256": disasm_hash,
        },
        "reflection": reflection_json,
        "renderdocResourceId": rid_text(shader_rid),
    })
    return shader_id, constant_buffers


def collect_texture_bindings(controller: Any, pipe: Any, resources: dict[str, Any], names: dict[str, str]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for stage_key, stage_label, _ in STAGE_DEFS:
        stage = stage_enum(stage_key)
        if stage is None:
            continue
        bindings = call(pipe, "GetReadOnlyResources", stage) or []
        for slot, binding in enumerate(list(bindings)):
            rid = extract_rid(binding)
            if is_null_rid(rid):
                continue
            tex_key = record_texture(resources, controller, names, rid)
            out.append({
                "stage": stage_label,
                "slot": slot,
                "name": get_attr(binding, "name"),
                "resource": tex_key,
                "renderdocResourceId": rid_text(rid),
            })
    return out


def collect_samplers(pipe: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for stage_key, stage_label, _ in STAGE_DEFS:
        stage = stage_enum(stage_key)
        if stage is None:
            continue
        samplers = call(pipe, "GetSamplers", stage) or []
        for slot, sampler in enumerate(list(samplers)):
            data = public_fields(sampler) or {}
            data.update({"stage": stage_label, "slot": slot})
            out.append(data)
    return out


def collect_targets(
    controller: Any,
    pipe: Any,
    resources: dict[str, Any],
    names: dict[str, str],
    out_dir: Path,
    ordinal: int,
    event_id: int | None,
    action: Any,
) -> tuple[dict[str, Any], dict[str, Any]]:
    color_targets: list[dict[str, Any]] = []
    output = {"resource": None, "png": None, "sha256": None, "visualStats": {"note": "PNG saved via RenderDoc SaveTexture; pixel statistics intentionally deferred."}}

    # Prefer the bound output-merger targets; fall back to the action's own
    # output list (stable across RenderDoc builds) so a missing PipeState helper
    # does not silently drop the pass and yield an empty trace.
    output_entries: list[tuple[int, Any, Any]] = []
    for slot, target in enumerate(list(call(pipe, "GetOutputTargets") or [])):
        rid = extract_rid(target)
        if not is_null_rid(rid):
            output_entries.append((slot, target, rid))
    if not output_entries:
        for slot, rid in enumerate(list(get_attr(action, "outputs", default=[]) or [])):
            if not is_null_rid(rid):
                output_entries.append((slot, None, rid))

    for slot, target, rid in output_entries:
        label = f"draw-{ordinal:04d}-event-{event_id}"
        rt_key = record_render_target(resources, controller, names, rid, label)
        png = out_dir / "rt" / f"pass-{ordinal:04d}-event-{event_id}-color{slot}.png"
        saved = save_texture_png(controller, rid, png)
        color_targets.append({
            "slot": slot,
            "resource": rt_key,
            "load": enum_name(get_attr(target, "loadOp", "loadAction")) if target is not None else None,
            "store": enum_name(get_attr(target, "storeOp", "storeAction")) if target is not None else None,
            "renderdocResourceId": rid_text(rid),
            "png": saved,
        })
        if output["resource"] is None:
            output = {
                "resource": rt_key,
                "png": saved,
                "sha256": sha256_file(Path(saved)) if saved else None,
                "visualStats": {"note": "PNG saved via RenderDoc SaveTexture; pixel statistics intentionally deferred."},
            }

    depth_target = call(pipe, "GetDepthTarget")
    depth = None
    depth_rid = extract_rid(depth_target)
    if not is_null_rid(depth_rid):
        depth = {
            "resource": record_render_target(resources, controller, names, depth_rid, f"depth-draw-{ordinal:04d}"),
            "load": enum_name(get_attr(depth_target, "loadOp", "loadAction")),
            "store": enum_name(get_attr(depth_target, "storeOp", "storeAction")),
            "renderdocResourceId": rid_text(depth_rid),
        }
    return {"color": color_targets, "depth": depth}, output


def viewport_to_json(viewport: Any) -> list[float]:
    if viewport is None:
        return []
    values = []
    for name in ("x", "y", "width", "height", "minDepth", "maxDepth"):
        value = get_attr(viewport, name)
        if value is not None:
            try:
                values.append(float(value))
            except Exception:
                pass
    return values


def first_viewport(pipe: Any) -> list[float]:
    viewport = call(pipe, "GetViewport", 0)
    if viewport is None:
        viewports = call(pipe, "GetViewports") or []
        viewport = list(viewports)[0] if viewports else None
    return viewport_to_json(viewport)


def first_scissor(pipe: Any) -> list[float]:
    scissor = call(pipe, "GetScissor", 0)
    if scissor is None:
        scissors = call(pipe, "GetScissors") or []
        scissor = list(scissors)[0] if scissors else None
    return viewport_to_json(scissor)


def collect_pipeline_state(pipe: Any) -> dict[str, Any]:
    return {
        "blend": public_fields(call_any(pipe, ("GetBlendState", "GetOutputMergerState"))),
        "depth": public_fields(call_any(pipe, ("GetDepthState", "GetDepthStencilState"))),
        "raster": public_fields(call_any(pipe, ("GetRasterizerState", "GetRasterState"))),
        "samplers": collect_samplers(pipe),
    }


def collect_pass(controller: Any, resources: dict[str, Any], names: dict[str, str], out_dir: Path, ordinal: int, action: Any) -> dict[str, Any] | None:
    event_id = get_attr(action, "eventId")
    if event_id is None:
        return None
    try:
        controller.SetFrameEvent(event_id, True)
    except Exception:
        return None
    pipe = controller.GetPipelineState()
    targets, output = collect_targets(controller, pipe, resources, names, out_dir, ordinal, event_id, action)
    if not targets["color"]:
        return None

    shaders: dict[str, str | None] = {"vs": None, "fs": None}
    constant_buffers: list[dict[str, Any]] = []
    for stage_key, stage_label, _ in STAGE_DEFS:
        shader_id, cbuffers = collect_shader(controller, pipe, resources, out_dir, ordinal, stage_key, stage_label)
        shaders[stage_key] = shader_id
        constant_buffers.extend(cbuffers)

    return {
        "ordinal": ordinal,
        "eventId": int(event_id),
        "layerId": None,
        "passId": None,
        "shaderName": action_name(controller, action),
        "draw": {
            "topology": enum_name(get_attr(action, "topology", default=call(pipe, "GetPrimitiveTopology"))),
            "vertexCount": get_attr(action, "numVertices", default=None),
            "indexCount": get_attr(action, "numIndices", default=None),
            "instanceCount": get_attr(action, "numInstances", default=None),
            "viewport": first_viewport(pipe),
            "scissor": first_scissor(pipe),
        },
        "targets": targets,
        "textures": collect_texture_bindings(controller, pipe, resources, names),
        "shaders": shaders,
        "constantBuffers": constant_buffers,
        "state": collect_pipeline_state(pipe),
        "output": output,
    }


def infer_resolution(resources: dict[str, Any], job: dict[str, Any]) -> dict[str, int]:
    explicit = job.get("resolution") or job.get("preferredResolution")
    if isinstance(explicit, dict) and explicit.get("width") and explicit.get("height"):
        return {"width": int(explicit["width"]), "height": int(explicit["height"])}
    best = (1, 1)
    for rt in resources["renderTargets"].values():
        w, h = rt.get("width"), rt.get("height")
        if isinstance(w, int) and isinstance(h, int) and w * h > best[0] * best[1]:
            best = (w, h)
    return {"width": best[0], "height": best[1]}


def build_trace(args: argparse.Namespace, controller: Any, job: dict[str, Any]) -> dict[str, Any]:
    out_dir = Path(args.out)
    resources = {
        "textures": {},
        "renderTargets": {},
        "buffers": {},
        "shaders": {},
    }
    names = resource_names(controller)
    passes: list[dict[str, Any]] = []
    for action in walk_actions(root_actions(controller)):
        if not is_draw_action(action):
            continue
        captured = collect_pass(controller, resources, names, out_dir, len(passes), action)
        if captured is not None:
            passes.append(captured)

    final = {"resource": None, "png": None, "sha256": None}
    if passes:
        last_output = passes[-1]["output"]
        final = {
            "resource": last_output.get("resource"),
            "png": last_output.get("png"),
            "sha256": last_output.get("sha256"),
        }

    project_json = args.project_json or job.get("projectJson") or ""
    project_sha = sha256_file(Path(project_json)) if project_json else None
    scene_id = args.scene_id or str(job.get("sceneId") or job.get("workshopId") or "")
    mode = args.mode or job.get("mode") or "shader-first"
    warmup_ms = int(args.warmup_ms if args.warmup_ms is not None else job.get("warmupMs", 0) or 0)
    pointer = job.get("pointer") or [0.5, 0.5]

    return {
        "schema": "wpe.trace.v1",
        "producer": {
            "side": "windows-wpe",
            "tool": "RenderDoc",
            "toolVersion": renderdoc_version(),
            "wpeVersion": args.wpe_version,
            "appBuild": None,
        },
        "scene": {
            "workshopId": scene_id,
            "projectJson": project_json,
            "projectJsonSha256": project_sha,
            "scenePkgSha256": sha256_file(Path(project_json).with_name("scene.pkg")) if project_json else None,
            "entryFile": "project.json",
            "assetRoots": [str(Path(project_json).parent)] if project_json else [],
        },
        "capture": {
            "jobId": str(job.get("jobId") or args.job_id or ""),
            "mode": mode,
            "frameOrdinal": int(args.frame_ordinal),
            "warmupMs": warmup_ms,
            "resolution": infer_resolution(resources, job),
            "wallpaperWindow": {
                "class": "WorkerW",
                "hwnd": job.get("workerWHwnd"),
                "pid": job.get("wallpaperPid"),
            },
            "determinism": {
                "time": None,
                "daytime": None,
                "pointer": pointer,
                "audioMode": job.get("audioMode", "muted"),
                "mouseParallax": job.get("mouseParallax", "centered"),
            },
        },
        "resources": resources,
        "passes": passes,
        "final": final,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rdc", type=Path, help="Input .rdc capture to replay.")
    parser.add_argument("--target", type=Path, help="Optional target exe to capture before extraction.")
    parser.add_argument("--renderdoccmd", type=Path, help="renderdoccmd.exe path when --target is used.")
    parser.add_argument("--capture-file", type=Path, help="Output .rdc path when --target is used.")
    parser.add_argument("--working-dir", type=Path, help="Target working directory when --target is used.")
    parser.add_argument("--out", type=Path, required=True, help="Output windows artifact directory.")
    parser.add_argument("--job", type=Path, help="Job descriptor JSON.")
    parser.add_argument("--job-id", default="", help="Job id override.")
    parser.add_argument("--scene-id", default="", help="Workshop scene id override.")
    parser.add_argument("--project-json", default="", help="project.json path override.")
    parser.add_argument("--mode", choices=("shader-first", "state", "full"), default=None)
    parser.add_argument("--warmup-ms", type=int, default=None)
    parser.add_argument("--frame-ordinal", type=int, default=0)
    parser.add_argument("--wpe-version", default="2.8.26")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "rt").mkdir(parents=True, exist_ok=True)
    (args.out / "shaders").mkdir(parents=True, exist_ok=True)

    job = read_json(args.job) if args.job else {}
    rdc = args.rdc
    if rdc is None and args.target is not None:
        if args.renderdoccmd is None:
            raise SystemExit("--renderdoccmd is required with --target")
        rdc = args.capture_file or args.out / "frame.rdc"
        capture_with_renderdoccmd(args.renderdoccmd, args.target, rdc, args.working_dir)
    if rdc is None:
        raise SystemExit("Either --rdc or --target is required")
    if not rdc.is_file():
        raise SystemExit(f"Capture file does not exist: {rdc}")

    cap = controller = None
    try:
        cap, controller = open_capture(rdc)
        trace = build_trace(args, controller, job)
        write_json(args.out / "trace.json", trace)
        return 0
    finally:
        if cap is not None and controller is not None:
            shutdown_capture(cap, controller)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
