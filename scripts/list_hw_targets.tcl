#!/usr/bin/env tclsh
# List Vivado Hardware Manager targets/devices with extra identity details.
#
# Usage:
#   vivado -mode batch -source scripts/list_hw_targets.tcl
#
# This script is read-only: it opens hardware targets and reports visible
# devices/ILAs, but does not program the FPGA or arm captures.

proc object_name {obj} {
    set name $obj
    catch {set name [get_property NAME $obj]}
    return $name
}

proc print_property_if_present {obj prop indent} {
    set props [list_property $obj]
    if {[lsearch -exact $props $prop] < 0} {
        return
    }
    if {[catch {set value [get_property $prop $obj]}]} {
        return
    }
    if {$value ne ""} {
        puts "${indent}${prop}: $value"
    }
}

proc print_selected_properties {obj indent} {
    foreach prop {
        NAME
        DESCRIPTION
        PART
        DEVICE_ID
        IDCODE
        DNA
        REGISTER.EFUSE.FUSE_DNA
        REGISTER.IDCODE
        REGISTER.JTAG_STATUS
        PROGRAM.HW_CFGMEM
        PROBES.FILE
        PROGRAM.FILE
    } {
        print_property_if_present $obj $prop $indent
    }
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets -quiet *]
puts "INFO: hardware target count: [llength $targets]"
if {[llength $targets] == 0} {
    puts "ERROR: no hardware targets found. Check board power, JTAG cable, and driver."
    exit 1
}

for {set target_idx 0} {$target_idx < [llength $targets]} {incr target_idx} {
    set target [lindex $targets $target_idx]
    puts "INFO: target #$target_idx: [object_name $target]"
    print_selected_properties $target "INFO:   "

    if {[catch {open_hw_target $target} open_msg]} {
        puts "WARNING: failed to open target #$target_idx: $open_msg"
        continue
    }

    set devices [get_hw_devices -quiet *]
    puts "INFO:   device count: [llength $devices]"
    for {set dev_idx 0} {$dev_idx < [llength $devices]} {incr dev_idx} {
        set dev [lindex $devices $dev_idx]
        puts "INFO:   device #$dev_idx: [object_name $dev]"
        current_hw_device $dev
        if {[catch {refresh_hw_device $dev} refresh_msg]} {
            puts "WARNING:   refresh failed for device #$dev_idx: $refresh_msg"
        }
        print_selected_properties $dev "INFO:     "
    }

    set ilas [get_hw_ilas -quiet *]
    puts "INFO:   ILA count after opening target: [llength $ilas]"
    for {set ila_idx 0} {$ila_idx < [llength $ilas]} {incr ila_idx} {
        set ila [lindex $ilas $ila_idx]
        puts "INFO:   ILA #$ila_idx: [object_name $ila]"
        print_selected_properties $ila "INFO:     "
    }

    catch {close_hw_target $target}
}

puts "INFO: hardware target listing completed."
