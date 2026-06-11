#!/usr/bin/env tclsh
# Deprecated compatibility guard.
#
# The two-board hardware roles were corrected after this script was introduced:
#   - original AX7020-style interface: TX
#   - new high-speed interface: RX
#
# Do not build a TX image for the new interface by using this old script name.

puts "ERROR: scripts/run_second_board_tx_bitstream.tcl is deprecated."
puts "ERROR: The new high-speed interface is the RX side, not the TX side."
puts "ERROR: Use scripts/run_original_interface_tx_bitstream.tcl for TX."
puts "ERROR: Use scripts/run_new_interface_rx_bitstream.tcl for RX."
exit 1
