# ------------------------------------------------------------------------------
# Second Zynq board high-speed ADC pin constraints for pl_comm_top_fixed_cfg
# ------------------------------------------------------------------------------
# User-provided interface table:
#   HS_AD_CLK -> G17
#   HS_AD0    -> M15
#   HS_AD1    -> H17
#   HS_AD2    -> M14
#   HS_AD3    -> H16
#   HS_AD4    -> L17
#   HS_AD5    -> H18
#   HS_AD6    -> L16
#   HS_AD7    -> J18
#   HS_AD8    -> J14
#   HS_AD9    -> K14
#
# NOTE:
# - This file is included in the second-board profile so all current top-level
#   ADC ports remain constrained, even when the second board is used TX-only.
# - IOSTANDARD is set to LVCMOS33 to match the current AX7020 constraints.
#   Confirm the second board bank-35 VCCO before using the image on hardware.
# - clk_adc is the forwarded 100 MHz sample clock from PS FCLK0/clk_io.
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN G17 [get_ports clk_adc]
set_property IOSTANDARD LVCMOS33 [get_ports clk_adc]

set_property PACKAGE_PIN M15 [get_ports {adc_data[0]}]
set_property PACKAGE_PIN H17 [get_ports {adc_data[1]}]
set_property PACKAGE_PIN M14 [get_ports {adc_data[2]}]
set_property PACKAGE_PIN H16 [get_ports {adc_data[3]}]
set_property PACKAGE_PIN L17 [get_ports {adc_data[4]}]
set_property PACKAGE_PIN H18 [get_ports {adc_data[5]}]
set_property PACKAGE_PIN L16 [get_ports {adc_data[6]}]
set_property PACKAGE_PIN J18 [get_ports {adc_data[7]}]
set_property PACKAGE_PIN J14 [get_ports {adc_data[8]}]
set_property PACKAGE_PIN K14 [get_ports {adc_data[9]}]

set_property IOSTANDARD LVCMOS33 [get_ports {adc_data[*]}]
