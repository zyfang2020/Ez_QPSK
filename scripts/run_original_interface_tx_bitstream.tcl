#!/usr/bin/env tclsh
# Build a TX-only image for the original AX7020-style interface.
#
# Usage:
#   vivado -mode batch -source scripts/run_original_interface_tx_bitstream.tcl
#   vivado -mode batch -source scripts/run_original_interface_tx_bitstream.tcl -tclargs prbs
#   vivado -mode batch -source scripts/run_original_interface_tx_bitstream.tcl -tclargs gray

set script_dir [file normalize [file dirname [info script]]]
set tx_mode "prbs"
if {[llength $argv] > 0} {
    set tx_mode [lindex $argv 0]
}

switch -- $tx_mode {
    prbs {
        set argv [list "original_tx_prbs"]
    }
    gray {
        set argv [list "original_tx_gray"]
    }
    default {
        puts "ERROR: unknown TX mode '$tx_mode'. Expected prbs or gray."
        exit 1
    }
}

source [file join $script_dir "run_external_rx_bitstream.tcl"]
