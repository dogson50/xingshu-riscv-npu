# V13 活动 RTL 端口注释核验（2026-09-07）

## 范围与结果

当前 `rtl/npu/v13` 下 13 个生产 RTL 模块，共 306 个输入/输出端口，已全部具有逐端口中文注释，并按一行一个端口排版。保留原有分组说明；未修改 `unuse` 归档或 testbench/时序测试顶层的源码。

只改注释和空白，不改端口名称、方向、类型、顺序、位宽、参数、逻辑或流水周期。13 个文件均已由现有 Vivado 工程引用；本次没有新增模块，因此未修改项目源文件清单或 .xpr。

## 覆盖清单

| RTL 文件 | 端口数 | 中文注释覆盖 |
| --- | ---: | ---: |
| [npu_v13_dsp48e1_macc.v](../rtl/npu/v13/compute/npu_v13_dsp48e1_macc.v) | 9 | 9/9 |
| [npu_v13_systolic_cluster_16x4x4_stream.v](../rtl/npu/v13/compute/npu_v13_systolic_cluster_16x4x4_stream.v) | 13 | 13/13 |
| [npu_v13_systolic_cluster_runtime_stream.v](../rtl/npu/v13/compute/npu_v13_systolic_cluster_runtime_stream.v) | 19 | 19/19 |
| [npu_v13_systolic_pe_stream.v](../rtl/npu/v13/compute/npu_v13_systolic_pe_stream.v) | 13 | 13/13 |
| [npu_v13_systolic_result_delay.v](../rtl/npu/v13/compute/npu_v13_systolic_result_delay.v) | 3 | 3/3 |
| [npu_v13_systolic_tile_4x4_stream.v](../rtl/npu/v13/compute/npu_v13_systolic_tile_4x4_stream.v) | 12 | 12/12 |
| [npu_v13_cluster_mode_ctrl.v](../rtl/npu/v13/control/npu_v13_cluster_mode_ctrl.v) | 15 | 15/15 |
| [npu_v13_command_fifo.sv](../rtl/npu/v13/control/npu_v13_command_fifo.sv) | 11 | 11/11 |
| [npu_v13_command_queue_dispatcher.sv](../rtl/npu/v13/control/npu_v13_command_queue_dispatcher.sv) | 52 | 52/52 |
| [npu_v13_job_executor.sv](../rtl/npu/v13/control/npu_v13_job_executor.sv) | 67 | 67/67 |
| [npu_v13_bram_bank.sv](../rtl/npu/v13/memory/npu_v13_bram_bank.sv) | 15 | 15/15 |
| [npu_v13_buffer_manager.sv](../rtl/npu/v13/memory/npu_v13_buffer_manager.sv) | 51 | 51/51 |
| [npu_v13_gemm_tile_scheduler.sv](../rtl/npu/v13/scheduler/npu_v13_gemm_tile_scheduler.sv) | 26 | 26/26 |
| 合计 | 306 | 306/306 |

## 注释内容

- 时钟、复位极性及同步/异步行为；明确只清有效状态还是清数据，避免误以为复位擦除 BRAM。
- ready/valid 握手、反压时稳定要求、错误位的有效窗口；区分“请求受理”和“操作成功”。
- 实际 M/N/K 与 count-1 shape 编码；runtime 的紧凑 shape 字段随模式改变，不是固定每 source lane 一份。
- source lane、逻辑 group、物理 tile 的区别；矩阵打包顺序和有效 shape 外的不关心值。
- FIFO 预取有效与真正 pop 的区别；队列总占用包含预取级。
- 命令接收、资源取得、后端启动、描述符结束、结果排空、租约释放及命令退休的不同意义。
- A/B/C bank 所有权、装载/丢弃/读取/归还的前置条件，以及 BRAM 字地址、读延迟、tag 和冲突错误行为。

## 修改前备份与源码核验

备份：[v13_pre_port_comments_20260907.zip](../backups/v13_pre_port_comments_20260907.zip)

SHA256：`3530DDEFA420C162BC18C6006A8BCF6D22A359BB36221E1E5E5E9173EDE95157`

已逐文件核对备份中的 13 份 RTL，其 SHA256 与修改前读取的源码内容一致。随后对全部修改文件完成以下检查：

1. 去除普通注释和空白后，Verilog/SystemVerilog token 序列完全一致；字符串内容保留比较。
2. 综合相关注释指令单独比较，内容完全一致；RTL 属性也保留在 token 比较中。
3. 端口名称及顺序完全一致；声明区以外的文本完全未改。
4. 306 个端口均各占一行且附带中文注释，无 NUL 字符。

本次编辑会改变源文件字节哈希；历史综合/时序报告中的旧哈希是当时的真实记录，不回写成新哈希。

## 本次重新运行的仿真

运行命令：`.\scripts\run_rtl_tests.ps1`（Icarus Verilog / vvp）。进程退出码 0，14/14 项 PASS。

完整日志：[v13_port_comments_rtl_regression_20260907.log](v13_port_comments_rtl_regression_20260907.log)

```text
PASS v13_tile_stream
PASS v13_cluster_16x4x4_stream
PASS v13_cluster_runtime_stream
PASS v13_cluster_mode_ctrl
PASS v13_cluster_mode_ctrl_runtime_joint
PASS v13_gemm_tile_scheduler
PASS v13_command_fifo
PASS v13_command_queue_dispatcher
PASS v13_command_dispatcher_runtime_joint
PASS v13_job_executor
PASS v13_job_executor_runtime_joint
PASS v13_bram_bank
PASS v13_buffer_manager
PASS v13_buffer_bram_runtime_joint
NPU_MYDESIGN_RUNTIME_RTL_TESTS_PASS checks=14
```

最后一项真实 BRAM 联合仿真包含 14 条命令、10 次 GEMM、341 个物理 tile、4410 个结果元素和 6 次模式切换；输入写/读分别为 1460/4326，C 写/读均为 4410，装载与计算租约重叠写入 84 次，C 消费完成 10 次。

本次未重新运行 Vivado XSim、综合或布局布线；注释核验与 RTL 回归不冒充新的时序或资源验证结果。

