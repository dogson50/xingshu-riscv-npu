# V13 缓存所有权与同步 BRAM（2026-09-06）

本轮新增两个可综合模块，不修改已有 dispatcher、FIFO、executor、scheduler 和计算集群 RTL。

- rtl/npu/v13/memory/npu_v13_buffer_manager.sv：管理谁有权使用 bank、什么时候交接。
- rtl/npu/v13/memory/npu_v13_bram_bank.sv：存储一个 bank 的数据，执行真实同步读写。

这两层刻意分开：更换存储字宽/深度不应改变命令生命周期，改变 bank 数量也不应把 M/N/K 或卷积窗口算法塞进 RAM。

## 1. 在现有工程中的位置

~~~text
command_queue_dispatcher -> job_executor -> gemm_tile_scheduler
                               |
                         acquire / release
                               |
                         buffer_manager
                      / 状态权限       状态权限 \
                 输入装载器            结果消费者
                      |                     ^
                 A/B bram_bank             C bram_bank
                      |                     ^
                地址生成 + feeder -> runtime cluster -> collector
~~~

本轮实物 RTL 是 manager 和 bram_bank。图中的地址生成、feeder、collector、装载器和消费者目前在联合 TB 中以行为模型补齐，不能当作已经完成的生产 RTL。

manager 的默认参数是 AB_BANKS=2、C_BANKS=1：A 有两个 bank，B 有两个 bank，而 C 只有一个。C_BANKS 独立配置，不因输入双缓冲而强制输出双缓冲。BANK_W 必须能编码所有配置的 bank；例如 AB_BANKS=3、C_BANKS=2 时至少为 2。

manager 不自动选择空闲 bank；命令中的 bank 编号由上层指定。它也不检查这个 bank 中的数据是否属于正确矩阵、是否已装满，装载器/命令生产者必须保证对应关系。

## 2. buffer_manager 输入输出

除 clk/resetn 外，事务仅在时钟上升沿 valid && ready 时被接收。上游遇到 valid=1、ready=0 必须保持请求及字段稳定。有 error_o 的接口，应在握手时采样 error_o；error_o 单独为 1 不是一个新事件。

| 端口组 | 谁连接 | 含义 |
|---|---|---|
| load_begin_valid_i / ready_o | 输入装载器 | 请求占用一个 FREE 输入 bank，成功后进入 LOADING |
| load_begin_operand_i / bank_i | 输入装载器 | operand=0 为 A，1 为 B；bank 是该 operand 内的编号 |
| load_begin_error_o | 返回装载器 | bank 越界时握手拒绝；合法但忙则 ready=0 等待 |
| load_finish_valid_i / ready_o | 输入装载器 | 所有写已提交后，结束本次 LOADING |
| load_finish_operand_i / bank_i | 输入装载器 | 指明结束哪一个 A/B bank |
| load_finish_error_i | 输入装载器 | 本次装载失败/主动放弃：回 FREE，不发布 READY |
| load_finish_error_o | 返回装载器 | bank 非法或并非 LOADING，事务被消费但不改状态 |
| input_discard_valid_i / ready_o | 上层取消/回收控制 | 丢弃未使用的 READY 输入，防止预加载数据长期占 bank |
| input_discard_operand_i / bank_i / error_o | 同上 | 仅允许 READY -> FREE；LOADING/IN_USE/FREE 或越界均报错 |
| req_a_bank_i / req_b_bank_i / req_c_bank_i / req_tag_i | executor 上下文 | 本命令请求使用的 bank 和身份；租约期间保持不变 |
| buffer_acquire_valid_i / ready_o / error_o | executor | 原子取得 A、B、C 使用权；成功时一个不漏，失败时一个不占 |
| buffer_release_valid_i / ready_o / error_i | executor | 结束执行租约，释放 A/B，并提交有效 C 或作废 C |
| c_take_valid_i / ready_o / bank_i / error_o | 结果消费者 | 取走 READY 的 C 所有权，使其进入 DRAINING |
| c_take_tag_o | 返回结果消费者 | 成功 take 时对应结果的命令 tag |
| c_return_valid_i / ready_o / bank_i / error_o | 结果消费者 | 读响应及下游消费排空之后，把 DRAINING 的 C 归还为 FREE |
| a_*_o / b_*_o / c_*_o | bank 访问封装/上层状态 | 每 bit 对应一个 bank，指示它处于哪个状态 |
| lease_active_o | 上层监控 | 是否存在正在执行的租约；第一版最多一个 |
| protocol_error_o | 诊断 | 粘滞记录无效 finish、无效 C return、错 owner 的 release；reset 清除 |

