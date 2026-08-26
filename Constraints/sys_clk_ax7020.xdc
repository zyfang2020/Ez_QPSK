# ------------------------------------------------------------------------------
# Current system clock architecture
# ------------------------------------------------------------------------------
# The active design does not use an external PL clk_50M input or a PL userrst
# port. processing_system7_0/FCLK_CLK0 supplies the 100 MHz clk_axi/clk_io clock,
# and proc_sys_reset derives the associated PL reset.
#
# The PS7 IP contributes the FCLK timing constraints through its generated XDC,
# so this board-level file intentionally contains no clock or reset pin command.
# Keep the file in the project because the constraint-selection scripts reference
# it; add external-clock constraints here only if the BD is explicitly changed to
# use the AX7020 50 MHz oscillator and a Clocking Wizard/MMCM.
