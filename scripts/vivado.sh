#!/bin/bash
# Run Vivado, putting it on the PATH first if it is not there already.
#
# Vivado's installation is not on a login shell's PATH; its own settings script
# is what puts it there, and that script needs bash. This is the one place that
# knows about it, so `make synth` works from a plain shell.
#
# Point VIVADO_SETTINGS at another installation to use it instead.

set -e

: "${VIVADO_SETTINGS:=/opt/Xilinx/2025.2/Vivado/settings64.sh}"

if ! command -v vivado >/dev/null 2>&1; then
    if [ ! -r "$VIVADO_SETTINGS" ]; then
        echo "vivado is not on PATH and $VIVADO_SETTINGS is not readable;" >&2
        echo "set VIVADO_SETTINGS to your installation's settings64.sh" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$VIVADO_SETTINGS"
fi

exec vivado "$@"
