#!/usr/bin/env python3
"""Parse RenderDoc zip.xml D3D11 captures into wpe.trace.v1.

RenderDoc 1.44 does not expose a standalone `renderdoc` Python module outside
qrenderdoc. The headless path is:

  renderdoccmd convert -f frame.rdc -o frame.zip.xml -c zip.xml

This script runs on macOS with stdlib only and parses the structured XML plus
the companion `blobs/000000` files or `frame.zip` blob archive.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, BinaryIO, Iterable


SCHEMA_VERSION = "wpe.trace.v1"
DEFAULT_WPE_VERSION = "2.8.26"
D3D11_MAP_WRITE_DISCARD = 4
D3D11_MAP_WRITE_NO_OVERWRITE = 5
D3D_SVF_USED = 0x2

RESOURCE_BIND_TYPES = {
    0: "CBUFFER",
    1: "TBUFFER",
    2: "TEXTURE",
    3: "SAMPLER",
    4: "UAV_RWTYPED",
    5: "STRUCTURED",
    6: "UAV_RWSTRUCTURED",
    7: "BYTEADDRESS",
    8: "UAV_RWBYTEADDRESS",
    9: "UAV_APPEND_STRUCTURED",
    10: "UAV_CONSUME_STRUCTURED",
    11: "UAV_RWSTRUCTURED_WITH_COUNTER",
}

SHADER_VARIABLE_CLASSES = {
    0: "scalar",
    1: "vector",
    2: "matrix_rows",
    3: "matrix_columns",
    4: "object",
    5: "struct",
    6: "interface_class",
    7: "interface_pointer",
}

SHADER_VARIABLE_TYPES = {
    0: "void",
    1: "bool",
    2: "int",
    3: "float",
    4: "string",
    5: "texture",
    6: "texture1d",
    7: "texture2d",
    8: "texture3d",
    9: "texturecube",
    10: "sampler",
    11: "sampler1d",
    12: "sampler2d",
    13: "sampler3d",
    14: "samplercube",
    15: "pixelshader",
    16: "vertexshader",
    17: "uint",
    18: "uint8",
    19: "geometryshader",
    20: "rasterizer",
    21: "depthstencil",
    22: "blend",
    23: "buffer",
    24: "cbuffer",
    25: "tbuffer",
    26: "texture1darray",
    27: "texture2darray",
    28: "rendertargetview",
    29: "depthstencilview",
    30: "texture2dms",
    31: "texture2dmsarray",
    32: "texturecubearray",
    33: "hullshader",
    34: "domainshader",
    35: "interface_pointer",
    36: "compute_shader",
    37: "double",
    38: "rwttexture1d",
    39: "rwtexture1darray",
    40: "rwtexture2d",
    41: "rwtexture2darray",
    42: "rwtexture3d",
    43: "rwbuffer",
    44: "byteaddress_buffer",
    45: "rwbyteaddress_buffer",
    46: "structured_buffer",
    47: "rwstructured_buffer",
    48: "append_structured_buffer",
    49: "consume_structured_buffer",
}

COMPONENT_TYPES = {
    0: "unknown",
    1: "uint32",
    2: "sint32",
    3: "float32",
}

SIGNATURE_CHUNKS = {"ISGN", "OSGN", "ISG1", "OSG1", "ISG5", "OSG5", "PCSG"}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp.replace(path)


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8", newline="\n")


def cstr(buf: bytes, offset: int | None) -> str:
    if offset is None or offset == 0xFFFFFFFF or offset < 0 or offset >= len(buf):
        return ""
    end = buf.find(b"\x00", offset)
    if end < 0:
        end = len(buf)
    return buf[offset:end].decode("utf-8", errors="replace")


def valid_cstr(buf: bytes, offset: int | None) -> bool:
    return bool(cstr(buf, offset))


def u32(buf: bytes, offset: int) -> int:
    return struct.unpack_from("<I", buf, offset)[0]


def text(elem: ET.Element | None) -> str:
    return (elem.text or "").strip() if elem is not None else ""


def direct(elem: ET.Element, name: str | None = None, tag: str | None = None) -> ET.Element | None:
    for child in list(elem):
        if name is not None and child.get("name") != name:
            continue
        if tag is not None and child.tag != tag:
            continue
        return child
    return None


def find_named(elem: ET.Element, name: str) -> ET.Element | None:
    for child in elem.iter():
        if child.get("name") == name:
            return child
    return None


def int_child(elem: ET.Element, name: str, default: int = 0) -> int:
    child = direct(elem, name)
    if child is None:
        child = find_named(elem, name)
    try:
        return int(text(child), 0)
    except ValueError:
        return default


def float_child(elem: ET.Element, name: str, default: float = 0.0) -> float:
    child = direct(elem, name)
    if child is None:
        child = find_named(elem, name)
    try:
        return float(text(child))
    except ValueError:
        return default


def rid_child(elem: ET.Element, name: str) -> str | None:
    child = direct(elem, name, "ResourceId")
    if child is None:
        child = find_named(elem, name)
    value = text(child)
    return None if value in ("", "0") else value


def array_resource_ids(elem: ET.Element, name: str) -> list[str | None]:
    arr = direct(elem, name, "array")
    if arr is None:
        return []
    out: list[str | None] = []
    for child in list(arr):
        value = text(child)
        out.append(None if value in ("", "0") else value)
    return out


def buffer_ref(elem: ET.Element, name: str | None = None) -> tuple[int | None, int | None]:
    for child in elem.iter("buffer"):
        if name is not None and child.get("name") != name:
            continue
        raw = text(child)
        try:
            index = int(raw)
        except ValueError:
            index = None
        byte_length = child.get("byteLength")
        return index, int(byte_length) if byte_length and byte_length.isdigit() else None
    return None, None


def enum_value(elem: ET.Element | None) -> str | None:
    if elem is None:
        return None
    return elem.get("string") or text(elem) or None


def xml_value(elem: ET.Element) -> Any:
    if len(list(elem)) == 0:
        raw = text(elem)
        if elem.tag == "bool":
            return raw.lower() == "true"
        if elem.tag in ("uint", "int"):
            try:
                return int(raw, 0)
            except ValueError:
                return raw
        if elem.tag == "float":
            try:
                return float(raw)
            except ValueError:
                return raw
        if elem.tag == "enum":
            return elem.get("string") or raw
        return raw
    values: dict[str, Any] = {}
    for child in list(elem):
        key = child.get("name") or child.get("typename") or child.tag
        child_value = xml_value(child)
        if key in values:
            existing = values[key]
            if not isinstance(existing, list):
                values[key] = [existing]
            values[key].append(child_value)
        else:
            values[key] = child_value
    return values


class BlobStore:
    def __init__(self, capture_dir: Path) -> None:
        self.capture_dir = capture_dir
        self.blob_dir = capture_dir / "blobs"
        self.zip_path = capture_dir / "frame.zip"
        self._zip: zipfile.ZipFile | None = None

    def close(self) -> None:
        if self._zip is not None:
            self._zip.close()
            self._zip = None

    @property
    def zip(self) -> zipfile.ZipFile | None:
        if self._zip is None and self.zip_path.is_file():
            self._zip = zipfile.ZipFile(self.zip_path)
        return self._zip

    def open_xml(self) -> BinaryIO:
        xml_path = self.capture_dir / "frame.zip.xml"
        if xml_path.is_file():
            return xml_path.open("rb")
        archive = self.zip
        if archive is not None:
            for name in archive.namelist():
                if name.endswith(".xml"):
                    return archive.open(name)
        raise FileNotFoundError(f"no frame.zip.xml found in {self.capture_dir}")

    def read_blob(self, index: int | None) -> bytes:
        if index is None:
            return b""
        name = f"{index:06d}"
        disk_path = self.blob_dir / name
        if disk_path.is_file():
            return disk_path.read_bytes()
        archive = self.zip
        if archive is not None:
            try:
                return archive.read(name)
            except KeyError:
                pass
        return b""


def parse_signature(data: bytes, fourcc: str) -> list[dict[str, Any]]:
    if len(data) < 8:
        return []
    count = u32(data, 0)
    prefer = (28, 24) if fourcc.endswith("1") else (24, 28)
    stride = prefer[-1]
    for candidate in prefer:
        if 8 + count * candidate <= len(data):
            offsets = []
            for i in range(count):
                rec_off = 8 + i * candidate
                name_off = u32(data, rec_off + (4 if candidate >= 28 else 0))
                offsets.append(name_off)
            if all(valid_cstr(data, offset) for offset in offsets):
                stride = candidate
                break

    out: list[dict[str, Any]] = []
    for i in range(count):
        rec_off = 8 + i * stride
        if rec_off + stride > len(data):
            break
        if stride >= 28:
            stream, name_off, semantic_index, system_value, component_type, register, packed = struct.unpack_from("<IIIIIII", data, rec_off)
        else:
            stream = None
            name_off, semantic_index, system_value, component_type, register, packed = struct.unpack_from("<IIIIII", data, rec_off)
        out.append({
            "semanticName": cstr(data, name_off),
            "semanticIndex": semantic_index,
            "stream": stream,
            "systemValueType": system_value,
            "componentType": COMPONENT_TYPES.get(component_type, str(component_type)),
            "register": register,
            "mask": packed & 0xFF,
            "readWriteMask": (packed >> 8) & 0xFF,
        })
    return out


def choose_resource_stride(data: bytes, offset: int, count: int) -> int:
    for stride in (32, 40, 48):
        if offset + count * stride > len(data):
            continue
        if all(valid_cstr(data, u32(data, offset + i * stride)) for i in range(count)):
            return stride
    return 32


def choose_variable_stride(data: bytes, offset: int, count: int) -> int:
    for stride in (40, 24):
        if offset + count * stride > len(data):
            continue
        if all(valid_cstr(data, u32(data, offset + i * stride)) for i in range(count)):
            return stride
    return 40


def parse_type_desc(data: bytes, offset: int) -> dict[str, Any]:
    if offset <= 0 or offset + 12 > len(data):
        return {"class": None, "type": None, "rows": None, "cols": None, "elements": None}
    class_id, type_id, rows, cols, elements, members = struct.unpack_from("<HHHHHH", data, offset)
    return {
        "class": SHADER_VARIABLE_CLASSES.get(class_id, str(class_id)),
        "type": SHADER_VARIABLE_TYPES.get(type_id, str(type_id)),
        "rows": rows,
        "cols": cols,
        "elements": elements or None,
        "members": members or None,
    }


def parse_rdef(data: bytes) -> dict[str, Any]:
    if len(data) < 28:
        return {"constantBuffers": [], "resourceBindings": [], "creator": ""}
    cb_count, cb_offset, binding_count, binding_offset, shader_version, flags, creator_offset = struct.unpack_from("<IIIIIII", data, 0)
    binding_stride = choose_resource_stride(data, binding_offset, binding_count)

    bindings: list[dict[str, Any]] = []
    for i in range(binding_count):
        rec_off = binding_offset + i * binding_stride
        if rec_off + 32 > len(data):
            break
        name_off, type_id, return_type, dimension, sample_count, bind_point, bind_count, bind_flags = struct.unpack_from("<IIIIIIII", data, rec_off)
        extra: list[int] = []
        if binding_stride > 32 and rec_off + binding_stride <= len(data):
            extra = list(struct.unpack_from("<" + "I" * ((binding_stride - 32) // 4), data, rec_off + 32))
        bindings.append({
            "name": cstr(data, name_off),
            "type": RESOURCE_BIND_TYPES.get(type_id, str(type_id)),
            "returnType": return_type,
            "dimension": dimension,
            "sampleCount": sample_count,
            "bindPoint": bind_point,
            "bindCount": bind_count,
            "flags": bind_flags,
            "extra": extra,
        })

    binding_by_name = {b["name"]: b for b in bindings}
    cbuffers: list[dict[str, Any]] = []
    for i in range(cb_count):
        rec_off = cb_offset + i * 24
        if rec_off + 24 > len(data):
            break
        name_off, var_count, var_offset, size, cb_flags, cb_type = struct.unpack_from("<IIIIII", data, rec_off)
        name = cstr(data, name_off)
        var_stride = choose_variable_stride(data, var_offset, var_count)
        variables: list[dict[str, Any]] = []
        for j in range(var_count):
            var_off = var_offset + j * var_stride
            if var_off + 24 > len(data):
                break
            fields = list(struct.unpack_from("<IIIIII", data, var_off))
            start_texture = texture_size = start_sampler = sampler_size = None
            if var_stride >= 40 and var_off + 40 <= len(data):
                fields = list(struct.unpack_from("<IIIIIIIIII", data, var_off))
                start_texture, texture_size, start_sampler, sampler_size = fields[6], fields[7], fields[8], fields[9]
            var_name_off, start_offset, var_size, var_flags, type_offset, default_offset = fields[:6]
            type_desc = parse_type_desc(data, type_offset)
            variable = {
                "name": cstr(data, var_name_off),
                "startOffset": start_offset,
                "size": var_size,
                "flags": var_flags,
                "type": type_desc,
            }
            if default_offset not in (0, 0xFFFFFFFF):
                variable["defaultValueOffset"] = default_offset
            if start_texture not in (None, 0xFFFFFFFF):
                variable["startTexture"] = start_texture
                variable["textureSize"] = texture_size
            if start_sampler not in (None, 0xFFFFFFFF):
                variable["startSampler"] = start_sampler
                variable["samplerSize"] = sampler_size
            variables.append(variable)
        binding = binding_by_name.get(name, {})
        cbuffers.append({
            "name": name,
            "size": size,
            "flags": cb_flags,
            "type": cb_type,
            "bindPoint": binding.get("bindPoint", i),
            "bindCount": binding.get("bindCount", 1),
            "variables": variables,
        })
    return {
        "constantBuffers": cbuffers,
        "resourceBindings": bindings,
        "shaderVersion": shader_version,
        "flags": flags,
        "creator": cstr(data, creator_offset),
    }


def parse_dxbc(data: bytes) -> dict[str, Any]:
    if len(data) < 32 or data[:4] != b"DXBC":
        return {
            "valid": False,
            "sha256": sha256_bytes(data),
            "chunks": [],
            "rdef": {"constantBuffers": [], "resourceBindings": [], "creator": ""},
            "signatures": {},
        }
    try:
        version, total_size, chunk_count = struct.unpack_from("<III", data, 20)
        if 32 + 4 * chunk_count > len(data):
            raise struct.error("DXBC chunk table exceeds blob length")
        chunk_offsets = struct.unpack_from("<" + "I" * chunk_count, data, 32)
    except struct.error:
        return {
            "valid": False,
            "sha256": sha256_bytes(data),
            "chunks": [],
            "rdef": {"constantBuffers": [], "resourceBindings": [], "creator": ""},
            "signatures": {},
        }
    chunks: list[dict[str, Any]] = []
    signatures: dict[str, list[dict[str, Any]]] = {}
    rdef = {"constantBuffers": [], "resourceBindings": [], "creator": ""}
    shex_payload = b""
    for offset in chunk_offsets:
        if offset + 8 > len(data):
            continue
        fourcc = data[offset:offset + 4].decode("ascii", errors="replace")
        size = u32(data, offset + 4)
        payload = data[offset + 8: offset + 8 + size]
        chunks.append({"fourcc": fourcc, "offset": offset, "size": size})
        if fourcc == "RDEF":
            rdef = parse_rdef(payload)
        elif fourcc in SIGNATURE_CHUNKS:
            signatures[fourcc] = parse_signature(payload, fourcc)
        elif fourcc in ("SHEX", "SHDR"):
            shex_payload = payload
    stable_payload = shex_payload or data
    return {
        "valid": True,
        "version": version,
        "totalSize": total_size,
        "sha256": sha256_bytes(data),
        "stableShaderSha256": sha256_bytes(stable_payload),
        "chunks": chunks,
        "rdef": rdef,
        "signatures": signatures,
    }


@dataclass
class ShaderRecord:
    stage: str
    resource_id: str
    blob_index: int
    shader_id: str
    dxbc: dict[str, Any]


@dataclass
class TraceState:
    vertex_shader: str | None = None
    fragment_shader: str | None = None
    topology: str | None = None
    input_layout: str | None = None
    vertex_buffers: dict[int, str] = field(default_factory=dict)
    index_buffer: str | None = None
    render_targets: list[str | None] = field(default_factory=list)
    depth_target: str | None = None
    viewport: list[float] = field(default_factory=list)
    blend_state: str | None = None
    constant_buffers: dict[str, dict[int, str]] = field(default_factory=lambda: {"vertex": {}, "fragment": {}})
    shader_resources: dict[str, dict[int, str]] = field(default_factory=lambda: {"vertex": {}, "fragment": {}})
    samplers: dict[str, dict[int, str]] = field(default_factory=lambda: {"vertex": {}, "fragment": {}})


@dataclass
class PendingMap:
    resource_id: str
    subresource: int
    map_type: int
    map_type_label: str | None


class CaptureParser:
    def __init__(self, capture_dir: Path, out_dir: Path, scene_id: str, project_json: str, wpe_version: str) -> None:
        self.capture_dir = capture_dir
        self.out_dir = out_dir
        self.scene_id = scene_id
        self.project_json = project_json
        self.wpe_version = wpe_version
        self.blobs = BlobStore(capture_dir)
        self.state = TraceState()

        self.textures: dict[str, dict[str, Any]] = {}
        self.buffers: dict[str, dict[str, Any]] = {}
        self.buffer_data: dict[str, bytes] = {}
        self.buffer_backing: dict[str, bytearray] = {}
        self.pending_maps: dict[tuple[str, int], PendingMap] = {}
        self.rtv_to_texture: dict[str, str] = {}
        self.srv_to_texture: dict[str, str] = {}
        self.dsv_to_texture: dict[str, str] = {}
        self.samplers: dict[str, dict[str, Any]] = {}
        self.blend_states: dict[str, dict[str, Any]] = {}
        self.shaders_by_resource: dict[str, ShaderRecord] = {}
        self.shader_interfaces: dict[str, ShaderRecord] = {}

        self.resources: dict[str, dict[str, Any]] = {
            "textures": {},
            "renderTargets": {},
            "buffers": {},
            "shaders": {},
        }
        self.passes: list[dict[str, Any]] = []

    def close(self) -> None:
        self.blobs.close()

    def texture_key(self, rid: str) -> str:
        return f"tex-{rid}"

    def rt_key(self, rid: str) -> str:
        return f"rt-{rid}"

    def buffer_key(self, rid: str) -> str:
        return f"buf-{rid}"

    def record_texture_resource(self, texture_rid: str | None) -> str | None:
        if texture_rid is None:
            return None
        key = self.texture_key(texture_rid)
        desc = self.textures.get(texture_rid, {})
        self.resources["textures"].setdefault(key, {
            "label": desc.get("label") or f"Texture {texture_rid}",
            "sourcePath": None,
            "width": desc.get("width"),
            "height": desc.get("height"),
            "format": desc.get("format"),
            "mips": desc.get("mips"),
            "sha256": None,
            "png": None,
        })
        return key

    def record_render_target_resource(self, view_rid: str | None, ordinal: int) -> str | None:
        if view_rid is None:
            return None
        texture_rid = self.rtv_to_texture.get(view_rid) or self.dsv_to_texture.get(view_rid) or view_rid
        desc = self.textures.get(texture_rid, {})
        key = self.rt_key(texture_rid)
        entry = self.resources["renderTargets"].setdefault(key, {
            "label": desc.get("label") or f"RT {texture_rid}",
            "width": desc.get("width"),
            "height": desc.get("height"),
            "format": desc.get("format"),
            "lineage": [],
        })
        marker = f"pass-{ordinal:04d}"
        if marker not in entry["lineage"]:
            entry["lineage"].append(marker)
        return key

    def record_buffer_resource(self, rid: str | None) -> str | None:
        if rid is None:
            return None
        key = self.buffer_key(rid)
        desc = self.buffers.get(rid, {})
        data = self.buffer_data.get(rid, b"")
        byte_length = desc.get("byteLength") or len(data) or None
        entry = self.resources["buffers"].setdefault(key, {
            "label": desc.get("label") or f"Buffer {rid}",
            "byteLength": byte_length,
            "sha256": None,
        })
        entry["byteLength"] = byte_length
        entry["sha256"] = sha256_bytes(data) if data else None
        return key

    def shader_id_for_resource(self, rid: str | None) -> str | None:
        if rid is None:
            return None
        record = self.shaders_by_resource.get(rid)
        return record.shader_id if record is not None else None

    def parse(self) -> dict[str, Any]:
        with self.blobs.open_xml() as xml_stream:
            for _, elem in ET.iterparse(xml_stream, events=("end",)):
                if elem.tag == "chunk":
                    self.handle_chunk(elem)
                    elem.clear()
        trace = self.build_trace()
        write_json(self.out_dir / "trace.json", trace)
        write_text(self.out_dir / "shader-interface.md", self.shader_interface_markdown())
        return trace

    def handle_chunk(self, chunk: ET.Element) -> None:
        name = chunk.get("name") or ""
        if name == "IDXGISwapChain::GetBuffer":
            self.handle_swapchain_get_buffer(chunk)
        elif name == "ID3D11Device::CreateTexture2D":
            self.handle_create_texture2d(chunk)
        elif name == "ID3D11Device::CreateBuffer":
            self.handle_create_buffer(chunk)
        elif name == "ID3D11Device::CreateRenderTargetView":
            self.rtv_to_texture[rid_child(chunk, "pView") or ""] = rid_child(chunk, "pResource") or ""
        elif name == "ID3D11Device::CreateDepthStencilView":
            self.dsv_to_texture[rid_child(chunk, "pView") or ""] = rid_child(chunk, "pResource") or ""
        elif name == "ID3D11Device::CreateShaderResourceView":
            self.srv_to_texture[rid_child(chunk, "pView") or ""] = rid_child(chunk, "pResource") or ""
        elif name == "ID3D11Device::CreateSamplerState":
            desc = direct(chunk, "Descriptor")
            self.samplers[rid_child(chunk, "pSamplerState") or rid_child(chunk, "pState") or ""] = xml_value(desc if desc is not None else chunk)
        elif name == "ID3D11Device::CreateBlendState":
            desc = direct(chunk, "Descriptor")
            self.blend_states[rid_child(chunk, "pState") or ""] = xml_value(desc if desc is not None else chunk)
        elif name == "ID3D11Device::CreateVertexShader":
            self.handle_create_shader(chunk, "vertex")
        elif name == "ID3D11Device::CreatePixelShader":
            self.handle_create_shader(chunk, "fragment")
        elif name == "ID3D11DeviceContext::VSSetShader":
            self.state.vertex_shader = rid_child(chunk, "pVertexShader") or rid_child(chunk, "pShader")
        elif name == "ID3D11DeviceContext::PSSetShader":
            self.state.fragment_shader = rid_child(chunk, "pPixelShader") or rid_child(chunk, "pShader")
        elif name == "ID3D11DeviceContext::IASetPrimitiveTopology":
            self.state.topology = enum_value(direct(chunk, "Topology"))
        elif name == "ID3D11DeviceContext::IASetInputLayout":
            self.state.input_layout = rid_child(chunk, "pInputLayout")
        elif name == "ID3D11DeviceContext::IASetVertexBuffers":
            self.handle_set_vertex_buffers(chunk)
        elif name == "ID3D11DeviceContext::IASetIndexBuffer":
            self.state.index_buffer = rid_child(chunk, "pIndexBuffer")
        elif name == "ID3D11DeviceContext::RSSetViewports":
            self.handle_set_viewports(chunk)
        elif name == "ID3D11DeviceContext::OMSetBlendState":
            self.state.blend_state = rid_child(chunk, "pBlendState")
        elif name == "ID3D11DeviceContext::OMSetRenderTargets":
            self.state.render_targets = array_resource_ids(chunk, "ppRenderTargetViews")
            self.state.depth_target = rid_child(chunk, "pDepthStencilView")
        elif name in ("ID3D11DeviceContext::VSSetConstantBuffers", "ID3D11DeviceContext::PSSetConstantBuffers"):
            self.handle_set_constant_buffers(chunk, "vertex" if "::VS" in name else "fragment")
        elif name in ("ID3D11DeviceContext::VSSetShaderResources", "ID3D11DeviceContext::PSSetShaderResources"):
            self.handle_set_shader_resources(chunk, "vertex" if "::VS" in name else "fragment")
        elif name in ("ID3D11DeviceContext::VSSetSamplers", "ID3D11DeviceContext::PSSetSamplers"):
            self.handle_set_samplers(chunk, "vertex" if "::VS" in name else "fragment")
        elif name == "ID3D11DeviceContext::Map":
            self.handle_map(chunk)
        elif name == "ID3D11DeviceContext::Unmap":
            self.handle_unmap(chunk)
        elif name in ("ID3D11DeviceContext::UpdateSubresource", "ID3D11DeviceContext::UpdateSubresource1"):
            self.handle_update_subresource(chunk)
        elif name == "ID3D11DeviceContext::DrawIndexed":
            self.emit_draw(chunk, indexed=True)
        elif name == "ID3D11DeviceContext::Draw":
            self.emit_draw(chunk, indexed=False)

    def handle_swapchain_get_buffer(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "SwapbufferID")
        desc = direct(chunk, "BackbufferDescriptor")
        if rid is None or desc is None:
            return
        self.textures[rid] = {
            "label": "Swap Chain Backbuffer",
            "width": int_child(desc, "Width"),
            "height": int_child(desc, "Height"),
            "mips": 1,
            "format": enum_value(find_named(desc, "Format")),
        }

    def handle_create_texture2d(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "pTexture")
        desc = direct(chunk, "Descriptor")
        if rid is None or desc is None:
            return
        self.textures[rid] = {
            "label": f"Texture2D {rid}",
            "width": int_child(desc, "Width"),
            "height": int_child(desc, "Height"),
            "mips": int_child(desc, "MipLevels", 1),
            "format": enum_value(find_named(desc, "Format")),
            "bindFlags": enum_value(find_named(desc, "BindFlags")),
        }

    def handle_create_buffer(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "pBuffer")
        desc = direct(chunk, "pDesc")
        if rid is None:
            return
        byte_width = int_child(desc, "ByteWidth") if desc is not None else 0
        bind_flags = enum_value(find_named(desc, "BindFlags")) if desc is not None else None
        self.buffers[rid] = {
            "label": f"Buffer {rid}",
            "byteLength": byte_width or None,
            "bindFlags": bind_flags,
        }
        blob_index, _ = buffer_ref(chunk, "InitialData")
        self.ensure_buffer_backing(rid, byte_width)
        data = self.blobs.read_blob(blob_index)
        if data:
            self.write_buffer_data(rid, data, offset=0, discard=True)
        else:
            self.publish_buffer_data(rid)

    def buffer_byte_width(self, rid: str) -> int:
        desc = self.buffers.get(rid, {})
        width = desc.get("byteLength")
        if isinstance(width, int) and width > 0:
            return width
        return max(len(self.buffer_backing.get(rid, b"")), len(self.buffer_data.get(rid, b"")))

    def ensure_buffer_backing(self, rid: str, min_size: int = 0) -> bytearray:
        size = max(min_size, self.buffer_byte_width(rid))
        backing = self.buffer_backing.get(rid)
        if backing is None:
            old = self.buffer_data.get(rid, b"")
            size = max(size, len(old))
            backing = bytearray(size)
            backing[:min(len(old), size)] = old[:size]
            self.buffer_backing[rid] = backing
        elif len(backing) < size:
            backing.extend(b"\x00" * (size - len(backing)))
        return backing

    def publish_buffer_data(self, rid: str) -> None:
        backing = self.buffer_backing.get(rid)
        if backing is not None:
            self.buffer_data[rid] = bytes(backing)

    def write_buffer_data(self, rid: str, data: bytes, offset: int = 0, discard: bool = False) -> None:
        if not rid:
            return
        offset = max(offset, 0)
        byte_width = self.buffer_byte_width(rid)
        needed = max(byte_width, offset + len(data))
        if discard:
            self.buffer_backing[rid] = bytearray(needed)
        backing = self.ensure_buffer_backing(rid, needed)
        backing[offset:offset + len(data)] = data
        self.publish_buffer_data(rid)

    def handle_map(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "pResource")
        if rid is None:
            return
        subresource = int_child(chunk, "Subresource")
        map_type = int_child(chunk, "MapType")
        self.pending_maps[(rid, subresource)] = PendingMap(
            resource_id=rid,
            subresource=subresource,
            map_type=map_type,
            map_type_label=enum_value(direct(chunk, "MapType")),
        )

    def handle_create_shader(self, chunk: ET.Element, stage: str) -> None:
        rid = rid_child(chunk, "pShader")
        blob_index, _ = buffer_ref(chunk, "pShaderBytecode")
        if rid is None or blob_index is None:
            return
        data = self.blobs.read_blob(blob_index)
        dxbc = parse_dxbc(data)
        stable = dxbc.get("stableShaderSha256") or dxbc.get("sha256") or sha256_bytes(data)
        shader_id = f"shader-{'vs' if stage == 'vertex' else 'fs'}-{stable[:16]}"
        record = ShaderRecord(stage=stage, resource_id=rid, blob_index=blob_index, shader_id=shader_id, dxbc=dxbc)
        self.shaders_by_resource[rid] = record
        self.shader_interfaces[shader_id] = record
        rdef = dxbc.get("rdef", {})
        bindings = rdef.get("resourceBindings", [])
        cbuffers = rdef.get("constantBuffers", [])
        reflection = {
            "samplers": [binding_md(b) for b in bindings if b.get("type") == "SAMPLER"],
            "textures": [binding_md(b) for b in bindings if b.get("type") == "TEXTURE"],
            "constantBlocks": [binding_md(b) for b in bindings if b.get("type") == "CBUFFER"],
            "uniforms": [variable_schema(v) for cb in cbuffers for v in cb.get("variables", [])],
            "inputSignature": first_signature(dxbc, ("ISGN", "ISG1", "ISG5")),
            "outputSignature": first_signature(dxbc, ("OSGN", "OSG1", "OSG5")),
            "dxbcChunks": dxbc.get("chunks", []),
            "creator": rdef.get("creator", ""),
        }
        self.resources["shaders"][shader_id] = {
            "stage": stage,
            "sourceLanguage": "DXBC",
            "entryPoint": None,
            "sourcePath": f"blobs/{blob_index:06d}",
            "sourceSha256": dxbc.get("sha256"),
            "disassembly": {
                "path": None,
                "sha256": stable,
            },
            "reflection": reflection,
            "renderdocResourceId": rid,
        }

    def handle_set_vertex_buffers(self, chunk: ET.Element) -> None:
        start = int_child(chunk, "StartSlot")
        buffers = array_resource_ids(chunk, "ppVertexBuffers")
        for i, rid in enumerate(buffers):
            if rid is None:
                self.state.vertex_buffers.pop(start + i, None)
            else:
                self.state.vertex_buffers[start + i] = rid

    def handle_set_viewports(self, chunk: ET.Element) -> None:
        arr = direct(chunk, "pViewports", "array")
        if arr is None or not list(arr):
            self.state.viewport = []
            return
        vp = list(arr)[0]
        self.state.viewport = [
            float_child(vp, "TopLeftX"),
            float_child(vp, "TopLeftY"),
            float_child(vp, "Width"),
            float_child(vp, "Height"),
            float_child(vp, "MinDepth"),
            float_child(vp, "MaxDepth"),
        ]

    def handle_set_constant_buffers(self, chunk: ET.Element, stage: str) -> None:
        start = int_child(chunk, "StartSlot")
        buffers = array_resource_ids(chunk, "ppConstantBuffers")
        for i, rid in enumerate(buffers):
            slot = start + i
            if rid is None:
                self.state.constant_buffers[stage].pop(slot, None)
            else:
                self.state.constant_buffers[stage][slot] = rid

    def handle_set_shader_resources(self, chunk: ET.Element, stage: str) -> None:
        start = int_child(chunk, "StartSlot")
        srvs = array_resource_ids(chunk, "ppShaderResourceViews")
        for i, rid in enumerate(srvs):
            slot = start + i
            if rid is None:
                self.state.shader_resources[stage].pop(slot, None)
            else:
                self.state.shader_resources[stage][slot] = rid

    def handle_set_samplers(self, chunk: ET.Element, stage: str) -> None:
        start = int_child(chunk, "StartSlot")
        samplers = array_resource_ids(chunk, "ppSamplers")
        for i, rid in enumerate(samplers):
            slot = start + i
            if rid is None:
                self.state.samplers[stage].pop(slot, None)
            else:
                self.state.samplers[stage][slot] = rid

    def handle_unmap(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "pResource")
        if rid is None:
            return
        subresource = int_child(chunk, "Subresource")
        pending = self.pending_maps.pop((rid, subresource), None)
        map_type = int_child(chunk, "MapType", pending.map_type if pending is not None else 0)
        start = int_child(chunk, "Byte offset to start of written data")
        end = int_child(chunk, "Byte offset to end of written data")
        blob_index, byte_length = buffer_ref(chunk, "MapWrittenData")
        data = self.blobs.read_blob(blob_index)
        if not data:
            return
        expected = max(end - start, 0)
        if expected and len(data) > expected:
            data = data[:expected]
        elif byte_length is not None and byte_length > 0 and len(data) > byte_length:
            data = data[:byte_length]
        discard = map_type == D3D11_MAP_WRITE_DISCARD
        self.write_buffer_data(rid, data, offset=start, discard=discard)
        self.record_buffer_resource(rid)

    def handle_update_subresource(self, chunk: ET.Element) -> None:
        rid = rid_child(chunk, "pDstResource")
        if rid is None:
            return
        offset, limit = self.update_subresource_range(chunk)
        blob_index, byte_length = buffer_ref(chunk, "pSrcData")
        data = self.blobs.read_blob(blob_index)
        if not data:
            return
        if limit is not None and limit >= offset:
            data = data[:limit - offset]
        elif byte_length is not None and byte_length > 0 and len(data) > byte_length:
            data = data[:byte_length]
        self.write_buffer_data(rid, data, offset=offset, discard=False)
        self.record_buffer_resource(rid)

    def update_subresource_range(self, chunk: ET.Element) -> tuple[int, int | None]:
        box = direct(chunk, "pDstBox") or direct(chunk, "DstBox")
        if box is None:
            return 0, None
        left = int_child(box, "left", int_child(box, "Left"))
        right = int_child(box, "right", int_child(box, "Right", -1))
        if right < left:
            right = None
        return max(left, 0), right

    def emit_draw(self, chunk: ET.Element, indexed: bool) -> None:
        ordinal = len(self.passes)
        event_id = int(chunk.get("chunkIndex") or chunk.get("id") or ordinal)
        color_targets: list[dict[str, Any]] = []
        for slot, view_rid in enumerate(self.state.render_targets):
            rt_key = self.record_render_target_resource(view_rid, ordinal)
            if rt_key is None:
                continue
            color_targets.append({
                "slot": slot,
                "resource": rt_key,
                "load": None,
                "store": None,
                "renderdocView": view_rid,
            })
        depth = None
        if self.state.depth_target:
            depth_key = self.record_render_target_resource(self.state.depth_target, ordinal)
            if depth_key:
                depth = {
                    "resource": depth_key,
                    "load": None,
                    "store": None,
                    "renderdocView": self.state.depth_target,
                }

        output_resource = color_targets[0]["resource"] if color_targets else None
        pass_record = {
            "ordinal": ordinal,
            "eventId": event_id,
            "layerId": None,
            "passId": None,
            "shaderName": None,
            "draw": self.draw_record(chunk, indexed),
            "targets": {
                "color": color_targets,
                "depth": depth,
            },
            "textures": self.texture_bindings_for_pass(),
            "shaders": {
                "vs": self.shader_id_for_resource(self.state.vertex_shader),
                "fs": self.shader_id_for_resource(self.state.fragment_shader),
            },
            "constantBuffers": self.constant_buffers_for_pass(),
            "state": {
                "blend": {
                    "resource": self.state.blend_state,
                    "descriptor": self.blend_states.get(self.state.blend_state or ""),
                },
                "depth": None,
                "raster": None,
                "samplers": self.samplers_for_pass(),
            },
            "output": {
                "resource": output_resource,
                "png": None,
                "sha256": None,
                "visualStats": {"note": "RenderDoc convert path has no replay readback; PNG intentionally unavailable."},
            },
        }
        self.passes.append(pass_record)

    def draw_record(self, chunk: ET.Element, indexed: bool) -> dict[str, Any]:
        if indexed:
            vertex_count = None
            index_count = int_child(chunk, "IndexCount")
            start = int_child(chunk, "StartIndexLocation")
        else:
            vertex_count = int_child(chunk, "VertexCount")
            index_count = None
            start = int_child(chunk, "StartVertexLocation")
        return {
            "topology": self.state.topology,
            "vertexCount": vertex_count,
            "indexCount": index_count,
            "instanceCount": 1,
            "viewport": self.state.viewport,
            "scissor": [],
            "start": start,
            "indexed": indexed,
        }

    def texture_bindings_for_pass(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for stage in ("vertex", "fragment"):
            shader = self.shader_for_stage(stage)
            bindings = shader.dxbc.get("rdef", {}).get("resourceBindings", []) if shader else []
            names_by_slot = {
                b.get("bindPoint"): b.get("name")
                for b in bindings
                if b.get("type") == "TEXTURE"
            }
            for slot, srv_rid in sorted(self.state.shader_resources[stage].items()):
                texture_rid = self.srv_to_texture.get(srv_rid, srv_rid)
                tex_key = self.record_texture_resource(texture_rid)
                if tex_key is None:
                    continue
                out.append({
                    "stage": stage,
                    "slot": slot,
                    "name": names_by_slot.get(slot),
                    "resource": tex_key,
                    "renderdocView": srv_rid,
                })
        return out

    def samplers_for_pass(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for stage in ("vertex", "fragment"):
            shader = self.shader_for_stage(stage)
            bindings = shader.dxbc.get("rdef", {}).get("resourceBindings", []) if shader else []
            names_by_slot = {
                b.get("bindPoint"): b.get("name")
                for b in bindings
                if b.get("type") == "SAMPLER"
            }
            for slot, sampler_rid in sorted(self.state.samplers[stage].items()):
                entry = {
                    "stage": stage,
                    "slot": slot,
                    "name": names_by_slot.get(slot),
                    "resource": sampler_rid,
                }
                descriptor = self.samplers.get(sampler_rid)
                if descriptor is not None:
                    entry["descriptor"] = descriptor
                out.append(entry)
        return out

    def shader_for_stage(self, stage: str) -> ShaderRecord | None:
        rid = self.state.vertex_shader if stage == "vertex" else self.state.fragment_shader
        return self.shaders_by_resource.get(rid or "")

    def constant_buffers_for_pass(self) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for stage in ("vertex", "fragment"):
            shader = self.shader_for_stage(stage)
            if shader is None:
                continue
            cbuffers = shader.dxbc.get("rdef", {}).get("constantBuffers", [])
            for cbuffer in cbuffers:
                slot = cbuffer.get("bindPoint")
                bound_rid = self.state.constant_buffers[stage].get(slot)
                data = self.buffer_data.get(bound_rid or "", b"")
                cb_vars = cbuffer.get("variables", [])
                # Defensive fallback: if a compiler emitted ALL-zero variable flags
                # (no D3D_SVF_USED on any), the used-gate would silently drop every
                # value — decode them all instead of returning an empty cbuffer.
                force_used = bool(cb_vars) and all((v.get("flags") or 0) == 0 for v in cb_vars)
                variables = [decode_variable_value(v, data, force_used=force_used) for v in cb_vars]
                out.append({
                    "name": cbuffer.get("name"),
                    "stage": stage,
                    "slot": slot,
                    "resource": self.record_buffer_resource(bound_rid),
                    "rawBytesSha256": sha256_bytes(data) if data else None,
                    "variables": variables,
                    "byteLength": len(data) if data else None,
                })
        return out

    def build_trace(self) -> dict[str, Any]:
        width, height = self.infer_resolution()
        final = {"resource": None, "png": None, "sha256": None}
        if self.passes:
            output = self.passes[-1]["output"]
            final = {"resource": output.get("resource"), "png": None, "sha256": None}
        return {
            "schema": SCHEMA_VERSION,
            "producer": {
                "side": "windows-wpe",
                "tool": "renderdoccmd convert",
                "toolVersion": None,
                "wpeVersion": self.wpe_version,
                "appBuild": None,
            },
            "scene": {
                "workshopId": self.scene_id,
                "projectJson": self.project_json,
                "projectJsonSha256": sha256_file(Path(self.project_json)) if self.project_json else None,
                "scenePkgSha256": sha256_file(Path(self.project_json).with_name("scene.pkg")) if self.project_json else None,
                "entryFile": "project.json",
                "assetRoots": [str(Path(self.project_json).parent)] if self.project_json else [],
            },
            "capture": {
                "jobId": self.capture_dir.parent.name if self.capture_dir.name == "windows" else self.capture_dir.name,
                "mode": "shader-first",
                "frameOrdinal": 0,
                "resolution": {"width": width, "height": height},
                "wallpaperWindow": {"class": "WorkerW", "hwnd": None, "pid": None},
                "determinism": {"time": None, "daytime": None, "pointer": [0.5, 0.5], "audioMode": "muted", "mouseParallax": "centered"},
            },
            "resources": self.resources,
            "passes": self.passes,
            "final": final,
        }

    def infer_resolution(self) -> tuple[int, int]:
        best = (1, 1)
        for tex in self.textures.values():
            width, height = tex.get("width") or 0, tex.get("height") or 0
            if width * height > best[0] * best[1]:
                best = (int(width), int(height))
        return best

    def shader_interface_markdown(self) -> str:
        lines = [
            "# WPE Shader Interface",
            "",
            f"Capture: `{self.capture_dir}`",
            "",
        ]
        for shader_id in sorted(self.shader_interfaces):
            record = self.shader_interfaces[shader_id]
            rdef = record.dxbc.get("rdef", {})
            sigs = record.dxbc.get("signatures", {})
            lines.extend([
                f"## {record.stage} `{shader_id}`",
                "",
                f"- RenderDoc resource: `{record.resource_id}`",
                f"- Blob: `blobs/{record.blob_index:06d}`",
                f"- SHA256: `{record.dxbc.get('stableShaderSha256') or record.dxbc.get('sha256')}`",
                f"- DXBC chunks: {', '.join(c['fourcc'] for c in record.dxbc.get('chunks', []))}",
                "",
                "### Resource Bindings",
                "",
                "| name | type | bindPoint | bindCount |",
                "| --- | --- | ---: | ---: |",
            ])
            for binding in rdef.get("resourceBindings", []):
                lines.append(f"| {binding.get('name','')} | {binding.get('type','')} | {binding.get('bindPoint','')} | {binding.get('bindCount','')} |")
            lines.extend(["", "### Constant Buffers", ""])
            for cb in rdef.get("constantBuffers", []):
                lines.extend([
                    f"#### `{cb.get('name')}` slot {cb.get('bindPoint')} size {cb.get('size')}",
                    "",
                    "| variable | offset | size | class | type | rows | cols | elements |",
                    "| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |",
                ])
                for var in cb.get("variables", []):
                    typ = var.get("type", {})
                    lines.append(
                        f"| {var.get('name','')} | {var.get('startOffset','')} | {var.get('size','')} | "
                        f"{typ.get('class','')} | {typ.get('type','')} | {typ.get('rows','')} | {typ.get('cols','')} | {typ.get('elements','')} |"
                    )
                lines.append("")
            for label, keys in (("Input Signature", ("ISGN", "ISG1", "ISG5")), ("Output Signature", ("OSGN", "OSG1", "OSG5")), ("Patch Constant Signature", ("PCSG",))):
                params = []
                for key in keys:
                    params = sigs.get(key) or []
                    if params:
                        break
                lines.extend([
                    f"### {label}",
                    "",
                    "| semantic | index | register | mask | component |",
                    "| --- | ---: | ---: | ---: | --- |",
                ])
                for param in params:
                    lines.append(
                        f"| {param.get('semanticName','')} | {param.get('semanticIndex','')} | "
                        f"{param.get('register','')} | {param.get('mask','')} | {param.get('componentType','')} |"
                    )
                lines.append("")
        return "\n".join(lines)


def binding_md(binding: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": binding.get("name", ""),
        "slot": binding.get("bindPoint"),
        "type": binding.get("type"),
        "bindCount": binding.get("bindCount"),
    }


def variable_schema(var: dict[str, Any]) -> dict[str, Any]:
    typ = var.get("type", {})
    flags = int(var.get("flags") or 0)
    return {
        "name": var.get("name", ""),
        "type": f"{typ.get('class')}<{typ.get('type')}>",
        "startOffset": var.get("startOffset"),
        "size": var.get("size"),
        "flags": flags,
        "usedByShader": bool(flags & D3D_SVF_USED),
        "rows": typ.get("rows"),
        "cols": typ.get("cols"),
        "elements": typ.get("elements"),
    }


def decode_variable_value(var: dict[str, Any], data: bytes, force_used: bool = False) -> dict[str, Any]:
    out = variable_schema(var)
    start = int(var.get("startOffset") or 0)
    size = int(var.get("size") or 0)
    raw = data[start:start + size] if start < len(data) else b""
    typ = var.get("type", {})
    rows = int(typ.get("rows") or 0)
    if not out["usedByShader"] and not force_used:
        out["valueStatus"] = "unused-reflection-slot"
        if raw:
            out["rawBytesSha256"] = sha256_bytes(raw)
        return out

    cols = int(typ.get("cols") or 0)
    elements = int(typ.get("elements") or 1)
    values = decode_scalar_values(raw, typ.get("type"))
    if values:
        out["value"] = values[0] if len(values) == 1 else values
        if rows == 4 and cols == 4 and len(values) >= 16:
            # WPE/HLSL constant-buffer matrices are column-major; expose the raw
            # 16 floats plus a row-major view for comparison against our
            # column-major Metal matrices.
            major = "row" if typ.get("class") == "matrix_rows" else "column"
            out["matrixMajor"] = major
            mats, row_major = [], []
            for i in range(max(1, elements)):
                chunk = values[i * 16:(i + 1) * 16]
                if len(chunk) < 16:
                    break
                m = [float(v) for v in chunk]
                mats.append(m)
                row_major.append(m if major == "row" else transpose_square4(m))
            if mats:
                out["matrix4x4"] = mats[0]
                out["matrix4x4RowMajor"] = row_major[0]
            if len(mats) > 1:
                out["matrix4x4Array"] = mats
                out["matrix4x4RowMajorArray"] = row_major
    if raw:
        out["rawBytesSha256"] = sha256_bytes(raw)
    return out


def decode_scalar_values(raw: bytes, value_type: str | None) -> list[float | int | bool]:
    if not raw:
        return []
    if value_type == "double":
        count = len(raw) // 8
        return list(struct.unpack_from("<" + "d" * count, raw, 0)) if count else []
    fmt = {"float": "f", "int": "i", "uint": "I", "bool": "I"}.get(value_type)
    if fmt is None:
        return list(raw)
    count = len(raw) // 4
    if not count:
        return []
    values = list(struct.unpack_from("<" + fmt * count, raw, 0))
    return [bool(v) for v in values] if value_type == "bool" else values


def transpose_square4(values: list[float | int | bool]) -> list[float]:
    return [float(values[c * 4 + r]) for r in range(4) for c in range(4)]


def first_signature(dxbc: dict[str, Any], keys: Iterable[str]) -> list[dict[str, Any]]:
    signatures = dxbc.get("signatures", {})
    for key in keys:
        params = signatures.get(key)
        if params:
            return params
    return []


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-dir", type=Path, required=True, help="Directory containing frame.zip.xml and blobs/ or frame.zip.")
    parser.add_argument("--out", type=Path, help="Output directory. Defaults to --capture-dir.")
    parser.add_argument("--scene-id", default="3526278753")
    parser.add_argument("--project-json", default="")
    parser.add_argument("--wpe-version", default=DEFAULT_WPE_VERSION)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    capture_dir = args.capture_dir
    out_dir = args.out or capture_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    parser = CaptureParser(
        capture_dir=capture_dir,
        out_dir=out_dir,
        scene_id=args.scene_id,
        project_json=args.project_json,
        wpe_version=args.wpe_version,
    )
    try:
        trace = parser.parse()
    finally:
        parser.close()
    print(f"wrote {out_dir / 'trace.json'} ({len(trace['passes'])} passes, {len(trace['resources']['shaders'])} shaders)")
    print(f"wrote {out_dir / 'shader-interface.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
