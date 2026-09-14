# npu_v13_job_executor：命令执行控制器

## 1. 这次补上的是什么

源码：`rtl/npu/v13/control/npu_v13_job_executor.sv`。

它直接承接 `npu_v13_command_queue_dispatcher.exec_cmd_*`，并把一个命令的执行
生命周期收敛成一次 `exec_done_*`。它复用已有的独立 scheduler，不复制 scheduler，
也不把地址计算、BRAM 和卷积算法塞进同一状态机。

```text
command_queue_dispatcher
  ├─ cfg ---------------------------------------------> runtime cluster
  └─ exec_cmd / exec_done <-> job_executor
                               ├─ ctx + acquire/release <-> buffer manager（后续）
                               ├─ ctx + prepare/start  <-> 数据后端（后续）
                               ├─ gemm_tile_scheduler
                               │     └─ tile_batch -> expander/地址/feeder（后续）
                               │                          └─ A/B packet -> cluster
                               └─ job_complete <--- collector/完成跟踪（后续）
```

图中“后续”模块目前只有 TB 行为模型，不是本次新增的生产 RTL。cfg 仍由 dispatcher
中的 mode controller 独占管理；executor 不再发 cfg，也不自行改变命令指定的 mode。

## 2. 参数及命令字段

默认参数与 dispatcher 一致：`DIM_W=16, ADDR_W=32, BANK_W=1, OP_CFG_W=32, TAG_W=8`。
默认命令总宽度为 194 bit，全部在 exec_cmd 握手沿锁存到上下文。

| 字段 | 默认位宽 | 本模块如何处理 |
|---|---:|---|
| opcode | 2 | 00 GEMM、01 CONV；10/11 拒绝 |
| M/N/K | 各 16 | 动态、均须非零；CONV 时是等效 GEMM 维度 |
| cluster_mode | 2 | 00=1x16x16、01=4x8x8、10=16x4x4；11 拒绝 |
| layout | 3 | 允许范围随 mode 为 0、0..2、0..4 |
| A/B/C base | 各 32 | 原样保存，不做地址运算、不规定 byte/word 单位 |
| A/B/C bank | 各 1 | 原样保存，由独立 manager 解释占用/依赖 |
| op_cfg | 32 | 原样保存，由后端解释；可为紧凑配置或扩展描述符索引 |
| tag | 8 | 跟踪命令，必须随安全完成原样返回 |

本模块不静态推导 K 或 ACC_W。16-bit 维度接口并不意味着片上一定能驻留整个矩阵；
容量、stride、地址范围以及较大 K 的数据分段属于后续数据/存储系统。

## 3. 输入输出端口，按连接对象理解

以下接口全部处于 `clk` 时钟域，没有跨时钟同步器。

### 3.1 与 dispatcher 相连

- `exec_cmd_valid_i/exec_cmd_ready_o`：同时为 1 的上升沿接收整条命令。
- `exec_cmd_*_i`：上表的所有命令字段。
- `exec_done_valid_o/exec_done_ready_i`：完成结果的 ready/valid 接口。
- `exec_done_tag_o/exec_done_error_o`：当前命令标识和聚合错误，反压期间保持不变。

`exec_cmd_ready_o` 只表示一个上下文槽为空。它不是“bank 已准备好”，也不是
“cluster 这一拍可以接收 A/B”。命令接管后，FIFO 可以 pop/预取，executor 则持有整条
命令继续等待资源。dispatcher 在 RUNNING 阶段不会下发下一条命令或提前切 mode。

### 3.2 共享上下文 ctx

`ctx_valid_o` 为 1 时，所有 `ctx_*_o` 字段构成当前命令的稳定快照。从接管到
exec_done 被接收期间均不变，包括等待 bank、后端拒绝处理和 done 反压期间。

不能仅凭 `ctx_valid_o` 启动读写：CHECK 阶段也有上下文，但命令尚未合法化。
manager 用 acquire/release 事务，后端用 prepare/start 事务。

