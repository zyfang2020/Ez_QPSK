#!/usr/bin/env tclsh
# Export the current Vivado hardware platform XSA for PS/Vitis refresh.
#
# By default this exports hardware metadata only. Pass -include-bit after a
# routed bitstream has been generated when the Vitis/boot flow should carry the
# matching PL image.
#
# Usage:
#   vivado -mode batch -source scripts/export_current_xsa.tcl
#   vivado -mode batch -source scripts/export_current_xsa.tcl -tclargs \
#       -out artifacts/xsa/Ez_QPSK_current.xsa
#   vivado -mode batch -source scripts/export_current_xsa.tcl -tclargs \
#       -include-bit -out artifacts/xsa/Ez_QPSK_current_with_bit.xsa

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set out_xsa    [file join $repo_root "artifacts" "xsa" "Ez_QPSK_current.xsa"]
set include_bit 0

proc usage {} {
    puts "Usage:"
    puts "  vivado -mode batch -source scripts/export_current_xsa.tcl"
    puts "  vivado -mode batch -source scripts/export_current_xsa.tcl -tclargs -out <file.xsa>"
    puts "  vivado -mode batch -source scripts/export_current_xsa.tcl -tclargs -include-bit -out <file.xsa>"
}

proc take_arg_value {idx_var arg_name} {
    upvar 1 $idx_var idx
    upvar 1 argc argc
    upvar 1 argv argv
    incr idx
    if {$idx >= $argc} {
        puts "ERROR: $arg_name requires a value."
        usage
        exit 1
    }
    return [lindex $argv $idx]
}

for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -out {
            set out_xsa [file normalize [take_arg_value i $arg]]
        }
        -include-bit {
            set include_bit 1
        }
        -help {
            usage
            exit 0
        }
        default {
            puts "ERROR: unknown argument: $arg"
            usage
            exit 1
        }
    }
}

if {![file exists $xpr_path]} {
    puts "ERROR: project not found: $xpr_path"
    exit 1
}

open_project $xpr_path
update_compile_order -fileset sources_1

file mkdir [file dirname $out_xsa]
set args [list -fixed -force -file $out_xsa]
if {$include_bit} {
    if {[llength [get_runs impl_1]] == 0} {
        puts "ERROR: run impl_1 not found; cannot export with bitstream."
        close_project
        exit 1
    }
    open_run impl_1
    lappend args -include_bit
}

write_hw_platform {*}$args
close_project

puts "INFO: exported XSA: $out_xsa"
if {$include_bit} {
    puts "INFO: XSA includes bitstream from impl_1."
} else {
    puts "INFO: XSA contains hardware metadata only."
}
