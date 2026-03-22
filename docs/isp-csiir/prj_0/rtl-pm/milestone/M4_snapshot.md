# M4 里程碑快照

## 基本信息
- 里程碑: M4 RTL 实现
- 完成日期: 2026-03-22
- 负责 Skill: rtl-impl

## 主要产出
- RTL 代码目录: `rtl/`
- 全局定义头文件: `rtl/isp_csiir_defines.vh`
- 顶层模块: `rtl/isp_csiir_top.v`
- 寄存器配置块: `rtl/isp_csiir_reg_block.v`
- 像素行缓存: `rtl/isp_csiir_line_buffer.v`
- Stage 1-4 流水线模块: `rtl/stage1_gradient.v` ~ `rtl/stage4_iir_blend.v`
- 通用模块: `rtl/common/` (6个)

## 关键设计决策
| 决策点 | 选择 | 原因 |
|--------|------|------|
| 像素行缓存 | 5 行 | 梯度 3x3 可视域 + IIR 反馈 |
| 梯度行缓存 | 2 行 | Stage 3 需要 3x3 梯度窗 |
| avg_u 缓存 | 0 行 | 从当前 5x5 窗口直接计算 |
| 流水线延迟 | 24 cycles | 600MHz 时序约束 |
| 代码风格 | 纯 Verilog-2001 | 可综合 RTL 要求 |

## 模块结构
```
isp_csiir_top
├── isp_csiir_reg_block          // APB 寄存器配置块
├── isp_csiir_line_buffer        // 5 行像素缓存
├── stage1_gradient              // Stage 1: 5 cycles
├── stage2_directional_avg       // Stage 2: 8 cycles
├── stage3_gradient_fusion       // Stage 3: 6 cycles
└── stage4_iir_blend             // Stage 4: 5 cycles
```

## 遇到的问题
| 问题 | 解决方案 |
|------|----------|
| 无重大问题 | - |

## 后续风险
- M5 验证需要完整 golden model 对比
- IIR 反馈路径需要验证时序正确性
- 600MHz 时序收敛需要在综合后验证