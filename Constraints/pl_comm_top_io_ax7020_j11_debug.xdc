# ------------------------------------------------------------------------------
# AX7020 J11 debug pin constraints for PL-side QPSK RX demod bring-up
# ------------------------------------------------------------------------------
# Tentative debug mapping from AGENTS.md:
#   rx_demod_bit  -> J11 PIN3 -> FPGA F17
#   rx_demod_lock -> J11 PIN4 -> FPGA F16
#
# Use these pins for oscilloscope or logic-analyzer checks while bringing up an
# external fixed-carrier QPSK source. The demod bit is meaningful after
# rx_demod_lock is asserted.
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN F17 [get_ports rx_demod_bit]
set_property PACKAGE_PIN F16 [get_ports rx_demod_lock]

set_property IOSTANDARD LVCMOS33 [get_ports {rx_demod_bit rx_demod_lock}]
set_property DRIVE 8 [get_ports {rx_demod_bit rx_demod_lock}]
set_property SLEW SLOW [get_ports {rx_demod_bit rx_demod_lock}]
