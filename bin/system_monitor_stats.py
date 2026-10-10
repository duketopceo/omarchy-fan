#!/usr/bin/python3
"""System stats JSON for the lukedaduke.fan panel."""

from __future__ import annotations

import json
import os
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any

SAMPLE_SECONDS = 0.1
MIN_MEM_MB = 15
JOB_DEADLINE_S = 8
MAX_OUT_BYTES = 262144
MAX_STR = 96
MAX_LIST = 64

CONFIG_PATH = Path.home() / ".config" / "omarchy" / "resources.json"

# Built-in comm -> display name map; ~/.config/omarchy/resources.json
# "names" overrides or extends it. Keys are the 15-char comm.
FRIENDLY_NAMES: dict[str, str] = {
    "qemu-system-aar": "Windows VM",
    "qemu-system-x86": "QEMU VM",
    "wlfreerdp": "Windows RDP",
    "wlfreerdp3": "Windows RDP",
    "xfreerdp": "Windows RDP",
    "xfreerdp3": "Windows RDP",
    "remote-viewer": "VM Console",
    "muvm": "Steam VM",
    "libkrun": "Steam VM",
    "chromium": "Chromium",
    "chrome": "Chrome",
    "cursor": "Cursor",
    "devin": "Devin",
    "quickshell": "Omarchy Shell",
    "wispr-flow": "Wispr Flow",
    "wispd": "Wisp",
    "grok-bot": "Grok Bot",
    "agy": "Antigravity",
    "ollama": "Ollama",
    "dockerd": "Docker",
    "docker": "Docker",
    "docker-compose": "Docker Compose",
    "containerd": "containerd",
    "tailscaled": "Tailscale",
    "steam": "Steam",
    "ghostty": "Ghostty",
    "kitty": "Kitty",
    "foot": "Foot",
    "footclient": "Foot",
    "code": "VS Code",
    "obsidian": "Obsidian",
    "Hermes": "Hermes",
    "hermes": "Hermes",
    "voxtype": "Voxtype",
    "firefox": "Firefox",
    "thunderbird": "Thunderbird",
    "slack": "Slack",
    "nautilus": "Files",
    "spotifast": "Spotifast",
    "easyeffects": "Easy Effects",
    "solaar": "Solaar",
    "Hyprland": "Hyprland",
    "hyprland": "Hyprland",
    "1password": "1Password",
    "gh": "GitHub CLI",
    "codex": "Codex",
    "claude": "Claude",
    "gemini": "Gemini",
    "btop": "btop",
    "python": "Python",
    "python3": "Python",
    "node": "Node.js",
    "npm": "npm",
    "java": "Java",
    "postgres": "PostgreSQL",
    "Xwayland": "Xwayland",
    "pipewire": "PipeWire",
    "wireplumber": "WirePlumber",
    "blip-bridged": "Blip Bridge",
    "llama-server": "llama.cpp",
    "kworker": "kernel worker",
    "systemd": "systemd",
    "sshd": "SSH",
}


def _argv_flag_value(args: str, *flags: str) -> str:
    """Value of `-f v` / `--flag v` / `--flag=v` inside a cmdline string."""
    try:
        toks = shlex.split(args)
    except ValueError:
        toks = args.split()
    for i, tok in enumerate(toks):
        for flag in flags:
            if tok == flag:
                return toks[i + 1] if i + 1 < len(toks) else ""
            if tok.startswith(flag + "="):
                return tok.split("=", 1)[1]
    return ""


# Trailing quantization tag on GGUF filenames: -q4_k_m, -IQ2_XXS, -f16, -bf16.
_QUANT_SUFFIX = re.compile(r"[-_.](?:i?q\d[\w]*|f(?:16|32|p16)|bf16)$", re.I)


def _llama_cpp_name(comm: str, exe: str, args: str) -> str:
    """`llama.cpp {model basename} (:port)` derived from the server's argv."""
    label = "llama.cpp"
    model = _argv_flag_value(args, "-m", "--model")
    if model:
        base = os.path.basename(model)
        base = re.sub(r"\.(?:gguf|bin)$", "", base, flags=re.I)
        base = _QUANT_SUFFIX.sub("", base)
        if base:
            label += " " + _clip(base, 32)
    port = _argv_flag_value(args, "--port")
    if port.isdigit():
        label += f" (:{port})"
    return label


# Data-driven naming rules, evaluated in order; first match wins.
# Keys: "comm" exact match, "exe_contains"/"arg_contains" substring match —
# all present keys must hold. "name" is a string or a
# (comm, exe, args) -> str callable.
NAMING_RULES: list[dict[str, Any]] = [
    # Ollama's spawned runner vs. the user's own llama.cpp fleet (KTD1).
    {"comm": "llama-server", "exe_contains": "ollama", "name": "Ollama Backend"},
    {"comm": "llama-server", "arg_contains": "ollama", "name": "Ollama Backend"},
    {"comm": "ollama_llama_se", "name": "Ollama Backend"},
    {"comm": "llama-server", "exe_contains": "llama.cpp", "name": _llama_cpp_name},
]


def _rule_matches(match: dict[str, str], comm: str, exe: str, args: str) -> bool:
    """All present match keys must hold: comm/exe equality-or-substring,
    arg/exe_contains/arg_contains substrings."""
    if "comm" in match and match["comm"] != comm:
        return False
    for key, haystack in (("exe", exe), ("exe_contains", exe),
                          ("arg", args), ("arg_contains", args)):
        if key in match and match[key] not in haystack:
            return False
    return True


