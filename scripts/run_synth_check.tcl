#!/usr/bin/env tclsh
# Run synth_1 as a batch sanity check for the current Vivado project.
# Usage:
#   vivado -mode batch -source scripts/run_synth_check.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]

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

if {[llength [get_runs synth_1]] == 0} {
    puts "ERROR: run synth_1 not found."
    close_project
    exit 1
}

add_file_if_missing sources_1 [file join $repo_root "RTL" "modem" "qpsk_rx_fixed_demod.v"]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 2
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "INFO: synth_1 status: $synth_status"
if {[string first "Complete" $synth_status] < 0} {
    puts "ERROR: synth_1 did not complete successfully."
    close_project
    exit 1
}

open_run synth_1
report_utilization -file [file join $repo_root "Ez_QPSK.runs" "synth_1" "utilization_synth_check.rpt"]
close_project

puts "INFO: synthesis check completed."
