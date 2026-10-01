#!/bin/bash
# SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Source location: https://github.com/MelkhiorVintageComputing/RD68011
# Run Vivado, putting it on the PATH first if it is not there already.
#
# The work is all in scripts/xilinx.sh, which does the same for any tool in the
# installation -- xvlog, xvhdl, xelab and xsim as well as vivado itself. This
# stays as its own script because `make synth` and `make impl` name it, and
# because "run vivado" is worth being able to say directly.
#
# Point VIVADO_SETTINGS at another installation to use it instead.

set -e

exec "$(dirname "$0")/xilinx.sh" vivado "$@"