def _parse_user_rule(entry: Any) -> dict[str, Any] | None:
    """Normalize one resources.json "rules" entry; None when malformed.

    Shape: {"match": {"comm"|"exe"|"arg": str}, "name": str}. `comm` is an
    exact match; `exe`/`arg` are substring contains (same as built-ins).
    """
    if not isinstance(entry, dict):
        return None
    match = entry.get("match")
    name = entry.get("name")
    if not isinstance(match, dict) or not isinstance(name, str) or not name.strip():
        return None
    cleaned: dict[str, str] = {}
    for key in ("comm", "exe", "arg"):
        val = match.get(key)
        if val is None:
            continue
        if not isinstance(val, str) or not val:
            return None
        cleaned[key] = _clip(val, MAX_STR)
    if not cleaned:
        return None
    return {"match": cleaned, "name": _clip(name.strip(), 48)}


_proc_config_cache: dict[str, Any] | None = None


def _proc_config() -> dict[str, Any]:
    """User process-view config: names, rules, min_mem_mb, top, find_max."""
    global _proc_config_cache
    if _proc_config_cache is not None:
        return _proc_config_cache
    cfg: dict[str, Any] = {"names": {}, "rules": [], "min_mem_mb": MIN_MEM_MB, "top": 32, "find_max": 24}
    try:
        raw = CONFIG_PATH.read_bytes()
        if len(raw) <= 256 * 1024:
            data = json.loads(raw)
            if isinstance(data, dict):
                if isinstance(data.get("names"), dict):
                    cfg["names"] = {
                        _clip(str(k), 15): _clip(str(v), 48)
                        for k, v in data["names"].items()
                    }
                if isinstance(data.get("rules"), list):
                    for i, entry in enumerate(data["rules"][:MAX_LIST]):
                        rule = _parse_user_rule(entry)
                        if rule is None:
                            print(
                                f"resources.json: rule[{i}] malformed, skipped",
                                file=sys.stderr,
                            )
                            continue
                        cfg["rules"].append(rule)
                elif "rules" in data:
                    print("resources.json: 'rules' is not a list, ignored",
                          file=sys.stderr)
                for key, lo, hi in (("min_mem_mb", 1, 4096), ("top", 1, MAX_LIST), ("find_max", 1, MAX_LIST)):
                    try:
                        cfg[key] = max(lo, min(hi, int(data.get(key, cfg[key]))))
                    except (TypeError, ValueError):
                        pass
    except (OSError, ValueError):
        pass
    _proc_config_cache = cfg
    return cfg


def display_name(comm: str, exe: str | None = None, args: str | None = None,
                 cfg: dict[str, Any] | None = None) -> str:
    """Human label for a process (KTD1): user rules -> user names map ->
    built-in NAMING_RULES -> FRIENDLY_NAMES -> title-cased comm."""
    cfg = _proc_config() if cfg is None else cfg
    exe = exe or ""
    args = args or ""
    for rule in cfg.get("rules", []):
        if _rule_matches(rule["match"], comm, exe, args):
            return _clip(rule["name"], 48)
    friendly = cfg.get("names", {}).get(comm)
    if friendly is not None:
        return friendly
    for rule in NAMING_RULES:
        if _rule_matches(rule, comm, exe, args):
            name = rule["name"]
            resolved = name(comm, exe, args) if callable(name) else name
            return _clip(resolved or comm, 48) or comm
    if comm in FRIENDLY_NAMES:
        return FRIENDLY_NAMES[comm]
    return comm.title() or comm

# Fixed search path for external tools: a PATH-preceding shadow binary in the
# caller's environment must never execute inside the long-lived shell process.
SAFE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
SAFE_ENV = {
    "PATH": SAFE_PATH,
    "LC_ALL": "C",
    "LANG": "C",
}


def _tool(name: str) -> str | None:
    """Absolute path for an external helper, resolved under SAFE_PATH only."""
    return shutil.which(name, path=SAFE_PATH)


def _kill_tree(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        try:
            proc.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass


def _run(argv: list[str], timeout: float = 2.0,
       max_bytes: int = MAX_OUT_BYTES) -> str | None:
    """Run argv with a minimal env, a hard deadline, and a producer byte cap.

    Returns stdout decoded as text, or None on failure/timeout/overflow.
    The child runs in its own process group so TERM/KILL reaches the tree.
    """
    if not argv or not argv[0]:
        return None
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=SAFE_ENV,
            start_new_session=True,
        )
    except OSError:
        return None
    buf = bytearray()
    deadline = time.monotonic() + timeout
    completed = False
    sel = selectors.DefaultSelector()
    try:
        sel.register(proc.stdout, selectors.EVENT_READ)
        while True:
            if proc.poll() is not None:
                tail = proc.stdout.read()
                if tail:
                    buf += tail
                completed = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if not sel.select(remaining):
                break
            try:
                chunk = os.read(proc.stdout.fileno(), 65536)
            except OSError:
                break
            if not chunk:
                completed = True  # producer closed stdout; nothing more to read
                break
            buf += chunk
            if len(buf) > max_bytes:
                break
    finally:
        sel.close()
        if proc.poll() is None:
            _kill_tree(proc)
        try:
            proc.stdout.close()
        except OSError:
            pass
    if not completed or len(buf) > max_bytes:
        return None
    return buf.decode(errors="replace")


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


