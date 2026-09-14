# Contributing

感谢参与星枢项目。所有可合并修改应能够被另一名队员复现和审核。

## 工作流程

1. 为任务创建 Issue，写明目标、边界、验收条件和依赖。
2. 从最新 `main` 创建短期分支：`feat/...`、`fix/...`、`docs/...` 或 `test/...`。
3. 小步提交，提交信息使用祈使句并指出模块，例如 `npu: add result backpressure test`。
4. 推送分支并创建 Pull Request。
5. 填写验证命令、结果、接口影响和PPA影响。
6. CI通过且至少一名队友审核后，以 Squash Merge 合并。

## 完成定义

RTL任务至少满足：

- 接口时序和复位语义有文档；
- 新功能有自检测试；
- 现有回归通过；
- 不引入仿真锁存、X传播或未说明的时钟域；
- 若影响关键路径或资源，附上工具版本、器件、约束、WNS/WHS和利用率；
- 不提交生成目录、License、密钥、绝对路径或无再分发权的文件。

## 分支命名示例

```text
feat/cpu-five-stage
feat/npu-pango-apm
feat/ddr-hmic-adapter
fix/command-fifo-backpressure
test/soc-ddr-integration
docs/memory-map
```

## 代码风格

- SystemVerilog优先使用显式位宽和非阻塞时序赋值；
- ready/valid接口必须说明稳定性与背压行为；
- 跨时钟域必须使用明确的CDC结构；
- 新文件添加适用的SPDX标识；
- 厂商原语必须隔离在 `rtl/vendor/`，通用逻辑不得直接依赖厂商原语。

## DDR-DMA子模块

在 `modules/ddr-multichannel-dma` 中完成修改并推送其独立仓库后，再在主仓库提交新的子模块指针。不要把子模块内容复制成普通目录。