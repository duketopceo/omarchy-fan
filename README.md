# Resource & Fan

A native Omarchy bar widget that turns your top bar into a compact laptop resource monitor: RAM, CPU load, CPU/GPU/NVMe thermals, fan RPM, and top processes, plus manual and automatic fan-curve control.

## Install

```bash
omarchy plugin add https://github.com/duketopceo/omarchy-fan
omarchy plugin enable lukedaduke.fan
```

## Features

- Real-time RAM and CPU load
- GPU section: utilization % where the driver exposes it (NVIDIA, AMD `gpu_busy_percent`, DRM fdinfo when the kernel supports it), plus package/heatpipe power and a live list of GPU client processes on Apple Silicon
- CPU, GPU, and NVMe temperatures via `hwmon`
- Laptop fan RPM readout
- Top memory/CPU processes with `j`/`k` selection and kill support
- Fan modes: auto, low, medium, high, plus a user-editable custom curve
- `omarchy-fan-daemon` runs the auto/custom curves and drives fan hwmon (`fan*_target` on Apple Silicon `macsmc_hwmon`, `pwm*` on `dell_smm`)

## Fan helper setup

Fan control is applied by the **`omarchy-fan-helper`** package, a root
service that runs `/usr/lib/omarchy-fan/omarchy-fan-daemon` (packaged from
`bin/omarchy-fan-daemon`). The plugin never installs, starts, or elevates
anything: it reads the helper's status from `/run/omarchy-fan/status.json`
and, when the helper is missing or older than the version the panel expects,
shows "install/update the omarchy-fan-helper package". Until then the panel
is telemetry-only.

Build and install the package from the umbrella repository
([`duketopceo/omarchy-plugins`](https://github.com/duketopceo/omarchy-plugins)):

```bash
cd packaging/omarchy-fan-helper && yay -Bi .
sudo systemctl enable --now omarchy-fan-daemon.service
```

Installing the package replaces a hand-installed
`/etc/systemd/system/omarchy-fan-daemon.service` that ran the daemon from a
user-owned plugin folder, and starts the packaged unit in its place.

How it behaves:

- The helper polls `$XDG_RUNTIME_DIR/omarchy-fan/current_fan_mode` (written by
  `bin/omarchy-fan-set`) every 2 s and applies the silent auto curve, a fixed
  preset, or the custom curve. It only reads from the user runtime directory.
- Fixed presets (low/med/high) need a live shell: the panel writes
  `$XDG_RUNTIME_DIR/omarchy-fan/heartbeat` every 30 s (no process spawn), and a
  preset older than 120 s without a heartbeat falls back to the auto curve.
  Screen lock does not stop the heartbeat.
- Whenever the helper stops, crashes, or is removed, the fans go back to
  firmware control (`macsmc_hwmon` `fan_control=N`, `dell_smm`
  `pwmN_enable=2`).
- Control is offered only when the fan targets are actually writable; otherwise
  the badge shows `READ` and the mode buttons are hidden.
- The helper never writes the ACPI platform profile; power-profiles-daemon
  owns power profiles.

To remove fan control, remove the `omarchy-fan-helper` package (it stops the
service and hands the fans back). Removing the plugin does not delete user fan
history or unrelated system services.

## Data and privacy

The plugin reads local hardware telemetry and writes only the local fan-mode
request/curve state. It sends no telemetry, account data, or credentials to a
network service. The plugin requests no authorization; fan writes happen in the packaged helper.

### GPU telemetry on Apple Silicon (Asahi)

The Asahi `apple-agx`/`asahi` DRM driver exposes no `gpu_busy_percent`,
devfreq device, or GPU hwmon sensor, and current kernels do not emit
`drm-*` fdinfo counters — so a true GPU busy% is not available
unprivileged today. The panel therefore shows what does exist:

- **Package power** — the `macsmc_hwmon` "Heatpipe Power" rail, a
  SoC-wide proxy (not GPU-isolated).
- **GPU clients** — processes holding `/dev/dri/*` handles, i.e. what's
  actually on the GPU right now.
- **Temperature** — the shared die temp (unified SoC; CPU temp doubles
  as GPU temp).

If a future kernel wires up asahi fdinfo, `gpu_load` starts reporting
automatically — the probe is already in place.

## Usage

- **Left click** the bar text — open the panel
- **Right click** the bar text — cycle fan mode
- **Middle click** — open `btop`
- **j / k** — move process list
- **x** — kill selected process
- **Esc** — close panel

The custom curve is editable from the panel when the helper is installed.

## Requirements

- `python3` (all helpers are Python; the panel execs `/usr/bin/python3`)
- A Linux laptop with `hwmon` thermal/fan sensors
- For fan control: `macsmc_hwmon` (Apple Silicon) or `dell_smm` fan
  targets plus the `omarchy-fan-helper` package (see above)
- Optional: `btop` + `omarchy-launch-or-focus-tui` for the middle-click
  launcher

## License

MIT
