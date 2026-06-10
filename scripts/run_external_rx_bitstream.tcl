#!/usr/bin/env tclsh
# Build a board image for PL-side QPSK demod bring-up.
#
# This keeps the existing BD/PS/DMA topology, sets the fixed RTL wrapper to
# the requested RX mode, includes J11 demod debug pins, connects the existing
# ILA to FCLK0/probe2 for RX demod debug, runs implementation through
# bitstream, checks routed timing, and copies .bit/.ltx into artifacts/<mode>.
#
# Usage:
#   vivado -mode batch -source scripts/run_external_rx_bitstream.tcl
#   vivado -mode batch -source scripts/run_external_rx_bitstream.tcl -tclargs external_rx
#   vivado -mode batch -source scripts/run_external_rx_bitstream.tcl -tclargs loopback
#
# Modes:
#   external_rx : TX disabled, RX enabled. Use with an external QPSK source.
#   loopback    : TX enabled, RX enabled. Use for local DAC-to-ADC bring-up.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set bd_path    [file join $repo_root "Ez_QPSK.srcs" "sources_1" "bd" "zynq_dma" "zynq_dma.bd"]
set j11_xdc    [file join $repo_root "Constraints" "pl_comm_top_io_ax7020_j11_debug.xdc"]
set cell_name  "pl_comm_top_fixed_cfg_0"
set ila_name   "ila_0"
set demod_dbg_bus_w 96

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

set out_dir [file join $repo_root "artifacts" $mode]

proc add_file_if_missing {fileset_name file_path} {
    set fs [get_filesets $fileset_name]
    set existing [get_files -quiet -of_objects $fs [list $file_path]]
    if {[llength $existing] == 0} {
        add_files -norecurse -fileset $fileset_name $file_path
    }
}

proc require_file {file_path label} {
    if {![file exists $file_path]} {
        puts "ERROR: $label not found: $file_path"
        exit 1
    }
}

proc object_name {obj} {
    if {[llength $obj] == 0} {
        return ""
    }
    return [string trimleft [lindex $obj 0] "/"]
}

proc connect_pin_to_net {pin_name net_name} {
    set pin_obj [get_bd_pins -quiet $pin_name]
    if {[llength $pin_obj] == 0} {
        error "BD pin not found: $pin_name"
    }
    set net_obj [get_bd_nets -quiet $net_name]
    if {[llength $net_obj] == 0} {
        error "BD net not found: $net_name"
    }

    foreach old_net [get_bd_nets -quiet -of_objects $pin_obj] {
        if {[object_name $old_net] ne $net_name} {
            disconnect_bd_net -objects $pin_obj -net $old_net
        }
    }

    set pin_nets [get_bd_nets -quiet -of_objects $pin_obj]
    if {([llength $pin_nets] == 0) || ([object_name $pin_nets] ne $net_name)} {
        connect_bd_net -net $net_name $pin_obj
    }
}

proc connect_pin_pair_to_net {pin_a_name pin_b_name net_name} {
    set pin_a [get_bd_pins -quiet $pin_a_name]
    set pin_b [get_bd_pins -quiet $pin_b_name]
    if {[llength $pin_a] == 0} {
        error "BD pin not found: $pin_a_name"
    }
    if {[llength $pin_b] == 0} {
        error "BD pin not found: $pin_b_name"
    }

    set net_obj [get_bd_nets -quiet $net_name]
    if {[llength $net_obj] == 0} {
        connect_bd_net -net $net_name $pin_a $pin_b
    } else {
        set net_pins [get_bd_pins -quiet -of_objects $net_obj]
        set pin_a_found 0
        set pin_b_found 0
        foreach net_pin $net_pins {
            if {[object_name $net_pin] eq [object_name $pin_a]} {
                set pin_a_found 1
            }
            if {[object_name $net_pin] eq [object_name $pin_b]} {
                set pin_b_found 1
            }
        }
        if {!$pin_a_found || !$pin_b_found} {
            error "BD net $net_name exists but is not connected to both $pin_a_name and $pin_b_name."
        }
    }
}

proc refresh_module_reference_if_possible {cell_name} {
    set ip_candidates [get_ips -quiet *pl_comm_top_fixed_cfg*]
    set module_ref_target $cell_name
    if {[llength $ip_candidates] > 0} {
        set module_ref_target [lindex $ip_candidates 0]
    }
    if {[catch {update_module_reference $module_ref_target} update_msg]} {
        puts "WARNING: update_module_reference returned nonzero: $update_msg"
        puts "WARNING: continuing; required pins will be checked before saving the BD."
    }
}

