# S2-N1 正式基线

**正式晋升日期：2026-09-14**
**正式顶层：`npu_v13_gemm_feature_transport`**
**兼容目录：`rtl/npu/v13/a04`（历史路径名保留，不再表示当前架构仍是 A04）**

## 1. 决策

S2-N1 原生 P4-striped full transport 已替换 P89-A04，成为 v13 当前正式 RTL 基线。正式版本保持 A04 的命令、multi-K、量化、feature store、read/release、completion 和 reset-abort 功能边界，但重构了计算结果传输微架构。

核心变化：

- 外部 panel 搬运与读回保持 64 bit；
- 16 个 4×4 物理 tile，峰值 256 个 INT8 MAC/cycle；
- 一个统一计算上下文和确定性 drain 控制器；
- 每拍输出四路独立 128-bit P4 word，不构造中央 512-bit matrix row；
- 每路使用 181-bit、2-entry 局部弹性 slice；
- 结果直接进入四个常驻 PSUM island，再进入 requant/post、feature store 与 completion；
- 删除四份 512-bit shadow、四个大结果 FIFO，以及结果预约/捕获/退休容量记账路径。

架构图见 [`docs/architecture/S2_N1_native_p4_architecture.svg`](../architecture/S2_N1_native_p4_architecture.svg)。

## 2. 输出条带

一个 16×16 packet 固定用 16 拍 drain：

```text
local_row = drain_step[3:2]
col_group = drain_step[1:0]
lane g    = tile[g][col_group].row[local_row], g=0..3
```

因此第 0 拍输出 rows `{0,4,8,12}` 的 columns `0..3`，第 15 拍输出 rows `{3,7,11,15}` 的 columns `12..15`。吞吐由固定 16 拍 drain 和上游 `II=max(K,16)` 约束决定，不依赖四岛结果在远端重新同拍汇合。

## 3. 正式功能回归

器件无关的完整 transport XSim 回归使用同一 64-bit 顶层与相同计数检查：

| 场景 | 周期 | 结果 |
|---|---:|---|
| Continuous | 3,417 | PASS |
| Random stalls | 4,280 | PASS |
| Stall + reset-abort | 4,540 | PASS |

相对 A04 分别减少 30、32、33 cycles。三个场景均检查 command、packet、commit、read、native write、output beat、success/failure 与 reset-abort 行为。

复现：

```powershell
./scripts/run_formal_transport_regression.ps1
```

## 4. Routed OOC PPA

公平比较条件：Vivado 2025.2.1，`xc7a200tfbg484-2`，registered OOC full transport fixture，`TRANSPORT_W=64`。它是架构比较数据，不是板级 sign-off。

| 目标 | WNS | WHS | TNS | Total LUT | Logic LUT | LUTRAM | FF | RAMB36 | RAMB18 | DSP |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 200 MHz | +0.090 ns | +0.046 ns | 0 ns | 17,601 | 16,141 | 1,104 | 34,386 | 83 | 4 | 324 |
| 300 MHz | -1.257 ns | +0.039 ns | -12,217.667 ns | 18,783 | 17,323 | 1,104 | 35,413 | 83 | 4 | 324 |

200 MHz 正式复核结果为 WNS `+0.090 ns`、WHS `+0.046 ns`、TNS `0`、0 routing error，route elapsed `607.622 s`；300 MHz **没有闭合**，不得把 300 MHz 当作正式工作频率。

相对旧 A04 200 MHz 基线，S2-N1 的 Total LUT 从 28,546 降到 17,601，LUTRAM 从 7,536 降到 1,104，FF 从 35,941 降到 34,386，BRAM18-equivalent 从 218 降到 170，DSP 保持 324。

详细机器可读数据见 [`benchmarks/ppa/S2_N1_native_p4_ppa.csv`](../../benchmarks/ppa/S2_N1_native_p4_ppa.csv)。

复现：

```powershell
vivado -mode batch -source scripts/run_a04_ppa_ooc.tcl -tclargs 200 local_run -notrace
```

脚本名与约束目录继续保留 `a04`，用于兼容已有工程和自动化；报告内的 `architecture` 字段会标记实际正式架构为 S2-N1。

## 5. 正式源清单

正式 source list 位于 `scripts/a04_formal_sources.tcl`，包含 56 个 design RTL、30 个 testbench 和 4 个 XDC。冻结哈希见 [`S2_N1_FORMAL_SOURCE_MANIFEST.csv`](S2_N1_FORMAL_SOURCE_MANIFEST.csv)。

正式迁移替换的边界模块：

- `rtl/npu/v13/a04/result_backend/npu_v13_packet_backend.sv`
- `rtl/npu/v13/a04/postprocess/npu_v13_psum_panel.sv`

新增的原生计算模块：

- `rtl/npu/v13/a04/base_compute/npu_s2_n1_unified_p4_core.sv`
- `rtl/npu/v13/a04/base_compute/npu_g1_tile4x4_capture.sv`
