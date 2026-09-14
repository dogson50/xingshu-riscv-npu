# job_executor 最终验收记录

日期：2026-09-06（Asia/Shanghai）。项目：E:/vivado_fpga_projects/npu_mydesign。

## 交付范围

新增 npu_v13_job_executor，直接承接现有 dispatcher 的完整 exec_cmd 接口，
锁存上下文，检查通用参数，原子申请 bank，等待后端准备，启动真实 scheduler，
等安全完成，释放 bank 后再回 exec_done。保持各部分职责独立，不复制旧 scheduler。

- 详细中文接口/代码块说明：docs/NPU_V13_JOB_EXECUTOR.md。
- 新 RTL：rtl/npu/v13/control/npu_v13_job_executor.sv。
- 接线示例：tb/unit/npu/v13/npu_v13_command_executor_timing_top.sv（可综合测试连接层，不是生产 engine）。
- 保留动态 M/N/K、三种阵列 mode、九种 mode/layout 组合以及运行气泡。
- 一条在执行命令；队列可排队，但不承诺跨命令零气泡。
- CONV 只定义控制类别和后端协商契约；未实现卷积窗口或 CONV 算术数据通路。

## 最终功能回归

| 门禁 | 结果 | 覆盖/统计 |
|---|---|---|
| 全量 Icarus 回归 | PASS，进程退出 0 | 11 项，包括旧模块回归及新单元/联合测试 |
| Icarus executor 单元 | PASS | 63 cases，1829 batches，68 accepted，63 returned，5 reset-aborted |
| Vivado XSim executor 单元 | PASS，进程退出 0 | 63 cases，1539 batches，68 accepted，63 returned，5 reset-aborted |
| Icarus 和 XSim runtime 联合 | 均 PASS | 14 commands，10 GEMMs，341 physical tiles，4410 C elements，6 mode changes |

XSim 和 Icarus 的 PRNG 序列不同，随机描述符数量不同；共享相同检查逻辑和测试范围。
单元测试覆盖随机反压、稳定上下文、零等待最短启动 E0->E4、描述符 II=1、K=1/65535、
参数拒绝、bank/后端拒绝、执行错误、错 tag、延迟写回，以及五种 reset 中止位置。
联合测试包含真实 dispatcher、executor、scheduler、runtime cluster 和下层计算 RTL，
逐元素对照整数矩阵乘法参考值，并检查 tile shape、重复/遗漏/越界写回及提前释放。

日志：

- reports/v13_job_executor_rtl_regression.log（最终 22:06:28）。
- reports/v13_job_executor_xsim/job_executor.log（最终 22:05:27）。
- reports/v13_job_executor_xsim/job_executor_runtime_joint.log（最终 22:05:37）。
- reports/v13_job_executor_xsim/vivado.log（工程脚本 22:05:38 正常结束，checks=2）。

## 最终 300 MHz 布局布线

Vivado 2025.2.1；xc7a200tfbg484-2；时钟周期 3.333 ns。
默认 DIM_W=16、ADDR_W=32、BANK_W=1、OP_CFG_W=32、TAG_W=8。

| 实际网表 | Slice LUT | FF | RAMB36 | DSP | latch | WNS ns | WHS ns | routing error |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| executor + scheduler | 259 | 368 | 0 | 0 | 0 | +0.167 | +0.116 | 0 |
| dispatcher/FIFO + executor + scheduler | 369 | 457 | 3 | 0 | 0 | +0.125 | +0.066 | 0 |

两组最终标准目录的运行均正常退出 0，与先前 onehot 隔离实验数值一致：

- reports/v13_job_executor_300m/summary.txt；22:08:14 结束。
- reports/v13_command_executor_300m/summary.txt；22:08:59 结束。

集成版 FIFO 深度 512，命令宽 194；检查三个 RAMB36 全部 DOA_REG=1。
两个目录均包含 synth/routed DCP、资源、setup/hold、route status 和 exceptions 报告。

### 时序结论的适用边界

1. OOC 排除外部端口输入/输出路径；未假设未来 manager、feeder 的物理位置和接口延迟。
2. executor ctx 寄存器到其内部 scheduler 的命令装载路径使用 setup=2、hold=1。
   FSM 在 E0 锁存上下文，最快 E4 才装载 scheduler，因此至少有四拍稳定窗口。
   两拍例外是在利用协议保证，不是该路径的单周期 300 MHz 结论。
3. ctx 捕获、CHECK、状态译码、done 反馈和 scheduler 内部枚举保持 3.333 ns 单周期检查。
   最终集成最差路径是 ctx_tag 到 executor error 状态，要求仍是 3.333 ns。
