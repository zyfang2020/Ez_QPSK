# ------------------------------------------------------------------------------
# Clock Constraints for current pure-RTL top
# ------------------------------------------------------------------------------
# Current assumption:
# - clk_axi is the single board-level input system clock.
# - clk_adc / clk_dac are forwarded output clocks used to drive the external
#   ADC / DAC devices, so they are not constrained as primary input clocks here.
# ------------------------------------------------------------------------------

create_clock -name clk_axi -period 10.000 [get_ports clk_axi]

# If you later need explicit forwarded-clock IO timing analysis, you can add
# create_generated_clock constraints on clk_adc / clk_dac after the board-side
# timing relationship is finalized.
