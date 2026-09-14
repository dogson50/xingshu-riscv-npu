# P89 完整四岛架构横向实验最终报告

**完成日期：2026-09-13**

## 1. 最终结论

本轮以 **P87-H / A00 零改动重放**为共同基线，实际实现并验证了 **12 种新候选 A01–A12**，连同基线共完成 **13 个完整四岛候选的 300 MHz routed PPA**。

结论不是“所有新架构都优于 P87-H”，而是形成了三个清晰的 Pareto 方向：

1. **综合 PPA 与正式化首选：A04 — single global cfg commit record**
   - 300 MHz：WNS **-0.756 ns**，仅比 A00 差 0.072 ns；但 TNS 改善 2622.954 ns（33.14%），失败端点减少 8046（23.25%）。
   - 300 MHz routed 面积：比 A00 少 **536 LUT、555 FF**。
   - 200 MHz：通过，WNS **+0.046 ns**；比 A00 多 0.015 ns 裕度，同时少 **400 LUT、666 FF**。
   - 300 MHz vectorless 总功耗估算：**3.740 W**，比 A00 低 0.096 W（2.50%）。
   - 只改一个 RTL 文件，补丁规模约 13 行新增/14 行删除，正式化风险最低。

2. **性能极限参考：A00 / P87-H**
   - 300 MHz 固定实现条件下 WNS 最好：**-0.684 ns**，近似 fixed-route Fmax **248.9 MHz**。
   - 但面积、TNS、失败端点和估算功耗均不如 A04。

3. **低功耗/200 MHz 研究支线：A07 — registered reservation credits**
   - 300 MHz vectorless 总功耗估算最低：**3.523 W**，比 A00 低 8.16%。
   - 200 MHz WNS **+0.080 ns**，为补跑候选中最好。
   - 但 300 MHz WNS **-0.943 ns**；独立 repeat 得到完全相同结果，说明接近性能上限时明显弱于 A04/A00。
   - 功耗是无 SAIF 的 Medium-confidence vectorless 估算，不能据此直接替代 A04 成为正式版。

**若现在必须只选一版进入正式工程：选择 A04。** 继续保留 A00 作为最高频参考，A07 作为以后有真实 SAIF/板级功耗数据时的低功耗备选。

---

## 2. 公平性边界

所有候选统一使用：

- 器件：`xc7a200tfbg484-2`
- Vivado：`2025.2.1`
- 搬运位宽：`TRANSPORT_W=64`
- 完整四岛 GEMM 主计算/结果/后处理通路
- 真实 `256 PE / 324 DSP`
- 保留式 panel/cache 复用
- 4 组局部结果处理通路
- 相同 XDC、综合/布局/物理优化/布线 directives
- routed Vivado 作业串行执行
- 源文件在每次实现前后进行哈希检查，结果均为 `source_unchanged=1`
- 每个候选先通过严格功能与 64-bit transport RTL 回归，再进入 P&R

这不是单岛或 cluster OOC 数字。PPA fixture 包含完整四岛 GEMM transport/backend、PSUM、量化和 feature store；报告内部记录的精确范围为：

```text
GEMM_transport64_real256DSP_PSUM4_quant4_feature2_no_CONV_pool_DDR
```

因此它可公平回答“四岛主计算架构哪版更好”，但**仍不是包含 CONV、pool、DDR PHY/系统壳层的最终整芯片 signoff**。正式化后还需在完整顶层重新做时序、DRC、功耗和接口验证。

---

## 3. 严格 RTL 等价结果

A01–A12 全部与 A00 保持功能、接口、吞吐和逐周期行为一致。

| 场景 | 周期 | II=1 reads | load/native/output |
|---|---:|---:|---:|
| continuous | 3447 | 1651 | 1152 / 576 / 829 |
| stalls | 4312 | 1480 | 1152 / 576 / 829 |
| reset | 4573 | 1480 | 1280 / 640 / 829 |

所有候选均满足：

