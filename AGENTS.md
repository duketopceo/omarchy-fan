# AGENTS.md — Resource & Fan (`lukedaduke.fan`)

> This file is the agent entry point for this repo.
> Full agent context lives at: https://github.com/duketopceo/luke-agents

Inherits from [luke-agents/AGENTS.md](https://github.com/duketopceo/luke-agents/blob/main/AGENTS.md). This file specializes; it does not replace.

## What This Repo Does

Laptop resource monitor for the Omarchy bar: RAM, CPU load, CPU/GPU/NVMe thermals
from `hwmon`, fan RPM, and a top-process list with `j`/`k` selection and kill.
On top of read-only monitoring it drives an optional fan daemon that applies
preset or user curves to `fan*_target` (Apple Silicon `macsmc_hwmon`) or `pwm*`
(`dell_smm`).

This is the most complex plugin in the family: it is the only one that mutates
hardware state, escalates to root via `pkexec`, and installs a systemd unit.

## Provenance — edit in the umbrella, not here

This repo is the published subtree of
[`duketopceo/omarchy-plugins`](https://github.com/duketopceo/omarchy-plugins) at
`plugins/lukedaduke.fan/`. `scripts/publish.sh` runs `git subtree split` and
fast-forwards this repo's `main`. **A commit made directly here is deleted on the
next publish.** Make the change in the umbrella, then
`scripts/publish.sh fan`.

## Layout

| Path | Role |
|---|---|
| `manifest.json` | Plugin contract. `id` / `kinds: ["bar-widget"]` / `entryPoints.barWidget` |
| `Panel.qml` | Bar text + dropdown. ~900 lines, the whole UI |
| `bin/system_monitor_stats.py` | Long-lived sampler. Emits bounded JSON on stdout |
| `bin/kill_proc.py` | Kills one pid by number. Refuses `pid <= 1` |
| `bin/omarchy-fan-set` | Writes fan mode + custom curve to `$XDG_RUNTIME_DIR/omarchy-fan/` |
| `bin/omarchy-fan-daemon` | Polls the mode file every 2 s, applies the curve to hwmon |
| `bin/omarchy-fan-daemon-start` | `#!/bin/bash`. Installs + starts the unit via `pkexec` |
| `omarchy-fan-daemon.service` | systemd unit installed into `/etc/systemd/system/` |

`Panel.qml` execs the helpers with the absolute interpreter `/usr/bin/python3`.
It is the only plugin here whose QML also owns a `pkexec` path.

## Runtime Contract

- **No build step.** Nothing to compile. `manifest.json` must stay valid JSON.
- **QML cannot be checked outside Omarchy.** The panel imports `Quickshell`,
  `Quickshell.Io`, `qs.Commons`, and `qs.Ui`. Those are supplied by the host shell
  at runtime and do not exist in a plain checkout, so `qmllint`/`qmlcachegen`
  cannot resolve them. Do not "fix" the imports and do not treat a missing
  `qs.*` module as a bug.
- `moduleName` and `ipcTarget` in `Panel.qml` must both equal the manifest `id`
  (`lukedaduke.fan`). The shell routes IPC on this string.
- Graceful degradation is a feature, not an oversight. With no daemon and no
  driveable fan target the panel stays read-only, shows `READ`, and disables the
  preset buttons. Keep that path working.

## Validation

There is no test suite in this repo. From the umbrella
([`duketopceo/omarchy-plugins`](https://github.com/duketopceo/omarchy-plugins)):

```bash
python3 scripts/validate-manifests.py     # schema + id/folder match + entryPoints exist
python3 -m pytest tests/ -q               # covers system_monitor_stats.py and kill_proc.py
```

Standalone syntax check for the helpers in this repo:

```bash
python3 -m py_compile bin/*.py
```

**The test suite requires Linux.** `tests/test_fan_stats.py` reads
`/proc/meminfo`, and `tests/test_agents.py` runs a bash scan that pipes to GNU
`head -z`. On macOS 9 tests fail for that reason alone while CI is green. Do not
"fix" them and do not report them as regressions.

Real verification is on a Linux laptop with the plugin enabled: confirm the bar
text populates, the panel opens, and the mode badge matches the fan mode you set.

## Runtime Requirements

- `python3` at `/usr/bin/python3` (all helpers are Python)
- A Linux laptop exposing `hwmon` thermal and fan sensors
- Fan *control* additionally needs `macsmc_hwmon` or `dell_smm` fan targets, plus
  `pkexec` to install and start the daemon
- Optional: `btop` + `omarchy-launch-or-focus-tui` for the middle-click launcher

## Conventions

- Theme with `qs.Commons` `Color` / `Style` only. No hardcoded palette hex.
- Security posture is deliberate and load-bearing. Keep it:
  - exec helpers via absolute `/usr/bin/python3`, never bare `python3`, so a
    `PATH`-preceding shadow binary cannot execute
  - pin the child `PATH` to a fixed safe list; do not inherit the caller's `PATH`
  - open runtime-state dirs with `O_NOFOLLOW` and assert `st_uid == geteuid()`
  - bound every helper's stdout (`MAX_OUT_BYTES`, `MAX_STR`, `MAX_LIST`) — the
    QML side parses it
  - refuse `pid <= 1` in any process-kill path
- Never edit `/usr/share/omarchy/`.
- Helpers live in `bin/`, not `~/.local/bin`.
- Bump `version` in `manifest.json` when shipping a behavior change; the umbrella
  release flow tracks it.
