# PC Power Widget

A lightweight Windows desktop overlay for monitoring PC load, estimated power use, electricity cost, FPS, date/time, outside temperature, and persistent electricity history.

## Download

**Latest installer ZIP:** [PC_Power_Widget_v1.12.1.zip](https://github.com/abchecker/PC-Power-Widget/releases/download/v1.12.2/PC_Power_Widget_v1.12.2.zip)

## What it shows

Compact mode displays:

- FPS
- CPU usage
- real CPU temperature
- GPU usage
- real GPU temperature
- RAM usage
- estimated total PC power draw in watts
- current electricity cost per hour
- weekday, date and local time
- outside temperature
- current calendar-month electricity cost

The system tray also provides a detailed view and an electricity-history viewer with daily, monthly, yearly and all-time totals.

## Install

1. Download the latest release ZIP.
2. Extract it anywhere.
3. Run `INSTALL.bat`.
4. Accept the Windows Administrator prompt.
5. Enter:
   - your electricity price in p/kWh
   - your town/city for outside temperature, or leave blank to disable weather
   - your PSU wattage if known

The widget installs to:

```text
%LOCALAPPDATA%\PCPowerWidget
```

It then starts automatically when you sign in to Windows.

## Features

- Lightweight WPF/PowerShell overlay
- System tray controls
- Always-on-top option
- Click-through mode
- Adjustable opacity
- No visible terminal after startup
- FPS monitoring through Intel PresentMon
- CPU/GPU telemetry through LibreHardwareMonitor
- NVIDIA power fallback through `nvidia-smi` when available
- Persistent local electricity history
- Automatic monthly rollover on the first day of each month
- Month, year and all-time electricity totals
- Optional outside temperature

## Power measurement

The widget uses real CPU and GPU power sensors when the hardware exposes them.

Total wall power is still an **estimate** because normal Windows software cannot directly measure every component and PSU conversion loss at the wall socket. RAM, motherboard, storage, fans and PSU losses may therefore be estimated.

Estimated values are marked with `~`.

For billing-grade accuracy, use a physical wall power meter.

## FPS

FPS monitoring uses [Intel PresentMon](https://github.com/GameTechDev/PresentMon).

Windowed, borderless and fullscreen applications are supported, but some anti-cheat or protected applications may block performance telemetry.

## Weather and privacy

If you enter a town or city during installation, that location text is sent to the **Open-Meteo geocoding API** to resolve coordinates. Current outside temperature is then requested from Open-Meteo.

The resulting settings are stored locally in:

```text
%LOCALAPPDATA%\PCPowerWidget\config.json
```

Electricity history is stored locally in:

```text
%LOCALAPPDATA%\PCPowerWidget\usage_history.csv
```

This repository does **not** contain user configuration, location data, electricity history, API keys, passwords, tokens or other personal data.

## Local files excluded from Git

The repository intentionally ignores runtime/user data including:

- `config.json`
- `usage_history.csv`
- `LAST_LAUNCHED_VERSION.txt`
- downloaded runtime binaries under `lib/`

## Dependencies

The installer downloads these from their official GitHub releases:

- LibreHardwareMonitor v0.9.6
- Intel PresentMon v2.5.1

Open-Meteo is used for optional geocoding and current outside temperature.

## Uninstall

Run:

```text
%LOCALAPPDATA%\PCPowerWidget\UNINSTALL.bat
```

## License

MIT License. See [LICENSE](LICENSE).


## v1.12.2

- Real CPU temperature below CPU usage.
- Real GPU temperature below GPU usage.
- Temperature text is smaller; compact widget stays 455 × 48.
- Missing sensors show `--°C`; temperatures are never estimated.
