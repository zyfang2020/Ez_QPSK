#!/usr/bin/env tclsh
# Capture external-RX ILA data to CSV for rx_demod_dbg_bus decoding.
#
# Usage:
#   vivado -mode batch -source scripts/capture_external_rx_ila.tcl
#   vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs \
#       -out Tool/data/external_rx_ila.csv
#   vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs \
#       -program -out Tool/data/external_rx_ila.csv
#   vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs \
#       -list
#   vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -dry-run

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set stamp      [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set out_csv    [file join $repo_root "Tool" "data" "external_rx_ila_${stamp}.csv"]
set bit_path   [file join $repo_root "artifacts" "external_rx" "Ez_QPSK_external_rx.bit"]
set ltx_path   [file join $repo_root "artifacts" "external_rx" "Ez_QPSK_external_rx.ltx"]
set program_first 0
set dry_run 0
set list_only 0
set target_sel ""
set device_sel ""
set ila_sel ""
set repeat_count 1
set warmup_ms 200
set repeat_gap_ms 50

proc usage {} {
    puts "Usage:"
    puts "  vivado -mode batch -source scripts/capture_external_rx_ila.tcl"
    puts "  vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -out <ila.csv>"
    puts "  vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -program -out <ila.csv>"
    puts "  vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -list"
    puts "Options:"
    puts "  -target <index|pattern>   Select a hardware target; default is index 0."
    puts "  -device <index|pattern>   Select a hardware device; default prefers xc7z020."
    puts "  -ila <index|pattern>      Select an ILA core; default is index 0."
    puts "  -repeat <count>           Capture multiple CSV files with _NN suffixes."
    puts "  -warmup-ms <ms>           Wait before the first capture; default 200."
    puts "  -gap-ms <ms>              Wait between repeated captures; default 50."
    puts "  vivado -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -dry-run"
}

proc require_file {file_path label} {
    if {![file exists $file_path]} {
        puts "ERROR: $label not found: $file_path"
        exit 1
    }
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

proc parse_nonnegative_int {text arg_name} {
    if {![string is integer -strict $text] || ($text < 0)} {
        puts "ERROR: $arg_name requires a nonnegative integer, got '$text'."
        usage
        exit 1
    }
    return $text
}

proc parse_positive_int {text arg_name} {
    if {![string is integer -strict $text] || ($text <= 0)} {
        puts "ERROR: $arg_name requires a positive integer, got '$text'."
        usage
        exit 1
    }
    return $text
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

proc numbered_csv_path {base_path idx total} {
    if {$total <= 1} {
        return $base_path
    }
    set dir [file dirname $base_path]
    set stem [file rootname [file tail $base_path]]
    set ext [file extension $base_path]
    return [file join $dir [format "%s_%02d%s" $stem $idx $ext]]
}

for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -out {
            set out_csv [file normalize [take_arg_value i $arg]]
        }
        -bit {
            set bit_path [file normalize [take_arg_value i $arg]]
        }
        -ltx {
            set ltx_path [file normalize [take_arg_value i $arg]]
        }
        -program {
            set program_first 1
        }
        -list {
            set list_only 1
        }
        -target {
            set target_sel [take_arg_value i $arg]
        }
        -device {
            set device_sel [take_arg_value i $arg]
        }
        -ila {
            set ila_sel [take_arg_value i $arg]
        }
        -repeat {
            set repeat_count [parse_positive_int [take_arg_value i $arg] $arg]
        }
        -warmup-ms {
            set warmup_ms [parse_nonnegative_int [take_arg_value i $arg] $arg]
        }
        -gap-ms {
            set repeat_gap_ms [parse_nonnegative_int [take_arg_value i $arg] $arg]
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

if {$list_only && $program_first} {
    puts "WARNING: -program is ignored in -list mode."
    set program_first 0
}

if {!$list_only} {
    require_file $ltx_path "probe file"
}
if {$program_first} {
    require_file $bit_path "bitstream"
}

puts "INFO: ILA CSV output: $out_csv"
if {!$list_only} {
    puts "INFO: probe file: $ltx_path"
}
if {$program_first} {
    puts "INFO: bitstream: $bit_path"
}
puts "INFO: repeat count: $repeat_count"
puts "INFO: warmup before first capture: $warmup_ms ms"
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
if {[llength $devices] == 0} {
    puts "ERROR: no FPGA hardware devices found on the selected target."
    exit 1
}

set dev [select_from_collection $devices $device_sel "hardware device"]
current_hw_device $dev
refresh_hw_device $dev
puts "INFO: selected hardware device: [object_name $dev]"

if {$program_first} {
    set_property PROBES.FILE $ltx_path $dev
    set_property PROGRAM.FILE $bit_path $dev
    puts "INFO: programming device before capture: $dev"
    program_hw_devices $dev
    refresh_hw_device $dev
} elseif {!$list_only} {
    set_property PROBES.FILE $ltx_path $dev
    refresh_hw_device $dev
}

set ilas [get_hw_ilas -quiet *]
print_collection "hardware ILA cores" $ilas
if {$list_only} {
    puts "INFO: list mode completed; no capture was armed."
    exit 0
}
if {[llength $ilas] == 0} {
    puts "ERROR: no hardware ILA cores found. Confirm the programmed bitstream and .ltx match."
    exit 1
}
set ila [select_from_collection $ilas $ila_sel "hardware ILA"]
puts "INFO: selected ILA: $ila"

set probes [get_hw_probes -quiet -of_objects $ila]
puts "INFO: hardware probes: $probes"

set demod_probes [get_hw_probes -quiet -of_objects $ila *rx_demod_dbg_bus*]
set probe2_candidates [get_hw_probes -quiet -of_objects $ila *probe2*]
if {([llength $demod_probes] == 0) && ([llength $probe2_candidates] == 0)} {
    puts "WARNING: did not find a probe name matching rx_demod_dbg_bus/probe2; capture will still proceed."
}

if {$warmup_ms > 0} {
    puts "INFO: waiting $warmup_ms ms before the first capture."
    after $warmup_ms
}

for {set cap_idx 0} {$cap_idx < $repeat_count} {incr cap_idx} {
    if {($cap_idx > 0) && ($repeat_gap_ms > 0)} {
        puts "INFO: waiting $repeat_gap_ms ms before repeated capture #$cap_idx."
        after $repeat_gap_ms
    }

    set this_csv [numbered_csv_path $out_csv $cap_idx $repeat_count]
    puts "INFO: arming ILA capture #$cap_idx with immediate trigger."
    if {[catch {run_hw_ila -trigger_now $ila} trigger_msg]} {
        puts "WARNING: run_hw_ila -trigger_now failed: $trigger_msg"
        puts "WARNING: falling back to run_hw_ila; ensure an ILA trigger condition is configured."
        run_hw_ila $ila
    }
    wait_on_hw_ila $ila

    set data_obj [upload_hw_ila_data $ila]
    file mkdir [file dirname $this_csv]
    write_hw_ila_data -force -csv_file $this_csv $data_obj
    puts "INFO: wrote ILA CSV: $this_csv"
}

set decode_csv [numbered_csv_path $out_csv 0 $repeat_count]
puts "INFO: decode with:"
puts "INFO:   python Tool/python/decode_rx_demod_ila.py \"$decode_csv\" --decoded-csv Tool/data/rx_demod_ila_decoded.csv --summary-json Tool/data/rx_demod_ila_summary.json"
if {$repeat_count > 1} {
    puts "INFO: repeated captures use numbered CSV suffixes from _00 to _[format %02d [expr {$repeat_count - 1}]]."
}
