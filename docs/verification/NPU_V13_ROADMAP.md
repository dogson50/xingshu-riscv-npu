# NPU V13 分层路线

## 设计原则

每个模块只承担一类职责，使用 ready/valid 边界独立验证。模块通过仿真后才加入
Vivado 工程；上层组合模块不得把调度、地址计算、存储和算术重新揉进同一个 FSM。

## 当前基线

`npu_v13_systolic_cluster_runtime_stream` 是计算后端，不是完整 NPU。它已经解决：

- 256 个 INT8 MAC 的连续 K 维累加；
- 16x16、4x8x8、16x4x4 三种输入复用范围；
- 动态 M/N 尾块 shape sideband（shape 外结果为 don't-care）；
- 动态 K packet；
- 固定延迟结果对齐。

它不应负责矩阵地址、DDR、片上缓存、卷积窗口、量化或网络图调度。

## 已完成：Cluster mode controller

`npu_v13_cluster_mode_ctrl` 是第一个直接连接 runtime cluster 的外部控制模块，
但不进入 A/B/C 主数据通路。它把 dispatcher 发出的一次目标模式请求，可靠地
转换成 runtime cluster 的 cfg 事务：

```text
mode_req_valid_i   <- dispatcher / command executor
mode_req_ready_o   -> dispatcher / command executor
mode_req_mode_i    <- dispatcher / command executor

cluster_cfg_valid_o   -> runtime.cfg_valid_i
cluster_cfg_mode_o    -> runtime.cfg_mode_i
cluster_cfg_ready_i   <- runtime.cfg_ready_o
cluster_cfg_error_i   <- runtime.cfg_error_o
cluster_active_mode_i <- runtime.active_mode_o

mode_rsp_*         -> dispatcher / command executor
```

控制器只允许一条 outstanding 请求，内部状态为 `IDLE -> CFG -> CONFIRM ->
RESPONSE`。集群忙时，runtime 的 `cfg_ready_o=0`，控制器会保存 mode 并保持
cfg ready/valid 字段稳定，既不会打断旧 packet，也不会要求上游一直保存原命令。
同模式请求直接成功，不生成冗余 cfg；非法 `2'b11` 在本地返回错误，不会进入
runtime cluster。response 也支持反压，完成信息保持到上游接收。

单元仿真覆盖 cfg 与 response 反压、同模式旁路、非法模式、下游错误和 reset
取消 pending 请求。真实联合仿真把控制器 cfg 端口逐线连接到 runtime cluster，
验证了 K=2 packet 执行期间提前提交下一模式时，配置会等待旧结果完全排空后才
生效，旧 packet 的结果不会丢失。Icarus 六项统一回归和 Vivado project XSim
均已通过，RTL/TB 已加入 Vivado 工程。

控制器 300 MHz OOC 完整布局布线使用 12 Slice LUT、5 FF、0 DSP、0 BRAM、
0 SRL、0 latch，内部 reg-to-reg WNS/WHS 为 `+1.316/+0.215 ns`，没有未布线
网络。由于独立 OOC 实现没有真实 dispatcher 和 cluster 的物理位置，顶层端口
路径被排除；它证明控制器内部时序通过，最终子系统组装后仍必须复查跨模块路径。
详细记录见 `reports/v13_cluster_mode_ctrl_verification_20260904.txt`。

## 已完成：命令队列与 dispatcher

`npu_v13_command_queue_dispatcher` 是控制面的统一外壳，对外提供一个完整命令
ready/valid 接口，对内仍保持三个职责解耦：

```text
npu_v13_command_queue_dispatcher
├── npu_v13_command_fifo          只保存和排序命令，不解释字段
├── npu_v13_cluster_mode_ctrl     只完成 runtime cluster 的安全 mode 切换
└── dispatcher FSM                管理 head、下发、完成和 response 生命周期
```