- feature RTL：PASS
- 64-bit transport RTL：PASS
- 周期与流量金标准：完全一致
- DSP：324
- BRAM36 / BRAM18：99 / 20
- routing errors：0

所以本轮比较没有通过降低 PE 数、吞吐或缓存容量来换取 PPA。

---

## 4. 13 个候选的完整四岛 300 MHz routed PPA

> 300 MHz 下没有候选闭合 setup；这组实验的作用是作为统一高压约束，比较相对架构质量。WNS 越接近 0 越好；TNS 和失败端点绝对值越小越好。

| ID | 架构 | WNS ns | TNS ns | 失败端点 | LUT | FF | LUTRAM | 总功耗 W* |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| A00 | P87-H 零改动重放 | **-0.684** | -7914.926 | 34608 | 30464 | 37644 | 7536 | 3.836 |
| A01 | 分层 completion tree | -0.867 | -7943.360 | 31766 | 30449 | 37607 | 7536 | 3.770 |
| A02 | 中央 cfg pending token | -0.865 | -8718.539 | 35337 | 30546 | 37554 | 7536 | 3.762 |
| A03 | 共享 cfg payload | -0.773 | -8944.263 | 37045 | 30435 | 37214 | 7536 | 3.830 |
| A04 | 单一全局 cfg commit record | **-0.756** | **-5291.972** | **26562** | **29928** | **37089** | 7536 | **3.740** |
| A05 | 双岛成对 cfg commit | -0.935 | -8195.391 | 33818 | 30127 | 37147 | 7536 | 3.537 |
| A06 | 四岛本地 completion credit | -0.921 | -5179.454 | 22587 | 30494 | 37971 | 7536 | 3.617 |
| A07 | 注册化 reservation credit | -0.943 | -9131.581 | 33462 | 30517 | 37617 | 7536 | **3.523** |
| A08 | collector head metadata cache | -0.875 | -9351.227 | 34836 | 31852 | 38056 | 7984 | 3.663 |
| A09 | 延迟 feature metadata commit | -0.875 | -9552.065 | 37173 | 30439 | 37632 | 7528 | 3.833 |
| A10 | cfg payload 无条件捕获 | **-1.008** | -10386.858 | 37318 | 30401 | **36982** | 7536 | 3.761 |
| A11 | executor legality token | -0.923 | **-4984.077** | **21417** | 30423 | 37735 | 7536 | 3.798 |
| A12 | cfg bank one-hot commit | -0.924 | -10057.881 | 37331 | 30482 | 37608 | 7536 | 3.797 |

\* 功耗为相同 routed checkpoint 上的 Vivado vectorless estimate，Confidence=`Medium`，无 SAIF；只能用于低置信度相对参考，不能当作板级功耗。

### 300 MHz 主要排名

- 最佳 WNS：A00；第二 A04。
- 最少 LUT：A04；第二 A05。
- 最少 FF：A10；第二 A04，但 A10 时序最差。
- 最佳 TNS/失败端点：A11；第二 A06；第三 A04。
- 最低 vectorless 功耗：A07；第二 A05；A04 排第五。

A04 是唯一同时位于 **WNS 前二、LUT 第一、FF 前二、TNS/失败端点前三** 的候选，因此它是最均衡而不是单项冠军。

---

## 5. Finalist 重复实现与 200 MHz 闭合

### 5.1 300 MHz 独立 repeat

| ID | 首轮 WNS | repeat WNS | 首轮 TNS | repeat TNS | 结论 |
|---|---:|---:|---:|---:|---|
| A00 | -0.684 | -0.684 | -7914.926 | -7914.926 | 完全一致 |
| A04 | -0.756 | -0.756 | -5291.972 | -5291.972 | 完全一致 |
| A07 | -0.943 | -0.943 | -9131.581 | -9131.581 | 完全一致 |
| A11 | -0.923 | -0.923 | -4984.077 | -4984.077 | 完全一致 |

面积、WHS、失败端点也逐项一致。因此关键选择不是一次偶然 P&R 波动造成的。

