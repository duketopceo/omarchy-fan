# Resource & Fan

A native Omarchy bar widget that turns your top bar into a compact laptop resource monitor: RAM, CPU load, CPU/GPU/NVMe thermals, fan RPM, and top processes, plus manual and automatic fan-curve control.

## Install

```bash
omarchy plugin add https://github.com/duketopceo/omarchy-fan
omarchy plugin enable lukedaduke.fan
```

## Features

- Real-time RAM and CPU load
- CPU, GPU, and NVMe temperatures via `hwmon`
- Laptop fan RPM readout
- Top memory/CPU processes with `j`/`k` selection and kill support
- Fan modes: auto, low, medium, high, plus a user-editable custom curve
- `omarchy-fan-daemon` runs the auto/custom curves and drives fan hwmon (`fan*_target` on Apple Silicon `macsmc_hwmon`, `pwm*` on `dell_smm`)

## Fan daemon setup

Fan control is applied by `bin/omarchy-fan-daemon`, which must run as
root to write `/sys/class/hwmon/*/fan*_target` / `pwm*`. The widget wires
it for you: click **⚡ Start Daemon** in the panel (or just pick a fan
mode — the first change auto-starts it). That runs
`bin/omarchy-fan-daemon-start` via `pkexec`, which installs the shipped
`omarchy-fan-daemon.service` into `/etc/systemd/system/` and starts it.

To install it by hand instead:

```bash
pkexec ~/.config/omarchy/plugins/lukedaduke.fan/bin/omarchy-fan-daemon-start
```

The daemon polls `$XDG_RUNTIME_DIR/omarchy-fan/current_fan_mode`
(written by `bin/omarchy-fan-set`) every 2 s and applies the matching
curve/preset. On hardware with no daemon-driveable fan (no
`macsmc_hwmon`/`dell_smm` fan targets) and no running daemon, the widget
degrades to read-only honestly: stats and fan RPM still render, the mode
badge shows `READ`, and the preset buttons are disabled.

## Usage

- **Left click** the bar text — open the panel
- **Right click** the bar text — cycle fan mode
- **Middle click** — open `btop`
- **j / k** — move process list
- **x** — kill selected process
- **Esc** — close panel

The custom curve is editable from the panel when the daemon is running.

## Requirements

- `python3` (all helpers are Python; the panel execs `/usr/bin/python3`)
- A Linux laptop with `hwmon` thermal/fan sensors
- For fan control: `macsmc_hwmon` (Apple Silicon) or `dell_smm` fan
  targets plus `pkexec` to install/start the daemon (see above)
- Optional: `btop` + `omarchy-launch-or-focus-tui` for the middle-click
  launcher

## License

MIT
