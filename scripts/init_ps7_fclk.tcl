#!/usr/bin/env xsct
# Initialize the Zynq PS7 clocks over JTAG so PL debug clocks driven by FCLK
# are active before Vivado Hardware Manager tries to discover ILA/debug_hub.
#
# Usage:
#   xsct scripts/init_ps7_fclk.tcl
#   xsct scripts/init_ps7_fclk.tcl Vitis_WS/EZ_QPSK/hw/ps7_init.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set ps7_init   [file join $repo_root "Vitis_WS" "EZ_QPSK" "hw" "ps7_init.tcl"]

if {$argc >= 1} {
    set ps7_init [file normalize [lindex $argv 0]]
}

if {![file exists $ps7_init]} {
    puts "ERROR: ps7_init.tcl not found: $ps7_init"
    exit 1
}

puts "INFO: connecting XSCT to local hw_server."
connect

puts "INFO: available XSCT targets:"
targets

set selected 0
foreach target_filter {
    {name =~ "APU*"}
    {name =~ "*Cortex-A9*#0*"}
    {name =~ "*ARM*#0*"}
} {
    if {[catch {targets -set -nocase -filter $target_filter} msg]} {
        puts "WARNING: target filter '$target_filter' failed: $msg"
    } else {
        set selected 1
        break
    }
}

if {!$selected} {
    puts "ERROR: no APU/Cortex-A9 target selected."
    exit 1
}

puts "INFO: selected target:"
targets

puts "INFO: sourcing $ps7_init"
source $ps7_init

puts "INFO: running ps7_init"
ps7_init

puts "INFO: running ps7_post_config"
ps7_post_config

puts "INFO: PS7 FCLK registers after init:"
mrd 0xF8000170
mrd 0xF80001C4

puts "INFO: PS7 init completed."
