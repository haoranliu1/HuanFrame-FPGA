# BGM Gray-pointer CDC only. The first synchronizer stage may be metastable;
# retain ordinary timing on stage 1 -> stage 2 and all synchronous datapaths.
# Bound every Gray bit's flight time to the faster clock period (10 ns).
# Separate PLL outputs are not assumed phase aligned for these FIFO crossings.
# TD resolves merged Gray MSBs to wbin[10]/rbin[10] automatically.
# Keep this file flat: TD's SDC reader does not evaluate Tcl foreach blocks.
set_max_delay -from [get_regs -nowarn {*/wgray[*]}] -to [get_regs -nowarn {*/wgray_r0[*]}] 10.000 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*/wgray[*]}] -to [get_regs -nowarn {*/wgray_r0[*]}]
set_max_delay -from [get_regs -nowarn {*/rgray[*]}] -to [get_regs -nowarn {*/rgray_w0[*]}] 10.000 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*/rgray[*]}] -to [get_regs -nowarn {*/rgray_w0[*]}]
# Single-bit flush handshake, first stage only (subsequent stages timed).
set_max_delay -from [get_regs -nowarn {*/ack_read}] -to [get_regs -nowarn {*/ack_write_sync[0]}] 10.000 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*/ack_read}] -to [get_regs -nowarn {*/ack_write_sync[0]}]
set_max_delay -from [get_regs -nowarn {*/flush_toggle}] -to [get_regs -nowarn {*/flush_read_sync[0]}] 10.000 -datapath_only
set_false_path -hold -from [get_regs -nowarn {*/flush_toggle}] -to [get_regs -nowarn {*/flush_read_sync[0]}]