默认命令为 194 bit、FIFO 深度为 512，字段包括 `opcode`、M/N/K、cluster mode、
mode-local layout、A/B/C base、A/B/C bank、`op_cfg` 和 tag。`opcode=00/01`
分别表示 GEMM/CONV；当前模块只保存并转发 CONV 类别，卷积窗口、stride、padding
等仍应由独立 CONV frontend 或 executor 解释。它也不计算地址、不拥有双缓冲状态；
当前 `npu_v13_job_executor` 的 `exec_cmd_ready` 表示有空上下文槽，命令握手后
即锁存全部字段；真正的 scheduler/后端启动仍须等待 bank 原子授予和后端准备成功。
这样命令接管与资源就绪解耦，不要求 FIFO head 一直等待 bank。

FIFO 使用同步写、同步读的 block RAM 推断模板。BRAM 读数据先进入 raw stage，
再进入可吸收到 `RAMB36E1.DOA_REG` 的 output stage；两级 valid 独立管理，因此输出
反压时可以保留 head，同时 raw stage 预取下一条命令，热身后连续 pop 的 II=1。
memory、raw data 和 output data 均不复位，只复位指针、计数和 valid。满队列不会用
同拍 pop 组合放行 push，避免 consumer 反向进入 BRAM 写使能路径。

dispatcher 只锁存 head 的 `opcode/mode/tag` 控制元数据，M/N/K、地址和 `op_cfg`
等宽 payload 仍直接由稳定的 FIFO head 驱动执行接口。处置事件先生成
`head_retire`，下一拍才由寄存的单周期 `fifo_pop_r` 真正 pop；这样
payload decode、`exec_cmd_ready`、response 和 mode 结果不会组合反馈到 RAMB36 的
EN/REGCE。相应地，执行器接管 head 后，`queue_level` 还会在一个周期内包含它；
这是明确的观测语义，不是重复执行。

执行生命周期为 single outstanding：

```text
HEAD -> WAIT_MODE -> ISSUE -> RUNNING -> HEAD
  |        |           |          |
  |        |           |          +-- 等待安全点 exec_done
  |        |           +------------- 执行器接管完整命令
  |        +------------------------- 不同 mode 等待 cfg/确认
  +---------------------------------- 同 mode 直接下发或本地拒绝
```

`exec_cmd` 握手只表示执行器接管命令，不能当作计算完成。只有 feeder、cluster 和
collector 已到达允许下一条命令接管 cluster 的安全点后，执行器才能发送一次
`exec_done`。在 `RUNNING` 期间，即使下一条 head 已经预取，也不会提前切换 mode。
同 mode 命令跳过 cfg；不同 mode 通过内部 mode controller 等待 runtime 空闲并
确认生效。cluster cfg 必须由该子系统独占；若以后存在多个配置主机，必须先增加
仲裁。

每条入口已接收命令严格产生一次带原 tag 的退休 response，一深弹性 response 槽
支持反压并可在旧 response 被接收的同拍装入新 response。状态码为：

- `000`：成功；
- `001`：非法 opcode；
- `010`：非法 cluster mode；
- `011`：mode 配置报错或确认值不匹配；
- `100`：执行器报错；
- `101`：`exec_done` tag 与当前执行命令不匹配。

dispatcher 当前只本地检查 opcode 和 cluster mode。`M/N/K=0`、mode-local layout
非法、scheduler 拒绝、buffer 访问错误和计算/写回错误必须由 executor 与后端协作收敛为
恰好一次 `exec_done_valid_i + exec_done_error_i`；否则 single-outstanding FSM 会
按设计停留在 `RUNNING`，不能错误地放行下一条命令。

自检覆盖 512 深度 FIFO 的满/空、反压、指针多次回绕、稀疏碰撞和稳态
push+pop II=1；dispatcher 覆盖同/异 mode、cfg/exec/response 反压、所有六种
response、连续 ready 下不重复执行、每条 head 只 pop 一次以及 queue level 精确
减一。真实联合 TB 将 cfg 逐线连接到
`npu_v13_systolic_cluster_runtime_stream`，以两个 K=2、1x1 packet 验证结果
`-14` 和 `30`，并确认 RUNNING 期间不能提前切换 mode、非法 mode 不会到达
runtime。九项 Icarus 统一回归通过；命令队列的三个自检也已通过 Vivado project
XSim 门禁，RTL/TB 已注册到工程。

