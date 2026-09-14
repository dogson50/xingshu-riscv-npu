# 命令上下文只在 IDLE 的 exec_cmd 握手沿更新。scheduler 只在 LAUNCH 沿装载：
# E0 接管，E1 CHECK，E2 最早 ACQUIRE，E3 最早 PREPARE，E4 最早 LAUNCH。
# 中间状态不能旁路。上下文整个命令保持，新的上下文更新时 scheduler 已无描述符。
# 因此这段“命令装载”数据确实至少有 4 个周期；这里只使用保守的 2 个周期。
# 配对 setup=2 / hold=1，保持原来的同沿 hold 检查。
# 不放宽 CHECK、RUN 控制、外部 FIFO 到 ctx、以及 scheduler 内每拍枚举路径。
# 此文件在综合后读取，工程中用 SCOPED_TO_REF 限定到 job_executor 实例。
# XDC 不接受 if；文件内仅使用受支持的 set/查询/约束命令。
# 若以后允许 IDLE->LAUNCH 旁路或每拍改 ctx，必须删除/重审约束。
set executor_context_regs [get_cells -quiet -hierarchical -filter \
    {IS_SEQUENTIAL == 1 && NAME =~ *ctx_*_o_reg*}]
set executor_scheduler_regs [get_cells -quiet -hierarchical -filter \
    {IS_SEQUENTIAL == 1 && NAME =~ *u_scheduler/*}]
set_multicycle_path 2 -setup -from $executor_context_regs -to $executor_scheduler_regs
set_multicycle_path 1 -hold -from $executor_context_regs -to $executor_scheduler_regs
