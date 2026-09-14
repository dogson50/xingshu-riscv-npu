# XingShu Roadmap

## M0 — 开源仓库基线

- [x] 仓库骨架、许可证和协作模板
- [x] 导入v13/A04 NPU基线及14项RTL回归
- [x] 固定DDR-DMA子模块版本
- [x] 声明uiFDMA为不分发的外部依赖

## M1 — 自研RISC-V CPU

- [ ] RV32I五级流水
- [ ] 冒险处理、转发和分支控制
- [ ] UART、GPIO、Timer与中断
- [ ] 指令测试和CoreMark
- [ ] 两路组相联I/D Cache

## M2 — Pango后端

- [ ] PG2L200H最小PDS工程
- [ ] DSP48E1到APM的等价MAC封装
- [ ] RAMB到Pango存储资源的适配
- [ ] Pango时钟、复位和FDC约束
- [ ] A04 NPU功能与周期级对照回归

## M3 — SoC与DDR

- [ ] 地址空间和片上互连
- [ ] CPU MMIO控制NPU
- [ ] DDR-DMA到Pango HMIC适配
- [ ] 权重与特征图乒乓缓存
- [ ] CPU/NPU/视频通道仲裁

## M4 — 边缘AI演示

- [ ] INT8模型量化与算子映射
- [ ] 卷积、激活和重定量化数据通路
- [ ] 端到端推理正确性
- [ ] HDMI或摄像头演示
- [ ] 吞吐率、时延、资源和功耗报告

## M5 — 竞赛交付

- [ ] 可复现Release和Bitstream
- [ ] CoreMark与NPU性能证据
- [ ] 设计说明书、演示视频和答辩材料
- [ ] 第三方来源及许可证复核