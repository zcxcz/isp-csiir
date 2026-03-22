# ISP-CSIIR 项目规划书

## 基本信息

| 项目 | 内容 |
|------|------|
| 项目名称 | ISP-CSIIR (Channel Spatial Invariant Image Restoration) |
| 项目编号 | prj_0 |
| 启动日期 | 2026-03-22 |
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
| 输入数据位宽 | 10-bit 无符号 |
| 输出数据位宽 | 10-bit 无符号 |
| 目标工作频率 | 600MHz |
| 吞吐量 | 1 pixel/clock |
| 目标工艺 | 12nm |

## 里程碑计划

| 里程碑 | 交付物 | 负责Skill | 状态 |
|--------|--------|-----------|------|
| M0: 项目启动 | 项目规划书 | rtl-pm | ✓已完成 |
| M1: 需求基线 | 模块规格文档 | rtl-std | 待开始 |
| M2: 算法定型 | 定点模型+位宽分析报告 | rtl-algo | 待开始 |
| M3: 架构评审 | 架构设计文档 | rtl-arch | 待开始 |
| M4: RTL完成 | RTL代码 | rtl-impl | 待开始 |
| M5: 验证通过 | 验证报告+覆盖率报告 | rtl-verf | 待开始 |
| M6: 项目交付 | 全部交付物 | rtl-pm | 待开始 |

## 算法参考

参见: `isp-csiir-ref.md`

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