4. 约束在工程里 SCOPED_TO_REF=npu_v13_job_executor，仅用于实现；脚本检查非空对象匹配，
   并检查真实 exceptions 报告中 setup cycles=2 / hold cycles=1，防止未加载约束的假通过。
5. 计算集群在功能联合仿真中是真实 RTL，但不在本次控制链路 OOC 布局布线网表中。
6. 最终完整 engine 必须使用真实存储/数据模块重做联合仿真与全层次布局布线。

### one-hot 取舍与失败记录

二进制编码集成版：357 LUT，446 FF，WNS=-0.003 ns，WHS=+0.079 ns。
one-hot：多 12 LUT、11 FF，解除状态译码到 scheduler 装载使能的临界路径，
不增加 DSP/BRAM、不改变状态周期、不放宽这条控制路径，因此保留。
二进制编码一次 post-route phys_opt 发生 EXCEPTION_ACCESS_VIOLATION，未计为成功。
隔离的旧单周期输入解码诊断报告和中间失败报告保留，不应拿来代表最终版本。

## 工程注册和原有设计保护

- 已在 vivado_project/npu_mydesign.xpr 注册新 RTL、两份新 TB、测试连接层和上下文 XDC。
- sources_1 共 11 个 RTL 文件，sim_1 共 12 个文件。
- 默认综合 top 仍是 npu_v13_systolic_cluster_runtime_stream。
- 默认仿真 top 仍是 tb_npu_v13_systolic_cluster_runtime_stream。
- project XSim 已恢复默认仿真 top；未关闭用户原有 Vivado GUI。
- 与实现前 ZIP 的 SHA256 逐文件比较：六个 compute RTL、scheduler、FIFO、mode_ctrl 完全一致。
- dispatcher 去除行注释及空白后与备份一致；仅解释 exec_cmd_ready 的上下文容量语义。
- 本次没有删除、移动用户旧模块，也没有改 compute 接口和算术实现。

实现前备份：backups/v13_pre_job_executor_20260906_implementation.zip

SHA256：EFDD9DD3E7BC585D2EA83F05DD9AA8092C3C156D53B2ECFC5618C444B0D90296

二进制时序历史：backups/v13_job_executor_binary_timing_20260906.zip

SHA256：AC8C32289F93BF1BF0B1234C072547DC9B5C7AEDAF88DE8A920C9F30DD059711

## 尚未实现的后端，不作超范围承诺

联合 TB 中的双 bank A/B/C 数组、读数 feeder、collector 和完成跟踪是行为模型。
本次没有交付生产 BRAM manager、GEMM 地址流水、CONV 窗口、DMA、跨 K 分块部分和、
量化后处理或网络图调度器。描述符 II=1 不等于整机 MAC 永远满载；联合 feeder 故意
串行处理部分 batch 并加入气泡、写提交等待。下一步应逐个将行为模型换成独立 RTL。

## 复现命令

从项目根目录运行：

~~~powershell
.\scripts\run_rtl_tests.ps1
.\scripts\run_v13_job_executor_project_xsim.ps1
.\scripts\synth_v13_job_executor_300m.ps1
.\scripts\synth_v13_job_executor_300m.ps1 -Integrated
~~~

时序 wrapper 已隔离两组日志，可用 -ReportVariant 标识实验报告目录。

## 最终源文件 SHA256

~~~text
502B7ECF9430746A7D9C128230306AA7FEE5E12D4549BAAED66868D9BC458D1B  rtl/npu/v13/control/npu_v13_job_executor.sv
93A528008A16C2BD6A4317AB7804DF6BC5F214F8E0C8A3E4114E971694FC24AA  tb/unit/npu/v13/tb_npu_v13_job_executor.sv
352ED387428528439707461D1AC058BF723B7768569002B5853CDF147916C97A  tb/unit/npu/v13/tb_npu_v13_job_executor_runtime_joint.sv
D953DFC4699E4EE4499ED7007EB25A02E7B13C5093E2F59FF88AA09B7058ECF6  tb/unit/npu/v13/npu_v13_command_executor_timing_top.sv
27ACCCB392ACADDB1FA297DD433ADFEE6159DAABDF8FFDE18C70DBAA8EC4825B  constraints/npu_v13_job_executor_context.xdc
E3B08F726FF35CB1AAD3081450A6C14708AC55F2187D59FD9BF16AA8C52759D1  scripts/synth_v13_job_executor_300m.tcl
1070306DD7A63DD17C59E018985B28FAAEF9E1EDA9BBEC85A027991A88EEC8CE  scripts/synth_v13_job_executor_300m.ps1
~~~
