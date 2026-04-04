#!/usr/bin/env tclsh
# Run behavioral simulation for tb_qpsk_tx_single_dac_min in batch mode.
# Usage:
#   vivado -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set sim_top    "tb_qpsk_tx_single_dac_min"

if {![file exists $xpr_path]} {
    puts "ERROR: project not found: $xpr_path"
    exit 1
}

open_project $xpr_path

if {[llength [get_filesets sim_1]] == 0} {
    puts "ERROR: fileset sim_1 not found."
    close_project
    exit 1
}

set_property top $sim_top [get_filesets sim_1]
update_compile_order -fileset sim_1

# Ensure a clean behavioral sim run and execute until TB finishes.
reset_simulation
launch_simulation -simset sim_1 -mode behavioral
run all

close_sim
close_project
puts "INFO: simulation completed."
