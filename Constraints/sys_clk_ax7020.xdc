# ------------------------------------------------------------------------------
# AX7020 onboard PL clock input
# Assumption:
# - The real synthesis top exposes an input port named `clk_50M`
# - This port is connected to the AX7020 onboard 50 MHz PL oscillator on U18
# - 100 MHz is generated inside the design by a PLL/MMCM/Clocking Wizard
# ------------------------------------------------------------------------------

set_property PACKAGE_PIN U18 [get_ports clk_50M]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50M]

# The Clocking Wizard IP already provides the input clock timing constraint for
# this board clock through its scoped XDC. Keep the board-level XDC focused on
# pin assignment here so implementation does not see a duplicate create_clock
# and so the file stays valid pure XDC syntax.
#
# If you later remove clk_wiz from the design, add a project-level create_clock
# for clk_50M in the active top-level constraints instead of using Tcl control
# flow inside this XDC file.

# ------------------------------------------------------------------------------
# AX7020 PL user button
# Assumption:
# - The top exposes an input port named `userrst`
# - `userrst` is connected to AX7020 PL user button KEY1 on N15
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN N15 [get_ports userrst]
set_property IOSTANDARD LVCMOS33 [get_ports userrst]

# userrst is a manual asynchronous push-button input. Do not ask STA to model
# it like a synchronous data input relative to the PL clocks.
set_false_path -from [get_ports userrst]