proc ensure_demod_ila_probe {cell_name ila_name bus_width} {
    set ila_obj [get_bd_cells -quiet $ila_name]
    if {[llength $ila_obj] == 0} {
        error "BD ILA cell not found: $ila_name"
    }

    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES {3} \
        CONFIG.C_PROBE2_WIDTH $bus_width \
    ] $ila_obj

    set bus_pin [get_bd_pins -quiet "${cell_name}/rx_demod_dbg_bus"]
    if {[llength $bus_pin] == 0} {
        error "BD cell ${cell_name} does not expose rx_demod_dbg_bus. Refresh the module reference first."
    }
    set probe_pin [get_bd_pins -quiet "${ila_name}/probe2"]
    if {[llength $probe_pin] == 0} {
        error "BD ILA ${ila_name} does not expose probe2 after C_NUM_OF_PROBES=3."
    }

    connect_pin_pair_to_net "${cell_name}/rx_demod_dbg_bus" \
                            "${ila_name}/probe2" \
                            "${cell_name}_rx_demod_dbg_bus"
    connect_pin_to_net "${ila_name}/clk" "processing_system7_0_FCLK_CLK0"
}

require_file $xpr_path "project"
require_file $bd_path "BD"
require_file $j11_xdc "J11 constraint"

open_project $xpr_path

if {[llength [get_filesets sources_1]] == 0} {
    puts "ERROR: fileset sources_1 not found."
    close_project
    exit 1
}
if {[llength [get_filesets constrs_1]] == 0} {
    puts "ERROR: fileset constrs_1 not found."
    close_project
    exit 1
}
if {[llength [get_runs synth_1]] == 0} {
    puts "ERROR: run synth_1 not found."
    close_project
    exit 1
}
if {[llength [get_runs impl_1]] == 0} {
    puts "ERROR: run impl_1 not found."
    close_project
    exit 1
}

add_file_if_missing sources_1 [file join $repo_root "RTL" "modem" "qpsk_rx_fixed_demod.v"]
add_file_if_missing constrs_1 $j11_xdc

open_bd_design $bd_path
refresh_module_reference_if_possible $cell_name
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

if {[catch {ensure_demod_ila_probe $cell_name $ila_name $demod_dbg_bus_w} ila_msg]} {
    puts "ERROR: RX demod ILA debug setup failed: $ila_msg"
    close_project
    exit 1
}

validate_bd_design
save_bd_design
generate_target all [get_files $bd_path]
make_wrapper -files [get_files $bd_path] -top -import
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

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "INFO: impl_1 status: $impl_status"
if {[string first "Complete" $impl_status] < 0} {
    puts "ERROR: impl_1 did not complete write_bitstream successfully."
    close_project
    exit 1
}

open_run impl_1
set timing_rpt [file join $repo_root "Ez_QPSK.runs" "impl_1" "timing_${mode}_bitstream.rpt"]
report_timing_summary -file $timing_rpt

set setup_paths [get_timing_paths -max_paths 1 -setup]
set hold_paths  [get_timing_paths -max_paths 1 -hold]
set setup_slack 0.0
set hold_slack  0.0
if {[llength $setup_paths] > 0} {
    set setup_slack [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
    set hold_slack [get_property SLACK [lindex $hold_paths 0]]
}

puts "INFO: $mode setup slack: $setup_slack ns"
puts "INFO: $mode hold slack: $hold_slack ns"
if {$setup_slack < 0.0 || $hold_slack < 0.0} {
    puts "ERROR: $mode timing check failed. See $timing_rpt"
    close_project
    exit 1
}

file mkdir $out_dir
set run_dir [get_property DIRECTORY [get_runs impl_1]]
set bit_candidates [glob -nocomplain -directory $run_dir *.bit]
if {[llength $bit_candidates] == 0} {
    puts "ERROR: bitstream not found in $run_dir"
    close_project
    exit 1
}

set bit_src [lindex $bit_candidates 0]
set bit_dst [file join $out_dir "Ez_QPSK_${mode}.bit"]
file copy -force $bit_src $bit_dst
puts "INFO: copied bitstream: $bit_dst"

set ltx_candidates [glob -nocomplain -directory $run_dir *.ltx]
if {[llength $ltx_candidates] > 0} {
    set ltx_src [lindex $ltx_candidates 0]
    set ltx_dst [file join $out_dir "Ez_QPSK_${mode}.ltx"]
    file copy -force $ltx_src $ltx_dst
    puts "INFO: copied probes: $ltx_dst"
} else {
    puts "WARNING: no .ltx probe file found in $run_dir"
}

close_project
puts "INFO: $mode bitstream build completed."
