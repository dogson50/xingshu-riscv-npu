# Production-top clock constraint for npu_v13_gemm_feature_transport.
# Board-level pin placement, I/O delay, DDR/CDC constraints belong to the SoC wrapper.
create_clock -name compute_clk -period 5.000 [get_ports clk]
