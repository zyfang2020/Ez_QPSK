#!/usr/bin/env tclsh
# Rebuild Vivado project from source files tracked in Git.
# Usage:
#   vivado -mode batch -source scripts/rebuild_project.tcl
#   vivado -mode batch -source scripts/rebuild_project.tcl -tclargs --run-synth
#   vivado -mode batch -source scripts/rebuild_project.tcl -tclargs --run-impl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set proj_name  "Ez_QPSK"
set proj_dir   [file join $repo_root "build" "vivado"]
set part_name  "xc7z020clg400-1"
set top_name   "pl_comm_top_fixed_cfg"
set sim_top    "tb_qpsk_tx_single_dac_min"

set run_synth 0
set run_impl  0

foreach arg $argv {
    switch -- $arg {
        "--run-synth" { set run_synth 1 }
        "--run-impl"  { set run_impl 1; set run_synth 1 }
        default {
            puts "WARN: unknown arg '$arg' ignored."
        }
    }
}

file mkdir $proj_dir

set xpr_path [file join $proj_dir "${proj_name}.xpr"]
if {[file exists $xpr_path]} {
    puts "INFO: existing project found, removing: $proj_dir"
    file delete -force $proj_dir
    file mkdir $proj_dir
}

create_project $proj_name $proj_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]

# Recursively collect files by extension using plain Tcl APIs (Vivado-compatible).
proc collect_files_recursive {root ext_list} {
    set out {}
    set entries [glob -nocomplain -directory $root *]
    foreach p $entries {
        if {[file isdirectory $p]} {
            set nested [collect_files_recursive $p $ext_list]
            if {[llength $nested] > 0} {
                set out [concat $out $nested]
            }
        } else {
            set ext [string tolower [file extension $p]]
            if {[lsearch -exact $ext_list $ext] >= 0} {
                lappend out $p
            }
        }
    }
    return $out
}

# Collect design sources.
set rtl_abs [collect_files_recursive [file join $repo_root RTL] {.v .sv .vh}]

if {[llength $rtl_abs] == 0} {
    puts "ERROR: no RTL source found under RTL/"
    exit 1
}

add_files -norecurse $rtl_abs

# Constraints.
set xdc_files [glob -nocomplain -directory [file join $repo_root constraints] -types f *.xdc]
if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 -norecurse $xdc_files
}

# Simulation sources.
set sim_files [concat \
    [glob -nocomplain -directory [file join $repo_root sim] -types f *.v] \
    [glob -nocomplain -directory [file join $repo_root sim] -types f *.sv] \
]
if {[llength $sim_files] > 0} {
    add_files -fileset sim_1 -norecurse $sim_files
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property top $top_name [get_filesets sources_1]
if {[llength [get_filesets sim_1]] > 0} {
    set_property top $sim_top [get_filesets sim_1]
}

save_project

puts "INFO: rebuild complete."
puts "INFO: project = $xpr_path"
puts "INFO: synth top = $top_name"
puts "INFO: sim top = $sim_top"

if {$run_synth} {
    puts "INFO: launching synth_1 ..."
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}

if {$run_impl} {
    puts "INFO: launching impl_1 to write bitstream ..."
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
}

puts "INFO: done."
