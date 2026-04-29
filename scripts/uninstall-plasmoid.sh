#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ID="com.syslens.monitor"

if ! command -v kpackagetool6 >/dev/null 2>&1; then
  echo "kpackagetool6 was not found in PATH." >&2
  exit 1
fi

if kpackagetool6 --type Plasma/Applet --show "${PACKAGE_ID}" >/dev/null 2>&1; then
  kpackagetool6 --type Plasma/Applet --remove "${PACKAGE_ID}"
  echo "Uninstalled ${PACKAGE_ID}"
else
  echo "${PACKAGE_ID} is not installed"
fi