load_finish_ready_o、input_discard_ready_o、c_return_ready_o 在非复位时恒为 1；非法事务以 error 返回，不能把它理解成操作一定成功。discard 的错误有本事务 error_o，不额外置 protocol_error_o。

### 2.1 与现有 executor 的精确接线

| executor 端口 | manager 端口 |
|---|---|
| ctx_a_bank_o / ctx_b_bank_o / ctx_c_bank_o | req_a_bank_i / req_b_bank_i / req_c_bank_i |
| ctx_tag_o | req_tag_i |
| buffer_acquire_valid_o | buffer_acquire_valid_i |
| buffer_acquire_ready_i | buffer_acquire_ready_o |
| buffer_acquire_error_i | buffer_acquire_error_o |
| buffer_release_valid_o | buffer_release_valid_i |
| buffer_release_ready_i | buffer_release_ready_o |
| buffer_release_error_o | buffer_release_error_i |

这些接线已经存在于 tb/unit/npu/v13/tb_npu_v13_buffer_bram_runtime_joint.sv，不是只画接口未联动。

## 3. 按代码块理解 buffer_manager

### 3.1 状态和 owner 寄存器

每个 A/B bank 使用 2 bit 状态，每个 C bank 也使用 2 bit 状态。lease_r 表示是否已有执行者；owner_a/b/c_r 与 owner_tag_r 锁住成功 acquire 时的身份；c_tag_r 保存已提交 C 的身份。

~~~text
A/B: FREE --begin--> LOADING --finish成功--> READY --acquire--> IN_USE --release--> FREE
                      |                       |
                 finish失败                discard
                      v                       v
                    FREE                    FREE

C:   FREE --acquire--> IN_USE --release成功--> READY --take--> DRAINING --return--> FREE
                         |
                    release失败
                         v
                       FREE
~~~

READY 的 A/B 已写好但尚未给计算任务使用；READY 的 C 已算完但消费者还没接手。两者虽然状态名相同，交接对象不同。

### 3.2 begin / finish / discard 判定

begin_index_ok_w 等信号先检查编号，避免非法编号被当作可用 bank。begin 只接收 FREE；finish 只允许 LOADING。

新增 discard 是为一个实际恢复边界：上层可能已装好 A/B，但命令在 acquire 之前因非法维度/配置/输出 bank 被拒绝。这时没有租约可 release，必须能显式回收 READY 输入。discard 不是 reset，更不能释放正在计算的 IN_USE。

同拍 discard 与 acquire 若瞄准同一个 READY 输入，discard_conflict_w 阻止成功 acquire，discard 优先。另一输入和 C 都不会被部分占用。不同 bank 的装载、丢弃、读出可以并行。

### 3.3 原子 acquire

available_w 的成功条件是：编号合法、A 为 READY、B 为 READY、C 为 FREE，并且没有同 bank 的成功 discard。

没有数据或 C 正被消费时 ready=0，executor 留在等待状态。编号非法或已经存在租约时 error=1 并接收拒绝，不改变任何 bank。真正的 acquire_fire_w 才同时把 A/B 置 IN_USE、C 置 C_IN_USE，并锁存 owner。

这里没有擅自缩小 M/N/K，也没有把这些维度复制进 manager。它只理解 bank/tag 和生命周期。

### 3.4 安全 release 和 C 消费

owner_match_w 比较租约、三个 bank 和 tag。只有匹配时 release_ready 才拉高；错 owner 的 release 不会释放别人的数据，会记下 protocol_error。

成功执行的 release：A/B 回 FREE，C 进入 READY，C tag 被写入。失败执行的 release：A/B/C 均回 FREE，不让消费者读半成品。

release 不等于最后一个输入 K beat，也不等于 scheduler 发完最后一个描述符。executor/后端必须等计算流水、输入读响应和 C 写入全部排空后才能 release。manager 本身看不到这些流水，无法替后端判断。

C 消费者先 take，之后在 DRAINING 状态发读请求；等最后一个响应被下游真正接收，再 return。单 C 时，下一命令会等 C 归还，但可以并行预加载另一组 A/B。若希望 C 消费与下一任务的 C 写入重叠，可提高 C_BANKS 并配套实例化存储；这不是本轮默认配置。

