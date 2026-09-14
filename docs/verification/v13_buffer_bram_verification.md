# V13 buffer manager / BRAM 验证记录

验证日期：2026-09-06。工程：E:/vivado_fpga_projects/npu_mydesign。

## 1. 实现范围与保留边界

新增生产 RTL：npu_v13_buffer_manager.sv、npu_v13_bram_bank.sv。
管理器默认 A/B 各 2 bank、C 独立 1 bank、单执行租约；显式 acquire/release 和 C take/return。
BRAM 提供独立同步读/写、固定 1/2 拍读延迟、tag/错误对齐，不含输出反压。
最后补齐 READY 输入 discard，用于命令取得租约前被拒绝的回收。

原有 11 个 RTL 与任务前 ZIP 中对应文件逐一 SHA256 比对：11 个一致，0 个修改。
已有计算阵列、FIFO、scheduler、dispatcher 和 executor 的功能/时序实现未在本轮更改。

## 2. 备份及最终 RTL 身份

| 文件 | SHA256 |
|---|---|
| backups/v13_pre_buffer_bram_20260906.zip | B63A005BC07221C728FCF475D0C3D4C0493F8F83BF2C4CC7A8A54FC6D0933DF1 |
| backups/v13_buffer_bram_verified_draft_20260906.zip | 5F284288024E7490F3225F8A99F92633A1C282989F62CAAACDBA37799FCFCD85 |
| rtl/npu/v13/memory/npu_v13_buffer_manager.sv | 39B9262274B5B4F5752EE16774E191EBCC0BBC4B3F3432D6ED265F262040C439 |
| rtl/npu/v13/memory/npu_v13_bram_bank.sv | B741DA7D957A93A14007E1441BA50F39BF910C31961F33C914E48C1E45EB46F0 |
| rtl/npu/v13/control/npu_v13_job_executor.sv（原样保留） | 502B7ECF9430746A7D9C128230306AA7FEE5E12D4549BAAED66868D9BC458D1B |

第一个 ZIP 是实施前的 RTL/TB/脚本/文档/约束/工程快照。第二个是两个新模块首轮单测及联合仿真已通过的草案，不含最后的 READY discard 增补，也不是最终交付版本。

## 3. Icarus 回归：14/14 PASS

入口：scripts/run_rtl_tests.ps1。
完整本轮日志：reports/v13_buffer_bram_rtl_regression.log。
最终标记：NPU_MYDESIGN_RUNTIME_RTL_TESTS_PASS checks=14。

旧 11 项全部保持通过，新增以下 3 项：

### 3.1 同步 BRAM 单测

文件：tb/unit/npu/v13/tb_npu_v13_bram_bank.sv。

| 配置 | 检查周期 | 读请求 | 写请求 | 错误读响应 | 最长连续读请求 |
|---|---:|---:|---:|---:|---:|
| L1 / DEPTH=13 | 1090 | 961 | 644 | 208 | 82 |
| L2 / DEPTH=13 | 1090 | 960 | 656 | 189 | 81 |
| L2 / DEPTH=32 | 1202 | 1027 | 848 | 17 | 184 |
| L2 / DEPTH=1 | 1018 | 883 | 353 | 577 | 35 |

错误读是有意注入的越界/同地址读写，不是测试失败。覆盖固定时延、连续端口使用、并发独立地址读写、气泡/tag/error 对齐、复位取消在途读、保留 RAM 内容。
使用端口装载，参考数组只做计分，没有层次化直接写 DUT 存储体。

最终标记：NPU_V13_BRAM_BANK_TB_PASS configurations=4。

### 3.2 bank 所有权管理单测

文件：tb/unit/npu/v13/tb_npu_v13_buffer_manager.sv。

| 配置 | 检查周期 | 成功 acquire | release | C take | C return | 执行租约中成功 load_begin |
|---|---:|---:|---:|---:|---:|---:|
| AB2 / C1 / BANK_W1 | 5036 | 32 | 31 | 16 | 15 | 17 |
| AB3 / C2 / BANK_W2 | 5036 | 24 | 22 | 9 | 8 | 10 |

