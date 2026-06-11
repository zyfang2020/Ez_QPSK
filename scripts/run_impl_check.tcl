#!/usr/bin/env tclsh
# Run synth_1 and impl_1 through route_design, then check routed setup/hold slack.
# Usage:
#   vivado -mode batch -source scripts/run_impl_check.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set board_io_helper [file join $script_dir "select_qpsk_board_io_constraints.tcl"]

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
if {![file exists $board_io_helper]} {
    puts "ERROR: board IO constraint helper not found: $board_io_helper"
    exit 1
}
source $board_io_helper

open_project $xpr_path

if {[llength [get_runs synth_1]] == 0} {
    puts "ERROR: run synth_1 not found."
    close_project
    exit 1
}
if {[llength [get_runs impl_1]] == 0} {
    puts "ERROR: run impl_1 not found."
    close_project
    exit 1
}

add_file_if_missing sources_1 [file join $repo_root "RTL" "modem" "qpsk_rx_fixed_demod.v"]
qpsk_select_board_io_constraints $repo_root "ax7020"
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "INFO: synth_1 status: $synth_status"
if {[string first "Complete" $synth_status] < 0} {
    puts "ERROR: synth_1 did not complete successfully: $synth_status"
    close_project
    exit 1
}

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 2
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: impl_1 status: $impl_status"
if {[string first "Complete" $impl_status] < 0} {
    puts "ERROR: impl_1 did not complete route_design successfully."
    close_project
    exit 1
}

open_run impl_1
set timing_rpt [file join $repo_root "Ez_QPSK.runs" "impl_1" "timing_route_check.rpt"]
report_timing_summary -file $timing_rpt

set setup_paths [get_timing_paths -max_paths 1 -setup]
set hold_paths  [get_timing_paths -max_paths 1 -hold]
set setup_slack 0.0
set hold_slack  0.0
if {[llength $setup_paths] > 0} {
    set setup_slack [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
    set hold_slack [get_property SLACK [lindex $hold_paths 0]]
}

puts "INFO: routed setup slack: $setup_slack ns"
puts "INFO: routed hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: routed timing check failed. See $timing_rpt"
    close_project
    exit 1
}

close_project
puts "INFO: implementation timing check completed."
