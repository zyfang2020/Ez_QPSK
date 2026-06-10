#!/usr/bin/env tclsh
# Run behavioral simulation for tb_pl_comm_top_external_rx with a negative
# residual carrier offset in batch mode.
# Usage:
#   vivado -mode batch -source scripts/run_pl_comm_top_external_rx_neg_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set sim_top    "tb_pl_comm_top_external_rx"
set sim_log    [file join $repo_root "Ez_QPSK.sim" "sim_1" "behav" "xsim" "simulate.log"]

proc add_file_if_missing {fileset_name file_path} {
    set fs [get_filesets $fileset_name]
    set existing [get_files -quiet -of_objects $fs [list $file_path]]
    if {[llength $existing] == 0} {
        add_files -norecurse -fileset $fileset_name $file_path
    }
}

if {![file exists $xpr_path]} {
    puts "ERROR: project not found: $xpr_path"
    exit 1
}

open_project $xpr_path

if {[llength [get_filesets sources_1]] == 0} {
    puts "ERROR: fileset sources_1 not found."
    close_project
    exit 1
}

if {[llength [get_filesets sim_1]] == 0} {
    puts "ERROR: fileset sim_1 not found."
    close_project
    exit 1
}

add_file_if_missing sources_1 [file join $repo_root "RTL" "modem" "qpsk_rx_fixed_demod.v"]
add_file_if_missing sim_1     [file join $repo_root "Sim" "tb_pl_comm_top_external_rx.v"]

set_property verilog_define {QPSK_TOP_EXT_RX_NEG=1} [get_filesets sim_1]
set_property top $sim_top [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

reset_simulation
launch_simulation -simset sim_1 -mode behavioral
run all

close_sim
set_property verilog_define {} [get_filesets sim_1]
close_project

if {![file exists $sim_log]} {
    puts "ERROR: simulation log not found: $sim_log"
    exit 1
}

set fh [open $sim_log r]
set sim_text [read $fh]
close $fh

if {[string first {[TB_TOP_EXT_RX][FAIL]} $sim_text] >= 0} {
    puts "ERROR: simulation reported \[TB_TOP_EXT_RX\]\[FAIL\]. See $sim_log"
    exit 1
}

if {[string first {[TB_TOP_EXT_RX][PASS]} $sim_text] < 0} {
    puts "ERROR: simulation did not report \[TB_TOP_EXT_RX\]\[PASS\]. See $sim_log"
    exit 1
}

puts "INFO: top-level external RX negative-offset simulation completed."
