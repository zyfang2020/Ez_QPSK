#!/usr/bin/env xsct
# Initialize PS7/FCLK and download a bare-metal ELF to Cortex-A9 over JTAG.
#
# Usage:
#   xsct scripts/download_ps_app.tcl -list
#   xsct scripts/download_ps_app.tcl
#   xsct scripts/download_ps_app.tcl -target <xsct_target_id_or_name_pattern>
#   xsct scripts/download_ps_app.tcl -elf <app.elf> -ps7-init <ps7_init.tcl>

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set ps7_init   [file join $repo_root "Vitis_WS" "EZ_QPSK" "hw" "ps7_init.tcl"]
set elf_path   [file join $repo_root "Vitis_WS" "codex_xsa_smoke_external_rx_wide_acq" "manual_build" "baremetal_dma_rx_smoke.elf"]
set target_sel ""
set list_only 0
set no_run 0
set skip_ps7_init 0

proc usage {} {
    puts "Usage:"
    puts "  xsct scripts/download_ps_app.tcl -list"
    puts "  xsct scripts/download_ps_app.tcl ?-target <id-or-name>? ?-elf <app.elf>? ?-ps7-init <ps7_init.tcl>?"
    puts "Options:"
    puts "  -target <id|pattern>      Select XSCT target; default prefers APU/Cortex-A9 #0."
    puts "  -elf <app.elf>            Bare-metal ELF to download and run."
    puts "  -ps7-init <ps7_init.tcl>  PS7 init script to source before downloading."
    puts "  -skip-ps7-init            Download ELF without running ps7_init/ps7_post_config."
    puts "  -no-run                   Download ELF but do not continue the CPU."
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

for {set i 0} {$i < $argc} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -target {
            set target_sel [take_arg_value i $arg]
        }
        -elf {
            set elf_path [file normalize [take_arg_value i $arg]]
        }
        -ps7-init {
            set ps7_init [file normalize [take_arg_value i $arg]]
        }
        -list {
            set list_only 1
        }
        -no-run {
            set no_run 1
        }
        -skip-ps7-init {
            set skip_ps7_init 1
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
    require_file $elf_path "ELF"
    if {!$skip_ps7_init} {
        require_file $ps7_init "ps7_init.tcl"
    }
}

puts "INFO: connecting XSCT to local hw_server."
connect

puts "INFO: available XSCT targets:"
targets

if {$list_only} {
    puts "INFO: list mode completed; PS app was not downloaded."
    exit 0
}

if {![select_xsct_target $target_sel]} {
    puts "ERROR: no APU/Cortex-A9 target selected."
    puts "ERROR: use -list to inspect XSCT targets, then pass -target <id-or-name>."
    exit 1
}

puts "INFO: selected target:"
targets

if {!$skip_ps7_init} {
    puts "INFO: sourcing $ps7_init"
    source $ps7_init

    puts "INFO: running ps7_init"
    ps7_init

    puts "INFO: running ps7_post_config"
    ps7_post_config

    puts "INFO: PS7 FCLK registers after init:"
    mrd 0xF8000170
    mrd 0xF80001C4
}

puts "INFO: downloading ELF: $elf_path"
dow $elf_path

if {$no_run} {
    puts "INFO: -no-run selected; CPU was not continued."
} else {
    puts "INFO: continuing CPU."
    con
}

puts "INFO: PS app download completed."