### 3.5 时序 always 和状态输出

owner/tag 数据块不复位，状态/lease/粘滞错误块复位；状态无效时 owner/tag 不可用。

所有判断依据该边沿之前的旧状态。因此同一 bank 不支持同拍 finish 后立刻 acquire、release 后立刻 take、return 后立刻 acquire 的跨级旁路。每次交接最多多一个管理周期，避免把多个外部握手串成长组合链；这不会把 BRAM 数据通路变成隔拍读写。

状态输出均受 resetn 限定。manager 不包含 RAM 端口，这些位本身不会物理阻止写入：集成时必须真正接到请求权限门控。

## 4. 所有权必须落实到 RAM 端口

| 存储区 | 允许写请求的状态 | 允许读请求的状态 |
|---|---|---|
| A/B | LOADING，仅装载器写 | IN_USE，仅当前执行 feeder 读 |
| C | IN_USE，仅当前 collector 写 | DRAINING，仅已 take 的消费者读 |

例如写口封装应同时满足：

~~~verilog
assign ram_wr_valid = producer_valid && write_permission;
assign producer_ready = ram_wr_ready && write_permission;
~~~

只门控 valid、不门控返回 ready 会让上游误以为数据已被 RAM 接收。多执行者系统还需比对 owner；本轮限定只有一个执行租约。权限撤销前还要排空已经发出的请求/响应，不能只看当前 rd_valid。

联合 TB 已门控实际 RAM 请求，并在写入、读出、release、return 边界放断言。生产版 bank wrapper 将来同样必须做到这一点。

## 5. bram_bank 输入输出及逐块逻辑

默认 DATA_W=32、DEPTH=1024、TAG_W=8、READ_LATENCY=2，ADDR_W 默认由 DEPTH 推导且最小为 1。支持 READ_LATENCY=1 或 2；非 2 的幂深度通过范围检查拒绝空洞地址。

| 端口 | 含义 |
|---|---|
| wr_valid_i / wr_ready_o | 写请求握手，每拍最多一个完整 word |
| wr_addr_i / wr_data_i | word 地址和完整 DATA_W 位数据；不是字节地址，无 byte enable |
| wr_error_o | 本拍握手的写地址非法；该写不改变存储体 |
| rd_valid_i / rd_ready_o | 读请求握手，每拍最多一个 word |
| rd_addr_i / rd_tag_i | word 地址和将随响应原样返回的 tag |
| rd_rsp_valid_o | 固定时延之后的响应有效指示 |
| rd_rsp_data_o | 正常读响应的数据；错误响应的数据无意义 |
| rd_rsp_tag_o / rd_rsp_error_o | 与响应同拍的原 tag 和错误标志 |

读、写 ready 在非复位时恒为 1。读响应没有 ready，后端不能临时阻止响应；发请求前必须保证响应接收能力，必要时由外层 FIFO/credit 控制发起量。

### 5.1 地址、碰撞和 RAM 存储块

wr_addr_ok_w / rd_addr_ok_w 对扩展一位的地址与 DEPTH 比较。wr_fire_w 只代表合法写；rd_fire_w 代表已接收读，非法读也要按约定返回一个错误响应，不能静默丢掉。

同拍有效读写同地址时：写照常提交，物理 RAM 读被禁止，读响应按原时延带 error 返回。不依赖不同器件/模式对 read-during-write 的处理。冲突计算只使用真正合法的写，非法写不会误伤另一个合法读。

memory_r 带 ram_style=block。两个独立 posedge always 分别描述写口和同步读口，不清存储内容、不对数据做错误清零 mux。READ_LATENCY=2 的额外 ram_output_r 每拍推进；本轮默认配置的 routed 网表确认其吸收到 RAMB36 内部输出寄存器。

拆分读写 always 是为结构清晰；不能把它宣称为已经证明节省了 32 个 FF 的优化，具体归因见验证报告。

### 5.2 固定延迟和连续吞吐

以请求在上升沿 E0 被接收为例：READ_LATENCY=1 的响应在 E0 之后有效，下游可在 E1 采样；READ_LATENCY=2 的响应在 E1 之后有效，下游可在 E2 采样。