随机 reset 会主动取消租约，所以 acquire/release 等计数不要求相等。逐周期比较所有握手和每个公开 bank 状态；覆盖非法编号、装载失败、执行失败、错误 owner release、C 生命周期、原子等待、输入 ping-pong、READY discard 优先级与 IN_USE 不可丢弃。

最终标记：NPU_V13_BUFFER_MANAGER_TB_PASS configurations=2。

### 3.3 真实 runtime + 管理器 + 同步 RAM 联合仿真

文件：tb/unit/npu/v13/tb_npu_v13_buffer_bram_runtime_joint.sv。

真实 RTL 链：dispatcher/FIFO/mode controller -> job executor -> scheduler；executor acquire/release 直接连接 buffer_manager；A0/A1/B0/B1 使用 8-bit x 4096 同步 bram_bank，单 C 使用 32-bit x 4096，读延迟均为 2；真实 runtime cluster 及计算层级参与乘加。

装载器、几何/地址展开、feeder、collector、C 消费者仍是 TB 行为模型。逐字读输入、拼 source vector、快照 tile 输出后逐字写 C，是为了验证完整数据路径的时序和结果，不是生产高带宽实现。

最终结果：

~~~text
NPU_V13_BUFFER_BRAM_RUNTIME_JOINT_TB_PASS commands=14 gemms=10 physical_tiles=341 elements=4410 mode_changes=6
REAL_BRAM_COUNTS input_writes=1460 input_reads=4326 c_writes=4410 c_reads=4410 overlap_writes=84 c_drains=10
~~~

10 个 GEMM 覆盖全部 9 种 mode/layout 和额外 M37/N35/K5，非整块边界、K1~5、非零 A/B/C 基地址、输入气泡与配置切换。4410 个有效 C 元素从同步 C RAM 读回后与整数矩阵乘参考结果核对；检查重复/缺失结果和 shape。

14 条命令还包含零维度、CONV 未支持、非法 C bank、后端拒绝四种错误。非法 C bank 导致 acquire 前拒绝后，显式 discard 回收预加载 A/B；末尾要求 A/B/C 全 FREE、无租约。

实际输入写/读按状态门控；断言禁止无权 RAM 访问、带在途读/写的 release，以及响应未排空的 C return。84 次装载写确实与上一条命令执行租约重叠；这不是满阵列利用率数据。

## 4. Vivado 工程 XSim：3/3 PASS

入口：scripts/run_v13_buffer_bram_project_xsim.ps1。
日志：reports/v13_buffer_bram_xsim/bram_bank.log、buffer_manager.log、buffer_bram_runtime_joint.log、vivado.log。
上述两个单测与真实联合 TB 均在已有工程 sim_1 编译运行，最终检查 PASS 标记，不仅检查进程退出码。

~~~text
NPU_MYDESIGN_BUFFER_BRAM_PROJECT_XSIM_PASS checks=3
NPU_MYDESIGN_BUFFER_BRAM_PROJECT_XSIM_LOG_PASS checks=3
~~~

工程增量注册 13 个 RTL、16 个仿真/夹具文件。运行后默认顶层仍为：
- synthesis：npu_v13_systolic_cluster_runtime_stream
- simulation：tb_npu_v13_systolic_cluster_runtime_stream

## 5. 300 MHz 注册边界布局布线

器件 xc7a200tfbg484-2；时钟 3.333 ns；Vivado 2025.2.1。
实际入口为 scripts/synth_v13_memory_registered_300m.tcl，PowerShell 包装器是 scripts/synth_v13_buffer_bram_300m.ps1。

夹具 tb/unit/npu/v13/npu_v13_memory_timing_top.sv 为非 clk/reset 输入加真实发射寄存器，为输出加真实捕获寄存器。
launch FF -> DUT -> capture FF 全部真实布线、单周期计时；只排除 reset 与夹具外侧没有物理位置的输入/输出路径，没有新增多周期例外。

| 最终配置 | 物理 Slice LUT | DUT FF | 夹具边界 FF | 总 FF | RAMB36 | DSP | WNS ns | WHS ns |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| manager：AB2/C1，含 discard | 96 | 31 | 70 | 101 | 0 | 0 | +0.005 | +0.164 |
| BRAM：32x1024，L1 | 8 | 10 | 106 | 116 | 1 | 0 | +0.101 | +0.070 |
| BRAM：32x1024，L2（默认） | 9 | 20 | 106 | 126 | 1 | 0 | +0.107 | +0.059 |

