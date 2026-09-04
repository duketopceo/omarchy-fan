#!/usr/bin/env python3
"""System stats JSON for the lukedaduke.fan panel."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SAMPLE_SECONDS = 0.1
MIN_MEM_MB = 15


def _read_proc_stat() -> dict[str, tuple[int, int]]:
    """Return {name: (total, idle)} for every cpu* line in /proc/stat."""
    stats: dict[str, tuple[int, int]] = {}
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            parts = line.split()
            if not parts or not parts[0].startswith("cpu"):
                continue
            values = [int(p) for p in parts[1:]]
            total = sum(values)
            idle = values[3]  # idle only; matches original single-cpu calc
            stats[parts[0]] = (total, idle)
    except OSError as exc:
        print(f"stat failed: {exc}", file=sys.stderr)
    return stats


def read_cpu_load(sample_seconds: float = SAMPLE_SECONDS) -> int:
    s1 = _read_proc_stat().get("cpu")
    if s1 is None:
        return 0
    if sample_seconds > 0:
        time.sleep(sample_seconds)
        s2 = _read_proc_stat().get("cpu")
    else:
        s2 = s1
    if s2 is None:
        return 0
    dtotal = s2[0] - s1[0]
    didle = s2[1] - s1[1]
    if dtotal <= 0:
        return 0
    return round(100 * (1 - didle / dtotal))


def read_cpu_cores(sample_seconds: float = SAMPLE_SECONDS) -> list[dict[str, int]]:
    s1 = _read_proc_stat()
    if sample_seconds > 0:
        time.sleep(sample_seconds)
        s2 = _read_proc_stat()
    else:
        s2 = s1.copy()

    cores: list[dict[str, int]] = []
    labels = [k for k in s2 if k.startswith("cpu") and k != "cpu" and k[3:].isdigit()]
    labels.sort(key=lambda x: int(x[3:]))
    for label in labels:
        if label not in s1:
            continue
        dtotal = s2[label][0] - s1[label][0]
        didle = s2[label][1] - s1[label][1]
        if dtotal <= 0:
            continue
        pct = round(100 * (1 - didle / dtotal))
        cores.append({"core": int(label[3:]), "percent": max(0, min(100, pct))})
    return cores


def cpu_name() -> str:
    try:
        with open("/proc/cpuinfo") as fh:
            for line in fh:
                if line.startswith("model name"):
                    name = line.split(":", 1)[1].strip()
                    # strip clock/brand noise
                    name = re.sub(r"\(R\)|\(TM\)|\(tm\)|\(r\)", "", name, flags=re.I)
                    name = re.sub(r"\s*CPU\s*@\s*[\d.]+\s*GHz", "", name, flags=re.I)
                    name = re.sub(r"\d+-Core Processor.*", "", name, flags=re.I)
                    name = name.replace("Processor", "").strip(" ,")
                    return " ".join(name.split()) or "CPU"
    except OSError:
        pass
    return "CPU"


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


def top_mem(n: int = 5, min_mb: int = MIN_MEM_MB) -> list[dict[str, Any]]:
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


def _milli_c_int(path: Path) -> int | None:
    try:
        return round(int(path.read_text().strip()) / 1000)
    except (OSError, ValueError):
        return None


def _read_fan_input(path: Path) -> int:
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return 0


def cpu_temp_and_fans(devices: dict[str, Path] | None = None) -> tuple[str, int, int]:
    cpu_temp = "--"
    fan1_rpm = 0
    fan2_rpm = 0
    if devices is None:
        devices = hwmon_paths()

    # Dell ddv gives us package temp and fan RPM
    ddv = devices.get("dell_ddv")
    if ddv:
        cpu_temp = _milli_c(ddv / "temp1_input") or cpu_temp
        fan1_rpm = _read_fan_input(ddv / "fan1_input")
        fan2_rpm = _read_fan_input(ddv / "fan2_input")
        return cpu_temp, fan1_rpm, fan2_rpm

    # Common laptop/CPU temp sensors
    for name in ("coretemp", "k10temp", "zenpower"):
        path = devices.get(name)
        if path:
            # prefer the first input; coretemp package is often temp1
            for label in ("temp1_input", "temp2_input"):
                cpu_temp = _milli_c(path / label) or cpu_temp
            if cpu_temp != "--":
                break

    # Generic fan inputs if no dell sensor
    for name in ("dell_smm", "dell_ddv"):
        path = devices.get(name)
        if path:
            fan1_rpm = _read_fan_input(path / "fan1_input")
            fan2_rpm = _read_fan_input(path / "fan2_input")
            break

    return cpu_temp, fan1_rpm, fan2_rpm


def nvme_temp(devices: dict[str, Path] | None = None) -> str:
    if devices is None:
        devices = hwmon_paths()
    temps: list[int] = []
    for name, path in devices.items():
        if name != "nvme":
            continue
        try:
            temps.append(round(int((path / "temp1_input").read_text().strip()) / 1000))
        except (OSError, ValueError):
            continue
    if not temps:
        return "--"
    return f"{max(temps)}°C"


def gpu_info() -> tuple[str, int | None, str]:
    """Return (gpu_name, gpu_load_percent_or_None, gpu_temp_str)."""
    gpu_name = "GPU"
    gpu_load: int | None = None
    gpu_temp = "--"

    # NVIDIA
    if Path("/proc/driver/nvidia/version").is_file():
        try:
            out = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,name",
                 "--format=csv,noheader,nounits"],
                text=True,
                timeout=1,
            ).strip().splitlines()[0].split(",")
            if len(out) >= 3:
                load = out[0].strip()
                temp = out[1].strip()
                name = out[2].strip()
                if load:
                    gpu_load = max(0, min(100, round(float(load))))
                if temp:
                    gpu_temp = f"{round(float(temp))}°C"
                gpu_name = _clean_gpu_name(name)
                return gpu_name, gpu_load, gpu_temp
        except (OSError, subprocess.SubprocessError, ValueError):
            pass

    # AMD gpu_busy_percent
    try:
        for f in Path("/sys/class/drm").glob("card*/device/gpu_busy_percent"):
            if not f.is_file():
                continue
            v = f.read_text().strip()
            if v:
                gpu_load = max(0, min(100, round(float(v))))
                # temp alongside
                temp_path = f.parent / "hwmon" / "hwmon*" / "temp1_input"
                for tp in f.parent.glob("hwmon/hwmon*/temp1_input"):
                    t = _milli_c(tp)
                    if t:
                        gpu_temp = t
                        break
                gpu_name = _gpu_name_from_lspci() or "AMD GPU"
                return gpu_name, gpu_load, gpu_temp
    except (OSError, ValueError):
        pass

    # Fallback to just a name and no load/temp
    gpu_name = _gpu_name_from_lspci() or "GPU"
    return gpu_name, gpu_load, gpu_temp


def _clean_gpu_name(raw: str) -> str:
    name = raw.strip()
    name = re.sub(r"\s*\([^)]*rev[^)]*\)", "", name, flags=re.I)
    name = re.sub(r"^Advanced Micro Devices, Inc\.?\s*", "", name, flags=re.I)
    name = re.sub(r"^(AMD/ATI|ATI)\s*", "AMD ", name, flags=re.I)
    name = re.sub(r"^Intel Corporation\s*", "Intel ", name, flags=re.I)
    name = re.sub(r"^NVIDIA Corporation\s*", "NVIDIA ", name, flags=re.I)
    name = name.replace(" Corporation", "").strip()
    return " ".join(name.split()) or "GPU"


def _gpu_name_from_lspci() -> str | None:
    try:
        out = subprocess.check_output(["lspci", "-mm"], text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if "VGA" not in line and "3D controller" not in line and "Display controller" not in line:
            continue
        parts = re.findall(r'"([^"]*)"', line)
        if len(parts) >= 3:
            return _clean_gpu_name(parts[1] + " " + parts[2])
        if ": " in line:
            return _clean_gpu_name(line.split(": ", 1)[1])
    return None


def ram_info() -> str:
    """Try to produce a short RAM type + speed label."""
    try:
        out = subprocess.check_output(["inxi", "-m", "-c0"], text=True, timeout=2, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        out = ""
    if out:
        # Look for Memory: ... type: DDR4 ... speed: 3200 MT/s
        m = re.search(r"type:\s*([^\s,]+).*?speed:\s*([^\s,]+)\s*MT/s", out, re.I | re.S)
        if m:
            return f"{m.group(1).strip()} {m.group(2).strip()} MT/s"
    # dmidecode usually needs root, but try in case it works
    try:
        out = subprocess.check_output(["dmidecode", "-t", "memory"], text=True, timeout=1, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    types: set[str] = set()
    speeds: set[str] = set()
    block: dict[str, str] = {}
    for line in out.splitlines():
        if not line.strip():
            if block.get("Size") and block.get("Size") != "No Module Installed":
                t = block.get("Type", "")
                if t and t.lower() not in {"unknown", "other", "none", "n/a"}:
                    types.add(t)
                s = block.get("Configured Memory Speed") or block.get("Speed") or ""
                m = re.search(r"(\d+)\s*MT/s", s)
                if m:
                    speeds.add(m.group(1))
            block = {}
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            block[k.strip()] = v.strip()
    if types and speeds:
        return f"{'/'.join(sorted(types))} {'/'.join(sorted(speeds))} MT/s"
    if types:
        return "/".join(sorted(types))
    return ""


ALLOWED_FS = {
    "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "zfs", "jfs", "reiserfs",
    "nilfs2", "bcachefs", "vfat", "exfat", "ntfs", "ntfs3", "hfsplus", "ufs",
}


def disk_usage() -> list[dict[str, Any]]:
    try:
        out = subprocess.check_output(
            ["df", "-P", "-T", "-l", "--block-size=1"],
            text=True,
            timeout=2,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return []

    by_device: dict[str, dict[str, Any]] = {}
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 7:
            continue
        device = parts[0]
        type_ = parts[1]
        if not (type_ in ALLOWED_FS or parts[-1] == "/"):
            continue
        try:
            total_b = int(parts[2])
            used_b = int(parts[3])
            pct = int(parts[5].rstrip("%"))
            mount = " ".join(parts[6:])
        except ValueError:
            continue
        if total_b <= 0:
            continue
        entry = {
            "mount": mount,
            "used_gb": round(used_b / (1024 ** 3), 1),
            "total_gb": round(total_b / (1024 ** 3), 1),
            "percent": pct,
        }
        if device not in by_device or len(mount) < len(by_device[device]["mount"]):
            by_device[device] = entry

    # stable order: root first, then by mount name
    return sorted(by_device.values(), key=lambda x: (x["mount"] != "/", x["mount"]))


def read_fan_mode(path: Path | None = None) -> str:
    mode_path = path or Path("/tmp/current_fan_mode")
    if not mode_path.is_file():
        return "auto"
    try:
        mode = mode_path.read_text().strip().lower()
    except OSError:
        return "auto"
    return mode if mode in {"auto", "low", "med", "high", "custom"} or mode.startswith("custom-") else "auto"


def read_fan_curve() -> list[list[int]]:
    """Read the active custom fan curve from the XDG config path."""
    home = Path.home()
    path = home / ".config" / "omarchy" / "fan_curve.json"
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text())
        if isinstance(data, list) and all(isinstance(p, list) and len(p) == 2 for p in data):
            return [[int(p[0]), int(p[1])] for p in data]
    except (OSError, ValueError):
        pass
    return []


def collect(sample_seconds: float = SAMPLE_SECONDS) -> dict[str, Any]:
    mem = read_meminfo()
    devices = hwmon_paths()
    cpu_temp, fan1_rpm, fan2_rpm = cpu_temp_and_fans(devices)
    gpu_name, gpu_load, gpu_temp = gpu_info()

    # If nvidia gave a temp, prefer it for the GPU temp field; otherwise use the one we had
    return {
        "ok": True,
        "cpu_name": cpu_name(),
        "cpu_load": read_cpu_load(sample_seconds=sample_seconds),
        "cpu_cores": read_cpu_cores(),
        "cpu_temp": cpu_temp,
        "gpu_name": gpu_name,
        "gpu_load": gpu_load if gpu_load is not None else -1,
        "gpu_temp": gpu_temp,
        "nvme_temp": nvme_temp(devices),
        "ram_info": ram_info(),
        "mem_pct": mem["pct"],
        "mem_used": f"{mem['used'] / (1024 ** 3):.1f}",
        "mem_avail": f"{mem['available'] / (1024 ** 3):.1f}",
        "mem_total": f"{mem['total'] / (1024 ** 3):.1f}",
        "swap_used": f"{mem['swap_used'] / (1024 ** 3):.1f}",
        "swap_total": f"{mem['swap_total'] / (1024 ** 3):.1f}",
        "swap_pct": mem["swap_pct"],
        "disks": disk_usage(),
        "fan1_rpm": fan1_rpm,
        "fan2_rpm": fan2_rpm,
        "fan_mode": read_fan_mode(),
        "fan_curve": read_fan_curve(),
        "fan_control": (Path(__file__).parent / "omarchy-fan-set").is_file(),
        "top_mem": top_mem(),
        "top_cpu": top_cpu(),
    }


def main() -> int:
    print(json.dumps(collect()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
