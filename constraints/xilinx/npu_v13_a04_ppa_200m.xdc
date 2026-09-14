# Apples-to-apples OOC PPA constraint for gemm_feature_transport_timing only.
create_clock -name compute_clk -period 5.000 [get_ports clk]
set_false_path -from [get_ports stimulus_i*]
set_false_path -to [get_ports observation_o*]
