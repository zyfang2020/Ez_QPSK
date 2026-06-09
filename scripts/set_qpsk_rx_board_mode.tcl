#!/usr/bin/env tclsh
# Set the fixed board bring-up mode for the PL QPSK path.
#
# Usage:
#   vivado -mode batch -source scripts/set_qpsk_rx_board_mode.tcl -tclargs external_rx
#   vivado -mode batch -source scripts/set_qpsk_rx_board_mode.tcl -tclargs loopback
#
# Modes:
#   external_rx : TX disabled, RX enabled. Use when feeding an external QPSK
#                 source into the ADC and observing rx_demod_* debug signals.
#   loopback    : TX enabled, RX enabled. Use for local TX/ADC loopback bring-up.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set bd_path    [file join $repo_root "Ez_QPSK.srcs" "sources_1" "bd" "zynq_dma" "zynq_dma.bd"]
set cell_name  "pl_comm_top_fixed_cfg_0"

set mode "external_rx"
if {[llength $argv] > 0} {
    set mode [lindex $argv 0]
}

switch -- $mode {
    external_rx {
        set fixed_tx_en 0
        set fixed_rx_en 1
    }
    loopback {
        set fixed_tx_en 1
        set fixed_rx_en 1
    }
    default {
        puts "ERROR: unknown mode '$mode'. Expected external_rx or loopback."
        exit 1
    }
}

if {![file exists $xpr_path]} {
    puts "ERROR: project not found: $xpr_path"
    exit 1
}
if {![file exists $bd_path]} {
    puts "ERROR: BD not found: $bd_path"
    exit 1
}

open_project $xpr_path
open_bd_design $bd_path

set cell_obj [get_bd_cells -quiet $cell_name]
if {[llength $cell_obj] == 0} {
    puts "ERROR: BD cell not found: $cell_name"
    close_project
    exit 1
}

set cell_props [list_property $cell_obj]
foreach prop {CONFIG.FIXED_TX_EN CONFIG.FIXED_RX_EN} {
    if {[lsearch -exact $cell_props $prop] < 0} {
        puts "ERROR: $cell_name does not expose $prop. Refresh the module reference first."
        close_project
        exit 1
    }
}

set_property -dict [list \
    CONFIG.FIXED_TX_EN $fixed_tx_en \
    CONFIG.FIXED_RX_EN $fixed_rx_en \
] $cell_obj

validate_bd_design
save_bd_design
generate_target all [get_files $bd_path]
make_wrapper -files [get_files $bd_path] -top -import
update_compile_order -fileset sources_1

close_project
puts "INFO: set $cell_name mode=$mode FIXED_TX_EN=$fixed_tx_en FIXED_RX_EN=$fixed_rx_en"
