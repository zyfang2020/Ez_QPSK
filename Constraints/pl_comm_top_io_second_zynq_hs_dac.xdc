# ------------------------------------------------------------------------------
# Second Zynq board high-speed DAC pin constraints for pl_comm_top_fixed_cfg
# ------------------------------------------------------------------------------
# User-provided interface table:
#   HS_DA_CLK -> A20
#   HS_DA0    -> J20
#   HS_DA1    -> H20
#   HS_DA2    -> G15
#   HS_DA3    -> M20
#   HS_DA4    -> H15
#   HS_DA5    -> M19
#   HS_DA6    -> K18
#   HS_DA7    -> M18
#   HS_DA8    -> K17
#   HS_DA9    -> M17
#   HS_DA10   -> J16
#   HS_DA11   -> B19
#
# NOTE:
# - IOSTANDARD is set to LVCMOS33 to match the current AX7020 constraints.
#   Confirm the second board bank-35 VCCO before using the image on hardware.
# - clk_dac is the forwarded 100 MHz sample clock from PS FCLK0/clk_io.
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN A20 [get_ports clk_dac]
set_property IOSTANDARD LVCMOS33 [get_ports clk_dac]

set_property PACKAGE_PIN J20 [get_ports {dac_data[0]}]
set_property PACKAGE_PIN H20 [get_ports {dac_data[1]}]
set_property PACKAGE_PIN G15 [get_ports {dac_data[2]}]
set_property PACKAGE_PIN M20 [get_ports {dac_data[3]}]
set_property PACKAGE_PIN H15 [get_ports {dac_data[4]}]
set_property PACKAGE_PIN M19 [get_ports {dac_data[5]}]
set_property PACKAGE_PIN K18 [get_ports {dac_data[6]}]
set_property PACKAGE_PIN M18 [get_ports {dac_data[7]}]
set_property PACKAGE_PIN K17 [get_ports {dac_data[8]}]
set_property PACKAGE_PIN M17 [get_ports {dac_data[9]}]
set_property PACKAGE_PIN J16 [get_ports {dac_data[10]}]
set_property PACKAGE_PIN B19 [get_ports {dac_data[11]}]

set_property IOSTANDARD LVCMOS33 [get_ports {dac_data[*]}]
