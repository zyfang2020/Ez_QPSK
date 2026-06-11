#!/usr/bin/env xsct
# Initialize the Zynq PS7 clocks over JTAG so PL debug clocks driven by FCLK
# are active before Vivado Hardware Manager tries to discover ILA/debug_hub.
#
# Usage:
#   xsct scripts/init_ps7_fclk.tcl
#   xsct scripts/init_ps7_fclk.tcl Vitis_WS/EZ_QPSK/hw/ps7_init.tcl
#   xsct scripts/init_ps7_fclk.tcl -list
#   xsct scripts/init_ps7_fclk.tcl -target <xsct_target_id_or_name_pattern>

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set ps7_init   [file join $repo_root "Vitis_WS" "EZ_QPSK" "hw" "ps7_init.tcl"]
set target_sel ""
set list_only 0

proc usage {} {
    puts "Usage:"
    puts "  xsct scripts/init_ps7_fclk.tcl ?ps7_init.tcl?"
    puts "  xsct scripts/init_ps7_fclk.tcl -list"
    puts "  xsct scripts/init_ps7_fclk.tcl -target <xsct_target_id_or_name_pattern> ?-ps7-init <ps7_init.tcl>?"
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

proc select_xsct_target {selector} {
    if {$selector eq ""} {
        foreach target_filter {
            {name =~ "APU*"}
            {name =~ "*Cortex-A9*#0*"}
            {name =~ "*ARM*#0*"}
        } {
            if {[catch {targets -set -nocase -filter $target_filter} msg]} {
                puts "WARNING: target filter '$target_filter' failed: $msg"
            } else {
                return 1
            }
        }
        return 0
    }

    if {[string is integer -strict $selector]} {
        if {[catch {targets -set $selector} msg]} {
            puts "ERROR: target id '$selector' failed: $msg"
            return 0
        }
        return 1
    }

    foreach target_filter [list \
        "name =~ \"$selector\"" \
        "name =~ \"*$selector*\"" \
    ] {
        if {[catch {targets -set -nocase -filter $target_filter} msg]} {
            puts "WARNING: target selector '$selector' with filter '$target_filter' failed: $msg"
        } else {
            return 1
        }
    }
    return 0
}

set positional_seen 0
for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -ps7-init {
            set ps7_init [file normalize [take_arg_value i $arg]]
        }
        -target {
            set target_sel [take_arg_value i $arg]
        }
        -list {
            set list_only 1
        }
        -help {
            usage
            exit 0
        }
        default {
            if {[string match "-*" $arg]} {
                puts "ERROR: unknown argument: $arg"
                usage
                exit 1
            }
            if {$positional_seen} {
                puts "ERROR: only one positional ps7_init.tcl path is supported."
                usage
                exit 1
            }
            set ps7_init [file normalize $arg]
            set positional_seen 1
        }
    }
}

if {!$list_only && ![file exists $ps7_init]} {
    puts "ERROR: ps7_init.tcl not found: $ps7_init"
    exit 1
}

puts "INFO: connecting XSCT to local hw_server."
connect

puts "INFO: available XSCT targets:"
targets

if {$list_only} {
    puts "INFO: list mode completed; PS7 init was not run."
    exit 0
}

if {![select_xsct_target $target_sel]} {
    puts "ERROR: no APU/Cortex-A9 target selected."
    puts "ERROR: use -list to inspect XSCT targets, then pass -target <id-or-name>."
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
