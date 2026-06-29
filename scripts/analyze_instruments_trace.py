#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


WORKSPACE = Path("/Users/taijial/Xcode/LiveWallpaper")
LIVEWALLPAPER_BINARY = "LiveWallpaper"
TOOL_BINARIES = {
    "libclang_rt.tsan_osx_dynamic.dylib",
    "MetalTools",
    "GPUToolsCapture",
    "libMTLHud.dylib",
    "libRPAC.dylib",
    "libBacktraceRecording.dylib",
    "libMainThreadChecker.dylib",
}


def parse_int(text: str | None) -> int | None:
    if text is None:
        return None
    value = text.strip()
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def raw(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, tuple):
        return value[0]
    if isinstance(value, dict):
        return value.get("raw")
    return None


def display(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, tuple):
        return value[1] or ("" if value[0] is None else str(value[0]))
    if isinstance(value, dict):
        return value.get("display") or value.get("name") or ""
    return str(value)


def frames(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        return value.get("frames", [])
    return []


class XMLRowReader:
    def __init__(self, path: Path):
        self.path = path
        self.id_map: dict[str, Any] = {}
        self.columns: list[str] = []
        self.schema_name = ""

    def parse_value(self, elem: ET.Element) -> Any:
        ref = elem.attrib.get("ref")
        if ref is not None:
            return self.id_map.get(ref)

        tag = elem.tag
        if tag == "sentinel":
            return None
        if tag == "binary":
            value = {
                "tag": tag,
                "name": elem.attrib.get("name", ""),
                "path": elem.attrib.get("path", ""),
                "display": elem.attrib.get("name", ""),
            }
        elif tag == "source":
            path_value = ""
            for child in list(elem):
                child_value = self.parse_value(child)
                if child.tag == "path":
                    path_value = display(child_value)
            value = {
                "tag": tag,
                "line": parse_int(elem.attrib.get("line")),
                "path": path_value,
                "display": f"{path_value}:{elem.attrib.get('line', '')}",
            }
        elif tag == "frame":
            binary_value: dict[str, Any] | None = None
            source_value: dict[str, Any] | None = None
            for child in list(elem):
                child_value = self.parse_value(child)
                if child.tag == "binary":
                    binary_value = child_value
                elif child.tag == "source":
                    source_value = child_value
            value = {
                "tag": tag,
                "name": elem.attrib.get("name", ""),
                "binary": (binary_value or {}).get("name", ""),
                "binary_path": (binary_value or {}).get("path", ""),
                "path": (source_value or {}).get("path", ""),
                "line": (source_value or {}).get("line"),
                "display": elem.attrib.get("name", ""),
            }
        elif tag == "backtrace":
            frame_values = []
            for child in list(elem):
                if child.tag == "frame":
                    fv = self.parse_value(child)
                    if fv:
                        frame_values.append(fv)
                else:
                    self.parse_value(child)
            value = {"tag": tag, "frames": frame_values, "display": f"{len(frame_values)} frames"}
        elif tag == "tagged-backtrace":
            frame_values: list[dict[str, Any]] = []
            for child in list(elem):
                child_value = self.parse_value(child)
                if child.tag == "backtrace" and child_value:
                    frame_values = child_value.get("frames", [])
            value = {
                "tag": tag,
                "frames": frame_values,
                "display": elem.attrib.get("fmt", ""),
            }
        else:
            for child in list(elem):
                self.parse_value(child)
            value = (
                parse_int(elem.text),
                elem.attrib.get("fmt") if elem.attrib.get("fmt") is not None else (elem.text or "").strip(),
                tag,
            )

        elem_id = elem.attrib.get("id")
        if elem_id is not None:
            self.id_map[elem_id] = value
        return value

    def rows(self) -> Iterable[dict[str, Any]]:
        context = ET.iterparse(self.path, events=("end",))
        for _, elem in context:
            if elem.tag == "schema":
                self.schema_name = elem.attrib.get("name", "")
                self.columns = [
                    (col.findtext("mnemonic") or f"col_{index}")
                    for index, col in enumerate(elem.findall("col"))
                ]
                elem.clear()
            elif elem.tag == "row":
                values = [self.parse_value(child) for child in list(elem)]
                yield {
                    self.columns[index] if index < len(self.columns) else f"extra_{index}": value
                    for index, value in enumerate(values)
                }
                elem.clear()


def pct(part: float, total: float) -> float:
    return (part / total * 100.0) if total else 0.0


def ms(ns: float | int | None) -> float:
    return (float(ns or 0) / 1_000_000.0)


def seconds(ns: float | int | None) -> float:
    return (float(ns or 0) / 1_000_000_000.0)


def short_counter(counter: Counter, limit: int = 15) -> list[dict[str, Any]]:
    return [{"name": name, "value": value} for name, value in counter.most_common(limit)]


def quantiles(values: list[int]) -> dict[str, float]:
    if not values:
        return {"min": 0, "p50": 0, "p95": 0, "max": 0, "avg": 0}
    ordered = sorted(values)

    def percentile(p: float) -> float:
        if len(ordered) == 1:
            return float(ordered[0])
        pos = (len(ordered) - 1) * p
        lo = math.floor(pos)
        hi = math.ceil(pos)
        if lo == hi:
            return float(ordered[lo])
        return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)

    return {
        "min": float(ordered[0]),
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "max": float(ordered[-1]),
        "avg": float(statistics.fmean(ordered)),
    }


