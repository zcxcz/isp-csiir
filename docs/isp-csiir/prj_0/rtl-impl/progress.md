# rtl-impl 工作进展

## 当前阶段
- 阶段: M4 代码完成
- 状态: 完成
- 更新时间: 2026-03-22

## 工作目标
1. 实现四阶段流水线 RTL 代码
2. 完成行缓存和窗口生成逻辑
3. 通过功能仿真验证

## 已完成工作

### 2026-03-22 RTL实现完成

#### 创建的文件列表

| 文件路径 | 描述 |
|---------|------|
| `rtl/isp_csiir_defines.vh` | 全局定义头文件 |
| `rtl/isp_csiir_top.v` | 顶层模块 |
| `rtl/isp_csiir_reg_block.v` | APB寄存器配置块 |
| `rtl/isp_csiir_line_buffer.v` | 5行像素缓存 + 5x5窗口生成 |
| `rtl/stage1_gradient.v` | Stage 1: 梯度计算 (5 cycles) |
| `rtl/stage2_directional_avg.v` | Stage 2: 方向平均 (8 cycles) |
| `rtl/stage3_gradient_fusion.v` | Stage 3: 梯度融合 (6 cycles) |
| `rtl/stage4_iir_blend.v` | Stage 4: IIR混合 (5 cycles) |
| `rtl/common/common_pipe.v` | 通用流水寄存器 |
| `rtl/common/common_counter.v` | 通用计数器 |
| `rtl/common/common_fifo.v` | 通用同步FIFO |
| `rtl/common/common_adder_tree.v` | 通用平衡加法树 |
| `rtl/common/common_max_finder.v` | 通用最大值查找器 |
| `rtl/common/common_delay_line.v` | 通用延迟线 |

#### 设计特性

1. **流水线架构**
   - 总延迟: 24 cycles (din_valid -> dout_valid)
   - Stage 1: 梯度计算 (5 cycles)
   - Stage 2: 方向平均 (8 cycles)
   - Stage 3: 梯度融合 (6 cycles)
   - Stage 4: IIR混合 (5 cycles)

2. **行缓存架构**
   - 5行像素缓存 (支持5x5窗口)
   - IIR反馈写回支持
   - 循环缓存设计，节省存储资源

3. **配置接口**
   - APB从接口
   - 支持动态参数配置
   - 支持旁路模式

4. **代码风格**
   - 纯 Verilog-2001
   - 组合逻辑 + 流水寄存器模式
   - 参数化设计

#### 资源估算

| 资源类型 | 估算值 |
|---------|--------|
| 像素行缓存 | 273,600 bits (5行 x 5472 x 10-bit) |
| 逻辑单元 | ~25,000 LUTs |
| 寄存器 | ~20,000 FFs |

## 待处理
- [x] 实现各阶段模块
- [x] 集成顶层模块
- [ ] 代码风格检查
- [ ] 功能仿真验证
- [ ] 时序分析

## 下一步计划
1. 创建简单的测试平台进行功能验证
2. 检查代码风格符合规范
3. 综合后进行时序分析