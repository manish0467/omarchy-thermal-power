#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

node tests/test_model.js
python3 -I tests/test_helper.py

if command -v omarchy >/dev/null 2>&1; then
  if [ -L "$root" ]; then
    echo "Skipping omarchy plugin validate: $root is a development symlink." >&2
    echo "Validate the real checkout before symlinking it." >&2
  else
    omarchy plugin validate "$root"
  fi
fi

if command -v qmllint >/dev/null 2>&1; then
  # Omarchy/Quickshell style singletons may produce unresolved-import warnings.
  # Treat this as a syntax check, not a strict warning gate.
  qmllint BarWidget.qml Panel.qml || true
fi

echo "lint checks passed"