宽上下文寄存器不复位，节省 reset 网络；`ctx_valid_o=0` 时这些值无协议意义。

### 3.3 与 buffer manager 相连

| 端口 | 方向（相对 executor） | 语义 |
|---|---|---|
| buffer_acquire_valid_o | 输出 | 请求 ctx 指定的全部 A/B/C bank |
| buffer_acquire_ready_i | 输入 | manager 在本拍可以原子授予或明确拒绝该请求 |
| buffer_acquire_error_i | 输入 | 仅在握手时有效；1 表示拒绝，一个 bank 也未获得 |
| buffers_owned_o | 输出 | 成功申请后到 release 握手前保持 1 |
| buffer_release_valid_o | 输出 | 请求归还 A/B，发布或作废 C |
| buffer_release_ready_i | 输入 | 本拍可以完成原子释放/提交 |
| buffer_release_error_o | 输出 | 1 表示命令失败，C 不能发布为有效结果 |

资源只是暂时忙时，manager 应保持 acquire_ready=0，而不是当成错误。不能在一个
acquire 握手中只授予 A、却让 B/C 以后再到：当前接口是全有或全无，避免半占用悬挂。

A/B/C 是独立的逻辑存储空间，相同 bank 编号不自动构成地址冲突。若物理存储共用，
manager 必须另外检查别名。它还必须保证输入内容已就绪、C 容量可用，以及生产/消费
依赖满足。本模块不实现双缓冲状态表，也不会自动选择另一个空闲 bank。

release_ready 反压时不能假装已归还 bank；owned 保持 1，exec_done 也不会提前产生。
release 接口的 error 是输出，不是 manager 的失败返回。manager 必须先安全完成资源
归还才握手；存储提交错误应在 job_complete_error 阶段汇总。

### 3.4 与数据后端相连

- `backend_prepare_valid_o/ready_i/error_i`：检查 ctx 中的算子、地址、op_cfg 与能力。
- prepare 成功以前不允许读写 A/B/C；prepare 被拒绝不得留下需要等待排空的数据副作用。
- `job_start_o`：成功 prepare 后的一拍启动通知，与内部 scheduler 命令握手同拍。
  不是 MAC 使能，不是每个 tile 的启动，也不是每个 K beat 的 tuser。
- prepare 成功代表后端保证能接收随后这次 start，因此 start 不另设 ready。
- `job_cancel_o`：scheduler 意外拒绝命令时的防御性清理通知，不是通用异步 abort。
  后端仍必须返回带正确 tag 的安全完成。本地几何校验正常应挡住这一分支。

CONV 控制与 GEMM 共用生命周期，但只有后端真正实现窗口/stride/padding 等语义时，
才能接受 CONV。联合测试中的 GEMM 后端对 CONV 返回 prepare_error=1。

### 3.5 向 expander/feeder 输出描述符

`tile_batch_valid_o/ready_i` 直接连接内部 scheduler 的描述符接口，不再额外打一层宽寄存器。
字段有：M/N/K、M/N base、cluster mode、layout、命令首/尾 batch 标志、tag。
反压时 valid 和全部字段保持；ready 连续为 1 时，稳态每拍一个描述符（II=1）。

`tile_batch_cmd_first/last` 不是 cluster 的 `tuser/tlast`。
feeder 以后需要为每个 batch 的 K 拍重新产生 packet：第 0 拍 tuser，第 K-1 拍 tlast。
cluster 没有 tready，绝不能把 `tile_batch_ready` 直接当成计算核数据 ready。

`schedule_finished_o` 是每条命令内的粘滞状态，只说明 scheduler 发完描述符。
它在下一次命令接管或复位时清零；空闲间隙可能保留上一条的 1，应结合 ctx_valid 使用。

### 3.6 从完成跟踪模块接收安全完成

