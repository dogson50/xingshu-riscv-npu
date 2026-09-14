# P89-A04 正式版基线

正式冻结日期：2026-09-13  
目标器件：`xc7a200tfbg484-2`  
生产顶层：`npu_v13_gemm_feature_transport`

## 1. 正式集成边界

- 外部搬运：参数 `TRANSPORT_W=64`，默认值也是 64 bit。
- 计算规模：4 个自治结果岛，共 16 个 4×4 tile / 256 个 PE。
- 局部供给：计算岛内部保留宽数据通路；跨岛不交换整矩阵。
- 后处理：4 路 P4 PSUM → 参数查表 → requant/activation → 双 bank feature store。
- A04 控制特征：一个全局 `valid + index + 78-bit payload` 配置 commit record，在本地同步广播到 4 份岛内量化参数表。
- 当前生产顶层不包含板级 DDR 控制器、DMA、CDC、CONV 窗口生成器和 pool；这些必须在更外层 SoC wrapper 集成。

## 2. Vivado 工程组织

- `sources_1`：A04 设计源，顶层切换为 `npu_v13_gemm_feature_transport`。
- `sim_a04`：A04 定向和完整四岛 testbench，默认仿真顶层为 `tb_gemm_feature_transport`。
- `constrs_a04_200m` / `constrs_a04_300m`：生产顶层的 5.000 ns / 3.333 ns 时钟约束。
- `synth_a04_200m` / `impl_a04_200m`：默认正式基线 run。
- `synth_a04_300m` / `impl_a04_300m`：高压优化 run；不代表 300 MHz 已闭合。
- 独立公平 PPA 复现入口：`scripts/run_a04_ppa_ooc.tcl`，顶层固定为 `gemm_feature_transport_timing`。

旧 RTL 仍保留在原路径。预导入 `.xpr` 和恢复脚本位于：

`backups/a04_formal_preimport_20260913_125611`

## 3. 生产约束与 PPA 约束必须分开

生产顶层和 P89 的 PPA fixture 不是同一个顶层，不能共用端口例外：

- `npu_v13_a04_200m.xdc` / `npu_v13_a04_300m.xdc`：只对生产顶层创建计算时钟。板级 I/O delay、pin、DDR 和 CDC 约束必须由 SoC wrapper 补齐。
- `npu_v13_a04_ppa_200m.xdc` / `npu_v13_a04_ppa_300m.xdc`：只用于带输入 launch register 和输出 observation register 的 `gemm_feature_transport_timing`；仅豁免 fixture 外部端口。

因此：

1. 生产顶层 run 用于检查层级、综合可实现性以及后续 SoC 集成；
2. P89 架构横向 PPA 数字只能用注册式 OOC fixture 复现；
3. 禁止把未设置板级 I/O delay 的生产顶层 WNS 与 P89 表格直接比较。

## 4. 2026-09-13 正式源回归

正式目录中的 RTL 已用 XSim 重跑：

| Suite | Case | 结果 | 周期 |
|---|---|---:|---:|
| `tb_gemm_feature_backend` | continuous | PASS | TB 未打印周期 |
| `tb_gemm_feature_backend` | stalls | PASS | TB 未打印周期 |
| `tb_gemm_feature_backend` | reset-abort | PASS | TB 未打印周期 |
| `tb_gemm_feature_transport`, W=64 | continuous | PASS | 3447 |
| `tb_gemm_feature_transport`, W=64 | stalls | PASS | 4312 |
| `tb_gemm_feature_transport`, W=64 | reset-abort | PASS | 4573 |

运输层周期与 P89 冻结结果一致，未观察到吞吐或协议行为漂移。覆盖包括四岛提交、双 bank、配置 fence、输入反压、输出反压、连续 II=1 读取、复位中止、64→128-bit 本地拼装以及读出重打包。

## 5. P89 已知 PPA 结果

| 条目 | A04 |
|---|---:|
| 300 MHz routed WNS | -0.756 ns |
| 300 MHz routed TNS | -5291.972 ns |
| 200 MHz routed WNS | +0.046 ns |
| LUT | 29,928 |
| FF | 37,089 |
| LUTRAM | 7,536 |
| BRAM36 / BRAM18 | 99 / 20 |
| DSP | 324 |

这些数字来自 `gemm_feature_transport_timing` 的注册式 OOC fixture，不是带 DDR/CONV/pool/板级 I/O 的完整 SoC signoff。

## 6. 相对 P89 候选源的有意 RTL 差异

