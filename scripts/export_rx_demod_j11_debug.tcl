#!/usr/bin/env tclsh
# Export PL-side QPSK RX demod debug pins from the current BD to board IO.
#
# Usage:
#   vivado -mode batch -source scripts/export_rx_demod_j11_debug.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xpr_path   [file join $repo_root "Ez_QPSK.xpr"]
set bd_path    [file join $repo_root "Ez_QPSK.srcs" "sources_1" "bd" "zynq_dma" "zynq_dma.bd"]
set j11_xdc    [file join $repo_root "Constraints" "pl_comm_top_io_ax7020_j11_debug.xdc"]

proc add_file_if_missing {fileset_name file_path} {
    set fs [get_filesets $fileset_name]
    set existing [get_files -quiet -of_objects $fs [list $file_path]]
    if {[llength $existing] == 0} {
        add_files -norecurse -fileset $fileset_name $file_path
    }
}

proc ensure_bd_output_net {port_name cell_name} {
    set port_obj [get_bd_ports -quiet $port_name]
    if {[llength $port_obj] == 0} {
        set port_obj [create_bd_port -dir O $port_name]
    }

    set pin_obj [get_bd_pins -quiet "${cell_name}/${port_name}"]
    if {[llength $pin_obj] == 0} {
        error "BD cell ${cell_name} does not expose pin ${port_name}. Refresh the module reference first."
    }

    set port_nets [get_bd_nets -quiet -of_objects $port_obj]
    set pin_nets  [get_bd_nets -quiet -of_objects $pin_obj]
    if {([llength $port_nets] == 0) && ([llength $pin_nets] == 0)} {
        connect_bd_net -net "${cell_name}_${port_name}" $port_obj $pin_obj
    } elseif {([llength $port_nets] == 1) && ([llength $pin_nets] == 1) && ([lindex $port_nets 0] eq [lindex $pin_nets 0])} {
        puts "INFO: ${port_name} is already connected."
    } else {
        error "BD net conflict for ${port_name}; please inspect the existing connection manually."
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
if {![file exists $j11_xdc]} {
    puts "ERROR: J11 constraint not found: $j11_xdc"
    exit 1
}

open_project $xpr_path

if {[llength [get_filesets constrs_1]] == 0} {
    puts "ERROR: fileset constrs_1 not found."
    close_project
    exit 1
}

add_file_if_missing constrs_1 $j11_xdc
update_compile_order -fileset sources_1

open_bd_design $bd_path

set cell_name "pl_comm_top_fixed_cfg_0"
set cell_obj [get_bd_cells -quiet $cell_name]
if {[llength $cell_obj] == 0} {
    puts "ERROR: BD cell not found: $cell_name"
    close_project
    exit 1
}

set ip_candidates [get_ips -quiet *pl_comm_top_fixed_cfg*]
puts "INFO: module reference IP candidates: $ip_candidates"
set module_ref_target $cell_name
if {[llength $ip_candidates] > 0} {
    set module_ref_target [lindex $ip_candidates 0]
}

if {[catch {update_module_reference $module_ref_target} update_msg]} {
    puts "WARNING: update_module_reference returned nonzero: $update_msg"
    if {[info exists ::errorInfo]} {
        puts "WARNING: update_module_reference errorInfo: $::errorInfo"
    }
    puts "WARNING: continuing; required pins will be checked before saving the BD."
}

ensure_bd_output_net rx_demod_bit  $cell_name
ensure_bd_output_net rx_demod_lock $cell_name

validate_bd_design
save_bd_design
generate_target all [get_files $bd_path]
make_wrapper -files [get_files $bd_path] -top -import
update_compile_order -fileset sources_1

close_project
puts "INFO: RX demod J11 debug export completed."