def quantiles_ms(values: list[int]) -> dict[str, float]:
    return {key: ms(value) for key, value in quantiles(values).items()}


def function_label(frame: dict[str, Any] | None) -> str:
    if not frame:
        return "(no frame)"
    name = frame.get("name") or "(unknown)"
    path = frame.get("path") or ""
    line = frame.get("line")
    if path.startswith(str(WORKSPACE)):
        rel = Path(path).relative_to(WORKSPACE)
        return f"{name} ({rel}:{line})" if line else f"{name} ({rel})"
    binary = frame.get("binary") or ""
    return f"{name} [{binary}]" if binary else name


def is_app_frame(frame: dict[str, Any]) -> bool:
    return frame.get("binary") == LIVEWALLPAPER_BINARY or str(frame.get("path", "")).startswith(str(WORKSPACE))


def first_app_frame(stack: list[dict[str, Any]]) -> dict[str, Any] | None:
    for frame in stack:
        if is_app_frame(frame):
            return frame
    return None


def outermost_app_frame(stack: list[dict[str, Any]]) -> dict[str, Any] | None:
    for frame in reversed(stack):
        if is_app_frame(frame):
            return frame
    return None


def analyze_sample_file(xml_path: Path, unit_name: str) -> dict[str, Any]:
    reader = XMLRowReader(xml_path)
    total_weight = 0
    running_weight = 0
    row_count = 0
    by_state: Counter[str] = Counter()
    by_thread: Counter[str] = Counter()
    by_leaf_binary: Counter[str] = Counter()
    by_leaf_frame: Counter[str] = Counter()
    by_first_app: Counter[str] = Counter()
    by_outer_app: Counter[str] = Counter()
    by_app_pair: Counter[str] = Counter()
    by_app_source: Counter[str] = Counter()
    by_main_first_app: Counter[str] = Counter()
    tool_leaf_weight = 0
    no_stack_weight = 0
    main_total_weight = 0
    main_running_weight = 0

    for row in reader.rows():
        row_count += 1
        weight = raw(row.get("weight")) or 0
        total_weight += weight
        state = display(row.get("thread-state")) or "(unknown)"
        thread = display(row.get("thread")) or "(unknown)"
        by_state[state] += weight
        by_thread[thread] += weight
        if state == "Running":
            running_weight += weight
        if thread.startswith("Main Thread"):
            main_total_weight += weight
            if state == "Running":
                main_running_weight += weight

        stack = frames(row.get("stack"))
        if not stack:
            no_stack_weight += weight
            continue

        leaf = stack[0]
        leaf_binary = leaf.get("binary") or "(unknown)"
        by_leaf_binary[leaf_binary] += weight
        by_leaf_frame[function_label(leaf)] += weight
        if leaf_binary in TOOL_BINARIES:
            tool_leaf_weight += weight

        app_leaf = first_app_frame(stack)
        app_outer = outermost_app_frame(stack)
        if app_leaf:
            by_first_app[function_label(app_leaf)] += weight
            if thread.startswith("Main Thread"):
                by_main_first_app[function_label(app_leaf)] += weight
            source_path = app_leaf.get("path") or ""
            line = app_leaf.get("line")
            if source_path.startswith(str(WORKSPACE)):
                rel = Path(source_path).relative_to(WORKSPACE)
                by_app_source[f"{rel}:{line}"] += weight
        if app_outer:
            by_outer_app[function_label(app_outer)] += weight
        if app_leaf and app_outer:
            by_app_pair[f"{function_label(app_leaf)} <- {function_label(app_outer)}"] += weight

    def weighted(counter: Counter[str], limit: int = 20) -> list[dict[str, Any]]:
        return [
            {
                "name": name,
                "weight": value,
                "percent_total": pct(value, total_weight),
                "display_ms": ms(value) if unit_name == "ns" else None,
            }
            for name, value in counter.most_common(limit)
        ]

    return {
        "file": str(xml_path),
        "rows": row_count,
        "unit": unit_name,
        "total_weight": total_weight,
        "total_ms": ms(total_weight) if unit_name == "ns" else None,
        "running_weight": running_weight,
        "running_ms": ms(running_weight) if unit_name == "ns" else None,
        "main_total_weight": main_total_weight,
        "main_total_ms": ms(main_total_weight) if unit_name == "ns" else None,
        "main_running_weight": main_running_weight,
        "main_running_ms": ms(main_running_weight) if unit_name == "ns" else None,
        "tool_leaf_weight": tool_leaf_weight,
        "tool_leaf_percent": pct(tool_leaf_weight, total_weight),
        "no_stack_weight": no_stack_weight,
        "states": weighted(by_state, 10),
        "threads": weighted(by_thread, 12),
        "leaf_binaries": weighted(by_leaf_binary, 15),
        "leaf_frames": weighted(by_leaf_frame, 18),
        "first_app_frames": weighted(by_first_app, 25),
        "main_first_app_frames": weighted(by_main_first_app, 20),
        "outer_app_frames": weighted(by_outer_app, 12),
        "app_source_lines": weighted(by_app_source, 25),
        "app_pairs": weighted(by_app_pair, 15),
    }


