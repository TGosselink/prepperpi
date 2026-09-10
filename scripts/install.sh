#!/usr/bin/env bash
# Backward-compatibility shim — delegates to fresh-install.sh.
# For an existing Pi, use: sudo bash scripts/update-app.sh
exec "$(dirname "${BASH_SOURCE[0]}")/fresh-install.sh" "$@"
