#!/bin/bash
# Run any tool from the Questa installation, putting it on the PATH first.
#
#     scripts/questa.sh vlib work
#     scripts/questa.sh vlog -sv -lint foo.sv
#     scripts/questa.sh vopt rd68011_top -o topopt
#
# The binaries live in linux_x86_64/, not bin/ -- bin/ holds the `q`-prefixed
# aliases. Point QUESTA_ROOTDIR at another installation to use it instead.
#
# Only vlog and vopt are used by this project: they compile and elaborate, and
# neither needs a licence. `vsim` does -- it wants SALT_LICENSE_SERVER pointing
# at a node-locked file Altera issues for free -- so simulation under Questa is
# not part of any target here. doc/coding-standard.md says what that costs.

set -e

: "${QUESTA_ROOTDIR:=/opt/Altera/questa_fse}"

if [ $# -lt 1 ]; then
    echo "usage: $0 <tool> [args...]" >&2
    exit 2
fi

tool=$1
shift

if ! command -v "$tool" >/dev/null 2>&1; then
    if [ ! -x "$QUESTA_ROOTDIR/linux_x86_64/$tool" ]; then
        echo "$tool is not on PATH and $QUESTA_ROOTDIR/linux_x86_64/$tool does not exist;" >&2
        echo "set QUESTA_ROOTDIR to your Questa installation" >&2
        exit 1
    fi
    PATH="$QUESTA_ROOTDIR/linux_x86_64:$PATH"
fi

export PATH

exec "$tool" "$@"
