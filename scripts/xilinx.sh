#!/bin/bash
# Run any tool from the Xilinx installation, putting it on the PATH first.
#
#     scripts/xilinx.sh xvlog -sv foo.sv
#     scripts/xilinx.sh xelab -timescale 1ns/1ps top -s snap
#     scripts/xilinx.sh vivado -mode batch -source build.tcl
#
# The installation is not on a login shell's PATH; its own settings script is
# what puts it there, and that script needs bash. This is the one place that
# knows about it. scripts/vivado.sh delegates here, so `make synth` and
# `make impl` keep working unchanged.
#
# Point VIVADO_SETTINGS at another installation to use it instead.
#
# LIBRARY_PATH
#
# xelab compiles the elaborated design to C and links it with the system
# linker, which on this machine cannot find crti.o on its own -- the C runtime
# startup files are in the multiarch directory and nothing points ld at it. The
# failure is "cannot find crti.o" from /usr/bin/ld, at the very end of an
# otherwise clean elaboration, which is a confusing place to meet it. Adding
# the multiarch directory to LIBRARY_PATH fixes it and affects nothing else.

set -e

: "${VIVADO_SETTINGS:=/opt/Xilinx/2025.2/Vivado/settings64.sh}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <tool> [args...]" >&2
    exit 2
fi

tool=$1
shift

if ! command -v "$tool" >/dev/null 2>&1; then
    if [ ! -r "$VIVADO_SETTINGS" ]; then
        echo "$tool is not on PATH and $VIVADO_SETTINGS is not readable;" >&2
        echo "set VIVADO_SETTINGS to your installation's settings64.sh" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$VIVADO_SETTINGS"
fi

for d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    [ -e "$d/crti.o" ] && LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$d"
done
export LIBRARY_PATH

exec "$tool" "$@"
