#!/usr/bin/env tclsh
# Run behavioral simulation for tb_qpsk_tx_single_dac_min in batch mode.
# Usage:
#   vivado -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set sim_top    "tb_qpsk_tx_single_dac_min"
set sim_log    [file join $repo_root "Ez_QPSK.sim" "sim_1" "behav" "xsim" "simulate.log"]

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

if {![file exists $sim_log]} {
    puts "ERROR: simulation log not found: $sim_log"
    exit 1
}

set fh [open $sim_log r]
set sim_text [read $fh]
close $fh

if {[string first {[TB_QPSK_TX_DAC][FAIL]} $sim_text] >= 0} {
    puts "ERROR: simulation reported \[TB_QPSK_TX_DAC\]\[FAIL\]. See $sim_log"
    exit 1
}

if {[string first {[TB_QPSK_TX_DAC][PASS]} $sim_text] < 0} {
    puts "ERROR: simulation did not report \[TB_QPSK_TX_DAC\]\[PASS\]. See $sim_log"
    exit 1
}

puts "INFO: simulation completed."
