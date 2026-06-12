#!/usr/bin/env xsct
# Smoke-test Vitis platform/BSP creation from an exported XSA.
#
# This script intentionally writes only under Vitis_WS/codex_xsa_smoke by
# default, which is ignored by Git. It verifies that the PS-side standalone BSP
# can be regenerated from the XSA and that sw/baremetal_dma_rx/main.c compiles
# and links against the generated BSP.
#
# Usage:
#   xsct scripts/test_vitis_xsa_build.tcl
#   xsct scripts/test_vitis_xsa_build.tcl <xsa_path> <workspace_dir>

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set xsa_path   [file join $repo_root "artifacts" "xsa" "Ez_QPSK_external_rx_with_bit.xsa"]
set ws_dir     [file join $repo_root "Vitis_WS" "codex_xsa_smoke"]
set src_dir    [file join $repo_root "sw" "baremetal_dma_rx"]
set vitis_root "D:/Program_Files/Xilinx/Vitis/2020.2"

if {$argc >= 1} {
    set xsa_path [file normalize [lindex $argv 0]]
}
if {$argc >= 2} {
    set ws_dir [file normalize [lindex $argv 1]]
}
if {$argc >= 3} {
    set vitis_root [file normalize [lindex $argv 2]]
}

set platform_name "codex_stage2_platform"
set domain_name   "standalone_domain"
set processor     "ps7_cortexa9_0"
set gcc_path      [file join $vitis_root "gnu" "aarch32" "nt" \
                       "gcc-arm-none-eabi" "bin" "arm-none-eabi-gcc.exe"]

proc require_file {file_path label} {
    if {![file exists $file_path]} {
        puts "ERROR: $label not found: $file_path"
        exit 1
    }
}

proc require_dir {dir_path label} {
    if {![file isdirectory $dir_path]} {
        puts "ERROR: $label not found: $dir_path"
        exit 1
    }
}

require_file $xsa_path "XSA"
require_file [file join $src_dir "main.c"] "baremetal DMA RX source"
require_file [file join $src_dir "lscript.ld"] "baremetal DMA RX linker script"
require_file $gcc_path "ARM GCC"

puts "INFO: workspace: $ws_dir"
puts "INFO: XSA: $xsa_path"
puts "INFO: source: $src_dir"
puts "INFO: ARM GCC: $gcc_path"

if {[file exists $ws_dir]} {
    puts "INFO: removing old smoke workspace: $ws_dir"
    file delete -force $ws_dir
}
file mkdir $ws_dir
setws $ws_dir

platform create \
    -name $platform_name \
    -hw $xsa_path \
    -proc $processor \
    -os standalone
platform active $platform_name
domain active $domain_name
platform generate

set bsp_root [file join $ws_dir $platform_name $processor $domain_name "bsp" $processor]
set include_dir [file join $bsp_root "include"]
set lib_dir [file join $bsp_root "lib"]
set libxil [file join $lib_dir "libxil.a"]
set main_c [file join $src_dir "main.c"]
set lscript [file join $src_dir "lscript.ld"]
set build_dir [file join $ws_dir "manual_build"]
set obj_path [file join $build_dir "main.o"]
set elf_path [file join $build_dir "baremetal_dma_rx_smoke.elf"]
set spec_path [file join $build_dir "Xilinx.spec"]

require_dir $include_dir "BSP include directory"
require_dir $lib_dir "BSP lib directory"
require_file $libxil "BSP libxil.a"

file mkdir $build_dir
set spec_fh [open $spec_path "w"]
puts $spec_fh "*startfile:"
puts $spec_fh "crti%O%s crtbegin%O%s"
close $spec_fh

set compile_args [list \
    "-Wall" "-O0" "-g3" "-c" "-fmessage-length=0" \
    "-MMD" "-MP" "-MT" "main.o" \
    "-mcpu=cortex-a9" "-mfpu=vfpv3" "-mfloat-abi=hard" \
    "-I" $include_dir \
    "-o" $obj_path \
    $main_c \
]
puts "INFO: compiling PS app source."
exec $gcc_path {*}$compile_args

set link_args [list \
    "-mcpu=cortex-a9" "-mfpu=vfpv3" "-mfloat-abi=hard" \
    "-Wl,-build-id=none" "-specs=$spec_path" \
    "-Wl,-T" "-Wl,$lscript" \
    "-L" $lib_dir \
    "-o" $elf_path \
    $obj_path \
    "-Wl,--start-group,-lxil,-lgcc,-lc,--end-group" \
]
puts "INFO: linking PS app ELF."
exec $gcc_path {*}$link_args

require_file $elf_path "built ELF"
puts "INFO: built ELF: $elf_path"
puts "INFO: Vitis XSA import/build smoke test passed."
