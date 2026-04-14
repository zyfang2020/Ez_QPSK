# ------------------------------------------------------------------------------
# AX7020 ADC Data Pin Constraints for pl_comm_top_fixed_cfg / pl_comm_top
# ------------------------------------------------------------------------------
# Source basis:
# 1) AX7020 user manual: board connector PINxx -> FPGA package pin
# 2) User-provided ADC mezzanine wiring: adc_data[n] -> board PINxx
#
# Current mapping interpreted as:
#   clk_adc     -> PIN25 -> V13
#   adc_data[0] -> PIN28 -> V12
#   adc_data[1] -> PIN27 -> W13
#   adc_data[2] -> PIN30 -> T12
#   adc_data[3] -> PIN29 -> U12
#   adc_data[4] -> PIN32 -> T11
#   adc_data[5] -> PIN31 -> T10
#   adc_data[6] -> PIN34 -> B19
#   adc_data[7] -> PIN33 -> A20
#   adc_data[8] -> PIN36 -> C20
#   adc_data[9] -> PIN35 -> B20
#
# NOTE:
# - IOSTANDARD is currently set to LVCMOS33 based on the common AX7020 expansion
#   bank usage assumption. Please confirm target bank VCCO before final bitstream.
# - This file only constrains ADC parallel data bits for now.
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN V13 [get_ports clk_adc]
set_property IOSTANDARD LVCMOS33 [get_ports clk_adc]

set_property PACKAGE_PIN V12 [get_ports {adc_data[0]}]
set_property PACKAGE_PIN W13 [get_ports {adc_data[1]}]
set_property PACKAGE_PIN T12 [get_ports {adc_data[2]}]
set_property PACKAGE_PIN U12 [get_ports {adc_data[3]}]
set_property PACKAGE_PIN T11 [get_ports {adc_data[4]}]
set_property PACKAGE_PIN T10 [get_ports {adc_data[5]}]
set_property PACKAGE_PIN B19 [get_ports {adc_data[6]}]
set_property PACKAGE_PIN A20 [get_ports {adc_data[7]}]
set_property PACKAGE_PIN C20 [get_ports {adc_data[8]}]
set_property PACKAGE_PIN B20 [get_ports {adc_data[9]}]

set_property IOSTANDARD LVCMOS33 [get_ports {adc_data[*]}]
