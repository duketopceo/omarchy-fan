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
- `omarchy-fan-daemon` runs the auto curve and writes to `/sys/class/thermal` cooling devices

## Usage

- **Left click** the bar text — open the panel
- **Right click** the bar text — cycle fan mode
- **Middle click** — open `btop`
- **j / k** — move process list
- **x** — kill selected process
- **Esc** — close panel

The custom curve is editable from the panel when the daemon is running.

## Requirements

- A Linux laptop with `hwmon` thermal/fan sensors
- `nbfc` or compatible `cooling_device*` files for the fan daemon to write to (auto mode works without them)

## License

MIT
