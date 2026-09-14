# Production-top stress clock constraint for npu_v13_gemm_feature_transport.
# 300 MHz is an optimization target; the frozen A04 P89 baseline did not close it.
create_clock -name compute_clk -period 3.333 [get_ports clk]