默认 512x194 配置在 xc7a200tfbg484-2 上完成 300 MHz OOC 布局布线：3 个
RAMB36E1 且 3/3 使用 `DOA_REG=1`、96 Slice LUT、82 FF、0 DSP、0 LUTRAM、
0 SRL、0 latch；内部 WNS/WHS 为 `+0.224/+0.110 ns`，无 routing error。OOC
顶层输入输出路径因没有真实 producer/consumer 放置而排除，最终 engine 集成后仍需
复查跨模块路径。详细记录见
`reports/v13_command_queue_verification_20260904.txt`。

## 已完成：Job executor 命令执行控制器

`npu_v13_job_executor` 直接接收 dispatcher 的完整 `exec_cmd_*`，内部连接已有
`npu_v13_gemm_tile_scheduler`，并在命令安全完成后返回 `exec_done_*`。

生命周期为 `IDLE -> CHECK -> ACQUIRE -> PREPARE -> LAUNCH -> RUN -> RELEASE -> DONE`：

- 先锁存整条命令，再检查 opcode、M/N/K 和 layout；非法命令不触碰数据通路。
- 向独立 buffer manager 原子申请 A/B/C bank；资源忙可以等待，拒绝则返回错误。
- 后端检查地址、算子配置和能力；成功后才产生一次 `job_start`。
- scheduler 只产生紧凑描述符，无反压 II=1；`schedule_finished` 不代表计算完成。
- 等正确 tag 的安全完成（包含实际写回提交与流水排空），然后释放 bank，再返回 done。
- 错 tag 记录错误但不释放当前命令；运行期错误必须由后端安全排空后完成，不能硬停阵列。

它是执行控制面，不实现 BRAM、卷积窗口、地址生成、feeder 或 collector。联合仿真
将真实 dispatcher/executor/scheduler/runtime 连接起来，缺少的数据模块由 TB 行为模型
提供。CONV 控制请求可以传输，但当前 GEMM 测试后端明确拒绝 CONV，不能据此宣称
已支持卷积计算。生产版下一个几何模块仍是 tile batch expander。

源码带中文注释，完整端口、状态和约束说明见 `docs/NPU_V13_JOB_EXECUTOR.md`。
命令上下文到 scheduler 的装载路径使用限定范围的 setup=2/hold=1 多周期约束；
FSM 保证至少 4 拍稳定，测试覆盖最快启动。其他内部路径及描述符迭代仍按 3.333 ns
单周期检查，最终接入存储/feeder 后仍要验证真实跨模块端口路径。

## 已完成：连续流计算集群资源优化

三项优化按独立 A/B 顺序完成，详细原始数据见
`reports/v13_stream_optimization_ab_20260903.txt`：

1. shape/mask 流水由 16-bit mask 改为 4-bit count-1 shape，末端才解码；
   同时只复位真正影响协议的 valid/token 状态。该阶段保留，runtime 集群减少
   320 LUT、640 FF 和 192 SRL16E，routed WNS 从 `+0.156 ns` 提升到
   `+0.379 ns`。
2. 每个 4x4 tile 的首行 4 个 DSP 直接接收 B，后三行 12 个 DSP 使用已有
   `BCOUT -> BCIN` 专用链。全集群仍为 256 个 DSP，其中 192 个配置为
   `B_INPUT=CASCADE`，不是新增 192 个 DSP。该阶段减少 1536 FF，300 MHz
   routed WNS 为 `+0.222 ns`，因此保留。
3. runtime 包装器曾实验旁路固定集群的每 tile 输入边界寄存器。功能仿真通过，
   综合减少 1136 FF，但 routed WNS 从 `+0.222 ns` 降到 `+0.040 ns`，最差路径
   变为 runtime 控制选择到 DSP OPMODE。按“时序恶化则不删除”的约束，该实验
   已回退，最终仍保留输入边界寄存器和 10 拍固定结果延迟。