### 5.2 200 MHz routed

| ID | WNS ns | WHS ns | TNS | 失败端点 | LUT | FF | 结论 |
|---|---:|---:|---:|---:|---:|---:|---|
| A00 | +0.031 | +0.010 | 0 | 0 | 29012 | 36575 | PASS |
| A04 | +0.046 | +0.041 | 0 | 0 | **28612** | **35909** | PASS，面积最佳 |
| A05 | +0.007 | +0.042 | 0 | 0 | 28669 | 36068 | PASS，但仅 7 ps setup 裕量 |
| A07 | **+0.080** | +0.017 | 0 | 0 | 29088 | 36652 | PASS，200 MHz WNS 最好 |
| A11 | +0.075 | +0.008 | 0 | 0 | 29065 | 36550 | PASS |

全部仍为 324 DSP、99 BRAM36、20 BRAM18、0 routing errors。

200 MHz 的正 WNS 不能推翻 300 MHz 高压比较：不同目标频率会驱动不同的综合和布局决策。A07 在 200 MHz 取得 +0.080 ns，但其 300 MHz 独立 repeat 仍稳定为 -0.943 ns；A04 在接近极限频率时更有余量。

---

## 6. 各架构实验得到的明确结论

### A01：分层 completion tree

局部计数再平衡归约没有改善 WNS，说明 completion 汇总不是唯一主导问题；它会将最差路径转移到其他跨岛控制网络。

### A02–A05、A10、A12：cfg 分发拓扑

- 保留四份 payload、只中央化 pending token（A02）没有收益。
- 共享 payload 但保留局部 valid（A03）减少 FF，却增加宽广播代价。
- 单全局 commit record（A04）是此组唯一实现整体净收益的结构。
- 两两配对（A05）在 vectorless 功耗上看似较低，但 200 MHz 仅余 7 ps，面积也略差于 A04。
- 无条件捕获 payload（A10）扩大高活动率宽寄存器翻转，得到全组最差 WNS/TNS。
- one-hot bank token（A12）减少小比较器，但不能补偿新增状态和剩余宽路由。

这说明“减少寄存器数量”本身不是目标；关键是减少**高活动率、跨物理区域、高扇出**的有效网络，同时不把组合/CE 锥重新推到另一端。

### A06：四岛本地 completion credit

明显减少 TNS 和失败端点，但增加 FF 并把 WNS 转移到 feeder/issue 路径。适合证明“本地化控制状态”方向正确，但不是当前 PPA 最优实现。

### A07：注册化 reservation credit

去掉 collector 和 island admission 的加法/比较锥后，200 MHz 表现很好、vectorless 功耗最低；但 300 MHz 最差路径转移为 `ended_r -> room_ge4_r` 一类跨模块反馈，说明仅注册阈值仍没有把 reserve/retire 环完全物理切断。

### A08：collector metadata head cache

没有消除 128-bit row data LUTRAM 读出及其重排网络，却新增 16 份 metadata/cache 状态：比 A00 多 1388 LUT、448 LUTRAM，时序也未改善。该方向按当前形式应停止。

### A09：延迟 feature metadata commit

打断 begin-ready 到 metadata write-enable 的直接锥后，瓶颈转移到 executor/context，整体 TNS/失败端点反而恶化。单独延迟一个 metadata 阶段不足以解决全局物理耦合。

### A11：executor legality token

预解码一位 legality token 显著改善 TNS 和失败端点，证明控制预解码有价值；但 WNS、面积、功耗均不如 A04。它更适合作为未来与 A04 组合时的局部实验，而不是单独正式化。

---

## 7. 对原始架构问题的回答

原始问题不只是 `c_matrix_o` 或单条大位宽总线，而是几个因素叠加：

