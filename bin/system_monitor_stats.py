#!/usr/bin/env python3
"""System stats JSON for the lukedaduke.fan panel."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def read_cpu_load(sample_seconds: float = 0.1, stat_path: Path | None = None) -> int:
    path = stat_path or Path("/proc/stat")

    def parse_stat() -> tuple[int, int]:
        line = path.read_text().splitlines()[0]
        values = [int(p) for p in line.split()[1:]]
        idle = values[3]
        total = sum(values)
        return total, idle

    total1, idle1 = parse_stat()
    if sample_seconds > 0:
        time.sleep(sample_seconds)
        total2, idle2 = parse_stat()
    else:
        total2, idle2 = total1, idle1
    total_diff = total2 - total1
    idle_diff = idle2 - idle1
    if total_diff <= 0:
        return 0
    return round(100 * (1 - idle_diff / total_diff))


def read_meminfo(meminfo_path: Path | None = None) -> dict[str, Any]:
    path = meminfo_path or Path("/proc/meminfo")
    info: dict[str, int] = {}
    for line in path.read_text().splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        info[key.strip()] = int(value.strip().split()[0])
    total = info.get("MemTotal", 0) * 1024
    available = info.get("MemAvailable", info.get("MemFree", 0)) * 1024
    used = total - available
    swap_total = info.get("SwapTotal", 0) * 1024
    swap_free = info.get("SwapFree", 0) * 1024
    swap_used = swap_total - swap_free
    return {
        "total": total,
        "available": available,
        "used": used,
        "pct": round((used / total) * 100) if total else 0,
        "swap_total": swap_total,
        "swap_used": swap_used,
        "swap_pct": round((swap_used / swap_total) * 100) if swap_total else 0,
    }


def _ps_rows(sort_key: str, fields: str) -> list[list[str]]:
    try:
        out = subprocess.check_output(
            ["ps", "-eo", fields, f"--sort=-{sort_key}"],
            text=True,
            timeout=2,
        ).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"ps failed: {exc}", file=sys.stderr)
        return []
    rows: list[list[str]] = []
    for line in out.splitlines()[1:]:
        parts = line.strip().split(None, 3)
        if parts:
            rows.append(parts)
    return rows


def top_cpu(n: int = 5) -> list[dict[str, Any]]:
    procs: list[dict[str, Any]] = []
    for parts in _ps_rows("%cpu", "pid,comm,%cpu")[:n]:
        if len(parts) < 3:
            continue
        try:
            procs.append({
                "pid": int(parts[0]),
                "name": parts[1],
                "cpu_pct": float(parts[2]),
            })
        except ValueError:
            continue
    return procs


def top_mem(n: int = 5, min_mb: int = 15) -> list[dict[str, Any]]:
    procs: list[dict[str, Any]] = []
    for parts in _ps_rows("rss", "pid,comm,rss,pmem"):
        if len(procs) >= n:
            break
        if len(parts) < 4:
            continue
        try:
            rss_kb = int(parts[2])
            if rss_kb <= min_mb * 1024:
                continue
            procs.append({
                "pid": int(parts[0]),
                "name": parts[1],
                "mem_mb": round(rss_kb / 1024, 1),
                "mem_pct": float(parts[3]),
            })
        except ValueError:
            continue
    return procs


def hwmon_paths(base: Path | None = None) -> dict[str, Path]:
    mapping: dict[str, Path] = {}
    root = base or Path("/sys/class/hwmon")
    if not root.is_dir():
        return mapping
    for entry in root.iterdir():
        name_path = entry / "name"
        if not name_path.is_file():
            continue
        try:
            mapping[name_path.read_text().strip()] = entry
        except OSError:
            continue
    return mapping


def _milli_c(path: Path) -> str | None:
    try:
        return f"{round(int(path.read_text().strip()) / 1000)}°C"
    except (OSError, ValueError):
        return None


def read_temps(hwmon: dict[str, Path] | None = None) -> tuple[str, str, str, int, int]:
    cpu_temp = "--"
    gpu_temp = "--"
    nvme_temp = "--"
    fan1_rpm = 0
    fan2_rpm = 0
    devices = hwmon if hwmon is not None else hwmon_paths()
    ddv = devices.get("dell_ddv")
    if ddv:
        cpu_temp = _milli_c(ddv / "temp1_input") or cpu_temp
        try:
            fan1_rpm = int((ddv / "fan1_input").read_text().strip())
        except (OSError, ValueError):
            fan1_rpm = 0
        try:
            fan2_rpm = int((ddv / "fan2_input").read_text().strip())
        except (OSError, ValueError):
            fan2_rpm = 0
    nvme_temps: list[int] = []
    for name, path in devices.items():
        if name != "nvme":
            continue
        try:
            nvme_temps.append(round(int((path / "temp1_input").read_text().strip()) / 1000))
        except (OSError, ValueError):
            continue
    if nvme_temps:
        nvme_temp = f"{max(nvme_temps)}°C"
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
            text=True,
            timeout=1,
        ).strip()
        if out:
            gpu_temp = f"{round(float(out))}°C"
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return cpu_temp, gpu_temp, nvme_temp, fan1_rpm, fan2_rpm


def read_fan_mode(path: Path | None = None) -> str:
    mode_path = path or Path("/tmp/current_fan_mode")
    if not mode_path.is_file():
        return "med"
    try:
        mode = mode_path.read_text().strip()
    except OSError:
        return "med"
    return mode if mode in {"low", "med", "high"} else "med"


def collect(sample_seconds: float = 0.1) -> dict[str, Any]:
    mem = read_meminfo()
    cpu_temp, gpu_temp, nvme_temp, fan1_rpm, fan2_rpm = read_temps()
    return {
        "ok": True,
        "cpu_load": read_cpu_load(sample_seconds=sample_seconds),
        "cpu_temp": cpu_temp,
        "gpu_temp": gpu_temp,
        "nvme_temp": nvme_temp,
        "mem_pct": mem["pct"],
        "mem_used": f"{mem['used'] / (1024 ** 3):.1f}",
        "mem_avail": f"{mem['available'] / (1024 ** 3):.1f}",
        "mem_total": f"{mem['total'] / (1024 ** 3):.1f}",
        "swap_used": f"{mem['swap_used'] / (1024 ** 3):.1f}",
        "swap_total": f"{mem['swap_total'] / (1024 ** 3):.1f}",
        "swap_pct": mem["swap_pct"],
        "fan1_rpm": fan1_rpm,
        "fan2_rpm": fan2_rpm,
        "fan_mode": read_fan_mode(),
        "fan_control": shutil_which("omarchy-fan-set"),
        "top_mem": top_mem(),
        "top_cpu": top_cpu(),
    }


def shutil_which(name: str) -> bool:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return True
    return False


def main() -> int:
    print(json.dumps(collect()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