三项 route_error_nets=0、latch=0。物理 Slice LUT 使用 utilization.rpt 的计数；LUT 原语可在 slice 内组合，不能把 summary 中 dut_lut_primitives 当成最终物理 LUT 数。边界只有 FF，无额外 LUT 数据处理。DUT FF 列不含夹具 FF。

manager 的 +0.005 ns 仅表示本次实现满足 300 MHz 门禁，裕量很紧，不能宣传为充裕。最差路径来自 owner_tag_r[7]，经过 release 身份校验/状态更新到 a_state_r[1][1]；数据路径 3.285 ns，其中布线 2.382 ns。全系统重布线后必须重新检查，不能外推为整个 NPU 时序已过。

BRAM L2 routed summary 确认 RAMB36 DOA_REG=0、DOB_REG=1；数据的第二级 32 bit 寄存器留在 BRAM 内。L1 为 DOA_REG=0、DOB_REG=0。这里资源是单个 32x1024 bank，不是联合 TB 中所有 A/B/C 存储的总数，也不能推广为任意 DATA_W/DEPTH 配置均占一个 RAMB36。

最终报告目录：
- reports/v13_manager_registered_300m/
- reports/v13_bram_l1_registered_300m/
- reports/v13_bram_l2_registered_300m/

每个目录保留 summary.txt、utilization.rpt、utilization_hier.rpt、timing_summary.rpt、timing_setup.rpt、timing_hold.rpt、route_status.rpt、exceptions.rpt 和综合/布线 checkpoint。

### 5.1 早期未通过的实验（保留，不隐瞒）

最初的裸 OOC 顶层没有真实发射/捕获寄存器和 HD.PARTPIN_LOCS。工具出现 Route 35-198 外部端口部分路径缺失警告；这种结果不适合作为真实接口物理时序的通过依据。

- 裸 BRAM L2：WNS=-0.126 ns、WHS=-0.709 ns。
- 裸 BRAM L1：WNS=-1.702 ns、WHS=-0.706 ns。
- 裸 manager 在 post-route phys_opt 发生 Vivado EXCEPTION_ACCESS_VIOLATION；日志 reports/v13_manager_impl.log、hs_err_pid39608.log，没有将崩溃当作通过。

随后改用注册边界夹具，正向检查真实寄存器间路径，而不是放宽内部时序或把负数改写为正数。scripts/synth_v13_buffer_bram_300m.tcl 留作最初裸 OOC 诊断脚本；默认 PowerShell 入口不再调用它。

归因说明：最初 BRAM RTL 在 synthesis 阶段已经把 L2 输出寄存器吸收到 BRAM（20 FF）；裸 OOC 物理优化曾把这 32 bit 再提出为 FF（52 FF）。因此，后来拆成独立读/写 always 主要是可读性与模板清晰化，不能把最终少 32 FF 归功于这个改写。最终注册边界实现保留内部输出寄存器，才是有网表证据的结果。

manager 增加 discard 前曾通过 75 LUT / 31 DUT FF / WNS+0.134 ns；该数字属于草案，不作为含 discard 的最终资源/时序值。

## 6. 复现与下一步

~~~powershell
.\scripts\run_rtl_tests.ps1
.\scripts\run_v13_buffer_bram_project_xsim.ps1
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration manager
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration bram_l1
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration bram_l2
~~~

目前证明了两个模块的功能、每 BRAM 端口 II=1、真实 runtime 与存储所有权/结果路径联动，以及指定配置的 300 MHz 注册边界实现。
还没有证明：可综合完整 GEMM/CONV engine、持续 256 MAC/cycle 的存储供数、完整结果收集硬件、DDR/AXI 链路、所有参数配置的物理时序。

后续需要独立几何展开/地址生成、banked 宽数据封装和高带宽 feeder/collector。默认单 C 可以先验证正确性；要与 C 排空重叠执行下一任务，应根据实际吞吐需求再配置 C bank 数量。
中文讲解见 docs/NPU_V13_BUFFER_BRAM.md。