def _read_cpu_stats(sample_seconds: float = SAMPLE_SECONDS) -> tuple[int, list[dict[str, int]]]:
    """Sample /proc/stat once to compute both overall CPU load and per-core percentages."""
    s1 = _read_proc_stat()
    if sample_seconds > 0:
        time.sleep(sample_seconds)
        s2 = _read_proc_stat()
    else:
        s2 = s1.copy()

    # Overall CPU load
    cpu_load = 0
    c1, c2 = s1.get("cpu"), s2.get("cpu")
    if c1 and c2:
        dt = c2[0] - c1[0]
        di = c2[1] - c1[1]
        if dt > 0:
            cpu_load = round(100 * (1 - di / dt))

    # Per-core breakdown
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

    return cpu_load, cores


def read_cpu_load(sample_seconds: float = SAMPLE_SECONDS) -> int:
    return _read_cpu_stats(sample_seconds)[0]


def read_cpu_cores(sample_seconds: float = SAMPLE_SECONDS) -> list[dict[str, int]]:
    return _read_cpu_stats(sample_seconds)[1]


_CACHED_CPU_NAME: str | None = None

def cpu_name() -> str:
    global _CACHED_CPU_NAME
    if _CACHED_CPU_NAME is not None:
        return _CACHED_CPU_NAME

    # 1. DeviceTree model (Apple Silicon, ARM boards)
    dt_model = Path("/sys/firmware/devicetree/base/model")
    if dt_model.is_file():
        try:
            raw = dt_model.read_bytes().replace(b"\x00", b"").decode("utf-8", errors="replace").strip()
            m = re.search(r"Apple.*?\((?:[^,]+,\s*)?(M\d+(?:\s+(?:Pro|Max|Ultra))?)(?:,\s*\d+)?\)", raw, re.I)
            if m:
                _CACHED_CPU_NAME = f"Apple {m.group(1).strip()}"
                return _CACHED_CPU_NAME
            elif raw.startswith("Apple "):
                _CACHED_CPU_NAME = raw.split("(")[0].strip()
                return _CACHED_CPU_NAME
            elif raw:
                _CACHED_CPU_NAME = raw[:32]
                return _CACHED_CPU_NAME
        except OSError:
            pass

    # 2. /proc/cpuinfo
    try:
        with open("/proc/cpuinfo") as fh:
            for line in fh:
                if line.startswith("model name"):
                    name = line.split(":", 1)[1].strip()
                    # strip clock/brand noise
                    name = re.sub(r"\(R\)|\(TM\)|\(tm\)|\(r\)", "", name, flags=re.I)
                    name = re.sub(r"\s*CPU\s*@\s*[\d.]+\s*GHz", "", name, flags=re.I)
                    name = re.sub(r"\d+-Core Processor.*", "", name, flags=re.I)
                    _CACHED_CPU_NAME = " ".join(name.split()) or "CPU"
                    return _CACHED_CPU_NAME
                elif line.startswith("Hardware") or line.startswith("Model"):
                    name = line.split(":", 1)[1].strip()
                    if name:
                        _CACHED_CPU_NAME = name
                        return _CACHED_CPU_NAME
    except OSError:
        pass

    # 3. DMI product name
    dmi = Path("/sys/devices/virtual/dmi/id/product_name")
    if dmi.is_file():
        try:
            val = dmi.read_text().strip()
            if val and val.lower() not in {"none", "system product name"}:
                _CACHED_CPU_NAME = val[:32]
                return _CACHED_CPU_NAME
        except OSError:
            pass

    _CACHED_CPU_NAME = "CPU"
    return _CACHED_CPU_NAME


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
    ps = _tool("ps")
    if not ps:
        return []
    out = _run([ps, "-eo", fields, f"--sort=-{sort_key}"], timeout=2)
    if out is None:
        print("ps failed", file=sys.stderr)
        return []
    out = out.strip()
    rows: list[list[str]] = []
    for line in out.splitlines()[1:]:
        # maxsplit = field count - 1, so a trailing "args" column keeps its
        # spaces; numeric columns always land in fixed slots.
        parts = line.strip().split(None, fields.count(","))
        if parts:
            rows.append(parts)
    return rows


def top_cpu(n: int = 5) -> list[dict[str, Any]]:
    cfg = _proc_config()
    procs: list[dict[str, Any]] = []
    for parts in _ps_rows("%cpu", "pid,comm,%cpu,args")[:n]:
        if len(parts) < 3:
            continue
        args = parts[3] if len(parts) > 3 else parts[1]
        row = _proc_row(parts[0], parts[1], args, cfg)
        if row is None:
            continue
        try:
            row["cpu_pct"] = float(parts[2])
        except ValueError:
            continue
        procs.append(row)
    return procs


