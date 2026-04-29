#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/plasmoid"
PACKAGE_ID="com.syslens.monitor"

if ! command -v kpackagetool6 >/dev/null 2>&1; then
  echo "kpackagetool6 was not found in PATH." >&2
  exit 1
fi

if [[ ! -f "${PACKAGE_DIR}/metadata.json" ]]; then
  echo "Missing plasmoid metadata at ${PACKAGE_DIR}/metadata.json" >&2
  exit 1
fi

if kpackagetool6 --type Plasma/Applet --show "${PACKAGE_ID}" >/dev/null 2>&1; then
  kpackagetool6 --type Plasma/Applet --upgrade "${PACKAGE_DIR}"
else
  kpackagetool6 --type Plasma/Applet --install "${PACKAGE_DIR}"
fi

echo "Installed ${PACKAGE_ID} from ${PACKAGE_DIR}"
