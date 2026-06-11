#!/usr/bin/env tclsh
# Program the external-RX board image and attach the matching ILA probes.
#
# Usage:
#   vivado -mode batch -source scripts/program_external_rx_bitstream.tcl
#   vivado -mode batch -source scripts/program_external_rx_bitstream.tcl \
#       -tclargs artifacts/external_rx/Ez_QPSK_external_rx.bit \
#                artifacts/external_rx/Ez_QPSK_external_rx.ltx
#
# With multiple JTAG boards connected, prefer scripts/program_bitstream.tcl and
# pass -target/-device explicitly.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set bit_path   [file join $repo_root "artifacts" "external_rx" "Ez_QPSK_external_rx.bit"]
set ltx_path   [file join $repo_root "artifacts" "external_rx" "Ez_QPSK_external_rx.ltx"]

if {$argc >= 1} {
    set bit_path [file normalize [lindex $argv 0]]
}
if {$argc >= 2} {
    set ltx_path [file normalize [lindex $argv 1]]
}

proc require_file {file_path label} {
    if {![file exists $file_path]} {
        puts "ERROR: $label not found: $file_path"
        exit 1
    }
}

require_file $bit_path "bitstream"
require_file $ltx_path "probe file"

open_hw_manager
connect_hw_server

set targets [get_hw_targets -quiet *]
if {[llength $targets] == 0} {
    puts "ERROR: no hardware targets found. Check board power, JTAG cable, and driver."
    exit 1
}

open_hw_target [lindex $targets 0]

set devices [get_hw_devices -quiet xc7z020*]
if {[llength $devices] == 0} {
    set devices [get_hw_devices -quiet *]
}
if {[llength $devices] == 0} {
    puts "ERROR: no FPGA hardware devices found on the selected target."
    exit 1
}

set dev [lindex $devices 0]
current_hw_device $dev
refresh_hw_device $dev

set_property PROGRAM.FILE $bit_path $dev
set_property PROBES.FILE  $ltx_path $dev

puts "INFO: programming device: $dev"
puts "INFO: bitstream: $bit_path"
puts "INFO: probes: $ltx_path"
program_hw_devices $dev
refresh_hw_device $dev

set ilas [get_hw_ilas -quiet *]
puts "INFO: hardware ILA cores: $ilas"
puts "INFO: external_rx bitstream programmed."