`job_complete_valid_i/ready_o/tag_i/error_i` 表示整条命令已到达安全点：

1. 所有描述符已处理（发生错误时也须消费并丢弃未执行的剩余描述符）。
2. 已启动的 K packet 完整结束，cluster/feeder 不再引用当前命令。
3. 所有有效结果已被正确收集，写回已提交，或者失败结果已安全丢弃。
4. 不再存在旧 tag/旧 bank 的在途写入。

一个物理 tile 的 `c_tile_valid`、最后一拍 A/B、scheduler 的 done 都不能单独充当安全完成。
producer 必须保持 valid/tag/error 到握手，不能只打一拍然后丢掉。

executor 在 RUN 且 schedule_finished 后才拉高 complete_ready。错误 tag 的完成会被
消费并记入 error，但不释放 bank；仍等待正确 tag。这样不会把另一条命令的完成误用
到当前任务上。协议严重失步而永远得不到正确 tag 时，不自动超时/复用 bank；需要外部
系统级恢复。没有安全排空依据的“强制 done”会导致跨命令数据污染。

### 3.7 reset / busy

`resetn` 低有效异步复位。必须与 dispatcher、manager、后端及完成跟踪一起复位，
不能只复位 executor 后立即复用原 bank。复位中止任务，不为被中止任务补发 done。
`busy_o` 表示本控制器持有命令，包括等待、释放和 done 反压阶段；不等同于 cluster busy。

## 4. 每个代码块负责什么

1. 参数与端口：明确命令、资源、描述符、完成四类边界，ctx 是它们共享的只读上下文。
2. localparam/state：八个生命周期状态；error、owned、schedule_finished 是三个独立状态位。
   `fsm_encoding="one_hot"` 要求综合器使用 one-hot 物理编码，减少 LAUNCH 状态译码；
   RTL 的状态编号和各状态驻留拍数不变，仿真流程也不变。
3. command_legal：只校验本层理解的 opcode、非零维度和 mode/layout 配对。
4. assign 输出译码：由状态决定当前哪一种事务 valid；全部对外控制在 reset 下无效。
5. 无 reset 的时序块：只在 command_fire 时锁存全命令，防止上游 pop 后字段被覆盖。
6. 控制时序块：管理失败分支、bank 所有权与最终完成，不进行地址/算术运算。
7. u_scheduler 实例：直接使用已验证的几何枚举，不改它的稳态计数与 ready/valid 逻辑。

状态逐项说明：

| 状态 | 等待/动作 | 下一步 |
|---|---|---|
| IDLE | 可以接收完整命令 | CHECK |
| CHECK | 检查通用字段 | 合法 ACQUIRE；非法 DONE(error) |
| ACQUIRE | 原子取得指定 bank | 成功 PREPARE；拒绝 DONE(error) |
| PREPARE | 后端验证/准备，不启动数据通路 | 成功 LAUNCH；拒绝 RELEASE(error) |
| LAUNCH | 与 scheduler 握手，并发出 job_start | RUN |
| RUN | 发送描述符，等正确 tag 的安全完成 | RELEASE |
| RELEASE | 归还/提交资源；反压则保持占用 | DONE |
| DONE | 向 dispatcher 保持一条完成响应 | 握手后 IDLE |

示例：prepare 拒绝也要走 RELEASE，因为申请 bank 已成功；CHECK 拒绝和 acquire
拒绝直接 DONE，因为这两种情况没有取得任何 bank。

## 5. 吞吐与时序契约

当前是 single outstanding：命令队列可以继续积压命令，但 executor 同时只执行一条。
本模块保证描述符稳态 II=1，不承诺跨命令零气泡，也不承诺尚未实现的 BRAM 带宽。
后端每个 batch 需要 K 个有效输入 beat；缓存、读端口、窗口生成与结果带宽决定实际利用率。

最快启动时序（E 表示上升沿）：

