# ISP-CSIIR 项目规划书

## 基本信息

| 项目 | 内容 |
|------|------|
| 项目名称 | ISP-CSIIR (Channel Spatial Invariant Image Restoration) |
| 项目编号 | prj_0 |
| 版本 | v1.1 |
| 启动日期 | 2026-03-22 |
| 更新日期 | 2026-03-31 |
| 目标交付 | 待定 |

## 项目目标

实现四阶段图像复原处理流水线，包含：
1. 梯度计算与窗口大小确定
2. 多尺度方向性平均
3. 梯度加权方向融合
4. IIR滤波与混合输出

## 约束条件

| 约束类型 | 规格 |
|----------|------|
| 输入数据位宽 | 10-bit |
| 输出数据位宽 | 10-bit |
| 数据格式 | 输入/输出像素均为无符号 u10 |
| 目标工作频率 | 600MHz |
| 吞吐量 | 1 pixel/clock |
| 目标工艺 | 12nm |
| 接口协议 | APB 配置接口 + 顶层 `valid/ready` 数据流 |
| 功能基线 | `/home/sheldon/rtl_project/isp-csiir/isp-csiir-ref.md`（只读） |
| 强制交付项 | 端到端 `valid/ready` backpressure |

## 当前轮次重点

- 当前 focus：对齐 `/home/sheldon/rtl_project/isp-csiir/isp-csiir-ref.md`，并将端到端 `valid/ready` backpressure 作为强制交付项。
- 本轮优先级：先冻结规格与 blocker 清单，再推进后续架构、验证与 RTL 修复。
- 任何阶段性交付都不得以“当前 RTL 行为”替代参考语义，也不得弱化 backpressure 要求。

## 里程碑计划

| 里程碑 | 交付物 | 负责Skill | 状态 |
|--------|--------|-----------|------|
| M0: 项目启动 | 项目规划书 | rtl-pm | ✓已完成 |
| M1: 需求基线 | 模块规格文档 | rtl-std | 进行中 |
| M2: 算法定型 | 定点模型+位宽分析报告 | rtl-algo | 待开始 |
| M3: 架构评审 | 架构设计文档 | rtl-arch | 待开始 |
| M4: RTL完成 | RTL代码 | rtl-impl | 待开始 |
| M5: 验证通过 | 验证报告+覆盖率报告 | rtl-verf | 待开始 |
| M6: 项目交付 | 全部交付物 | rtl-pm | 待开始 |

## 算法参考

参见: `/home/sheldon/rtl_project/isp-csiir/isp-csiir-ref.md`（只读功能基线）

## 目录结构

```
isp-csiir/
├── docs/
│   └── isp-csiir/
│       └── prj_0/
│           ├── rtl-std/
│           ├── rtl-algo/
│           ├── rtl-arch/
│           ├── rtl-impl/
│           ├── rtl-verf/
│           ├── rtl-fmt/
│           └── rtl-pm/
├── rtl/
│   ├── common/
│   └── ...
└── verification/
```