为了消除 Vivado 的“使用早于声明”歧义，只做声明顺序清理，不改变接口、组合表达式、状态机、握手或寄存周期：

1. `npu_v13_quant_params.sv`
   - 候选 SHA256：`8446E3EB616118CD4BB3F2E0FCC50AD8D41AA4691B61CB61ED6D07B3ED21A169`
   - 正式 SHA256：`6A5CAE67EC6C41819781A9AF9C74A4676D89D41E08913CF7C15FEEA4BF926D11`
2. `npu_v13_feature_store.sv`
   - 候选 SHA256：`07251447C3CB5C2F3C58516E2ACE803C421AAA59BE35EFADA6239DB8298E50C0`
   - 正式 SHA256：`6A57E55300082071A6D92A5CE20574C267BBD483287633A275D4597AF9A0FEC9`

完整四岛及 64-bit transport 回归必须在任何后续 RTL 修改后继续保持通过。

## 7. 为什么暂时保留历史模块名

首个正式基线保留 `*_exp`、`npu_v22_*`、`npu_v23_*` 和 `npu_v24_*` 的模块名，只把文件冻结到正式 `rtl/npu/v13/a04` 目录。这样不会因为批量重命名改变层级、约束匹配或布局布线随机性。命名清理应作为独立提交，并重新做功能与 PPA 回归。

## 8. 下一阶段协同优化纪律

- 每次只改一个明确的微架构假设；先跑定向仿真，再跑完整四岛回归。
- 200 MHz 是正式闭合基线；300 MHz 是优化压力目标。
- 比较 PPA 时固定器件、源集、`TRANSPORT_W=64`、fixture、综合/实现 directive 和随机条件。
- 若一次改动没有明显时序收益，或资源/吞吐代价不合理，回退到本 A04 正式基线。

## 9. 正式导入与审计证据（2026-09-13）

正式导入遵循“先回归、再生产约束 elaboration、再影子导入、最后当前 GUI 导入”的顺序：

1. 正式 RTL 回归：
   - `A04_BACKEND_REGRESSION_PASS cases=3`
   - `A04_TRANSPORT_REGRESSION_PASS cases=3 width=64`
   - W=64 周期保持 `3447 / 4312 / 4573`。
2. 生产顶层/XDC elaboration：
   - `A04_PRODUCTION_XDC_ELAB_PASS`
   - `54` 个 A04 RTL，`620` 个顶层端口，`65996` 个 elaborated cells；`compute_clk=5.000 ns`。
   - `0 Critical Warnings / 0 Errors`；旧 PPA fixture 端口和固定 `HD.CLK_SRC` 不再进入生产约束。
3. 影子工程完整导入：
   - `A04_SHADOW_IMPORT_AUDIT_PASS`
   - `56` 个设计文件（54 个 A04 RTL + 2 个原工程独立 memory RTL）、`30` 个 TB。
   - 专门验证“工程已打开”分支后得到 `A04_ALREADY_OPEN_IMPORT_PASS`。
4. 主 Vivado GUI 导入：
   - `A04_GUI_IMPORT_AUDIT_PASS`
   - 主工程：`E:/vivado_fpga_projects/npu_mydesign/vivado_project/npu_mydesign.xpr`
   - `sources_1` 顶层：`npu_v13_gemm_feature_transport`
   - 活动仿真集/顶层：`sim_a04 / tb_gemm_feature_transport`
   - 当前正式 run：`synth_a04_200m / impl_a04_200m`
   - 压力 run：`synth_a04_300m / impl_a04_300m`
   - 主 `.xpr` 由当前 GUI 于 `2026-09-13 13:33:08` 更新；未关闭或重启 GUI。

导入审计还修正了 `import_a04_formal.tcl` 的已打开工程路径检测：Vivado project 对象不提供 `FULL_PATH`，正式脚本现在由 `DIRECTORY + NAME + .xpr` 计算并核对活动工程路径。该分支已在影子工程和主 GUI 中分别验证。

当前主工程保留的两个非 A04 design source 仅为：

- `rtl/npu/v13/memory/npu_v13_buffer_manager.sv`
- `rtl/npu/v13/memory/npu_v13_bram_bank.sv`

旧计算和控制实现仍在磁盘上，但已从活动 `sources_1` 移除，不参与 A04 正式顶层编译。完整文件溯源和 SHA256 见 `docs/A04_FORMAL_SOURCE_MANIFEST.csv`（54 RTL + 30 TB + 4 XDC + 3 Tcl）。


