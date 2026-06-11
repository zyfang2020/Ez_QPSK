#!/usr/bin/env tclsh
# Select the active ADC/DAC board IO constraints for QPSK board images.
#
# Profiles:
#   ax7020      : current AX7020 ADC/DAC mezzanine mapping.
#   second_zynq : user-provided new high-speed ADC/DAC mapping.
#
# This helper only switches the ADC/DAC XDCs. The current sys_clk and J11 debug
# constraints remain separate because the new board's non-HS pins have not
# been provided yet.

proc qpsk_constraint_file_obj {fileset_name file_path} {
    set fs [get_filesets $fileset_name]
    set obj [get_files -quiet -of_objects $fs [list $file_path]]
    if {[llength $obj] == 0} {
        set tail [file tail $file_path]
        set obj [get_files -quiet -of_objects $fs [list "*$tail"]]
    }
    return $obj
}

proc qpsk_set_constraint_enabled {fileset_name file_path enabled} {
    set file_path [file normalize $file_path]
    set obj [qpsk_constraint_file_obj $fileset_name $file_path]

    if {[llength $obj] == 0} {
        if {!$enabled} {
            return
        }
        if {![file exists $file_path]} {
            error "constraint file not found: $file_path"
        }
        add_files -norecurse -fileset $fileset_name $file_path
        set obj [qpsk_constraint_file_obj $fileset_name $file_path]
    }

    if {[llength $obj] == 0} {
        error "failed to add/find constraint file: $file_path"
    }
    if {[llength $obj] > 1} {
        error "constraint file '$file_path' matched multiple project files: $obj"
    }

    set_property IS_ENABLED [expr {$enabled ? 1 : 0}] $obj
    if {$enabled} {
        set_property USED_IN {synthesis implementation} $obj
    }
}

proc qpsk_select_board_io_constraints {repo_root profile} {
    if {[llength [get_filesets constrs_1]] == 0} {
        error "fileset constrs_1 not found"
    }

    set ax7020_files [list \
        [file join $repo_root "Constraints" "pl_comm_top_io_ax7020_adc.xdc"] \
        [file join $repo_root "Constraints" "pl_comm_top_io_ax7020_dac.xdc"] \
    ]
    set second_zynq_files [list \
        [file join $repo_root "Constraints" "pl_comm_top_io_second_zynq_hs_adc.xdc"] \
        [file join $repo_root "Constraints" "pl_comm_top_io_second_zynq_hs_dac.xdc"] \
    ]

    switch -- $profile {
        ax7020 {
            set active_files $ax7020_files
            set inactive_files $second_zynq_files
        }
        second_zynq {
            set active_files $second_zynq_files
            set inactive_files $ax7020_files
        }
        default {
            error "unknown board IO profile '$profile'. Expected ax7020 or second_zynq."
        }
    }

    foreach file_path $inactive_files {
        qpsk_set_constraint_enabled constrs_1 $file_path 0
    }
    foreach file_path $active_files {
        qpsk_set_constraint_enabled constrs_1 $file_path 1
    }

    puts "INFO: selected QPSK board IO profile: $profile"
}
