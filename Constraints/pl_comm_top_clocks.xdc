# ------------------------------------------------------------------------------
# Clock Constraints for pl_comm_top
# ------------------------------------------------------------------------------
# Usage:
# 1) Add this file to Vivado "Constraints Sources"
# 2) Adjust periods to your real board clock plan
# ------------------------------------------------------------------------------

# Primary clocks.
# Note:
# - clk_dac / clk_adc are typically top-level ports in current board bring-up.
# - clk_axi may be either a top-level port or an internal PS FCLK when BD wrapper
#   is used as synthesis top, so guard the external-port clock creation here.
if {[llength [get_ports -quiet clk_dac]] > 0} {
    create_clock -name clk_dac -period 10.000 [get_ports clk_dac]
}

if {[llength [get_ports -quiet clk_adc]] > 0} {
    create_clock -name clk_adc -period 10.000 [get_ports clk_adc]
}

if {[llength [get_ports -quiet clk_axi]] > 0} {
    create_clock -name clk_axi -period 10.000 [get_ports clk_axi]
}

# These clock domains are asynchronous to each other in current architecture.
set async_groups {}
foreach clk_name {clk_dac clk_adc clk_axi} {
    if {[llength [get_clocks -quiet $clk_name]] > 0} {
        lappend async_groups -group [get_clocks $clk_name]
    }
}

if {[llength $async_groups] >= 4} {
    eval set_clock_groups -asynchronous $async_groups
}
