#!/usr/bin/env tclsh
# Build the RX image for the new high-speed interface board.
#
# This is the preferred two-board receiver profile:
#   original AX7020 interface TX -> channel -> new HS interface ADC/RX demod
#
# Usage:
#   vivado -mode batch -source scripts/run_new_interface_rx_bitstream.tcl

set script_dir [file normalize [file dirname [info script]]]
set argv [list "new_interface_rx"]
source [file join $script_dir "run_external_rx_bitstream.tcl"]