def _proc_identity(pid: int, args: str) -> tuple[str, str, str]:
    """(exe_path, exe_basename, unit_leaf) — cheap per-row identity for the
    hover tooltip and kill confirmation (KTD2). A readlink and a small cgroup
    read per accepted row; no process spawn. Falls back to argv0 when
    /proc/<pid>/exe is unreadable (other users' processes)."""
    exe_path = ""
    try:
        exe_path = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        pass
    if not exe_path and args:
        argv0 = args.split(None, 1)[0]
        if not argv0.startswith("["):
            exe_path = argv0
    exe_base = os.path.basename(exe_path) if exe_path else ""
    unit = ""
    try:
        with open(f"/proc/{pid}/cgroup", "rb") as fh:
            lines = fh.read(4096).splitlines()
        leaf = b""
        for line in lines:
            if line.startswith(b"0::"):
                leaf = line
                break
        else:
            leaf = lines[-1] if lines else b""
        if leaf:
            unit = leaf.rsplit(b"/", 1)[-1].decode(errors="replace")
    except OSError:
        pass
    return _clip(exe_path, MAX_STR), _clip(exe_base, 32), _clip(unit, 64)


def _proc_row(pid_s: str, comm: str, args: str,
              cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Identity fields shared by top_mem and find rows; None on bad pid."""
    try:
        pid = int(pid_s)
    except ValueError:
        return None
    exe_path, exe_base, unit = _proc_identity(pid, args)
    return {
        "pid": pid,
        "name": comm,
        "comm": comm,
        "display": _clip(display_name(comm, exe_path, args, cfg), 48),
        "exe": exe_base,
        "exe_path": exe_path,
        "args": _clip(args),
        "unit": unit,
    }


def top_mem(n: int = 5, min_mb: int = MIN_MEM_MB) -> list[dict[str, Any]]:
    cfg = _proc_config()
    procs: list[dict[str, Any]] = []
    for parts in _ps_rows("rss", "pid,comm,rss,pmem,%cpu,args"):
        if len(procs) >= n:
            break
        if len(parts) < 5:
            continue
        try:
            rss_kb = int(parts[2])
            if rss_kb <= min_mb * 1024:
                continue
            comm = parts[1]
            args = parts[5] if len(parts) > 5 else comm
            row = _proc_row(parts[0], comm, args, cfg)
            if row is None:
                continue
            row["mem_mb"] = round(rss_kb / 1024, 1)
            row["mem_pct"] = float(parts[3])
            row["cpu_pct"] = float(parts[4])
            procs.append(row)
        except ValueError:
            continue
    return procs


def find_procs(query: str, n: int = 24, min_mb: int = 1) -> list[dict[str, Any]]:
    """Search every process by comm/cmdline substring; sorted by RSS.

    Used by the panel's '/' find field, so matches are not limited to the
    top-memory slice the idle panel shows.
    """
    cfg = _proc_config()
    q = query.strip().lower()
    if not q:
        return []
    procs: list[dict[str, Any]] = []
    for parts in _ps_rows("rss", "pid,comm,rss,%cpu,args"):
        if len(parts) < 5:
            continue
        try:
            comm = parts[1]
            cmdline = parts[4] if len(parts) > 4 else comm
            if q not in comm.lower() and q not in cmdline.lower():
                continue
            rss_kb = int(parts[2])
            if rss_kb <= min_mb * 1024:
                continue
            row = _proc_row(parts[0], comm, cmdline, cfg)
            if row is None:
                continue
            row["mem_mb"] = round(rss_kb / 1024, 1)
            row["cpu_pct"] = float(parts[3])
            procs.append(row)
            if len(procs) >= n:
                break
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

    # Apple Silicon SMC (Asahi Linux macsmc_hwmon)
    macsmc = devices.get("macsmc_hwmon")
    if macsmc:
        fan1_rpm = _read_fan_input(macsmc / "fan1_input")
        fan2_rpm = _read_fan_input(macsmc / "fan2_input")
        temps = []
        for tfile in macsmc.glob("temp*_input"):
            val = _milli_c_int(tfile)
            if val is not None and 10 <= val <= 115:
                temps.append(val)
        if temps:
            cpu_temp = f"{max(temps)}°C"
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

    # 1. Apple Silicon macsmc NAND Flash temperature
    macsmc = devices.get("macsmc_hwmon")
    if macsmc:
        for tf in macsmc.glob("temp*input"):
            lf = macsmc / tf.name.replace("input", "label")
            if lf.is_file() and "nand" in lf.read_text().lower():
                val = _milli_c_int(tf)
                if val is not None:
                    return f"{val}°C"

    # 2. Standard NVMe or drivetemp sensors
    for name, path in devices.items():
        if "nvme" in name.lower() or "drivetemp" in name.lower():
            for tf in path.glob("temp*input"):
                val = _milli_c_int(tf)
                if val is not None and 0 <= val <= 110:
                    temps.append(val)

    if not temps:
        return "--"
    return f"{max(temps)}°C"


def gpu_info() -> tuple[str, int | None, str]:
    """Return (gpu_name, gpu_load_percent_or_None, gpu_temp_str)."""
    gpu_name = "GPU"
    gpu_load: int | None = None
    gpu_temp = "--"

    # 1. NVIDIA
    nvidia = _tool("nvidia-smi")
    if nvidia and Path("/proc/driver/nvidia/version").is_file():
        out_text = _run(
            [nvidia, "--query-gpu=utilization.gpu,temperature.gpu,name",
             "--format=csv,noheader,nounits"],
            timeout=1, max_bytes=8192,
        )
        try:
            if out_text:
                out = out_text.strip().splitlines()[0].split(",")
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
        except (ValueError, IndexError):
            pass

    # 2. AMD gpu_busy_percent
    try:
        for f in Path("/sys/class/drm").glob("card*/device/gpu_busy_percent"):
            if not f.is_file():
                continue
            v = f.read_text().strip()
            if v:
                gpu_load = max(0, min(100, round(float(v))))
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

    # 3. Apple Silicon AGX GPU (asahi DRM driver)
    if _is_asahi_gpu():
        c_name = cpu_name()
        gpu_name = f"{c_name} GPU" if "Apple" in c_name else "Apple Silicon GPU"
        gpu_load = _asahi_gpu_load()
        # On Apple Silicon unified SoC, die temp is shared
        devices = hwmon_paths()
        cpu_t, _, _ = cpu_temp_and_fans(devices)
        return gpu_name, gpu_load, cpu_t

    # 4. Fallback to lspci
    gpu_name = _gpu_name_from_lspci() or "GPU"
    return gpu_name, gpu_load, gpu_temp


def _is_asahi_gpu() -> bool:
    if Path("/sys/bus/platform/drivers/asahi").is_dir() or Path("/sys/bus/platform/drivers/apple-agx").is_dir():
        return True
    try:
        return any(Path("/sys/devices/platform/soc").glob("*.gpu"))
    except OSError:
        return False


def gpu_clients() -> list[dict[str, Any]]:
    """Processes holding /dev/dri/* fds — real GPU-usage signal on Asahi,
    where the kernel exposes no utilization counter."""
    clients: dict[int, str] = {}
    try:
        procs = list(Path("/proc").glob("[0-9]*"))
    except OSError:
        return []
    for p in procs:
        try:
            pid = int(p.name)
        except ValueError:
            continue
        try:
            fds = list((p / "fd").iterdir())
        except OSError:
            continue
        for fd in fds:
            try:
                tgt = os.readlink(fd)
            except OSError:
                continue
            if tgt.startswith("/dev/dri/"):
                try:
                    comm = (p / "comm").read_text().strip() or p.name
                except OSError:
                    comm = p.name
                clients[pid] = comm
                break
    cfg = _proc_config()
    out = []
    for pid, name in sorted(clients.items()):
        try:
            raw = (Path("/proc") / str(pid) / "cmdline").read_bytes()
            args = raw.replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            args = ""
        exe_path, _exe_base, unit = _proc_identity(pid, args)
        out.append({
            "pid": pid,
            "name": _clip(name, 32),
            "display": _clip(display_name(name, exe_path, args, cfg), 48),
            "unit": unit,
        })
    return out[:MAX_LIST]


def _drm_engine_cycles() -> dict[str, int]:
    """Aggregate drm-engine/drm-cycles counters across all DRM fds system-wide.
    Empty dict when the kernel exposes no fdinfo stats (Asahi today)."""
    totals: dict[str, int] = {}
    try:
        procs = list(Path("/proc").glob("[0-9]*"))
    except OSError:
        return totals
    for p in procs:
        try:
            fds = list((p / "fd").iterdir())
        except OSError:
            continue
        for fd in fds:
            try:
                tgt = os.readlink(fd)
            except OSError:
                continue
            if not tgt.startswith("/dev/dri/"):
                continue
            try:
                info = (p / "fdinfo" / fd.name).read_text()
            except OSError:
                continue
            for line in info.splitlines():
                if line.startswith("drm-engine-") or line.startswith("drm-cycles-"):
                    key, _, val = line.partition(":")
                    parts = val.strip().split()
                    if parts:
                        try:
                            totals[key] = totals.get(key, 0) + int(parts[0])
                        except ValueError:
                            pass
    return totals


def _asahi_gpu_load(sample_seconds: float = SAMPLE_SECONDS) -> int | None:
    """GPU busy% from DRM fdinfo deltas; None when the kernel exposes no
    fdinfo counters (asahi driver on current kernels)."""
    s1 = _drm_engine_cycles()
    if not s1:
        return None
    time.sleep(sample_seconds)
    s2 = _drm_engine_cycles()
    keys = set(s1) | set(s2)
    delta = sum(max(0, s2.get(k, 0) - s1.get(k, 0)) for k in keys)
    engines = len(keys) or 1
    # drm-engine-* counters are nanoseconds busy per engine
    busy = 100.0 * delta / (sample_seconds * 1e9 * engines)
    return max(0, min(100, round(busy)))


def soc_power_w(devices: dict[str, Path] | None = None) -> float | None:
    """SoC package power proxy: macsmc 'Heatpipe Power' rail, watts.
    Not GPU-isolated — unified-SoC context signal."""
    if devices is None:
        devices = hwmon_paths()
    macsmc = devices.get("macsmc_hwmon")
    if not macsmc:
        return None
    for pf in macsmc.glob("power*_input"):
        lf = macsmc / pf.name.replace("input", "label")
        try:
            if lf.is_file() and "heatpipe" in lf.read_text().lower():
                return round(int(pf.read_text().strip()) / 1e6, 1)
        except (OSError, ValueError):
            continue
    return None


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
    lspci = _tool("lspci")
    if not lspci:
        return None
    out = _run([lspci, "-mm"], timeout=2)
    if out is None:
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


_CACHED_RAM_INFO: str | None = None

def ram_info() -> str:
    """Try to produce a short RAM type + speed label (cached after first run)."""
    global _CACHED_RAM_INFO
    if _CACHED_RAM_INFO is not None:
        return _CACHED_RAM_INFO

    inxi = _tool("inxi")
    out = _run([inxi, "-m", "-c0"], timeout=2) if inxi else None
    if out:
        # Look for Memory: ... type: DDR4 ... speed: 3200 MT/s
        m = re.search(r"type:\s*([^\s,]+).*?speed:\s*([^\s,]+)\s*MT/s", out, re.I | re.S)
        if m:
            _CACHED_RAM_INFO = f"{m.group(1).strip()} {m.group(2).strip()} MT/s"
            return _CACHED_RAM_INFO

    # Apple Silicon DeviceTree check
    dt_model = Path("/sys/firmware/devicetree/base/model")
    if dt_model.is_file() and b"Apple" in dt_model.read_bytes():
        _CACHED_RAM_INFO = "LPDDR5 Unified"
        return _CACHED_RAM_INFO

    # dmidecode usually needs root, but try in case it works
    dmidecode = _tool("dmidecode")
    if not dmidecode:
        _CACHED_RAM_INFO = ""
        return ""
    out = _run([dmidecode, "-t", "memory"], timeout=1)
    if out is None:
        _CACHED_RAM_INFO = ""
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
        _CACHED_RAM_INFO = f"{'/'.join(sorted(types))} {'/'.join(sorted(speeds))} MT/s"
    elif types:
        _CACHED_RAM_INFO = "/".join(sorted(types))
    else:
        _CACHED_RAM_INFO = ""
    return _CACHED_RAM_INFO


ALLOWED_FS = {
    "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "zfs", "jfs", "reiserfs",
    "nilfs2", "bcachefs", "vfat", "exfat", "ntfs", "ntfs3", "hfsplus", "ufs",
}


def disk_usage() -> list[dict[str, Any]]:
    df = _tool("df")
    if not df:
        return []
    out = _run([df, "-P", "-T", "-l", "--block-size=1"], timeout=2)
    if out is None:
        return []
    out = out.strip()

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


def _read_net_dev(path: Path | None = None) -> dict[str, tuple[int, int]]:
    """{iface: (rx_bytes, tx_bytes)} from /proc/net/dev, loopback excluded."""
    out: dict[str, tuple[int, int]] = {}
    try:
        lines = (path or Path("/proc/net/dev")).read_text().splitlines()
    except OSError:
        return out
    for line in lines[2:]:
        name, sep, rest = line.partition(":")
        if not sep:
            continue
        fields = rest.split()
        if len(fields) < 9:
            continue
        try:
            rx, tx = int(fields[0]), int(fields[8])
        except ValueError:
            continue
        name = name.strip()
        if name and name != "lo":
            out[name] = (rx, tx)
    return out


# Whole-disk names only; partitions and virtual devices (loop, dm, zram)
# would double-count against the backing disk.
_WHOLE_DISK = re.compile(
    r"^(nvme\d+n\d+|mmcblk\d+|sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|md\d+)$")


def _read_diskstats(path: Path | None = None) -> dict[str, tuple[int, int]]:
    """{dev: (sectors_read, sectors_written)} for whole physical disks."""
    out: dict[str, tuple[int, int]] = {}
    try:
        lines = (path or Path("/proc/diskstats")).read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        f = line.split()
        if len(f) < 10 or not _WHOLE_DISK.match(f[2]):
            continue
        try:
            out[f[2]] = (int(f[5]), int(f[9]))
        except ValueError:
            continue
    return out


HISTORY_LEN = 60
_MAX_RATE_DT = 300.0  # ignore prev samples older than this; counters reset
_STATS_STATE: dict[str, Any] | None = None


def _empty_stats_state() -> dict[str, Any]:
    return {
        "ts": 0.0,
        "net": {},
        "disk": {},
        "hist": {k: deque(maxlen=HISTORY_LEN)
                 for k in ("cpu_load", "cpu_temp", "mem_used")},
    }


def _stats_state_path() -> Path:
    return _runtime_dir() / "stats_state.json"


def _load_stats_state() -> dict[str, Any]:
    """Prev counters + history rings persisted under the omarchy-fan runtime
    dir. The panel re-execs this helper every refresh (KTD5's "long-lived
    sampler" is really exec-per-sample), so prev state must live on disk."""
    state = _empty_stats_state()
    try:
        fd = os.open(_stats_state_path(), os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return state
    try:
        with os.fdopen(fd, "rb") as fh:
            st = os.fstat(fh.fileno())
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                    or st.st_size > 65536):
                return state
            data = json.loads(fh.read(65537))
    except (OSError, ValueError):
        return state
    if not isinstance(data, dict):
        return state
    if isinstance(data.get("ts"), (int, float)):
        state["ts"] = float(data["ts"])
    if isinstance(data.get("net"), dict):
        for k, v in list(data["net"].items())[:MAX_LIST]:
            if (isinstance(v, list) and len(v) == 2
                    and all(isinstance(x, (int, float)) and x >= 0 for x in v)):
                state["net"][_clip(str(k), 32)] = (int(v[0]), int(v[1]))
    if isinstance(data.get("disk"), dict):
        for k, v in list(data["disk"].items())[:MAX_LIST]:
            if (isinstance(v, list) and len(v) == 2
                    and all(isinstance(x, (int, float)) and x >= 0 for x in v)):
                state["disk"][_clip(str(k), 32)] = (int(v[0]), int(v[1]))
    if isinstance(data.get("hist"), dict):
        for key, ring in state["hist"].items():
            vals = data["hist"].get(key)
            if isinstance(vals, list):
                for x in vals[-HISTORY_LEN:]:
                    if isinstance(x, (int, float)) and not isinstance(x, bool):
                        ring.append(int(x))
    return state


def _stats_state() -> dict[str, Any]:
    global _STATS_STATE
    if _STATS_STATE is None:
        _STATS_STATE = _load_stats_state()
    return _STATS_STATE


def _save_stats_state(state: dict[str, Any]) -> None:
    """Best-effort persist; failures just mean no rates/history next run."""
    try:
        rdir = _runtime_dir()
        rdir.mkdir(mode=0o700, parents=True, exist_ok=True)
        payload = {
            "ts": state["ts"],
            "net": {k: list(v) for k, v in list(state["net"].items())[:MAX_LIST]},
            "disk": {k: list(v) for k, v in list(state["disk"].items())[:MAX_LIST]},
            "hist": {k: list(d) for k, d in state["hist"].items()},
        }
        raw = json.dumps(payload)[:MAX_OUT_BYTES]
        fd = os.open(_stats_state_path(),
                     os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(raw)
    except (OSError, ValueError):
        pass


def _rate_deltas(state: dict[str, Any], now: float,
                 net_now: dict[str, tuple[int, int]],
                 disk_now: dict[str, tuple[int, int]],
                 ) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Byte/sec rates vs the previous persisted sample (KTD5). Counters that
    shrank (reboot, iface replug) contribute nothing; stale prev (>5 min)
    rebases instead of reporting a huge bogus rate. Per-interface and
    per-device breakdowns ride alongside the aggregates for the card
    drill-downs."""
    prev_ts = state.get("ts") or 0.0
    dt = now - prev_ts
    if not (0 < dt <= _MAX_RATE_DT):
        return None, None
    net = None
    prev_net = state.get("net") or {}
    if net_now and prev_net:
        down = up = 0
        ifaces = []
        for name, (rx, tx) in net_now.items():
            prev = prev_net.get(name)
            if prev and rx >= prev[0] and tx >= prev[1]:
                down += rx - prev[0]
                up += tx - prev[1]
                d_bps = int((rx - prev[0]) / dt)
                u_bps = int((tx - prev[1]) / dt)
                if d_bps > 0 or u_bps > 0:
                    ifaces.append({"name": _clip(name, 32),
                                   "down_bps": d_bps, "up_bps": u_bps})
        # Busy links first; idle tunnels/veth pairs just add scroll.
        ifaces.sort(key=lambda i: i["down_bps"] + i["up_bps"], reverse=True)
        net = {"down_bps": int(down / dt), "up_bps": int(up / dt),
               "ifaces": ifaces[:MAX_LIST]}
    disk = None
    prev_disk = state.get("disk")
    if disk_now and isinstance(prev_disk, dict) and prev_disk:
        dr = dw = 0
        devs = []
        for name, (r, w) in disk_now.items():
            prev = prev_disk.get(name)
            if prev and r >= prev[0] and w >= prev[1]:
                dr += r - prev[0]
                dw += w - prev[1]
                r_bps = int((r - prev[0]) * 512 / dt)
                w_bps = int((w - prev[1]) * 512 / dt)
                if r_bps > 0 or w_bps > 0:
                    devs.append({"name": _clip(name, 32),
                                 "read_bps": r_bps, "write_bps": w_bps})
        devs.sort(key=lambda i: i["read_bps"] + i["write_bps"], reverse=True)
        if dr >= 0 and dw >= 0:
            disk = {"read_bps": int(dr * 512 / dt),
                    "write_bps": int(dw * 512 / dt),
                    "devs": devs[:MAX_LIST]}
    return net, disk


def _runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or os.path.join(
        os.path.expanduser("~"), ".local", "run"
    )
    return Path(base) / "omarchy-fan"


def read_fan_mode(path: Path | None = None) -> str:
    mode_path = path or _runtime_dir() / "current_fan_mode"
    try:
        fd = os.open(mode_path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return "auto"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            os.close(fd)
            return "auto"
        with os.fdopen(fd, "r") as fh:
            mode = fh.read(64).strip().lower()
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        return "auto"
    return mode if mode in {"auto", "low", "med", "high", "custom"} or mode.startswith("custom-") else "auto"


def read_fan_curve() -> list[list[int]]:
    """Read the active custom fan curve from the XDG config path."""
    home = Path.home()
    path = home / ".config" / "omarchy" / "fan_curve.json"
    if not path.is_file():
        return []
    try:
        with open(path, "rb") as fh:
            data = json.loads(fh.read(256 * 1024))
        if isinstance(data, list) and all(isinstance(p, list) and len(p) == 2 for p in data):
            return [[int(p[0]), int(p[1])] for p in data][:64]
    except (OSError, ValueError):
        pass
    return []


def _has_controllable_fan(devices: dict[str, Path] | None = None) -> bool:
    """True when hwmon exposes fan-control nodes the daemon can drive.

    The daemon only speaks macsmc (fan*_target) and dell_smm (pwm*);
    any other sensor means mode writes are dead drops.
    """
    if devices is None:
        devices = hwmon_paths()
    macsmc = devices.get("macsmc_hwmon")
    if macsmc and macsmc.is_dir() and any(macsmc.glob("fan*_target")):
        return True
    dell = devices.get("dell_smm")
    if dell and dell.is_dir() and any(dell.glob("pwm[0-9]*")):
        return True
    return False


def fan_control_available(devices: dict[str, Path] | None = None) -> bool:
    """Honest fan-control capability for the panel.

    A daemon heartbeat proves that a helper is alive, not that a writable fan
    target exists. Control is enabled only when the daemon's supported hwmon
    interface exposes a real target node; a missing or read-only target keeps
    the panel telemetry-only.
    """
    if not (Path(__file__).parent / "omarchy-fan-set").is_file():
        return False
    return _has_controllable_fan(devices)


def _clip(value: Any, limit: int = MAX_STR) -> str:
    return str(value)[:limit]


def collect(sample_seconds: float = SAMPLE_SECONDS) -> dict[str, Any]:
    mem = read_meminfo()
    devices = hwmon_paths()
    cpu_temp, fan1_rpm, fan2_rpm = cpu_temp_and_fans(devices)
    gpu_name, gpu_load, gpu_temp = gpu_info()
    gpu_load_reason = ""
    if gpu_load is None:
        gpu_load_reason = (
            "Asahi DRM utilization counter unavailable"
            if _is_asahi_gpu()
            else "GPU utilization counter unavailable"
        )

    cpu_load, cpu_cores = _read_cpu_stats(sample_seconds=sample_seconds)

    # Cross-exec sampler state: net/disk rates are deltas vs the previous
    # persisted sample; the bounded rings feed panel sparklines (KTD5).
    state = _stats_state()
    now = time.time()
    net_now = _read_net_dev()
    disk_now = _read_diskstats()
    net_rates, disk_rates = _rate_deltas(state, now, net_now, disk_now)
    hist = state["hist"]
    hist["cpu_load"].append(int(cpu_load))
    temp_m = re.match(r"-?\d+", cpu_temp or "")
    if temp_m:
        hist["cpu_temp"].append(int(temp_m.group(0)))
    hist["mem_used"].append(int(round(mem["used"] / (1024 ** 2))))
    state["ts"] = now
    if net_now:
        state["net"] = net_now
    if disk_now:
        state["disk"] = disk_now
    _save_stats_state(state)

    # If nvidia gave a temp, prefer it for the GPU temp field; otherwise use the one we had
    payload = {
        "ok": True,
        "cpu_name": _clip(cpu_name()),
        "cpu_load": cpu_load,
        "cpu_cores": cpu_cores[:MAX_LIST],
        "cpu_temp": _clip(cpu_temp, 16),
        "gpu_name": _clip(gpu_name),
        "gpu_load": gpu_load if gpu_load is not None else -1,
        "gpu_load_reason": _clip(gpu_load_reason, 80),
        "gpu_temp": _clip(gpu_temp, 16),
        "gpu_power_w": soc_power_w(devices),
        "gpu_clients": gpu_clients(),
        "nvme_temp": _clip(nvme_temp(devices), 16),
        "ram_info": _clip(ram_info()),
        "mem_pct": mem["pct"],
        "mem_used": f"{mem['used'] / (1024 ** 3):.1f}",
        "mem_avail": f"{mem['available'] / (1024 ** 3):.1f}",
        "mem_total": f"{mem['total'] / (1024 ** 3):.1f}",
        "swap_used": f"{mem['swap_used'] / (1024 ** 3):.1f}",
        "swap_total": f"{mem['swap_total'] / (1024 ** 3):.1f}",
        "swap_pct": mem["swap_pct"],
        "disks": disk_usage()[:MAX_LIST],
        "fan1_rpm": fan1_rpm,
        "fan2_rpm": fan2_rpm,
        "fan_mode": read_fan_mode(),
        "fan_curve": read_fan_curve(),
        "fan_control": fan_control_available(devices),
        "daemon_running": is_daemon_running(),
        "top_mem": top_mem(n=_proc_config()["top"], min_mb=_proc_config()["min_mem_mb"])[:MAX_LIST],
        "top_cpu": top_cpu()[:MAX_LIST],
    }
    # Additive keys (KTD6): absent on first sample or when a source is
    # missing — the panel renders "--" for whatever is not there.
    if net_rates is not None:
        payload["net"] = net_rates
    if disk_rates is not None:
        payload["disk"] = disk_rates
    if len(hist["cpu_load"]) >= 2:
        payload["history"] = {
            k: list(ring)[:MAX_LIST] for k, ring in hist.items()
        }
    return payload


def is_daemon_running() -> bool:
    try:
        for p in Path("/proc").glob("[0-9]*"):
            try:
                cmd = (p / "cmdline").read_bytes().replace(b"\x00", b" ")
                if b"omarchy-fan-daemon" in cmd and b"system_monitor_stats" not in cmd:
                    return True
            except OSError:
                continue
    except OSError:
        pass
    return False


def main() -> int:
    # Hard wall-clock deadline: never let a stuck sensor or tool pin the job.
    signal.signal(signal.SIGALRM, lambda *_: os._exit(124))
    signal.alarm(JOB_DEADLINE_S)
    # "--find <substr>": process-search mode used by the panel's '/' field.
    if len(sys.argv) >= 3 and sys.argv[1] == "--find":
        query = sys.argv[2]
        procs = find_procs(query, n=_proc_config()["find_max"])[:MAX_LIST]
        out = json.dumps({"ok": True, "procs": procs})
    else:
        out = json.dumps(collect())
    sys.stdout.write(out[:MAX_OUT_BYTES] + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
