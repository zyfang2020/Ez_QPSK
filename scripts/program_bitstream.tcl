#!/usr/bin/env tclsh
# Program a bitstream with optional hardware target/device selection.
#
# Usage:
#   vivado -mode batch -source scripts/program_bitstream.tcl -tclargs \
#       -bit artifacts/external_rx/Ez_QPSK_external_rx.bit \
#       -ltx artifacts/external_rx/Ez_QPSK_external_rx.ltx
#   vivado -mode batch -source scripts/program_bitstream.tcl -tclargs \
#       -bit artifacts/second_board_tx_prbs/Ez_QPSK_second_board_tx_prbs.bit \
#       -target 1
#   vivado -mode batch -source scripts/program_bitstream.tcl -tclargs -list

set bit_path ""
set ltx_path ""
set target_sel ""
set device_sel ""
set list_only 0
set dry_run 0

proc usage {} {
    puts "Usage:"
    puts "  vivado -mode batch -source scripts/program_bitstream.tcl -tclargs -bit <image.bit> ?-ltx <probes.ltx>?"
    puts "Options:"
    puts "  -target <index|pattern>   Select a hardware target; default is index 0."
    puts "  -device <index|pattern>   Select a hardware device; default prefers xc7z020."
    puts "  -list                     List visible targets/devices without programming."
    puts "  -dry-run                  Parse arguments and check files without opening hardware."
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

proc require_file {file_path label} {
    if {![file exists $file_path]} {
        puts "ERROR: $label not found: $file_path"
        exit 1
    }
}

proc object_name {obj} {
    set name $obj
    catch {set name [get_property NAME $obj]}
    return $name
}

proc print_collection {label objects} {
    puts "INFO: $label count: [llength $objects]"
    for {set i 0} {$i < [llength $objects]} {incr i} {
        set obj [lindex $objects $i]
        puts "INFO:   #$i [object_name $obj]"
    }
}

proc select_from_collection {objects selector label} {
    if {[llength $objects] == 0} {
        puts "ERROR: no $label found."
        exit 1
    }
    if {$selector eq ""} {
        return [lindex $objects 0]
    }
    if {[string is integer -strict $selector]} {
        if {($selector < 0) || ($selector >= [llength $objects])} {
            puts "ERROR: $label index $selector is out of range."
            exit 1
        }
        return [lindex $objects $selector]
    }

    set matches [list]
    foreach obj $objects {
        set name [object_name $obj]
        if {[string match $selector $name] ||
            [string match $selector $obj] ||
            [string match "*$selector*" $name] ||
            [string match "*$selector*" $obj]} {
            lappend matches $obj
        }
    }
    if {[llength $matches] == 0} {
        puts "ERROR: no $label matches selector '$selector'."
        exit 1
    }
    if {[llength $matches] > 1} {
        puts "ERROR: $label selector '$selector' matched multiple objects:"
        print_collection $label $matches
        exit 1
    }
    return [lindex $matches 0]
}

for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -bit {
            set bit_path [file normalize [take_arg_value i $arg]]
        }
        -ltx {
            set ltx_path [file normalize [take_arg_value i $arg]]
        }
        -target {
            set target_sel [take_arg_value i $arg]
        }
        -device {
            set device_sel [take_arg_value i $arg]
        }
        -list {
            set list_only 1
        }
        -dry-run {
            set dry_run 1
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

if {!$list_only} {
    if {$bit_path eq ""} {
        puts "ERROR: -bit is required unless -list is used."
        usage
        exit 1
    }
    require_file $bit_path "bitstream"
    if {$ltx_path ne ""} {
        require_file $ltx_path "probe file"
    }
}

puts "INFO: bitstream: $bit_path"
if {$ltx_path ne ""} {
    puts "INFO: probes: $ltx_path"
}
puts "INFO: target selector: $target_sel"
puts "INFO: device selector: $device_sel"

if {$dry_run} {
    puts "INFO: dry-run completed; hardware was not opened."
    exit 0
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets -quiet *]
print_collection "hardware targets" $targets
if {[llength $targets] == 0} {
    puts "ERROR: no hardware targets found. Check board power, JTAG cable, and driver."
    exit 1
}

set target [select_from_collection $targets $target_sel "hardware target"]
puts "INFO: selected hardware target: [object_name $target]"
open_hw_target $target

set devices [get_hw_devices -quiet xc7z020*]
if {[llength $devices] == 0} {
    set devices [get_hw_devices -quiet *]
}
print_collection "hardware devices" $devices
if {$list_only} {
    puts "INFO: list mode completed; no device was programmed."
    exit 0
}

set dev [select_from_collection $devices $device_sel "hardware device"]
current_hw_device $dev
refresh_hw_device $dev

set_property PROGRAM.FILE $bit_path $dev
if {$ltx_path ne ""} {
    set_property PROBES.FILE $ltx_path $dev
}

puts "INFO: programming device: [object_name $dev]"
program_hw_devices $dev
refresh_hw_device $dev

set ilas [get_hw_ilas -quiet *]
puts "INFO: hardware ILA cores: $ilas"
puts "INFO: bitstream programmed."
