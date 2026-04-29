#!/usr/bin/env python3
"""Kernel telemetry sampler for the SysLens plasmoid."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any


PROC = Path("/proc")
SYS = Path("/sys")
BLOCK_SECTOR_BYTES = 512
DISKSTAT_DEVICE_RE = re.compile(r"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme\d+n\d+|mmcblk\d+|md\d+)$")
VIRTUAL_INTERFACE_PREFIXES = ("br-", "docker", "veth", "virbr", "tun", "tap")
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "syslens"
STATE_FILE = STATE_DIR / "state.json"
CPU_BUCKET_SECONDS = 60
CPU_MONTH_SECONDS = 30 * 24 * 60 * 60
CPU_DAY_SECONDS = 24 * 60 * 60


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def read_int(path: Path) -> int | None:
    value = read_text(path)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def read_boot_id() -> str | None:
    return read_text(PROC / "sys/kernel/random/boot_id")


def clamp(value: float, minimum: float = 0.0, maximum: float = 100.0) -> float:
    return max(minimum, min(maximum, value))


def pct(used: float, total: float) -> float:
    if total <= 0:
        return 0.0
    return round(clamp((used / total) * 100.0), 1)


def finite_float(value: Any) -> float | None:
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        return None
    if numeric != numeric or numeric in (float("inf"), float("-inf")):
        return None
    return numeric


def bytes_from_kib(kib: int | float) -> int:
    return int(kib * 1024)


def load_state() -> dict[str, Any]:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, PermissionError, OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict[str, Any]) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    except (PermissionError, OSError):
        pass


def parse_key_value_file(path: Path, separator: str = ":") -> dict[str, str]:
    result: dict[str, str] = {}
    text = read_text(path)
    if not text:
        return result
    for line in text.splitlines():
        if separator not in line:
            continue
        key, value = line.split(separator, 1)
        result[key.strip()] = value.strip()
    return result


def parse_cpuinfo() -> list[dict[str, str]]:
    text = read_text(PROC / "cpuinfo")
    if not text:
        return []
    processors: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip():
            if current:
                processors.append(current)
                current = {}
            continue
        if ":" in line:
            key, value = line.split(":", 1)
            current[key.strip()] = value.strip()
    if current:
        processors.append(current)
    return processors


def read_cpu_times() -> list[list[int]]:
    text = read_text(PROC / "stat")
    if not text:
        return []
    times: list[list[int]] = []
    for line in text.splitlines():
        if not line.startswith("cpu"):
            continue
        parts = line.split()
        if parts[0] == "cpu" or parts[0][3:].isdigit():
            try:
                times.append([int(value) for value in parts[1:]])
            except ValueError:
                continue
    return times


def cpu_usage_from_times(before: list[list[int]], after: list[list[int]]) -> tuple[float, list[float]]:
    def one(previous: list[int], current: list[int]) -> float:
        prev_idle = previous[3] + (previous[4] if len(previous) > 4 else 0)
        curr_idle = current[3] + (current[4] if len(current) > 4 else 0)
        prev_total = sum(previous)
        curr_total = sum(current)
        total_delta = curr_total - prev_total
        idle_delta = curr_idle - prev_idle
        if total_delta <= 0:
            return 0.0
        return round(clamp((1.0 - (idle_delta / total_delta)) * 100.0), 1)

    count = min(len(before), len(after))
    if count == 0:
        return 0.0, []
    total = one(before[0], after[0])
    cores = [one(before[index], after[index]) for index in range(1, count)]
    return total, cores


def cpu_time_counters(times: list[int]) -> dict[str, int] | None:
    if len(times) < 4:
        return None
    idle = times[3] + (times[4] if len(times) > 4 else 0)
    total = sum(times)
    return {"total": total, "busy": max(0, total - idle)}


def read_cpufreq(cpu_count: int) -> dict[str, Any]:
    frequencies: list[float] = []
    min_limit: list[float] = []
    max_limit: list[float] = []
    governors: set[str] = set()
    boost_values: set[str] = set()

    for index in range(cpu_count):
        base = SYS / "devices/system/cpu" / f"cpu{index}" / "cpufreq"
        current = read_int(base / "scaling_cur_freq")
        minimum = read_int(base / "scaling_min_freq")
        maximum = read_int(base / "scaling_max_freq")
        governor = read_text(base / "scaling_governor")
        boost = read_text(base / "boost")
        if current is not None:
            frequencies.append(current / 1000.0)
        if minimum is not None:
            min_limit.append(minimum / 1000.0)
        if maximum is not None:
            max_limit.append(maximum / 1000.0)
        if governor:
            governors.add(governor)
        if boost:
            boost_values.add(boost)

    global_boost = read_text(SYS / "devices/system/cpu/cpufreq/boost")
    if global_boost:
        boost_values.add(global_boost)

    return {
        "available": bool(frequencies or governors or min_limit or max_limit),
        "current_mhz_avg": round(sum(frequencies) / len(frequencies), 1) if frequencies else None,
        "current_mhz_min": round(min(frequencies), 1) if frequencies else None,
        "current_mhz_max": round(max(frequencies), 1) if frequencies else None,
        "scaling_min_mhz": round(min(min_limit), 1) if min_limit else None,
        "scaling_max_mhz": round(max(max_limit), 1) if max_limit else None,
        "governors": sorted(governors),
        "boost": sorted(boost_values),
    }


def collect_cpu(sample_window: float) -> dict[str, Any]:
    processors = parse_cpuinfo()
    before = read_cpu_times()
    time.sleep(sample_window)
    after = read_cpu_times()
    total_usage, core_usage = cpu_usage_from_times(before, after)
    first = processors[0] if processors else {}
    physical_core_ids = {
        (cpu.get("physical id", "0"), cpu.get("core id", str(index)))
        for index, cpu in enumerate(processors)
    }
    mhz_values: list[float] = []
    for cpu in processors:
        try:
            mhz_values.append(float(cpu.get("cpu MHz", "")))
        except ValueError:
            pass

    try:
        load_1, load_5, load_15 = os.getloadavg()
    except OSError:
        load_1 = load_5 = load_15 = 0.0

    logical_cores = os.cpu_count() or len(processors) or len(core_usage)
    counters = cpu_time_counters(after[0]) if after else None
    return {
        "available": bool(before and after),
        "usage_percent": total_usage,
        "per_core_percent": core_usage,
        "logical_cores": logical_cores,
        "physical_cores": len(physical_core_ids) if processors else None,
        "model": first.get("model name") or platform.processor() or "Unknown CPU",
        "vendor": first.get("vendor_id"),
        "architecture": platform.machine(),
        "cache": first.get("cache size"),
        "microcode": first.get("microcode"),
        "flags": first.get("flags", "").split(),
        "current_mhz_avg": round(sum(mhz_values) / len(mhz_values), 1) if mhz_values else None,
        "current_mhz_min": round(min(mhz_values), 1) if mhz_values else None,
        "current_mhz_max": round(max(mhz_values), 1) if mhz_values else None,
        "cpufreq": read_cpufreq(logical_cores),
        "load_average": {
            "1m": round(load_1, 2),
            "5m": round(load_5, 2),
            "15m": round(load_15, 2),
        },
        "_time_counters": counters,
    }


def average_from_cpu_counters(current: dict[str, Any], baseline: dict[str, Any]) -> float | None:
    current_total = finite_float(current.get("total"))
    current_busy = finite_float(current.get("busy"))
    baseline_total = finite_float(baseline.get("total"))
    baseline_busy = finite_float(baseline.get("busy"))
    if current_total is None or current_busy is None or baseline_total is None or baseline_busy is None:
        return None
    total_delta = current_total - baseline_total
    busy_delta = current_busy - baseline_busy
    if total_delta <= 0 or busy_delta < 0:
        return None
    return round(clamp((busy_delta / total_delta) * 100.0), 1)


def apply_cpu_history(state: dict[str, Any], cpu: dict[str, Any], boot_id: str | None) -> None:
    now = time.time()
    counters = cpu.get("_time_counters")
    cpu.pop("_time_counters", None)
    if not isinstance(counters, dict):
        cpu["usage_average_percent"] = {"1d": None, "1mo": None, "overall": None}
        return

    history = state.setdefault("cpu_usage_history", {})
    if history.get("boot_id") != boot_id:
        history.clear()
        history["boot_id"] = boot_id

    samples = history.setdefault("samples", [])
    sample = {"t": now, "total": int(counters.get("total", 0)), "busy": int(counters.get("busy", 0))}
    valid_samples = [
        item for item in samples
        if isinstance(item, dict)
        and finite_float(item.get("t")) is not None
        and finite_float(item.get("total")) is not None
        and finite_float(item.get("busy")) is not None
        and float(item.get("t")) >= now - CPU_MONTH_SECONDS - (2 * CPU_BUCKET_SECONDS)
    ]
    valid_samples.sort(key=lambda item: float(item.get("t", 0)))
    if len(valid_samples) > 1 and now - float(valid_samples[-1].get("t", 0)) < CPU_BUCKET_SECONDS:
        valid_samples[-1] = sample
    else:
        valid_samples.append(sample)
    history["samples"] = valid_samples

    def window_average(seconds: int) -> dict[str, Any]:
        cutoff = now - seconds
        if len(valid_samples) < 2:
            return {"value": None, "coverage_seconds": 0}
        before_cutoff = [item for item in valid_samples if float(item.get("t", 0)) <= cutoff]
        baseline = before_cutoff[-1] if before_cutoff else valid_samples[0]
        value = average_from_cpu_counters(sample, baseline)
        return {
            "value": value,
            "coverage_seconds": max(0, round(now - float(baseline.get("t", now)))),
        }

    day_average = window_average(CPU_DAY_SECONDS)
    month_average = window_average(CPU_MONTH_SECONDS)
    overall_value = average_from_cpu_counters(sample, {"total": 0, "busy": 0})
    uptime_text = read_text(PROC / "uptime")
    try:
        uptime_seconds = round(float(uptime_text.split()[0])) if uptime_text else None
    except (IndexError, ValueError):
        uptime_seconds = None
    cpu["usage_average_percent"] = {
        "1d": day_average["value"],
        "1mo": month_average["value"],
        "overall": overall_value if overall_value is not None else cpu.get("usage_percent"),
    }
    cpu["usage_average_coverage_seconds"] = {
        "1d": day_average["coverage_seconds"],
        "1mo": month_average["coverage_seconds"],
        "overall": uptime_seconds,
    }


def collect_memory() -> dict[str, Any]:
    raw = parse_key_value_file(PROC / "meminfo")

    def kib(name: str) -> int:
        value = raw.get(name, "0").split()[0]
        try:
            return int(value)
        except ValueError:
            return 0

    total = kib("MemTotal")
    available = kib("MemAvailable") or kib("MemFree")
    used = max(0, total - available)
    swap_total = kib("SwapTotal")
    swap_free = kib("SwapFree")
    swap_used = max(0, swap_total - swap_free)
    return {
        "available": total > 0,
        "total_bytes": bytes_from_kib(total),
        "used_bytes": bytes_from_kib(used),
        "free_bytes": bytes_from_kib(kib("MemFree")),
        "available_bytes": bytes_from_kib(available),
        "usage_percent": pct(used, total),
        "buffers_bytes": bytes_from_kib(kib("Buffers")),
        "cached_bytes": bytes_from_kib(kib("Cached")),
        "dirty_bytes": bytes_from_kib(kib("Dirty")),
        "slab_bytes": bytes_from_kib(kib("Slab")),
        "swap": {
            "available": swap_total > 0,
            "total_bytes": bytes_from_kib(swap_total),
            "used_bytes": bytes_from_kib(swap_used),
            "free_bytes": bytes_from_kib(swap_free),
            "usage_percent": pct(swap_used, swap_total),
            "zswap_bytes": bytes_from_kib(kib("Zswap")),
            "zswapped_bytes": bytes_from_kib(kib("Zswapped")),
        },
    }


def temperature_label(path: Path) -> str:
    for candidate in (path.with_name(path.name.replace("_input", "_label")), path.parent / "type", path.parent / "name"):
        label = read_text(candidate)
        if label:
            return label
    return path.parent.name


def cpu_temperature_candidates(sensors: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cpu_terms = ("cpu", "core", "package", "k10temp", "tctl", "tdie", "zenpower")
    excluded_terms = ("gpu", "nvme", "ssd", "wifi", "wireless", "battery", "pch")
    candidates: list[dict[str, Any]] = []
    for sensor in sensors:
        label = str(sensor.get("label", "")).lower()
        path = str(sensor.get("path", "")).lower()
        haystack = f"{label} {path}"
        if any(term in haystack for term in excluded_terms):
            continue
        if any(term in haystack for term in cpu_terms):
            candidates.append(sensor)
    return candidates


def collect_temperatures() -> dict[str, Any]:
    sensors: list[dict[str, Any]] = []
    seen: set[Path] = set()
    roots = [SYS / "class/hwmon", SYS / "class/thermal"]
    for root in roots:
        if not root.exists():
            continue
        for path in sorted(root.glob("**/temp*_input")):
            if path in seen:
                continue
            seen.add(path)
            raw = read_int(path)
            if raw is None:
                continue
            celsius = raw / 1000.0 if abs(raw) > 300 else float(raw)
            sensors.append({
                "label": temperature_label(path),
                "path": str(path),
                "celsius": round(celsius, 1),
            })
    kde = collect_kde_cpu_temperatures()
    if kde.get("available"):
        for key, label in (("average_celsius", "KDE Average CPU"), ("maximum_celsius", "KDE Maximum CPU"), ("minimum_celsius", "KDE Minimum CPU")):
            if kde.get(key) is not None:
                sensors.append({"label": label, "path": "ksystemstats", "celsius": kde[key]})
    hottest = max(sensors, key=lambda item: item["celsius"], default=None)
    cpu_candidates = cpu_temperature_candidates(sensors)
    cpu_current = kde.get("average_celsius")
    if cpu_current is None and cpu_candidates:
        cpu_current = round(sum(float(item["celsius"]) for item in cpu_candidates) / len(cpu_candidates), 1)
    if cpu_current is None and hottest:
        cpu_current = hottest["celsius"]
    current_cpu_max = kde.get("maximum_celsius")
    if current_cpu_max is None and cpu_candidates:
        current_cpu_max = max(float(item["celsius"]) for item in cpu_candidates)
    return {
        "available": bool(sensors),
        "hottest_celsius": hottest["celsius"] if hottest else None,
        "hottest_label": hottest["label"] if hottest else None,
        "cpu_current_celsius": round(cpu_current, 1) if cpu_current is not None else None,
        "cpu_average_celsius": None,
        "cpu_maximum_celsius": round(current_cpu_max, 1) if current_cpu_max is not None else None,
        "cpu_minimum_celsius": kde.get("minimum_celsius"),
        "cpu_current_sensor_max_celsius": round(current_cpu_max, 1) if current_cpu_max is not None else None,
        "source": "ksystemstats" if kde.get("available") else ("sysfs" if sensors else None),
        "sensors": sensors,
    }


METRIC_BUCKET_SECONDS = 60


def update_metric_averages(
    state: dict[str, Any],
    key: str,
    value: float,
    boot_id: str | None,
    period1_days: int,
    period2_days: int,
) -> dict[str, Any]:
    now = time.time()
    period1_secs = period1_days * 86400
    period2_secs = period2_days * 86400
    max_age = max(period1_secs, period2_secs) + 2 * METRIC_BUCKET_SECONDS

    history = state.setdefault(f"metric_{key}", {})
    if history.get("boot_id") != boot_id:
        history.clear()
        history["boot_id"] = boot_id

    samples: list[dict[str, Any]] = [
        s for s in history.setdefault("samples", [])
        if now - float(s.get("t", 0)) <= max_age
    ]

    if samples and now - float(samples[-1]["t"]) < METRIC_BUCKET_SECONDS:
        last = samples[-1]
        n = int(last.get("n", 1))
        last["v"] = round((float(last["v"]) * n + value) / (n + 1), 3)
        last["n"] = n + 1
    else:
        samples.append({"t": round(now, 1), "v": round(value, 3)})

    history["samples"] = samples

    def window_avg(window_secs: int) -> float | None:
        cutoff = now - window_secs
        window = [float(s["v"]) for s in samples if float(s["t"]) >= cutoff]
        return round(sum(window) / len(window), 1) if window else None

    def period_label(days: int) -> str:
        if days == 1:
            return "1d"
        if days % 365 == 0:
            return f"{days // 365}y"
        if days % 30 == 0:
            return f"{days // 30}mo"
        if days % 7 == 0:
            return f"{days // 7}w"
        return f"{days}d"

    overall = round(sum(float(s["v"]) for s in samples) / len(samples), 1) if samples else None
    return {
        "period1": window_avg(period1_secs),
        "period2": window_avg(period2_secs),
        "overall": overall,
        "period1_label": period_label(period1_days),
        "period2_label": period_label(period2_days),
    }


def apply_temperature_history(state: dict[str, Any], temperatures: dict[str, Any], boot_id: str | None) -> None:
    current = finite_float(temperatures.get("cpu_current_celsius"))
    if current is None:
        return
    current_sensor_max = finite_float(temperatures.get("cpu_current_sensor_max_celsius")) or current

    now = time.time()
    temp_state = state.setdefault("cpu_temperature_history", {})
    if temp_state.get("schema") != 2 or temp_state.get("boot_id") != boot_id:
        temp_state.clear()
        temp_state.update({
            "schema": 2,
            "boot_id": boot_id,
            "created_at": now,
            "weighted_sum": 0.0,
            "duration_seconds": 0.0,
            "max_celsius": current_sensor_max,
        })

    last_t = finite_float(temp_state.get("last_t"))
    last_value = finite_float(temp_state.get("last_value"))
    if last_t is not None and last_value is not None:
        elapsed = now - last_t
        if 0 < elapsed <= 5 * 60:
            temp_state["weighted_sum"] = float(temp_state.get("weighted_sum", 0.0)) + (last_value * elapsed)
            temp_state["duration_seconds"] = float(temp_state.get("duration_seconds", 0.0)) + elapsed

    temp_state["max_celsius"] = max(float(temp_state.get("max_celsius", current_sensor_max)), current_sensor_max)
    temp_state["last_t"] = now
    temp_state["last_value"] = current

    duration = float(temp_state.get("duration_seconds", 0.0))
    average = float(temp_state.get("weighted_sum", 0.0)) / duration if duration > 0 else current
    temperatures["cpu_average_celsius"] = round(average, 1)
    temperatures["cpu_maximum_celsius"] = round(float(temp_state.get("max_celsius", current_sensor_max)), 1)
    temperatures["cpu_history_seconds"] = round(max(duration, now - float(temp_state.get("created_at", now))))


def collect_kde_cpu_temperatures() -> dict[str, Any]:
    sensor_map = {
        "cpu/all/averageTemperature": "average_celsius",
        "cpu/all/maximumTemperature": "maximum_celsius",
        "cpu/all/minimumTemperature": "minimum_celsius",
    }
    result: dict[str, Any] = {"available": False}
    try:
        completed = subprocess.run(
            ["kstatsviewer", *sensor_map.keys()],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1.2,
        )
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return result

    for line in completed.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] not in sensor_map:
            continue
        try:
            result[sensor_map[parts[0]]] = round(float(parts[1]), 1)
            result["available"] = True
        except ValueError:
            continue
    return result


def diskstats_snapshot() -> dict[str, dict[str, int]]:
    text = read_text(PROC / "diskstats")
    devices: dict[str, dict[str, int]] = {}
    if not text:
        return devices
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 14:
            continue
        name = parts[2]
        if not DISKSTAT_DEVICE_RE.match(name):
            continue
        try:
            devices[name] = {
                "reads": int(parts[3]),
                "read_sectors": int(parts[5]),
                "writes": int(parts[7]),
                "write_sectors": int(parts[9]),
                "io_ms": int(parts[12]),
            }
        except ValueError:
            continue
    return devices


def collect_disks(before: dict[str, dict[str, int]], after: dict[str, dict[str, int]], elapsed: float) -> dict[str, Any]:
    disks: list[dict[str, Any]] = []
    total_read = 0.0
    total_write = 0.0
    for name, current in sorted(after.items()):
        previous = before.get(name)
        if not previous:
            continue
        read_bps = max(0, current["read_sectors"] - previous["read_sectors"]) * BLOCK_SECTOR_BYTES / elapsed
        write_bps = max(0, current["write_sectors"] - previous["write_sectors"]) * BLOCK_SECTOR_BYTES / elapsed
        total_read += read_bps
        total_write += write_bps
        disks.append({
            "name": name,
            "read_bytes_per_sec": round(read_bps, 1),
            "write_bytes_per_sec": round(write_bps, 1),
            "reads_per_sec": round(max(0, current["reads"] - previous["reads"]) / elapsed, 1),
            "writes_per_sec": round(max(0, current["writes"] - previous["writes"]) / elapsed, 1),
            "busy_percent": round(clamp((max(0, current["io_ms"] - previous["io_ms"]) / (elapsed * 1000.0)) * 100.0), 1),
        })
    usage = shutil.disk_usage("/")
    usable_total = usage.used + usage.free
    return {
        "available": bool(disks),
        "root": {
            "mount": "/",
            "total_bytes": usage.total,
            "used_bytes": usage.used,
            "free_bytes": usage.free,
            "reserved_bytes": max(0, usage.total - usage.used - usage.free),
            "usage_percent": pct(usage.used, usable_total),
            "usage_percent_total": pct(usage.used, usage.total),
        },
        "total_read_bytes_per_sec": round(total_read, 1),
        "total_write_bytes_per_sec": round(total_write, 1),
        "devices": disks,
    }


def netdev_snapshot() -> dict[str, dict[str, int]]:
    text = read_text(PROC / "net/dev")
    devices: dict[str, dict[str, int]] = {}
    if not text:
        return devices
    for line in text.splitlines()[2:]:
        if ":" not in line:
            continue
        name, values = line.split(":", 1)
        name = name.strip()
        if name == "lo":
            continue
        parts = values.split()
        if len(parts) < 16:
            continue
        try:
            devices[name] = {
                "rx_bytes": int(parts[0]),
                "rx_packets": int(parts[1]),
                "rx_errors": int(parts[2]),
                "rx_drops": int(parts[3]),
                "tx_bytes": int(parts[8]),
                "tx_packets": int(parts[9]),
                "tx_errors": int(parts[10]),
                "tx_drops": int(parts[11]),
            }
        except ValueError:
            continue
    return devices


def is_virtual_interface(name: str) -> bool:
    if name.startswith(VIRTUAL_INTERFACE_PREFIXES):
        return True
    return (SYS / "devices/virtual/net" / name).exists()


def collect_network(before: dict[str, dict[str, int]], after: dict[str, dict[str, int]], elapsed: float) -> dict[str, Any]:
    interfaces: list[dict[str, Any]] = []
    total_rx = 0.0
    total_tx = 0.0
    for name, current in sorted(after.items()):
        previous = before.get(name)
        if not previous:
            continue
        rx_bps = max(0, current["rx_bytes"] - previous["rx_bytes"]) / elapsed
        tx_bps = max(0, current["tx_bytes"] - previous["tx_bytes"]) / elapsed
        total_rx += rx_bps
        total_tx += tx_bps
        operstate = read_text(SYS / "class/net" / name / "operstate")
        speed = read_int(SYS / "class/net" / name / "speed")
        virtual = is_virtual_interface(name)
        interfaces.append({
            "name": name,
            "state": operstate,
            "virtual": virtual,
            "rx_total_bytes": current["rx_bytes"],
            "tx_total_bytes": current["tx_bytes"],
            "speed_mbps": speed if speed and speed > 0 else None,
            "rx_bytes_per_sec": round(rx_bps, 1),
            "tx_bytes_per_sec": round(tx_bps, 1),
            "rx_packets_per_sec": round(max(0, current["rx_packets"] - previous["rx_packets"]) / elapsed, 1),
            "tx_packets_per_sec": round(max(0, current["tx_packets"] - previous["tx_packets"]) / elapsed, 1),
            "errors": current["rx_errors"] + current["tx_errors"],
            "drops": current["rx_drops"] + current["tx_drops"],
        })
    interfaces.sort(
        key=lambda item: (
            item["virtual"],
            item["state"] != "up",
            -(item["rx_bytes_per_sec"] + item["tx_bytes_per_sec"]),
            item["name"],
        )
    )
    return {
        "available": bool(interfaces),
        "download_bytes_per_sec": round(total_rx, 1),
        "upload_bytes_per_sec": round(total_tx, 1),
        "interfaces": interfaces[:12],
        "primary": interfaces[0] if interfaces else None,
        "interface_count": len(interfaces),
        "virtual_interface_count": len([item for item in interfaces if item["virtual"]]),
    }


def local_ipv4() -> str | None:
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(0.2)
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except OSError:
        return None
    finally:
        if sock is not None:
            sock.close()


def global_ipv4(state: dict[str, Any]) -> dict[str, Any]:
    cached = state.setdefault("global_ip", {})
    now = time.time()
    if cached.get("address") and now - float(cached.get("checked_at", 0)) < 60 * 60:
        return {"address": cached.get("address"), "checked_at": cached.get("checked_at"), "source": cached.get("source", "cache")}

    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=1.0) as response:
            address = response.read(64).decode("ascii", errors="ignore").strip()
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", address):
            cached.update({"address": address, "checked_at": now, "source": "api.ipify.org"})
            return {"address": address, "checked_at": now, "source": "api.ipify.org"}
    except Exception:
        pass
    return {"address": cached.get("address"), "checked_at": cached.get("checked_at"), "source": "cache" if cached.get("address") else None}


def period_keys(now: dt.datetime) -> dict[str, str]:
    iso = now.isocalendar()
    return {
        "daily": now.strftime("%Y-%m-%d"),
        "weekly": f"{iso.year}-W{iso.week:02d}",
        "monthly": now.strftime("%Y-%m"),
    }


def next_period_boundary(timestamp: float, period: str) -> float:
    current = dt.datetime.fromtimestamp(timestamp)
    if period == "daily":
        boundary = (current + dt.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    elif period == "weekly":
        start_of_day = current.replace(hour=0, minute=0, second=0, microsecond=0)
        boundary = start_of_day + dt.timedelta(days=7 - current.weekday())
    elif period == "monthly":
        if current.month == 12:
            boundary = current.replace(year=current.year + 1, month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
        else:
            boundary = current.replace(month=current.month + 1, day=1, hour=0, minute=0, second=0, microsecond=0)
    else:
        boundary = current + dt.timedelta(days=365 * 100)
    return boundary.timestamp()


def add_network_delta(periods: dict[str, Any], period: str, start: float, end: float, rx_delta: int, tx_delta: int) -> None:
    elapsed = max(0.0, end - start)
    if elapsed <= 0:
        return

    segments: list[tuple[str, float]] = []
    cursor = start
    while cursor < end:
        boundary = min(next_period_boundary(cursor, period), end)
        midpoint = cursor + max(0.0, boundary - cursor) / 2.0
        key = period_keys(dt.datetime.fromtimestamp(midpoint))[period]
        segments.append((key, max(0.0, boundary - cursor)))
        if boundary <= cursor:
            break
        cursor = boundary

    assigned_rx = 0
    assigned_tx = 0
    period_map = periods.setdefault(period, {})
    for index, (key, duration) in enumerate(segments):
        if index == len(segments) - 1:
            rx_part = rx_delta - assigned_rx
            tx_part = tx_delta - assigned_tx
        else:
            rx_part = int(round(rx_delta * (duration / elapsed)))
            tx_part = int(round(tx_delta * (duration / elapsed)))
            assigned_rx += rx_part
            assigned_tx += tx_part
        bucket = period_map.setdefault(key, {"rx_bytes": 0, "tx_bytes": 0})
        bucket["rx_bytes"] = int(bucket.get("rx_bytes", 0)) + max(0, rx_part)
        bucket["tx_bytes"] = int(bucket.get("tx_bytes", 0)) + max(0, tx_part)


def update_network_totals(state: dict[str, Any], network: dict[str, Any], counters: dict[str, dict[str, int]], boot_id: str | None) -> None:
    net_state = state.setdefault("network", {})
    periods = net_state.setdefault("periods", {})
    interface_state = net_state.setdefault("interfaces", {})
    now_ts = time.time()

    if net_state.get("boot_id") != boot_id:
        interface_state.clear()
        net_state["boot_id"] = boot_id

    traffic_interfaces: list[str] = []
    for name, current in sorted(counters.items()):
        if is_virtual_interface(name):
            continue
        traffic_interfaces.append(name)
        rx_total = int(current.get("rx_bytes") or 0)
        tx_total = int(current.get("tx_bytes") or 0)
        previous = interface_state.get(name)
        if isinstance(previous, dict):
            previous_rx = int(previous.get("rx_total_bytes") or 0)
            previous_tx = int(previous.get("tx_total_bytes") or 0)
            previous_ts = finite_float(previous.get("updated_at"))
            if previous_ts is not None and rx_total >= previous_rx and tx_total >= previous_tx:
                delta_rx = rx_total - previous_rx
                delta_tx = tx_total - previous_tx
                if delta_rx > 0 or delta_tx > 0:
                    for period in ("daily", "weekly", "monthly"):
                        add_network_delta(periods, period, previous_ts, now_ts, delta_rx, delta_tx)
        interface_state[name] = {
            "rx_total_bytes": rx_total,
            "tx_total_bytes": tx_total,
            "updated_at": now_ts,
        }

    active_names = set(counters.keys())
    for name in list(interface_state.keys()):
        if name not in active_names:
            interface_state.pop(name, None)

    now = dt.datetime.now()
    keys = period_keys(now)
    totals: dict[str, Any] = {}
    for period, key in keys.items():
        bucket = periods.setdefault(period, {}).setdefault(key, {"rx_bytes": 0, "tx_bytes": 0})
        totals[period] = {"key": key, "rx_bytes": int(bucket.get("rx_bytes", 0)), "tx_bytes": int(bucket.get("tx_bytes", 0))}

    for period, keep in (("daily", 45), ("weekly", 16), ("monthly", 18)):
        period_map = periods.setdefault(period, {})
        for key in sorted(period_map.keys())[:-keep]:
            period_map.pop(key, None)

    network["totals"] = totals
    network["traffic_interfaces"] = traffic_interfaces
    network["local_ipv4"] = local_ipv4()
    network["global_ipv4"] = global_ipv4(state)


def collect_power() -> dict[str, Any]:
    supplies: list[dict[str, Any]] = []
    root = SYS / "class/power_supply"
    if root.exists():
        for entry in sorted(root.iterdir()):
            if not entry.is_dir():
                continue
            supply_type = read_text(entry / "type")
            status = read_text(entry / "status")
            capacity = read_int(entry / "capacity")
            voltage = read_int(entry / "voltage_now")
            current_now = read_int(entry / "current_now")
            power_now = read_int(entry / "power_now")
            watts = power_now / 1_000_000.0 if power_now is not None else None
            if watts is None and voltage is not None and current_now is not None:
                watts = (voltage * current_now) / 1_000_000_000_000.0
            supply: dict[str, Any] = {
                "name": entry.name,
                "type": supply_type,
                "status": status,
                "capacity_percent": capacity,
                "power_watts": round(watts, 2) if watts is not None else None,
            }
            if supply_type == "Battery":
                energy_now = read_int(entry / "energy_now")
                energy_full = read_int(entry / "energy_full")
                energy_full_design = read_int(entry / "energy_full_design")
                charge_now = read_int(entry / "charge_now")
                charge_full = read_int(entry / "charge_full")
                charge_full_design = read_int(entry / "charge_full_design")
                voltage_min = read_int(entry / "voltage_min_design")
                time_to_empty = read_int(entry / "time_to_empty_now")
                time_to_full = read_int(entry / "time_to_full_now")
                health_percent = None
                if energy_full is not None and energy_full_design is not None and energy_full_design > 0:
                    health_percent = round(pct(energy_full, energy_full_design), 1)
                elif charge_full is not None and charge_full_design is not None and charge_full_design > 0:
                    health_percent = round(pct(charge_full, charge_full_design), 1)
                supply.update({
                    "manufacturer": read_text(entry / "manufacturer"),
                    "model_name": read_text(entry / "model_name"),
                    "technology": read_text(entry / "technology"),
                    "cycle_count": read_int(entry / "cycle_count"),
                    "health_percent": health_percent,
                    "energy_now_wh": round(energy_now / 1_000_000.0, 2) if energy_now is not None else None,
                    "energy_full_wh": round(energy_full / 1_000_000.0, 2) if energy_full is not None else None,
                    "energy_full_design_wh": round(energy_full_design / 1_000_000.0, 2) if energy_full_design is not None else None,
                    "charge_now_mah": round(charge_now / 1000.0) if charge_now is not None else None,
                    "charge_full_mah": round(charge_full / 1000.0) if charge_full is not None else None,
                    "charge_full_design_mah": round(charge_full_design / 1000.0) if charge_full_design is not None else None,
                    "voltage_v": round(voltage / 1_000_000.0, 3) if voltage is not None else None,
                    "voltage_min_design_v": round(voltage_min / 1_000_000.0, 3) if voltage_min is not None else None,
                    "time_to_empty_min": round(time_to_empty / 60) if time_to_empty is not None and 0 < time_to_empty < 86400 else None,
                    "time_to_full_min": round(time_to_full / 60) if time_to_full is not None and 0 < time_to_full < 86400 else None,
                })
            supplies.append(supply)

    rapl_watts: list[dict[str, Any]] = []
    for energy_path in sorted((SYS / "class/powercap").glob("intel-rapl:*/energy_uj")):
        name = read_text(energy_path.parent / "name") or energy_path.parent.name
        first = read_int(energy_path)
        time.sleep(0.05)
        second = read_int(energy_path)
        if first is None or second is None or second < first:
            continue
        rapl_watts.append({
            "name": name,
            "power_watts": round((second - first) / 1_000_000.0 / 0.05, 2),
        })
    return {
        "available": bool(supplies or rapl_watts),
        "supplies": supplies,
        "rapl": rapl_watts,
    }


def collect_battery(power: dict[str, Any]) -> dict[str, Any]:
    batteries = [s for s in power.get("supplies", []) if s.get("type") == "Battery"]
    if not batteries:
        return {"available": False}
    return {"available": True, **batteries[0]}


def first_cpu_power_watts(power: dict[str, Any]) -> float | None:
    for reading in power.get("rapl", []):
        name = str(reading.get("name", "")).lower()
        if "package" in name or "core" in name or "cpu" in name:
            return reading.get("power_watts")
    return power.get("rapl", [{}])[0].get("power_watts") if power.get("rapl") else None


def collect_gpu() -> dict[str, Any]:
    devices: list[dict[str, Any]] = []
    drm_root = SYS / "class/drm"
    if drm_root.exists():
        for card in sorted(drm_root.glob("card[0-9]")):
            vendor = read_text(card / "device/vendor")
            device = read_text(card / "device/device")
            busy = read_int(card / "device/gpu_busy_percent")
            mem_used = read_int(card / "device/mem_info_vram_used")
            mem_total = read_int(card / "device/mem_info_vram_total")
            name = read_text(card / "device/product") or read_text(card / "device/uevent")
            devices.append({
                "name": card.name,
                "vendor_id": vendor,
                "device_id": device,
                "label": name.splitlines()[0] if name else card.name,
                "usage_percent": busy,
                "vram_used_bytes": mem_used,
                "vram_total_bytes": mem_total,
                "vram_usage_percent": pct(mem_used or 0, mem_total or 0) if mem_total else None,
            })
    return {
        "available": bool(devices),
        "devices": devices,
    }


def process_snapshot() -> dict[int, dict[str, Any]]:
    processes: dict[int, dict[str, Any]] = {}
    boot_time = 0
    stat_text = read_text(PROC / "stat") or ""
    for line in stat_text.splitlines():
        if line.startswith("btime "):
            try:
                boot_time = int(line.split()[1])
            except (IndexError, ValueError):
                boot_time = 0
            break

    ticks = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
    page_size = os.sysconf("SC_PAGE_SIZE")
    own_pid = os.getpid()
    for proc in PROC.iterdir():
        if not proc.name.isdigit():
            continue
        if int(proc.name) == own_pid:
            continue
        stat = read_text(proc / "stat")
        status = parse_key_value_file(proc / "status")
        if not stat:
            continue
        try:
            comm_end = stat.rindex(")")
            comm = stat[stat.index("(") + 1:comm_end]
            fields = stat[comm_end + 2:].split()
            utime = int(fields[11])
            stime = int(fields[12])
            start_ticks = int(fields[19])
            rss_pages = int(fields[21])
        except (ValueError, IndexError, OSError):
            continue
        processes[int(proc.name)] = {
            "pid": int(proc.name),
            "name": status.get("Name") or comm,
            "state": status.get("State"),
            "cpu_ticks": utime + stime,
            "start_ticks": start_ticks,
            "rss_bytes": rss_pages * page_size,
            "boot_time": boot_time,
            "ticks_per_second": ticks,
        }
    return processes


def collect_processes(before: dict[int, dict[str, Any]], after: dict[int, dict[str, Any]], elapsed: float, limit: int) -> dict[str, Any]:
    processes: list[dict[str, Any]] = []
    ticks = os.sysconf(os.sysconf_names.get("SC_CLK_TCK", "SC_CLK_TCK"))
    for pid, current in after.items():
        previous = before.get(pid)
        if not previous or previous["start_ticks"] != current["start_ticks"]:
            continue
        cpu_delta = max(0, current["cpu_ticks"] - previous["cpu_ticks"])
        cpu_percent = (cpu_delta / ticks) / elapsed * 100.0
        processes.append({
            "pid": pid,
            "name": current["name"],
            "state": current["state"],
            "cpu_percent": round(cpu_percent, 1),
            "rss_bytes": current["rss_bytes"],
        })
    processes.sort(key=lambda item: (item["cpu_percent"], item["rss_bytes"]), reverse=True)
    return {
        "available": True,
        "count": len(after),
        "top": processes[:limit],
    }


def collect_uptime() -> dict[str, Any]:
    text = read_text(PROC / "uptime")
    seconds = 0.0
    if text:
        try:
            seconds = float(text.split()[0])
        except (IndexError, ValueError):
            seconds = 0.0
    return {
        "seconds": round(seconds, 1),
        "boot_time_epoch": round(time.time() - seconds, 1) if seconds else None,
        "kernel": platform.release(),
        "hostname": platform.node(),
        "os": platform.platform(),
    }


def collect_snapshot(  # noqa: PLR0913
    sample_window: float, process_limit: int,
    ram_p1: int = 1, ram_p2: int = 30,
    swap_p1: int = 1, swap_p2: int = 30,
    gpu_p1: int = 1, gpu_p2: int = 30,
    vram_p1: int = 1, vram_p2: int = 30,
    net_dl_p1: int = 1, net_dl_p2: int = 30,
    net_ul_p1: int = 1, net_ul_p2: int = 30,
) -> dict[str, Any]:
    sample_window = max(0.05, min(sample_window, 2.0))
    state = load_state()
    boot_id = read_boot_id()
    disk_before = diskstats_snapshot()
    net_before = netdev_snapshot()
    proc_before = process_snapshot()
    start = time.monotonic()
    cpu = collect_cpu(sample_window)
    elapsed = max(0.001, time.monotonic() - start)
    disk_after = diskstats_snapshot()
    net_after = netdev_snapshot()
    proc_after = process_snapshot()
    power = collect_power()
    cpu["power_watts"] = first_cpu_power_watts(power)
    memory = collect_memory()
    gpu = collect_gpu()
    network = collect_network(net_before, net_after, elapsed)
    temperatures = collect_temperatures()
    apply_cpu_history(state, cpu, boot_id)
    apply_temperature_history(state, temperatures, boot_id)
    update_network_totals(state, network, net_after, boot_id)

    memory["usage_average_percent"] = update_metric_averages(
        state, "ram_usage", memory["usage_percent"], boot_id, ram_p1, ram_p2)
    memory["swap"]["usage_average_percent"] = update_metric_averages(
        state, "swap_usage", memory["swap"]["usage_percent"], boot_id, swap_p1, swap_p2)

    gpu_devices = gpu.get("devices", [])
    if gpu_devices:
        gpu["usage_average_percent"] = update_metric_averages(
            state, "gpu_usage", float(gpu_devices[0].get("usage_percent") or 0), boot_id, gpu_p1, gpu_p2)
        gpu["vram_average_percent"] = update_metric_averages(
            state, "vram_usage", float(gpu_devices[0].get("vram_usage_percent") or 0), boot_id, vram_p1, vram_p2)

    network["download_average"] = update_metric_averages(
        state, "net_download", network.get("download_bytes_per_sec", 0), boot_id, net_dl_p1, net_dl_p2)
    network["upload_average"] = update_metric_averages(
        state, "net_upload", network.get("upload_bytes_per_sec", 0), boot_id, net_ul_p1, net_ul_p2)

    save_state(state)

    return {
        "schema_version": 1,
        "timestamp": time.time(),
        "sample_window_seconds": round(elapsed, 3),
        "uptime": collect_uptime(),
        "cpu": cpu,
        "memory": memory,
        "temperature": temperatures,
        "power": power,
        "battery": collect_battery(power),
        "gpu": gpu,
        "disk": collect_disks(disk_before, disk_after, elapsed),
        "network": network,
        "processes": collect_processes(proc_before, proc_after, elapsed, process_limit),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sample kernel telemetry for the SysLens plasmoid.")
    parser.add_argument("--json", action="store_true", help="print a single JSON snapshot")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON")
    parser.add_argument("--sample-window", type=float, default=0.35, help="seconds used for rate/usage sampling")
    parser.add_argument("--process-limit", type=int, default=6, help="number of top processes to include")
    parser.add_argument("--ram-period1-days",   type=int, default=1,  help="RAM short average window (days)")
    parser.add_argument("--ram-period2-days",   type=int, default=30, help="RAM long average window (days)")
    parser.add_argument("--swap-period1-days",  type=int, default=1,  help="swap short average window (days)")
    parser.add_argument("--swap-period2-days",  type=int, default=30, help="swap long average window (days)")
    parser.add_argument("--gpu-period1-days",   type=int, default=1,  help="GPU short average window (days)")
    parser.add_argument("--gpu-period2-days",   type=int, default=30, help="GPU long average window (days)")
    parser.add_argument("--vram-period1-days",  type=int, default=1,  help="VRAM short average window (days)")
    parser.add_argument("--vram-period2-days",  type=int, default=30, help="VRAM long average window (days)")
    parser.add_argument("--net-dl-period1-days",type=int, default=1,  help="net download short average window (days)")
    parser.add_argument("--net-dl-period2-days",type=int, default=30, help="net download long average window (days)")
    parser.add_argument("--net-ul-period1-days",type=int, default=1,  help="net upload short average window (days)")
    parser.add_argument("--net-ul-period2-days",type=int, default=30, help="net upload long average window (days)")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    snapshot = collect_snapshot(
        args.sample_window, max(0, args.process_limit),
        args.ram_period1_days,    args.ram_period2_days,
        args.swap_period1_days,   args.swap_period2_days,
        args.gpu_period1_days,    args.gpu_period2_days,
        args.vram_period1_days,   args.vram_period2_days,
        args.net_dl_period1_days, args.net_dl_period2_days,
        args.net_ul_period1_days, args.net_ul_period2_days,
    )
    indent = 2 if args.pretty else None
    print(json.dumps(snapshot, indent=indent, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
