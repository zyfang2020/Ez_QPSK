# ------------------------------------------------------------------------------
# Clock Constraints for pl_comm_top
# ------------------------------------------------------------------------------
# Usage:
# 1) Add this file to Vivado "Constraints Sources"
# 2) Adjust periods to your real board clock plan
# ------------------------------------------------------------------------------

# Primary clocks (ports are defined in RTL/top/pl_comm_top.v)
create_clock -name clk_dac -period 10.000 [get_ports clk_dac]
create_clock -name clk_adc -period 10.000 [get_ports clk_adc]
create_clock -name clk_axi -period 10.000 [get_ports clk_axi]

# These 3 clock domains are asynchronous to each other in current architecture
set_clock_groups -asynchronous \
    -group [get_clocks clk_dac] \
    -group [get_clocks clk_adc] \
    -group [get_clocks clk_axi]