| 上升沿 | 被接收的读请求 | L1 在该边沿后的响应 | L2 在该边沿后的响应 |
|---|---|---|---|
| E0 | X | X | 无 |
| E1 | Y | Y | X |
| E2 | 无，气泡 | 无 | Y |
| E3 | Z | Z | 无 |
| E4 | 无 | 无 | Z |

valid/tag/error 逐时钟推进，气泡也必须推进。不能等下一次 rd_valid 才推出上一笔响应。只要接收方容量足够，两种延迟都能每拍接收一个读，并独立每拍接收一个写，即每端口 II=1。两拍延迟不等于每两拍才能读一次。

### 5.3 最小化 reset

valid_r 复位，RAM、读数据、tag/error 不复位。复位中两个 ready 和响应 valid 都为 0，已在流水中的旧请求被取消，但存储内容保留。没有有效响应时不得检查数据/tag/error 是否为零。

系统 reset 必须协调 manager、executor、装载器、feeder 和 collector 一起中止；不能只复位 manager 后任由旧 feeder 继续访问已重新分配的 bank。

## 6. 已验证什么，尚未实现什么

- 14 项 Icarus 回归通过，旧 11 项保持通过；Vivado 工程新增 3 项 XSim 通过。
- BRAM 单测覆盖 L1/L2、DEPTH=1/13/32、连续读、同拍独立读写、非法地址、冲突、tag/气泡对齐、复位取消及数据保留；4 配置共 4400 个检查周期。
- manager 单测覆盖 AB2/C1 与 AB3/C2、随机事务/复位、原子申请、错误 release、单 C 生命周期、双缓冲预加载，以及 READY discard 与 acquire 冲突；共 10072 个检查周期。
- 真实联合仿真：14 条命令，10 次成功 GEMM，341 个物理 tile，4410 个逻辑结果元素，6 次模式改变；全 9 种 mode/layout 组合与非整块 M/N，动态 K 和输入气泡。
- 实际 RAM 端口统计：输入写 1460、输入读 4326、C 写/读各 4410，84 次输入写与上一执行租约重叠，C 消费完成 10 次。所有有效 C 元素均从真实 C RAM 读回后比对，最终 A/B/C 全部归还。
- 错误命令覆盖零维度、不支持的 CONV、C 编号越界、后端拒绝；acquire 前拒绝留下的 READY A/B 已通过 discard 回收。

联合 TB 为了优先把访问次序讲清楚，使用标量串行读 A/B、拼接 source lanes，以及快照结果后串行写 C。它验证真实计算/存储的功能与所有权时序，不能证明系统已达到 256 MAC/cycle，也不是可综合的高带宽 feeder/collector。没有给生产 CONV 功能打通过标记。

输入采用单次消费策略，release 后 A/B 都回 FREE；跨命令权重复用需后续增加显式保留策略。BRAM 模块参数化了容量/字宽，但默认一个 bank 并不天然提供整个阵列所需并行带宽。

## 7. 时序验证与复现

~~~powershell
.\scripts\run_rtl_tests.ps1
.\scripts\run_v13_buffer_bram_project_xsim.ps1
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration manager
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration bram_l1
.\scripts\synth_v13_buffer_bram_300m.ps1 -Configuration bram_l2
~~~

300 MHz 使用真实发射/捕获寄存器夹具，对 clk=3.333 ns 的内部与跨 DUT 边界路径布局布线；只排除 reset 和夹具外侧没有物理位置的板级端口，不使用多周期放宽。夹具寄存器不是生产模块的新接口延迟。

manager 最终 WNS/WHS 为 +0.005/+0.164 ns：满足本次门禁，但 setup 余量很小。BRAM 32x1024 的 L1 为 +0.101/+0.070 ns，L2 为 +0.107/+0.059 ns。并非整个 NPU 集成布线通过；实际跨模块连接后仍要重跑时序。资源统计、原始日志、早期失败记录和 SHA256 见 reports/v13_buffer_bram_verification.md。

Vivado 已增量注册 13 个 RTL、16 个仿真/夹具文件，保留原默认综合/仿真顶层。不要为了更新文件重复执行 create_vivado_project 覆盖现有项目。

建议阅读顺序：manager 的状态与 handshake -> bram_bank 的 valid/tag 延迟 -> 两个单测 -> 真实 BRAM runtime 联合 TB。下一步生产数据路径仍需几何展开、地址生成、高带宽 bank 封装、feeder 和 collector，本轮没有越界实现它们。

