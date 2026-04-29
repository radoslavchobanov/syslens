# SysLens Plasmoid

MVP package scaffolding for a KDE Plasma 6 plasmoid with package id `com.syslens.monitor`.

## Install

```bash
./scripts/install-plasmoid.sh
```

The installer uses `kpackagetool6 --type Plasma/Applet` and upgrades the local package when it is already installed.

## Uninstall

```bash
./scripts/uninstall-plasmoid.sh
```

## Backend One-Shot JSON Check

The telemetry backend is expected at `plasmoid/contents/code/backend.py`. Once implemented, run:

```bash
python3 plasmoid/contents/code/backend.py --json
```

## Project Layout

- `plasmoid/metadata.json`: Plasma package metadata.
- `plasmoid/contents/ui/main.qml`: QML widget entrypoint.
- `plasmoid/contents/code/backend.py`: telemetry backend entrypoint.
- `scripts/install-plasmoid.sh`: local install or upgrade helper.
- `scripts/uninstall-plasmoid.sh`: local uninstall helper.
