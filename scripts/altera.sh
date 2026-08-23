#!/bin/bash
# Run any tool from the Altera (Quartus Prime) installation, putting it on the
# PATH first.
#
#     scripts/altera.sh quartus_sh -t build.tcl
#     scripts/altera.sh quartus_map probe
#
# Quartus needs no settings script -- its bin/ is self-contained -- so this is
# a PATH prepend and nothing else. It is the one place that knows where the
# installation is; point QUARTUS_ROOTDIR at another one to use it instead.
#
# QUARTUS_ROOTDIR is also the variable Quartus itself reads to find its own
# libraries, so exporting it here is not redundant: a tool invoked by absolute
# path with the wrong one set would find the wrong device database.

set -e

: "${QUARTUS_ROOTDIR:=/opt/Altera/quartus}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <tool> [args...]" >&2
    exit 2
fi

tool=$1
shift

if ! command -v "$tool" >/dev/null 2>&1; then
    if [ ! -x "$QUARTUS_ROOTDIR/bin/$tool" ]; then
        echo "$tool is not on PATH and $QUARTUS_ROOTDIR/bin/$tool does not exist;" >&2
        echo "set QUARTUS_ROOTDIR to your Quartus installation" >&2
        exit 1
    fi
    PATH="$QUARTUS_ROOTDIR/bin:$PATH"
fi

export QUARTUS_ROOTDIR PATH

exec "$tool" "$@"