最终设计继续支持动态 M/N shape 和动态 K packet；用于连续结果对齐的 SRL
保持不变。综合脚本分别硬性检查单 tile、固定 16-lane 集群和 runtime 集群的
B 级联数为 12、192、192，防止后续修改静默退回 fabric B 传播。

## 已完成：结果 mask 网络与 reset 进一步缩减

第二轮逐项 A/B 数据见 `reports/v13_stream_optimization2_ab_20260904.txt`：

1. 每个本地 mask 副本由覆盖 8 个结果 bit 改为 16 个，runtime 减少
   512 LUT、512 FF；保留。
2. `local_mask_token_r` 不再复位。协议可观察性仍由已复位的 valid 控制，
   256 个 FDCE 转为无复位数据寄存器，runtime 再减少 16 LUT；保留。
3. 删除每 PE 的 mask token、复制和末级清零网络。每个物理 tile 新增与
   `c_tile_valid_o`、`c_matrix_o` 同拍的 2-bit rows/cols count-minus-one
   sideband；下游 collector 只采纳左上有效矩形，其余元素明确为 don't-care。
   runtime 最终为 9102 LUT、13596 FF、8016 SRL16E，较本轮基线净减少
   1262 LUT、1280 FF；routed WNS/WHS 为 `+0.236/+0.048 ns`，因此保留。
4. 强制结果链连末级都映射为纯 SRL 的实验把单 tile FF 从 740 降到 228，
   但 512 条 `SRL16E -> c_matrix_o` 边界路径全部违例，综合 WNS 为
   `-0.158 ns`。把同样的接收 FF 移到 collector 只会转移系统资源，不会净省，
   因此该属性已回退；保留由 Vivado 自动拉出的末级输出 FF。

当前输出协议因此不再承诺 shape 外元素清零。这是有意的接口收缩；未来
`npu_v13_result_collector` 必须以每 tile 的 `c_valid + rows_m1 + cols_m1` 为
唯一写回资格，不能读取或写回无效区域。固定结果延迟仍为 10 拍，三种模式
在无气泡输入下仍保持 256 MAC/cycle 和 II=1。

## 已完成：GEMM tile scheduler

`npu_v13_gemm_tile_scheduler.sv` 接收一个矩阵维度命令，
把任意 `M x K x N` 输出空间展开成一串 tile batch。一个 batch 最多包含：

- 16x16 模式的 1 个输出块；
- 8x8 模式的 4 个输出块；
- 4x4 模式的 16 个输出块。

第一版由命令显式给出模式。模式选择属于编译器或独立 policy 模块，不能和
“正确枚举所有块”的机制混在一起。这样可以分别回答两个问题：

1. 指定块大小后，是否不重不漏地覆盖整个 M/N 输出空间；
2. 对某个网络层，哪种块大小在 padding 利用率和 SRAM 带宽之间更好。

命令接口：

```text
cmd_valid/cmd_ready
cmd_m, cmd_n, cmd_k
cmd_mode                 00=16x16, 01=4x8x8, 10=16x4x4
cmd_layout
cmd_tag
```

紧凑 tile-batch 接口：

```text
tile_batch_valid/tile_batch_ready
tile_batch_m, tile_batch_n, tile_batch_k
tile_batch_m_base, tile_batch_n_base
tile_batch_cluster_mode, tile_batch_layout
tile_batch_cmd_first, tile_batch_cmd_last, tile_batch_tag
```

布局决定一个 tile batch 的矩形覆盖范围：16x16 为 `1x1`；4x8x8 为
`1x4/2x2/4x1`；16x4x4 为 `1x16/2x8/4x4/8x2/16x1`。scheduler 不读取 A/B、
不产生每 lane 地址或 shape，也不等待 cluster 固定流水延迟。这样运行期状态不含
16 份坐标加法器和比较器。

已通过的仿真门禁：