1. **四岛之间仍存在中央控制状态与返回反馈环**：cfg commit、params idle、feature begin、feeder issue、chunks remaining、completion/reservation 相互耦合。
2. **大量最差路径由路由主导**：典型关键路径约 60%–80% 为 route delay；部分 200 MHz 路径甚至超过 80%。
3. **异步 LUTRAM 读出后仍连接宽选择/重排网络**：只缓存 metadata 不会消除 row payload 的物理压力。
4. **BRAM 没有可合并的输出寄存器**：Vivado 多次报告 panel RAM 的可选输出寄存器无法合并；后续正式版应在允许增加固定流水级的位置显式设计 registered BRAM boundary，而不是简单强制 RAM_STYLE。
5. **高压下瓶颈会迁移**：优化某个局部比较器后，WNS 会迁移到 feeder、chunk、PSUM completion 或 feature-map reset/enable 网络；因此微小局部改写很难直接闭合 300 MHz。

64-bit 搬运本身是合理的：本轮保持 64 bit 后仍使用本地 128-bit 计算供给和保留式复用，没有降低计算吞吐。真正需要约束的是宽数据只在岛内存在，跨岛只交换窄 token/credit/descriptor，并在 BRAM 与局部计算边界设置明确流水级。

---

## 8. 正式化建议

### 8.1 建议导入 A04

正式版只导入 A04 的 `npu_v13_quant_params.sv` 结构：

- 单一 `valid/address/payload` commit record；
- 同步写入四个局部系数表；
- 保持一拍 commit latency 和每拍一个配置项吞吐；
- 不改变 64-bit transport、四岛数据通路、PE 数量、输出协议或逐周期行为。

正式导入前先清理一个不改变逻辑的 declaration-order warning：

```text
cfg_commit_valid_r used before declaration
```

本轮没有修改该 warning，以确保首轮与 repeat 的源文件完全一致。

### 8.2 正式版的下一阶段优化顺序

1. A04 正式导入并重复严格 RTL 回归。
2. 在完整顶层（含 CONV/pool/DDR shell）跑 200 MHz signoff。
3. 做 225/250 MHz 实际频点扫描，不只依赖 300 MHz checkpoint 的近似 Fmax。
4. 对 panel RAM/feature store 建立显式 registered BRAM read boundary；允许固定、可验证的流水延迟时再实验。
5. 在 A04 上单独叠加 A11 legality predecode，验证是否能保留面积优势并改善 TNS；不要同时混入多项变更。
6. 若重视功耗，采集代表性网络的 SAIF，再复测 A04/A07；没有 SAIF 前不依据 3.523 W 与 3.740 W 的差异做正式选择。
7. 最终进行完整顶层 CDC、DRC、约束覆盖、板级时钟/IO 和真实功耗审计。

---

## 9. 最终选择矩阵

| 使用目标 | 推荐版本 | 原因 |
|---|---|---|
| 综合 PPA、低正式化风险 | **A04** | 面积最小、300 MHz WNS 第二、TNS/失败端点前三、200 MHz 通过、功耗也低于基线 |
| 尽量逼近最高频 | **A00 / P87-H** | 固定 300 MHz route 的 WNS 最好 |
| 200 MHz 且优先研究低功耗 | **A07** | 200 MHz WNS 最好、vectorless 功耗最低；必须补 SAIF/板测 |
| 优先减少全局 setup 失败面 | **A11** | TNS和失败端点最佳，但最差路径和面积不占优 |

**正式版唯一推荐：A04。**

---

## 10. 数据文件

- `candidates.csv`：13 个候选的 RTL/P&R 总表
- `merged_ppa_300.csv`：300 MHz timing/area/power 合并表
- `finalist_runs_extended.csv`：repeat 与 200 MHz finalist 结果
- `supplemental_200.csv`：全部补跑的 200 MHz 结果
- `power_all_300.csv`：13 个候选的 vectorless 功耗报告索引
- `critical_paths_300.csv`：300 MHz 最差路径分类
- `architecture_decision_matrix.csv`：候选机制及保留/淘汰结论
- `P89_BASELINE_MANIFEST.sha256`：基线源文件哈希清单

正式 Vivado 工程未被修改；所有实验均在隔离工作区中完成。