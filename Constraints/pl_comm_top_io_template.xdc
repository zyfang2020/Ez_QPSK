# ------------------------------------------------------------------------------
# IO Constraints Template for pl_comm_top
# ------------------------------------------------------------------------------
# IMPORTANT:
# - Replace all PACKAGE_PIN placeholders (e.g. <PIN_CLK_DAC>) with real board pins.
# - Choose proper IOSTANDARD per bank voltage (commonly LVCMOS33/LVCMOS18).
# - Keep this file as a template; copy to a board-specific file for real use.
#   Example: constraints/pl_comm_top_io_ax7020.xdc
# ------------------------------------------------------------------------------

## -----------------------------------------------------------------------------
## Clocks / Reset
## -----------------------------------------------------------------------------
# set_property PACKAGE_PIN <PIN_CLK_DAC> [get_ports clk_dac]
# set_property IOSTANDARD LVCMOS33 [get_ports clk_dac]

# set_property PACKAGE_PIN <PIN_CLK_ADC> [get_ports clk_adc]
# set_property IOSTANDARD LVCMOS33 [get_ports clk_adc]

# set_property PACKAGE_PIN <PIN_CLK_AXI> [get_ports clk_axi]
# set_property IOSTANDARD LVCMOS33 [get_ports clk_axi]

# set_property PACKAGE_PIN <PIN_RST_N> [get_ports rst_n]
# set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
# set_property PULLUP true [get_ports rst_n]

## -----------------------------------------------------------------------------
## Mode / Control (can map to DIP keys, PMOD, or AXI GPIO in later stage)
## -----------------------------------------------------------------------------
# set_property PACKAGE_PIN <PIN_OP_MODE_TX> [get_ports op_mode_tx]
# set_property IOSTANDARD LVCMOS33 [get_ports op_mode_tx]

# set_property PACKAGE_PIN <PIN_TX_EN> [get_ports tx_en]
# set_property IOSTANDARD LVCMOS33 [get_ports tx_en]

# set_property PACKAGE_PIN <PIN_TX_SRC_SEL> [get_ports tx_src_sel]
# set_property IOSTANDARD LVCMOS33 [get_ports tx_src_sel]

# set_property PACKAGE_PIN <PIN_QPSK_EN> [get_ports qpsk_en]
# set_property IOSTANDARD LVCMOS33 [get_ports qpsk_en]

# set_property PACKAGE_PIN <PIN_QPSK_SRC_SEL> [get_ports qpsk_src_sel]
# set_property IOSTANDARD LVCMOS33 [get_ports qpsk_src_sel]

# Example for vector controls:
# set_property PACKAGE_PIN <PIN_TX_MODE_SEL_0> [get_ports {tx_mode_sel[0]}]
# set_property PACKAGE_PIN <PIN_TX_MODE_SEL_1> [get_ports {tx_mode_sel[1]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {tx_mode_sel[*]}]
#
# set_property PACKAGE_PIN <PIN_QPSK_MODE_SEL_0> [get_ports {qpsk_mode_sel[0]}]
# set_property PACKAGE_PIN <PIN_QPSK_MODE_SEL_1> [get_ports {qpsk_mode_sel[1]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {qpsk_mode_sel[*]}]

## -----------------------------------------------------------------------------
## ADC / DAC Parallel Data
## -----------------------------------------------------------------------------
# NOTE:
# - Fill each bit according to the board schematic and FMC/expansion mapping.
# - Keep ADC and DAC banks at correct I/O voltage and direction.
#
# Example:
# set_property PACKAGE_PIN <PIN_ADC_D0> [get_ports {adc_data[0]}]
# ...
# set_property PACKAGE_PIN <PIN_ADC_D9> [get_ports {adc_data[9]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {adc_data[*]}]
#
# set_property PACKAGE_PIN <PIN_DAC_D0> [get_ports {dac_data[0]}]
# ...
# set_property PACKAGE_PIN <PIN_DAC_D11> [get_ports {dac_data[11]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {dac_data[*]}]

## -----------------------------------------------------------------------------
## Optional external QPSK symbol source ports
## -----------------------------------------------------------------------------
# If not used on board currently, tie these in HDL wrapper instead of pin-mapping:
# - qpsk_sym_data[1:0]
# - qpsk_sym_valid
# - qpsk_sym_ready (output)
#
# Example:
# set_property PACKAGE_PIN <PIN_QPSK_SYM_DATA_0> [get_ports {qpsk_sym_data[0]}]
# set_property PACKAGE_PIN <PIN_QPSK_SYM_DATA_1> [get_ports {qpsk_sym_data[1]}]
# set_property PACKAGE_PIN <PIN_QPSK_SYM_VALID>  [get_ports qpsk_sym_valid]
# set_property PACKAGE_PIN <PIN_QPSK_SYM_READY>  [get_ports qpsk_sym_ready]
# set_property IOSTANDARD LVCMOS33 [get_ports {qpsk_sym_data[*] qpsk_sym_valid qpsk_sym_ready}]

## -----------------------------------------------------------------------------
## AXIS RX ports (usually connected internally in BD, not external FPGA pins)
## -----------------------------------------------------------------------------
# m_axis_rx_tdata / tkeep / tvalid / tready / tlast are commonly routed to AXI DMA
# inside Vivado Block Design, so they usually do NOT need PACKAGE_PIN constraints.