def analyze_gpu_intervals(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    count = 0
    total_duration = 0
    total_latency = 0
    durations: list[int] = []
    latencies: list[int] = []
    by_process_duration: Counter[str] = Counter()
    by_channel_duration: Counter[str] = Counter()
    by_process_rows: Counter[str] = Counter()
    by_state_duration: Counter[str] = Counter()
    by_cmd_rows: Counter[str] = Counter()
    start_min: int | None = None
    end_max: int | None = None

    for row in reader.rows():
        count += 1
        start = raw(row.get("start"))
        duration = raw(row.get("duration")) or 0
        latency = raw(row.get("start-latency")) or 0
        process = display(row.get("process")) or "(unknown)"
        channel = display(row.get("channel-name")) or "(unknown)"
        state = display(row.get("state")) or "(unknown)"
        cmd = display(row.get("cmdbuffer-id")) or "(none)"

        total_duration += duration
        total_latency += latency
        durations.append(duration)
        latencies.append(latency)
        by_process_duration[process] += duration
        by_channel_duration[channel] += duration
        by_process_rows[process] += 1
        by_state_duration[state] += duration
        by_cmd_rows[cmd] += 1
        if start is not None:
            start_min = start if start_min is None else min(start_min, start)
            end_max = (start + duration) if end_max is None else max(end_max, start + duration)

    return {
        "file": str(path),
        "rows": count,
        "span_ms": ms((end_max or 0) - (start_min or 0)) if start_min is not None and end_max is not None else 0,
        "channel_time_ms": ms(total_duration),
        "duration_ms": quantiles_ms(durations),
        "start_latency_ms": quantiles_ms(latencies),
        "avg_start_latency_ms": ms(total_latency / count) if count else 0,
        "process_duration": [
            {"name": name, "duration_ms": ms(value), "percent": pct(value, total_duration)}
            for name, value in by_process_duration.most_common(12)
        ],
        "process_rows": short_counter(by_process_rows, 12),
        "channel_duration": [
            {"name": name, "duration_ms": ms(value), "percent": pct(value, total_duration)}
            for name, value in by_channel_duration.most_common(8)
        ],
        "state_duration": [
            {"name": name, "duration_ms": ms(value), "percent": pct(value, total_duration)}
            for name, value in by_state_duration.most_common(8)
        ],
        "unique_command_buffers": len(by_cmd_rows),
        "top_command_buffer_rows": short_counter(by_cmd_rows, 10),
    }


def analyze_gpu_state(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    count = 0
    start_min: int | None = None
    end_max: int | None = None
    by_state: Counter[str] = Counter()
    by_channels: Counter[str] = Counter()

    for row in reader.rows():
        count += 1
        start = raw(row.get("start"))
        duration = raw(row.get("duration")) or 0
        state = display(row.get("state")) or "(unknown)"
        channels = display(row.get("num-events")) or "0"
        by_state[state] += duration
        if state == "Active":
            by_channels[channels] += duration
        if start is not None:
            start_min = start if start_min is None else min(start_min, start)
            end_max = (start + duration) if end_max is None else max(end_max, start + duration)

    total_state = sum(by_state.values())
    return {
        "file": str(path),
        "rows": count,
        "span_ms": ms((end_max or 0) - (start_min or 0)) if start_min is not None and end_max is not None else 0,
        "state_ms": [
            {"name": name, "duration_ms": ms(value), "percent": pct(value, total_state)}
            for name, value in by_state.most_common()
        ],
        "active_percent": pct(by_state["Active"], total_state),
        "active_channel_ms": [
            {"channels": name, "duration_ms": ms(value), "percent_of_active": pct(value, by_state["Active"])}
            for name, value in by_channels.most_common()
        ],
    }


def analyze_command_buffers_completed(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    count = 0
    start_min: int | None = None
    end_max: int | None = None
    ids = set()
    for row in reader.rows():
        count += 1
        t = raw(row.get("timestamp"))
        ids.add(display(row.get("cmdbuffer-id")))
        if t is not None:
            start_min = t if start_min is None else min(start_min, t)
            end_max = t if end_max is None else max(end_max, t)
    span = (end_max or 0) - (start_min or 0) if start_min is not None and end_max is not None else 0
    return {
        "file": str(path),
        "rows": count,
        "unique_command_buffers": len(ids),
        "span_ms": ms(span),
        "completed_per_second": count / seconds(span) if span else 0,
    }


def analyze_frame_assignment(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    by_process_rows: Counter[str] = Counter()
    by_process_frames: dict[str, set[int]] = defaultdict(set)
    per_process_frame_rows: dict[str, Counter[int]] = defaultdict(Counter)
    per_process_frame_presents: dict[str, Counter[int]] = defaultdict(Counter)
    surface_counts: dict[str, Counter[str]] = defaultdict(Counter)
    present_surface_counts: Counter[str] = Counter()
    has_present_counts: Counter[str] = Counter()
    index_counts: dict[str, Counter[str]] = defaultdict(Counter)
    time_minmax: dict[str, list[int | None]] = defaultdict(lambda: [None, None])
    rows = 0

    for row in reader.rows():
        rows += 1
        process = display(row.get("process")) or "(unknown)"
        frame = raw(row.get("frame-number"))
        timestamp = raw(row.get("timestamp"))
        has_present = raw(row.get("has-present")) or 0
        surface = display(row.get("present-surface-id")) or "0x0"
        index = display(row.get("cmdbuffer-index")) or "0"

        by_process_rows[process] += 1
        if frame is not None:
            by_process_frames[process].add(frame)
            per_process_frame_rows[process][frame] += 1
            if has_present:
                per_process_frame_presents[process][frame] += 1
        if has_present:
            present_surface_counts[surface] += 1
            surface_counts[process][surface] += 1
        has_present_counts[f"{process}: {has_present}"] += 1
        index_counts[process][index] += 1
        if timestamp is not None:
            mm = time_minmax[process]
            mm[0] = timestamp if mm[0] is None else min(mm[0], timestamp)
            mm[1] = timestamp if mm[1] is None else max(mm[1], timestamp)

    process_summaries = []
    for process, row_count in by_process_rows.most_common():
        frame_rows = list(per_process_frame_rows[process].values())
        frame_presents = list(per_process_frame_presents[process].values())
        mm = time_minmax[process]
        span = (mm[1] or 0) - (mm[0] or 0) if mm[0] is not None and mm[1] is not None else 0
        frames_count = len(by_process_frames[process])
        process_summaries.append(
            {
                "process": process,
                "rows": row_count,
                "unique_frames": frames_count,
                "span_ms": ms(span),
                "approx_unique_frames_per_second": frames_count / seconds(span) if span else 0,
                "command_buffers_per_frame": quantiles(frame_rows),
                "present_events_per_frame": quantiles(frame_presents),
                "present_surfaces": short_counter(surface_counts[process], 12),
                "cmdbuffer_indices": short_counter(index_counts[process], 12),
            }
        )

    return {
        "file": str(path),
        "rows": rows,
        "processes": process_summaries,
        "present_surfaces": short_counter(present_surface_counts, 20),
        "has_present_counts": short_counter(has_present_counts, 20),
    }


def analyze_io_surface(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    rows = 0
    by_process: Counter[str] = Counter()
    by_surface: Counter[str] = Counter()
    by_format_size: Counter[str] = Counter()
    by_process_surface: Counter[str] = Counter()
    by_process_format_size_access: Counter[str] = Counter()

    for row in reader.rows():
        rows += 1
        process = display(row.get("process")) or "(unknown)"
        surface = display(row.get("surface-id")) or "0"
        fmt = display(row.get("pixel-format")) or "(unknown)"
        width = display(row.get("width")) or "0"
        height = display(row.get("height")) or "0"
        access = display(row.get("access-type")) or "0"
        by_process[process] += 1
        by_surface[surface] += 1
        by_format_size[f"{fmt} {width}x{height}"] += 1
        by_process_surface[f"{process} surface={surface}"] += 1
        by_process_format_size_access[f"{process} {fmt} {width}x{height} access={access}"] += 1

    return {
        "file": str(path),
        "rows": rows,
        "processes": short_counter(by_process, 12),
        "surfaces": short_counter(by_surface, 20),
        "formats_sizes": short_counter(by_format_size, 20),
        "process_surfaces": short_counter(by_process_surface, 20),
        "process_format_size_access": short_counter(by_process_format_size_access, 25),
    }


def analyze_runloop(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    starts: dict[tuple[str, str, str], int] = {}
    durations_by_type: dict[str, list[int]] = defaultdict(list)
    rows = 0
    main_rows = 0
    for row in reader.rows():
        rows += 1
        if raw(row.get("is-main")) != 1:
            continue
        main_rows += 1
        interval_type = display(row.get("interval-type")) or "(unknown)"
        identifier = display(row.get("interval-identifier")) or ""
        thread = display(row.get("thread")) or ""
        event_type = display(row.get("event-type")) or ""
        timestamp = raw(row.get("timestamp"))
        if timestamp is None:
            continue
        key = (thread, interval_type, identifier)
        if event_type == "START":
            starts[key] = timestamp
        elif event_type == "END":
            start = starts.pop(key, None)
            if start is not None and timestamp >= start:
                durations_by_type[interval_type].append(timestamp - start)

    return {
        "file": str(path),
        "rows": rows,
        "main_rows": main_rows,
        "durations_ms": {name: quantiles_ms(values) for name, values in durations_by_type.items()},
        "counts": {name: len(values) for name, values in durations_by_type.items()},
        "long_individual_iterations_ms": sorted(
            [ms(v) for v in durations_by_type.get("individual_iteration", [])],
            reverse=True,
        )[:12],
    }


def analyze_potential_hangs(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    rows = 0
    durations: list[int] = []
    by_thread: Counter[str] = Counter()
    for row in reader.rows():
        rows += 1
        duration = raw(row.get("duration"))
        if duration is not None:
            durations.append(duration)
        by_thread[display(row.get("thread"))] += 1
    return {
        "file": str(path),
        "rows": rows,
        "durations_ms": quantiles_ms(durations),
        "threads": short_counter(by_thread, 10),
    }


SIGNPOST_NAME_RE = re.compile(r"Name=\s*([^\s]+)")
SIGNPOST_TYPE_RE = re.compile(r"Type=\s*([^\s]+)")


def analyze_signposts(path: Path) -> dict[str, Any]:
    reader = XMLRowReader(path)
    rows = 0
    function_compiled = 0
    by_shader: Counter[str] = Counter()
    by_shader_type: Counter[str] = Counter()
    by_process: Counter[str] = Counter()
    function_compiled_by_process: Counter[str] = Counter()
    shader_by_process: dict[str, Counter[str]] = defaultdict(Counter)
    shader_type_by_process: dict[str, Counter[str]] = defaultdict(Counter)
    times: list[int] = []
    for row in reader.rows():
        rows += 1
        name = display(row.get("name"))
        process = display(row.get("process")) or "(unknown)"
        by_process[process] += 1
        t = raw(row.get("time"))
        if t is not None:
            times.append(t)
        if name == "FunctionCompiled":
            function_compiled += 1
            function_compiled_by_process[process] += 1
            message = display(row.get("message"))
            shader = (SIGNPOST_NAME_RE.search(message) or [None, "(unknown)"])[1]
            shader_type = (SIGNPOST_TYPE_RE.search(message) or [None, "(unknown)"])[1]
            by_shader[shader] += 1
            by_shader_type[shader_type] += 1
            shader_by_process[process][shader] += 1
            shader_type_by_process[process][shader_type] += 1
    live_process = next((name for name in by_process if "LiveWallpaper" in name), "")
    return {
        "file": str(path),
        "rows": rows,
        "span_ms": ms(max(times) - min(times)) if len(times) >= 2 else 0,
        "function_compiled": function_compiled,
        "processes": short_counter(by_process, 12),
        "function_compiled_by_process": short_counter(function_compiled_by_process, 12),
        "shader_types": short_counter(by_shader_type, 8),
        "shaders": short_counter(by_shader, 25),
        "livewallpaper_process": live_process,
        "livewallpaper_function_compiled": function_compiled_by_process[live_process] if live_process else 0,
        "livewallpaper_shader_types": short_counter(shader_type_by_process[live_process], 8) if live_process else [],
        "livewallpaper_shaders": short_counter(shader_by_process[live_process], 25) if live_process else [],
    }


def parse_toc(path: Path) -> dict[str, Any]:
    root = ET.parse(path).getroot()
    run = root.find(".//run")
    target = root.find(".//target")
    device = target.find("device") if target is not None else None
    process = target.find("process") if target is not None else None
    env = {}
    for item in root.findall(".//environment/item"):
        key = item.attrib.get("key")
        value = item.attrib.get("value")
        if key:
            env[key] = value
    dyld = env.get("DYLD_INSERT_LIBRARIES", "") or ""
    injected = [item for item in dyld.split(":") if item]
    return {
        "file": str(path),
        "run_number": run.attrib.get("number") if run is not None else None,
        "device": device.attrib if device is not None else {},
        "process": process.attrib if process is not None else {},
        "start_date": root.findtext(".//start-date"),
        "end_date": root.findtext(".//end-date"),
        "duration": root.findtext(".//duration"),
        "template_name": root.findtext(".//template-name"),
        "time_limit": root.findtext(".//time-limit"),
        "environment_flags": {
            key: env.get(key)
            for key in [
                "MTL_DEBUG_LAYER",
                "METAL_LOAD_INTERPOSER",
                "GPUTOOLS_LOAD_GTMTLCAPTURE",
                "MTL_HUD_ENABLED",
            ]
            if key in env
        },
        "injected_libraries": injected,
    }


@dataclass
class TracePaths:
    key: str
    title: str
    toc: Path
    time_profile: Path
    cpu_profile: Path
    exports_prefix: str

    def export(self, suffix: str) -> Path:
        return WORKSPACE / "trace_exports" / f"{self.exports_prefix}_{suffix}.xml"


def analyze_trace(paths: TracePaths) -> dict[str, Any]:
    print(f"Analyzing {paths.title}: TOC", flush=True)
    result: dict[str, Any] = {
        "key": paths.key,
        "title": paths.title,
        "toc": parse_toc(paths.toc),
    }
    print(f"Analyzing {paths.title}: time profile", flush=True)
    result["time_profile"] = analyze_sample_file(paths.time_profile, "ns")
    print(f"Analyzing {paths.title}: cpu profile", flush=True)
    result["cpu_profile"] = analyze_sample_file(paths.cpu_profile, "cycles")
    print(f"Analyzing {paths.title}: GPU state", flush=True)
    result["gpu_state"] = analyze_gpu_state(paths.export("metal_gpu_state_intervals"))
    print(f"Analyzing {paths.title}: GPU intervals", flush=True)
    result["gpu_intervals"] = analyze_gpu_intervals(paths.export("metal_gpu_intervals"))
    print(f"Analyzing {paths.title}: command buffers", flush=True)
    result["command_buffers_completed"] = analyze_command_buffers_completed(paths.export("metal_command_buffer_completed"))
    result["frame_assignment"] = analyze_frame_assignment(paths.export("metal_command_buffer_frame_assignment"))
    print(f"Analyzing {paths.title}: IOSurface and runloop", flush=True)
    result["io_surface"] = analyze_io_surface(paths.export("metal_io_surface_access"))
    result["runloop"] = analyze_runloop(paths.export("runloop_events"))
    result["potential_hangs"] = analyze_potential_hangs(paths.export("potential_hangs"))
    print(f"Analyzing {paths.title}: signposts", flush=True)
    result["signposts"] = analyze_signposts(paths.export("os_signpost"))
    return result


def fmt_ms(value: float | int | None) -> str:
    return f"{float(value or 0):.2f} ms"


def fmt_pct(value: float | int | None) -> str:
    return f"{float(value or 0):.1f}%"


def top_names(items: list[dict[str, Any]], value_key: str = "value", limit: int = 5) -> str:
    if not items:
        return "无"
    return "; ".join(f"{item['name']} ({item.get(value_key, 0):.0f})" for item in items[:limit])


def weighted_names(items: list[dict[str, Any]], limit: int = 7) -> str:
    if not items:
        return "无"
    parts = []
    for item in items[:limit]:
        percent = item.get("percent_total")
        ms_value = item.get("display_ms")
        if ms_value is not None:
            parts.append(f"{item['name']} - {fmt_ms(ms_value)} / {fmt_pct(percent)}")
        else:
            parts.append(f"{item['name']} - {item.get('weight', 0):,} / {fmt_pct(percent)}")
    return "\n".join(f"- {part}" for part in parts)


def process_summary(frame_assignment: dict[str, Any], process_name: str) -> dict[str, Any] | None:
    for item in frame_assignment.get("processes", []):
        if process_name in item.get("process", ""):
            return item
    return None


def render_report(summary: dict[str, Any]) -> str:
    traces = summary["traces"]
    lines: list[str] = []
    lines.append("# LiveWallpaper 双屏渲染 Instruments 分析报告")
    lines.append("")
    lines.append("## 结论摘要")
    lines.append("")
    lines.append(
        "这两份 trace 的最大解释限制是采样环境本身：进程被注入了 Thread Sanitizer、Metal Debug Layer、GPUTools Capture、Metal HUD、Main Thread Checker 等库。"
        "因此绝对 CPU 时间、命令编码成本和 drawable 等待成本都会被放大；这些 trace 适合判断热点形状和相对瓶颈，不适合作为生产 FPS/功耗基线。"
    )
    lines.append("")
    lines.append(
        "在这个前提下，当前双屏渲染更像是 CPU/提交侧受限，而不是纯 GPU shader 执行被打满：GPU state 显示两个场景的 GPU Active 占比较低，"
        "但主线程和渲染提交路径持续出现在 `WPEMetalSceneRenderer.draw(in:) -> WPEMetalRenderExecutor.render(...) -> present(...)`，"
        "热点集中在粒子 pass 编码、translated uniform 打包、puppet/skinning/attachment 校验、target texture 选择、present/nextDrawable 和音频 FFT tap。"
    )
    lines.append("")
    lines.append("## Trace 元数据与污染项")
    lines.append("")
    for trace in traces:
        toc = trace["toc"]
        flags = ", ".join(f"{k}={v}" for k, v in toc.get("environment_flags", {}).items())
        injected = [Path(item).name for item in toc.get("injected_libraries", [])]
        lines.append(f"### {trace['title']}")
        lines.append("")
        lines.append(f"- 采样时间：{toc.get('start_date')} -> {toc.get('end_date')}，duration={toc.get('duration')}，template={toc.get('template_name')}")
        lines.append(f"- 设备：{toc.get('device', {}).get('model')} / macOS {toc.get('device', {}).get('os-version')}，GPU={trace['gpu_intervals'].get('process_duration', [{}])[0].get('name', '') and 'M5 Pro'}")
        lines.append(f"- 注入/调试开关：{flags}")
        lines.append(f"- 注入库：{', '.join(injected)}")
        lines.append("")
    lines.append("## CPU 与主线程热点")
    lines.append("")
    for trace in traces:
        tp = trace["time_profile"]
        cp = trace["cpu_profile"]
        lines.append(f"### {trace['title']}")
        lines.append("")
        lines.append(
            f"- Time Profile 总采样权重 {fmt_ms(tp.get('total_ms'))}，Running {fmt_ms(tp.get('running_ms'))}，"
            f"Main Thread {fmt_ms(tp.get('main_total_ms'))}；"
            f"栈顶落在 TSan/MetalTools/GPUTools/HUD 等工具库的权重占 {fmt_pct(tp.get('tool_leaf_percent'))}。"
        )
        lines.append(f"- CPU Profile 总 cycles：{cp.get('total_weight', 0):,}，Main Thread cycles：{cp.get('main_total_weight', 0):,}，工具库栈顶占 {fmt_pct(cp.get('tool_leaf_percent'))}。")
        lines.append("- Time Profile 第一层 App 栈帧热点：")
        lines.append(weighted_names(tp.get("first_app_frames", []), 10))
        lines.append("- Main Thread 第一层 App 栈帧热点：")
        lines.append(weighted_names(tp.get("main_first_app_frames", []), 10))
        lines.append("- CPU cycles 第一层 App 栈帧热点：")
        lines.append(weighted_names(cp.get("first_app_frames", []), 10))
        lines.append("")
    lines.append("## GPU、Command Buffer 与双屏证据")
    lines.append("")
    for trace in traces:
        gs = trace["gpu_state"]
        gi = trace["gpu_intervals"]
        fa = trace["frame_assignment"]
        ios = trace["io_surface"]
        live = process_summary(fa, "LiveWallpaper")
        window = process_summary(fa, "WindowServer")
        active_channels = ", ".join(
            f"{item['channels']}ch {fmt_ms(item['duration_ms'])}/{fmt_pct(item['percent_of_active'])}"
            for item in gs.get("active_channel_ms", [])[:4]
        )
        lines.append(f"### {trace['title']}")
        lines.append("")
        lines.append(f"- GPU state：Active {fmt_pct(gs.get('active_percent'))}，span {fmt_ms(gs.get('span_ms'))}；Active channel 分布：{active_channels}")
        lines.append(
            f"- GPU intervals：{gi.get('rows')} rows，channel-time {fmt_ms(gi.get('channel_time_ms'))}，"
            f"interval p50={fmt_ms(gi['duration_ms']['p50'])} / p95={fmt_ms(gi['duration_ms']['p95'])} / max={fmt_ms(gi['duration_ms']['max'])}，"
            f"CPU->GPU latency p50={fmt_ms(gi['start_latency_ms']['p50'])} / p95={fmt_ms(gi['start_latency_ms']['p95'])}。"
        )
        process_duration = "; ".join(
            f"{item['name']} {fmt_ms(item['duration_ms'])}/{fmt_pct(item['percent'])}"
            for item in gi.get("process_duration", [])[:5]
        )
        lines.append(f"- GPU interval channel-time 按进程：{process_duration}")
        if live:
            cbq = live["command_buffers_per_frame"]
            pq = live["present_events_per_frame"]
            lines.append(
                f"- LiveWallpaper frame assignment：{live['rows']} command-buffer rows，{live['unique_frames']} frame numbers，"
                f"约 {live['approx_unique_frames_per_second']:.1f} frame-numbers/s；每 frame command buffers p50={cbq['p50']:.1f}, p95={cbq['p95']:.1f}, max={cbq['max']:.0f}；"
                f"present/frame p50={pq['p50']:.1f}, p95={pq['p95']:.1f}, max={pq['max']:.0f}。"
            )
            lines.append(f"- LiveWallpaper present surfaces：{top_names(live.get('present_surfaces', []), 'value', 8)}")
        if window:
            lines.append(
                f"- WindowServer 同期也有 {window['rows']} command-buffer rows / {window['unique_frames']} frame numbers，"
                "说明 app present 后还有合成器侧工作。"
            )
        lines.append(f"- IOSurface 主要格式/尺寸：{top_names(ios.get('formats_sizes', []), 'value', 8)}")
        lines.append(f"- IOSurface 主要进程/尺寸/access：{top_names(ios.get('process_format_size_access', []), 'value', 10)}")
        lines.append("")
    lines.append("## RunLoop、Hang 与 Shader 编译")
    lines.append("")
    for trace in traces:
        rl = trace["runloop"]
        hangs = trace["potential_hangs"]
        sp = trace["signposts"]
        iter_stats = rl.get("durations_ms", {}).get("individual_iteration", {})
        wait_stats = rl.get("durations_ms", {}).get("waiting_for_events", {})
        lines.append(f"### {trace['title']}")
        lines.append("")
        lines.append(
            f"- Main RunLoop individual_iteration：count={rl.get('counts', {}).get('individual_iteration', 0)}，"
            f"p50={fmt_ms(iter_stats.get('p50'))} / p95={fmt_ms(iter_stats.get('p95'))} / max={fmt_ms(iter_stats.get('max'))}；"
            f"waiting p50={fmt_ms(wait_stats.get('p50'))} / max={fmt_ms(wait_stats.get('max'))}。"
        )
        lines.append(f"- Potential hangs rows：{hangs.get('rows')}。")
        lines.append(
            f"- Metal FunctionCompiled signposts：全系统 {sp.get('function_compiled')}，其中 LiveWallpaper {sp.get('livewallpaper_function_compiled')}；"
            f"LiveWallpaper 类型={top_names(sp.get('livewallpaper_shader_types', []), 'value', 4)}；"
            f"LiveWallpaper shader={top_names(sp.get('livewallpaper_shaders', []), 'value', 10)}。"
        )
        lines.append("")
    lines.append("## 根因判断")
    lines.append("")
    lines.append("1. 主要瓶颈不是单个长 GPU kernel，而是 CPU 端每屏每帧的渲染准备、pass/command buffer 编码和 present 提交流。GPU intervals 大量是微秒级 Vertex/Fragment 片段，GPU state 的 Active 占比不高。")
    lines.append("2. 双屏的成本主要表现为两套 drawable/present surface、更多 command buffer rows、WindowServer 合成器同步工作，以及相同 Swift render preparation 路径的重复执行。")
    lines.append("3. 当前 trace 的绝对数值被 TSan + Metal Debug Layer + Capture + HUD 严重污染，特别是 `makeRenderCommandEncoder`、`set*Buffer/Texture`、`draw*`、`commit`、`nextDrawable` 这些调用会显示出大量工具库帧。")
    lines.append("4. Scene 3462491575 的 app 侧采样更集中在粒子系统、translated uniform、puppet/attachment 逻辑；Scene 3660962877 额外出现视频帧获取、clearTexture、文本 overlay 和更高的 present surface/IOSurface 交换量，但总体仍落在同一渲染/提交链。")
    lines.append("")
    lines.append("## 优化优先级")
    lines.append("")
    lines.append("1. 先重录干净基线：Release、关闭 Thread Sanitizer、关闭 Metal API Validation/Debug Layer、关闭 HUD 和 GPU capture，只保留 Metal System Trace/GPU Counters；另加 app 自己的 `os_signpost` 包住 update/evaluate/encode/present。")
    lines.append("2. CPU 侧先降重复工作：缓存 `translatedUniformNameCandidates` 结果；避免每 pass 构建 `Set`/`Dictionary`；把 `makeAttachmentFrameContext`、`validatedSkinningState`、`composedBindWorldByBoneIndex` 这类只随模型/层级变化的结果移出逐帧路径。")
    lines.append("3. 粒子与 pass 编码：`encodeParticleSystem` 当前每个系统独立 render pass 且 `.load/.store`，双屏会放大 encoder 创建、attachment load/store、snapshot/refraction 成本；按材质/blend/refract 分组，减少 render pass 和 encoder 数量。")
    lines.append("4. Present/drawable：`present(texture:in:)` 已经晚到最后才取 `view.currentDrawable`，方向正确；下一步确认没有提前触发 `currentRenderPassDescriptor/currentDrawable`，并保持 `maximumDrawableCount=3`，避免持有 drawable 跨帧。")
    lines.append("5. Command buffer：按 Apple 建议减少每帧 command buffer 数量，在不让 GPU 饥饿的前提下倾向每帧 1-2 个；present copy pass 和主渲染 pass 是否能合并，要结合双屏输出纹理生命周期验证。")
    lines.append("6. 功耗/FPS：给每个 MTKView 设置可稳定达到的 `preferredFramesPerSecond`，静止/遮挡/低电量时降到 30 或暂停；只有场景真正使用音频响应时才启用 `WPESoundRuntime` 的 FFT tap。")
    lines.append("7. 为 Metal 管线优化做准备：把 pipeline state 全部预热/异步构建，避免播放中懒编译；检查 drawable `framebufferOnly=true`，中间纹理使用合适 storage/usage；用 ring buffer/triple buffering 管动态 uniform/particle 数据。")
    lines.append("")
    lines.append("## 参考资料")
    lines.append("")
    lines.append("- [Apple Metal Best Practices: Command Buffers](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/CommandBuffers.html) - fewer command buffers per frame, preferably one or two, while avoiding GPU starvation.")
    lines.append("- [Apple Metal Best Practices: Drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html) - acquire drawables late, release quickly, and present through the command buffer.")
    lines.append("- [Apple Metal Best Practices: Triple Buffering](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html) - keep CPU/GPU dynamic-buffer work parallel with a bounded in-flight model.")
    lines.append("- [Apple Metal Best Practices: Pipelines](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Pipelines.html) - build known render/compute pipelines asynchronously up front.")
    lines.append("- [Apple Metal Best Practices: Resource Options](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/ResourceOptions.html) - choose correct storage modes and explicit texture usage flags.")
    lines.append("- [Apple Metal Best Practices: Frame Rate](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/FrameRate.html) - target a stable frame rate and lower target FPS when a workload cannot consistently fit the interval.")
    lines.append("- [Apple CAMetalLayer.maximumDrawableCount](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount) and [Apple MTKView.preferredFramesPerSecond](https://developer.apple.com/documentation/metalkit/mtkview/preferredframespersecond).")
    lines.append("- [Metal by Example: Up and Running with Metal](https://metalbyexample.com/up-and-running-1/) - CAMetalLayer/drawable/command-buffer/present flow.")
    lines.append("- [Kodeco Metal Tutorial: Getting Started](https://www.kodeco.com/7475-metal-tutorial-getting-started) - `framebufferOnly=true` unless drawable textures must be sampled or used by compute.")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=WORKSPACE / "trace_analysis")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    traces = [
        TracePaths(
            key="scene3462491575",
            title="scene3462491575 / 文件1 run4",
            toc=WORKSPACE / "scene3462491575_toc.xml",
            time_profile=WORKSPACE / "scene3462491575_time_profile.xml",
            cpu_profile=WORKSPACE / "scene3462491575_cpu_profile.xml",
            exports_prefix="scene3462491575",
        ),
        TracePaths(
            key="3660962877",
            title="3660962877 / 文件2",
            toc=WORKSPACE / "3660962877_toc.xml",
            time_profile=WORKSPACE / "3660962877_time_profile.xml",
            cpu_profile=WORKSPACE / "3660962877_cpu_profile.xml",
            exports_prefix="3660962877",
        ),
    ]

    summary = {"traces": [analyze_trace(paths) for paths in traces]}
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    (args.out / "report.md").write_text(render_report(summary), encoding="utf-8")
    print(f"Wrote {args.out / 'summary.json'}", flush=True)
    print(f"Wrote {args.out / 'report.md'}", flush=True)


if __name__ == "__main__":
    main()