- 三种模式及整块、尾块、`M=1/N=1/K=1`；
- 每个逻辑输出元素恰好被一个 group 覆盖；
- tile-batch 数量符合 `ceil(tile_count/group_count)`；
- 随机 `tile_batch_ready` 反压时所有输出字段保持稳定；
- 动态 K 原样传递，不根据固定 K 推导 ACC_W；
- 零维度和非法模式产生错误且不发 tile batch；
- 新命令在上一命令最后一个 tile batch 被接收前不得覆盖状态。

Icarus 和 Vivado project XSim 使用同一自检 TB。300 MHz OOC 完整布局布线结果为
WNS `+0.424 ns`、WHS `+0.179 ns`；无反压 tile-batch II=1，相邻 single-batch 命令间隔为
1 cycle，未使用 DSP/BRAM。

## 已完成：输入/输出 bank 所有权与同步 BRAM

新增 `npu_v13_buffer_manager` 与 `npu_v13_bram_bank` 两个独立模块：前者直接接 executor 的 acquire/release，后者只实现同步数据存储。默认 A/B 各 2 bank，C 独立 1 bank；C 可参数化扩充，但不会被强制双缓冲。

manager 管理 FREE/LOADING/READY/IN_USE 及 C 的 DRAINING 交接；显式 READY discard 用于 acquire 前拒绝命令的输入回收。真实 RAM 的 valid 和返回 ready 都必须按状态权限门控，归还前必须排空读响应/写入；这些责任不会因为新增 manager 自动消失。

本轮 14 项 RTL 回归、3 项新增工程 XSim 通过；真实 runtime 联合仿真读取同步 A/B RAM，结果写入同步 C RAM 并读回比较，共 4410 个有效元素。行为 feeder/collector 只是测试夹具，不是生产高带宽实现。

指定配置 300 MHz 注册边界 P&R 通过，manager WNS 仅 +0.005 ns，集成时需要重点复查。端口、状态、读延迟和验证边界详见 docs/NPU_V13_BUFFER_BRAM.md 与 reports/v13_buffer_bram_verification.md。

## 下一模块：Tile batch expander

下一步实现 `npu_v13_tile_batch_expander`。它只把紧凑 tile batch 和 mode-local layout
展开成最多 16 组 `group_valid/group_m_base/group_n_base/active_rows_m1/
active_cols_m1`。shape 按逻辑 group 紧凑排列：16x16 使用 1x4 bit、4x8x8
使用 4x3 bit、16x4x4 使用 16x2 bit，每个行/列端口统一为 32 bit；控制与
A/B source 再按 runtime cluster 的物理 lane/锚点顺序排列。它不计算存储地址，
不访问 scratchpad，也不驱动 A/B 数据。

这一层单独存在的理由是：layout 到 lane 的映射属于几何展开，而 base/stride 到
SRAM 地址属于存储布局。两者分开后，可以在不改 scheduler 的情况下验证 NHWC、
NCHW 或权重布局，也可以独立检查每个尾块的逻辑 group shape 及 32-bit 模式相关紧凑编码。

## 后续模块顺序

1. `npu_v13_gemm_tile_scheduler`：已完成，只产生紧凑 tile batch。
2. `npu_v13_tile_batch_expander`：展开 group 坐标，并输出 32-bit 紧凑 rows/cols shape。
3. `npu_v13_gemm_addr_gen`：由 base/stride 和逻辑坐标产生 A/B/C 地址。
4. `npu_v13_operand_scratchpad`：复用已完成的 buffer_manager/bram_bank，继续实现高带宽 bank 化封装、权限门控与存储布局；不重复实现所有权 FSM。
5. `npu_v13_cluster_feeder`：把 scratchpad 数据打包成 runtime source lanes 和 K packet。
6. `npu_v13_result_collector`：按 tile-batch 元数据接收物理 tile 结果并写回逻辑 C 块。
7. 独立 post-op/vector 路径：bias、requant、activation、residual、pool。
8. Conv2D/window generator 与 depthwise 单元；它们位于 GEMM engine 之外。

这个顺序先建立任意 GEMM 的正确性，再接存储和卷积，便于定位每一层的问题。