```text
E0：exec_cmd 握手，锁存 ctx，进入 CHECK
E1：合法检查通过，进入 ACQUIRE
E2：最早取得 bank，进入 PREPARE
E3：最早准备成功，进入 LAUNCH
E4：scheduler 装载命令，job_start 同拍，进入 RUN
```

ctx 到 scheduler 的命令装载组合逻辑因此有至少 4 拍的稳定窗口。首次真实集成发现
旧 scheduler 的输入解码不能在 3.333 ns 单周期内完成；这里利用已存在的 FSM 稳定期，
而不是更改已通过验证的 scheduler 迭代路径。约束只保守使用 2 拍：

- `constraints/npu_v13_job_executor_context.xdc`：ctx 寄存器 -> u_scheduler 寄存器，setup=2、hold=1。
- 稳态 scheduler 内部迭代、ctx 捕获、CHECK、FSM 和 done 反馈仍按 3.333 ns 单周期检查。
- 单元与真实联合 TB 均检查 E4 下限；单元 TB 确实执行 acquire/prepare 零等待场景。
- 工程 XDC 使用 SCOPED_TO_REF，仅对 executor 实例生效；综合阶段禁用、实现阶段启用。
- 未来若引入 IDLE->LAUNCH 旁路或运行中修改 ctx，必须删除/重审此约束，不能原样继承。

OOC 边界输入/输出路径排除，因为本次还没有真实 manager/feeder 的物理位置。
集成时序 fixture 包含真实 dispatcher/FIFO + executor + scheduler，检查了这些模块间的
内部连接；它没有把实际 compute cluster 纳入同一个布局布线网表。最终完整 engine
仍要补充端口时序并做全层次布局布线，不能把本次 OOC 结果称为整机时序闭合。

## 6. 仿真验证范围

### 单元测试

`tb/unit/npu/v13/tb_npu_v13_job_executor.sv`：

- 63 个正常结束/报错测试；68 次接管=63 次返回+5 次 reset 中止。
- Icarus 检查 1,829 个描述符，Vivado XSim 检查 1,539 个；两种仿真器的随机序列不同，
  但使用相同的覆盖场景、数学/协议检查和通过条件。
- 全部 9 种 mode/layout、K=1 和 65535、边界尺寸和 30 组随机场景。
- 命令握手后立即破坏上游输入，检查 ctx 不变。
- 描述符随机反压与无气泡 II=1；最短启动与等待 bank/后端。
- 过早完成被阻塞、写回延迟期间不提前释放、错 tag 后正确安全完成。
- 非法 opcode/mode/layout、零维度、bank/后端拒绝、执行错误。
- reset 覆盖申请、准备、运行反压、释放和 done 阶段。
- CONV 正向用例只验证控制握手，绝不代表卷积算术已实现。

### 真实 runtime 集群联合测试

`tb/unit/npu/v13/tb_npu_v13_job_executor_runtime_joint.sv` 使用真实 dispatcher、executor、scheduler
和 runtime compute RTL，不用“延迟几拍就 done”的假集群。

TB 以行为模型提供双 bank 数组、数据 feeder、结果 collector 和安全完成跟踪，使用
命令的 A/B/C base/bank 字段完成读写；K 流中插入气泡。它检查每个有效物理 tile 的 shape、
每个 C 元素的数学参考结果，以及不丢失、不重复、不越界写回。

14 条排队命令包括：10 条成功 GEMM、零尺寸拒绝、CONV 后端不支持、bank 申请失败、
后端配置拒绝。成功 GEMM 覆盖 9 种布局和 37x5x35，核对 341 个物理 tile、4,410 个
结果元素，并执行 6 次真实 mode 配置。人为推迟写回提交，检查 done 不会提前出现。

不覆盖：生产 BRAM bank 仲裁、真实 GEMM 地址流水、卷积窗口、跨 K 分块部分和、DMA、
DDR 带宽和完整网络图。下一阶段必须把这些行为模型逐个换成独立 RTL 后再做联合验证。

