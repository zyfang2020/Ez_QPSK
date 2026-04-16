# ------------------------------------------------------------------------------
# AX7020 DAC Pin Constraints for pl_comm_top_fixed_cfg / pl_comm_top
# ------------------------------------------------------------------------------
# Source basis:
# 1) AX7020 user manual: board connector PINxx -> FPGA package pin
# 2) User-provided DAC mezzanine wiring: dac_data[n] -> board PINxx
#
# Current mapping interpreted as:
#   clk_dac      -> PIN3  -> W19  (FPGA output clock to DAC)
#   dac_data[0]  -> PIN16 -> U14
#   dac_data[1]  -> PIN15 -> U15
#   dac_data[2]  -> PIN14 -> N17
#   dac_data[3]  -> PIN13 -> P18
#   dac_data[4]  -> PIN12 -> W14
#   dac_data[5]  -> PIN11 -> Y14
#   dac_data[6]  -> PIN10 -> V15
#   dac_data[7]  -> PIN9  -> W15
#   dac_data[8]  -> PIN8  -> Y16
#   dac_data[9]  -> PIN7  -> Y17
#   dac_data[10] -> PIN6  -> P14
#   dac_data[11] -> PIN5  -> R14
#
# NOTE:
# - IOSTANDARD is currently set to LVCMOS33 based on the common AX7020 expansion
#   bank usage assumption. Please confirm target bank VCCO before final bitstream.
# - clk_dac is now used as the forwarded output clock to the DAC device.
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN W19 [get_ports clk_dac]
set_property IOSTANDARD LVCMOS33 [get_ports clk_dac]

set_property PACKAGE_PIN U14 [get_ports {dac_data[0]}]
set_property PACKAGE_PIN U15 [get_ports {dac_data[1]}]
set_property PACKAGE_PIN N17 [get_ports {dac_data[2]}]
set_property PACKAGE_PIN P18 [get_ports {dac_data[3]}]
set_property PACKAGE_PIN W14 [get_ports {dac_data[4]}]
set_property PACKAGE_PIN Y14 [get_ports {dac_data[5]}]
set_property PACKAGE_PIN V15 [get_ports {dac_data[6]}]
set_property PACKAGE_PIN W15 [get_ports {dac_data[7]}]
set_property PACKAGE_PIN Y16 [get_ports {dac_data[8]}]
set_property PACKAGE_PIN Y17 [get_ports {dac_data[9]}]
set_property PACKAGE_PIN P14 [get_ports {dac_data[10]}]
set_property PACKAGE_PIN R14 [get_ports {dac_data[11]}]

set_property IOSTANDARD LVCMOS33 [get_ports {dac_data[*]}]