## 7. 工程与复现

```powershell
.\scripts\run_rtl_tests.ps1
.\scripts\run_v13_job_executor_project_xsim.ps1
.\scripts\synth_v13_job_executor_300m.ps1
.\scripts\synth_v13_job_executor_300m.ps1 -Integrated
```

已将 executor 注册到 sources_1，单元 TB、联合 TB 和综合测试 fixture 注册到 sim_1。
默认综合/仿真顶层仍是 runtime cluster/runtime TB；project XSim 脚本在结束或失败时
恢复原仿真顶层。工程同步使用 additive 脚本，不重建现有工程。

`tb/unit/npu/v13/npu_v13_command_executor_timing_top.sv` 是测试连接层，便于验证 exec 接口与
时序；不是带真实存储/feeder 的生产 engine 顶层，默认不进入正常综合层次。

实现前备份：`backups/v13_pre_job_executor_20260906_implementation.zip`。
原有 compute/scheduler/FIFO/mode control 的功能 RTL 未修改；dispatcher 仅修正了
ready 语义的注释。没有删除、移动或回退用户的既有模块。

## 8. 最终实测记录

验证日期：2026-09-06；器件 xc7a200tfbg484-2，Vivado 2025.2.1，时钟周期 3.333 ns。
本次保留 one-hot 状态编码，最终报告以以下两个标准目录为准：

| 布局布线范围 | Slice LUT | FF | RAMB36 | DSP | WNS / ns | WHS / ns |
|---|---:|---:|---:|---:|---:|---:|
| executor + 真实 scheduler | 259 | 368 | 0 | 0 | +0.167 | +0.116 |
| 真实 dispatcher/FIFO + executor + scheduler | 369 | 457 | 3 | 0 | +0.125 | +0.066 |

- 单独门禁：`reports/v13_job_executor_300m/summary.txt`。
- 集成门禁：`reports/v13_command_executor_300m/summary.txt`。
- 两者均无 latch、无 routing error；集成版 FIFO 深度为 512、宽度为 194，三个 RAMB36
  都启用了内部输出寄存器 DOA_REG=1。上述资源包含 scheduler，不能称为 executor 状态机的纯增量。
- 布局布线门禁的端口排除与 context setup=2 / hold=1 条件见第 5 节；不是整个 NPU 的单周期时序保证。
- 吞吐测试证明描述符稳态 II=1，而非跨命令零气泡。当前每次只有一条在执行命令。

### 为什么保留 one-hot

二进制状态编码的集成版为 357 LUT、446 FF，布线后 WNS=-0.003 ns，WHS=+0.079 ns。
关键路径是 executor 状态译码到 scheduler 的命令装载使能，仍然按单周期检查。
one-hot 集成版增加 12 LUT、11 FF，WNS 提升到 +0.125 ns；没有额外 DSP/BRAM，
也没有增加状态周期或放宽这条控制路径的约束，因此本次保留。

二进制版本源码保存在 `reports/v13_job_executor_before_onehot/`；其标准目录的历史报告
保存在 `backups/v13_job_executor_binary_timing_20260906.zip`。二进制版的一次布线后物理优化
发生 Vivado EXCEPTION_ACCESS_VIOLATION，不能算作通过；最终 one-hot 的隔离实验与标准目录复现运行均正常退出并通过门禁。
`*_300m_onehot/` 为隔离实验报告，标准目录是最终选定源码的复现报告。

### 仿真与工程

全量 Icarus 回归共 11 项；新增两项亦通过 Vivado 工程 XSim。日志入口：

- `reports/v13_job_executor_rtl_regression.log`
- `reports/v13_job_executor_xsim/job_executor.log`
- `reports/v13_job_executor_xsim/job_executor_runtime_joint.log`

详细验收、备份和边界记录见 `reports/v13_job_executor_verification.md`。
