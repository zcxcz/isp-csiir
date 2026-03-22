# ISP-CSIIR 位宽分析报告

**文档版本**: v1.2
**日期**: 2026-03-22
**作者**: rtl-algo 职能代理

---

## 1. 概述

本文档针对 ISP-CSIIR 四阶段流水线算法进行详细的位宽分析，包括各阶段信号位宽需求、定点化格式建议、溢出风险评估，以及与 RTL 实现的对应关系。

**重要修正 (v1.2)**：
- 修正梯度行缓存需求为 **2 行**（处理任意像素需要 3x3 梯度窗）
- 明确 IIR 反馈机制：**输出写回像素 line buffer**，复用为下一轮迭代输入
- 澄清尾列特殊处理的写回逻辑

### 1.1 输入输出规格

| 参数 | 值 | 说明 |
|------|-----|------|
| 输入像素位宽 | 10 bit | 范围 0-1023，无符号 |
| 输出像素位宽 | 10 bit | 范围 0-1023，无符号 |
| 窗口大小 | 5x5 | Sobel/平均滤波窗口 |
| win_size_clip 范围 | [16, 40] | 窗口大小裁剪范围 |
| 流水线总延迟 | ~17 cycles | 4级流水 |

### 1.2 关键参数配置

| 参数 | 默认值 | 位宽 | 说明 |
|------|--------|------|------|
| win_size_thresh | [16, 24, 32, 40] | 6 bit | 窗口大小阈值 |
| win_size_clip_y | [400, 650, 900, 1023] | 10 bit | 梯度裁剪阈值 (RTL默认值) |
| blending_ratio | [32, 32, 32, 32] | 8 bit | IIR 混合比例 (0-64) |

---

## 2. 各阶段信号位宽分析表

### 2.1 Stage 1: 梯度计算与窗口大小确定

**流水线延迟**: 4 cycles

| 信号名 | 位宽 | 范围 | Q格式 | RTL信号 | 说明 |
|--------|------|------|-------|---------|------|
| **输入信号** |
| src_uv_5x5 | 10 | [0, 1023] | U10.0 | window_*_* | 5x5 窗口像素 |
| **中间信号** |
| row0_sum | 13 | [0, 5115] | U13.0 | row0_sum | 第0行像素和 (5 x 1023) |
| row4_sum | 13 | [0, 5115] | U13.0 | row4_sum | 第4行像素和 |
| col0_sum | 13 | [0, 5115] | U13.0 | col0_sum | 第0列像素和 |
| col4_sum | 13 | [0, 5115] | U13.0 | col4_sum | 第4列像素和 |
| grad_h_raw | 14 | [-5115, 5115] | S14.0 | grad_h_comb | 水平梯度原始值 |
| grad_v_raw | 14 | [-5115, 5115] | S14.0 | grad_v_comb | 垂直梯度原始值 |
| grad_h_abs | 14 | [0, 5115] | U14.0 | grad_h_abs_comb | 水平梯度绝对值 |
| grad_v_abs | 14 | [0, 5115] | U14.0 | grad_v_abs_comb | 垂直梯度绝对值 |
| grad | 14 | [0, 2557] | U14.0 | grad_sum_comb | 梯度和 (>>2 后) |
| grad_max | 14 | [0, 5115] | U14.0 | grad_max_comb | 三邻域梯度最大值 |
| **输出信号** |
| grad_h | 14 | [0, 5115] | U14.0 | grad_h | 输出水平梯度 |
| grad_v | 14 | [0, 5115] | U14.0 | grad_v | 输出垂直梯度 |
| grad | 14 | [0, 2557] | U14.0 | grad | 输出梯度 |
| win_size_clip | 6 | [16, 40] | U6.0 | win_size_clip | 窗口大小 |

**位宽计算依据**:
```
row_sum: 5 x 1023 = 5115, 需要 13 bit
grad_raw: row0_sum - row4_sum, 范围 [-5115, 5115], 需要 14 bit (含符号位)
grad_abs: 绝对值后为正数, 14 bit 无符号
grad: (grad_h_abs >> 2) + (grad_v_abs >> 2) = 1278 + 1278 = 2556
```

**RTL实现关键代码** (`stage1_gradient.v`):
```verilog
// 行和计算 (13位足够)
wire signed [DATA_WIDTH+2:0] row0_sum = window_0_0 + ... + window_0_4;

// 梯度差 (需要14位有符号)
wire signed [DATA_WIDTH+3:0] grad_h_comb = row0_sum - row4_sum;

// 绝对值
wire [GRAD_WIDTH-1:0] grad_h_abs_comb = (grad_h_s1 < 0) ? -grad_h_s1 : grad_h_s1;
```

### 2.2 Stage 2: 多尺度方向性平均

**流水线延迟**: 6 cycles

| 信号名 | 位宽 | 范围 | Q格式 | RTL信号 | 说明 |
|--------|------|------|-------|---------|------|
| **输入信号** |
| window_5x5 | 10 | [0, 1023] | U10.0 | win_s4_*_* | 延迟对齐的5x5窗口 |
| win_size_clip | 6 | [16, 40] | U6.0 | win_size_s1~s3 | 窗口大小 |
| **核选择信号** |
| kernel_select | 3 | [0, 4] | U3.0 | kernel_select_comb | 核选择索引 |
| **累加器信号 (最大情况: 4x4 核)** |
| sum0/1_c | 20 | [0, 44989] | U20.0 | sum0_c, sum1_c | 中心加权和 |
| sum0/1_u | 20 | [0, 36809] | U20.0 | sum0_u, sum1_u | 上方向加权和 |
| weight0/1_c | 8 | [0, 44] | U8.0 | weight0_c, weight1_c | 中心权重和 |
| weight0/1_u | 8 | [0, 36] | U8.0 | weight0_u, weight1_u | 上方向权重和 |
| **除法结果** |
| avg0_c/u/d/l/r | 10 | [0, 1023] | U10.0 | avg0_c, avg0_u... | avg0 各方向结果 |
| avg1_c/u/d/l/r | 10 | [0, 1023] | U10.0 | avg1_c, avg1_u... | avg1 各方向结果 |

**权重核参数**:
| 核类型 | 中心权重 sum | 最大系数 | kernel_select |
|--------|-------------|---------|---------------|
| 2x2 | 16 | 4 | 0 (avg1), 1 (avg0) |
| 3x3 | 9 | 1 | 1 (avg1), 2 (avg0) |
| 4x4 | 44 | 8 | 2 (avg1), 3 (avg0) |
| 5x5 | 25 | 1 | 3 (avg1), 4 (avg0) |

**位宽计算依据**:
```
4x4 核最大加权和: sum = 8 x 1023 = 8184 (中心权重8)
考虑 25 个像素累加: 25 x 1023 x 8 = 204600, 需要 18 bit
为安全预留: ACC_WIDTH = 20 bit
除法结果: sum/weight = 8184/8 = 1023, 范围 [0, 1023], 10 bit
```

**RTL实现关键代码** (`stage2_directional_avg.v`):
```verilog
// 累加器位宽定义
parameter ACC_WIDTH = 20;

// 核选择逻辑
assign kernel_select_comb = (win_size_clip < win_size_thresh0[5:0]) ? 3'd0 :
                            (win_size_clip < win_size_thresh1[5:0]) ? 3'd1 : ...;

// 除法 (使用整数除法)
avg0_c <= (w0_c_s5 != 0) ? sum0_c_s5 / w0_c_s5 : {DATA_WIDTH{1'b0}};
```

### 2.3 Stage 3: 梯度加权方向融合

**流水线延迟**: 4 cycles

| 信号名 | 位宽 | 范围 | Q格式 | RTL信号 | 说明 |
|--------|------|------|-------|---------|------|
| **输入信号** |
| avg0/avg1 (5个方向) | 10 | [0, 1023] | U10.0 | avg0_*_s1, avg1_*_s1 | 方向平均值 |
| grad_c/u/d/l/r | 14 | [0, 5115] | U14.0 | grad_*_s1 | 各方向梯度 |
| **排序后梯度** |
| grad_s0~s4 | 14 | [0, 5115] | U14.0 | grad_s*_s2 | 排序后梯度 |
| grad_sum | 17 | [0, 25575] | U17.0 | grad_sum_comb | 梯度和 (5 x 5115) |
| **加权乘累加** |
| blend0_partial | 24 | [0, 5231610] | U24.0 | blend0_partial* | avg x grad 乘积 |
| blend0_sum | 26 | [0, 26158050] | U26.0 | blend0_sum_comb | 5项加权和 |
| **除法结果** |
| blend0_dir_avg | 10 | [0, 1023] | U10.0 | blend0_dir_avg | avg0 融合结果 |
| blend1_dir_avg | 10 | [0, 1023] | U10.0 | blend1_dir_avg | avg1 融合结果 |

**位宽计算依据**:
```
grad_sum: 5 x 5115 = 25575, 需要 15 bit, RTL使用 GRAD_WIDTH+2 = 17 bit
blend_partial: 1023 x 5115 = 5232105, 需要 23 bit
blend_sum: 5 x 5232105 = 26160525, 需要 25 bit
RTL实现: DATA_WIDTH + GRAD_WIDTH + 2 = 26 bit
```

**RTL实现关键代码** (`stage3_gradient_fusion.v`):
```verilog
// 梯度和 (17位)
wire [GRAD_WIDTH+2:0] grad_sum_comb = grad_s0_s2 + ... + grad_s4_s2;

// 加权乘积 (24位)
wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial0 = avg0_c_s2 * grad_s0_s2;

// 加权和 (26位)
wire [DATA_WIDTH+GRAD_WIDTH+2:0] blend0_sum_comb = blend0_sum0 + blend0_sum1 + blend0_partial4;

// 除法
wire [DATA_WIDTH-1:0] blend0_div = (grad_sum_s3 != 0) ? (blend0_sum_s3 / grad_sum_s3) : 0;
```

### 2.4 Stage 4: IIR 滤波与混合输出

**流水线延迟**: 3 cycles

| 信号名 | 位宽 | 范围 | Q格式 | RTL信号 | 说明 |
|--------|------|------|-------|---------|------|
| **输入信号** |
| blend0/1_dir_avg | 10 | [0, 1023] | U10.0 | blend0_dir_avg_s1 | 融合结果 |
| avg0/1_u | 10 | [0, 1023] | U10.0 | avg0_u_s1, avg1_u_s1 | 上方向平均 |
| center_pixel | 10 | [0, 1023] | U10.0 | center_pixel_s1 | 中心像素 |
| win_size_clip | 6 | [16, 40] | U6.0 | win_size_clip_s1 | 窗口大小 |
| **中间信号** |
| blend_ratio | 8 | [0, 64] | U8.0 | blend_ratio_comb | 混合比例 |
| blend_factor | 4 | [0, 4] | U4.0 | blend_factor | 混合因子 |
| win_size_remain_8 | 7 | [0, 7] | U7.0 | win_size_remain_8 | 窗口余数 |
| **IIR 混合** |
| blend0_iir | 17 | [0, 65472] | U17.0 | blend0_iir_avg | ratio*avg 混合 |
| **窗混合** |
| blend0_out | 12 | [0, 4092] | U12.0 | blend0_out | blend_factor 混合 |
| **最终输出** |
| dout | 10 | [0, 1023] | U10.0 | dout | 输出像素 |

**位宽计算依据**:
```
IIR 混合: ratio x avg = 64 x 1023 = 65472, 需要 17 bit
窗混合: factor x blend = 4 x 1023 = 4092, 需要 12 bit
最终除法后截断到 10 bit
```

**RTL实现关键代码** (`stage4_iir_blend.v`):
```verilog
// IIR 混合 (17位中间结果)
blend0_iir_avg <= (blend_ratio_comb * blend0_dir_avg_s1 +
                   (64 - blend_ratio_comb) * avg0_u_s1) / 64;

// 窗混合 (12位中间结果)
blend0_out <= (blend0_iir_avg * blend_factor +
               center_pixel_s2 * (4 - blend_factor)) / 4;

// 最终混合
dout <= (blend0_out * win_size_remain_8[2:0] +
         blend1_out * (8 - win_size_remain_8[2:0])) / 8;
```

---

## 3. 定点化格式建议

### 3.1 数据类型定义

```verilog
// isp_csiir_defines.vh

// 像素数据类型 (无符号)
// U10.0: 整数部分 10 bit, 小数部分 0 bit
// 范围: [0, 1023], 精度: 1.0
`define DATA_WIDTH    10

// 梯度数据类型 (无符号绝对值)
// U14.0: 整数部分 14 bit, 小数部分 0 bit
// 范围: [0, 16383], 精度: 1.0
`define GRAD_WIDTH    14

// 累加器数据类型 (无符号)
// U20.0: 整数部分 20 bit, 小数部分 0 bit
// 范围: [0, 1048575], 精度: 1.0
`define ACC_WIDTH     20

// 窗口大小参数
`define WIN_SIZE_WIDTH  6

// 加权累加结果宽度 (Stage 3)
`define BLEND_SUM_WIDTH  26
```

### 3.2 各阶段 Q 格式汇总

| 阶段 | 信号 | Q格式 | 整数位 | 小数位 | 符号位 | 总位宽 |
|------|------|-------|--------|--------|--------|--------|
| **Stage 1** | src_uv | U10.0 | 10 | 0 | 0 | 10 |
| | grad_h/v (raw) | S14.0 | 13 | 0 | 1 | 14 |
| | grad_h/v (abs) | U14.0 | 14 | 0 | 0 | 14 |
| | grad | U14.0 | 14 | 0 | 0 | 14 |
| | win_size_clip | U6.0 | 6 | 0 | 0 | 6 |
| **Stage 2** | sum_xxx | U20.0 | 20 | 0 | 0 | 20 |
| | weight_xxx | U8.0 | 8 | 0 | 0 | 8 |
| | avg_xxx | U10.0 | 10 | 0 | 0 | 10 |
| **Stage 3** | grad_sum | U17.0 | 17 | 0 | 0 | 17 |
| | blend_sum | U26.0 | 26 | 0 | 0 | 26 |
| | blend_dir_avg | U10.0 | 10 | 0 | 0 | 10 |
| **Stage 4** | blend_iir | U17.0 | 17 | 0 | 0 | 17 |
| | blend_out | U12.0 | 12 | 0 | 0 | 12 |
| | dout | U10.0 | 10 | 0 | 0 | 10 |

---

## 4. 溢出风险评估

### 4.1 Stage 1 溢出分析

| 信号 | 最大值 | 位宽容量 | 安全裕量 | 风险等级 |
|------|--------|----------|----------|----------|
| row_sum | 5115 | 8191 (13bit) | 1.6x | 低 |
| grad_raw | 5115 | 16383 (14bit) | 3.2x | 低 |
| grad_abs | 5115 | 16383 (14bit) | 3.2x | 低 |
| grad | 2557 | 16383 (14bit) | 6.4x | 低 |

**结论**: Stage 1 位宽设计安全，无溢出风险。

### 4.2 Stage 2 溢出分析

| 信号 | 最大值 | 位宽容量 | 安全裕量 | 风险等级 |
|------|--------|----------|----------|----------|
| sum_c (4x4) | 44989 | 1048575 (20bit) | 23.3x | 低 |
| sum_u (4x4) | 36809 | 1048575 (20bit) | 28.5x | 低 |
| avg结果 | 1023 | 1023 (10bit) | 1.0x | 中 |

**风险点**: avg 除法结果可能刚好到 1023，需要确保不溢出。

**RTL保护措施**:
```verilog
// 除法结果天然限幅到 [0, 1023] (因为 sum <= weight * 1023)
avg0_c <= (w0_c_s5 != 0) ? sum0_c_s5 / w0_c_s5 : {DATA_WIDTH{1'b0}};
```

### 4.3 Stage 3 溢出分析

| 信号 | 最大值 | 位宽容量 | 安全裕量 | 风险等级 |
|------|--------|----------|----------|----------|
| grad_sum | 25575 | 131071 (17bit) | 5.1x | 低 |
| blend_partial | 5232105 | 16777215 (24bit) | 3.2x | 低 |
| blend_sum | 26160525 | 67108863 (26bit) | 2.6x | 中 |

**风险点**: blend_sum 安全裕量较小 (2.6x)。

**RTL保护措施**:
```verilog
// 位宽设计为 DATA_WIDTH + GRAD_WIDTH + 2 = 26 bit
// 最大值 26160525 < 67108863，安全
wire [DATA_WIDTH+GRAD_WIDTH+2:0] blend0_sum_comb;
```

### 4.4 Stage 4 溢出分析

| 信号 | 最大值 | 位宽容量 | 安全裕量 | 风险等级 |
|------|--------|----------|----------|----------|
| blend_iir | 65472 | 131071 (17bit) | 2.0x | 中 |
| blend_out | 4092 | 4095 (12bit) | 1.0x | 高 |

**风险点**: blend_out 安全裕量极小，接近边界。

**RTL保护措施**:
```verilog
// blend_out = iir * factor + center * (4-factor) / 4
// 最大值 = 1023 * 4 / 4 = 1023，实际不会超过 1023
blend0_out <= (blend0_iir_avg * blend_factor + center_pixel_s2 * (4 - blend_factor)) / 4;
```

---

## 5. 定点化设计建议

### 5.1 整数运算策略

本算法采用纯整数运算，无小数部分：

1. **除法使用整数截断**: `result = dividend / divisor`
2. **乘法后除法**: `result = (a * b) / divisor`
3. **移位替代除法**: 当除数为 2 的幂时使用 `>>`

### 5.2 除法实现方案

| 阶段 | 除法类型 | 除数范围 | 推荐实现 |
|------|----------|----------|----------|
| Stage 2 | sum / weight | [1, 44] | 整数除法 (综合器优化) |
| Stage 3 | blend_sum / grad_sum | [1, 25575] | 整数除法 |
| Stage 4 | ratio 混合 / 64 | 64 (常数) | 移位 `>> 6` |
| Stage 4 | factor 混合 / 4 | 4 (常数) | 移位 `>> 2` |

### 5.3 精度优化建议

1. **Stage 1 梯度计算优化**
   ```verilog
   // 当前实现: grad = (grad_h_abs >> 2) + (grad_v_abs >> 2)
   // 误差: 每次移位损失 0-3 的精度

   // 改进建议: 合并后移位
   // grad = (grad_h_abs + grad_v_abs) >> 2
   // 优点: 减少一次截断误差
   ```

2. **Stage 2/3 除法精度优化**
   ```verilog
   // 四舍五入除法
   avg = (sum + (weight >> 1)) / weight;
   // 最大误差从 0.5 LSB 减少到 0.25 LSB
   ```

### 5.4 边界保护策略

```verilog
// 输出饱和截断
function [DATA_WIDTH-1:0] saturate;
    input [31:0] value;
    begin
        saturate = (value > 1023) ? 10'd1023 :
                   (value < 0) ? 10'd0 : value[DATA_WIDTH-1:0];
    end
endfunction
```

---

## 6. RTL 对应关系总结

| 模块 | 文件 | 主要参数 |
|------|------|----------|
| Stage 1 | stage1_gradient.v | DATA_WIDTH=10, GRAD_WIDTH=14 |
| Stage 2 | stage2_directional_avg.v | DATA_WIDTH=10, ACC_WIDTH=20 |
| Stage 3 | stage3_gradient_fusion.v | DATA_WIDTH=10, GRAD_WIDTH=14 |
| Stage 4 | stage4_iir_blend.v | DATA_WIDTH=10 |
| 行缓存 | isp_csiir_line_buffer.v | 6行缓存 |
| IIR行缓存 | isp_csiir_iir_line_buffer.v | 反馈支持 |

---

## 7. 附录

### 7.1 参数汇总表

| 参数名 | 默认值 | 位宽 | 范围 |
|--------|--------|------|------|
| DATA_WIDTH | 10 | - | [8, 16] |
| GRAD_WIDTH | 14 | - | [12, 16] |
| ACC_WIDTH | 20 | - | [18, 24] |
| WIN_SIZE_WIDTH | 6 | - | 固定 |
| WIN_SIZE_THRESH | [16,24,32,40] | 16 bit | [16, 64] |
| BLENDING_RATIO | [32,32,32,32] | 8 bit | [0, 64] |

### 7.2 修订历史

| 版本 | 日期 | 修订内容 | 作者 |
|------|------|----------|------|
| v1.0 | 2026-03-22 | 初始版本 | rtl-algo |
| v1.1 | 2026-03-22 | 新增数据依赖分析，修正行缓存需求 | rtl-algo |
| v1.2 | 2026-03-22 | 修正梯度缓存为2行，明确IIR写回机制 | rtl-algo |

---

## 8. 数据依赖分析（v1.2 修正版）

### 8.1 问题概述

在原分析中存在以下需要修正的问题：

1. **Stage 3 梯度融合的前向依赖**：算法要求访问 `grad(i, j+1)`（下一行梯度）
2. **IIR 反馈机制的实现方式**：输出需要写回像素 line buffer，作为下一轮迭代输入
3. **行缓存行数的合理性**：需要 2 行梯度缓存支持 3x3 梯度窗

### 8.2 Stage 3 梯度融合的数据依赖详解

#### 8.2.1 算法原始定义

根据算法参考文档 (`isp-csiir-ref.md`)，Stage 3 需要获取 5 个方向的梯度：

```
grad_c = grad(i, j)           // 当前行
grad_u = grad(i, j-1)         // 上一行 (up)
grad_d = grad(i, j+1)         // 下一行 (down)  <-- 关键！
grad_l = grad(i-1, j)         // 左邻居
grad_r = grad(i+1, j)         // 右邻居
```

#### 8.2.2 3x3 梯度窗需求分析

**问题核心**：处理任意像素 (i, j) 时，需要访问 3x3 邻域的梯度值：

```
         [grad(i-1, j-1)]  grad_l  [grad(i+1, j-1)]
              grad_u          grad_c     grad_d
         [grad(i-1, j+1)]  grad_r  [grad(i+1, j+1)]

实际需要访问:
- 上一行: grad_u (行 j-1)
- 当前行: grad_c, grad_l, grad_r (行 j)
- 下一行: grad_d (行 j+1)
```

#### 8.2.3 梯度行缓存方案

**修正后的需求：2 行梯度缓存**

| 梯度分量 | 来源 | 存储需求 |
|---------|------|---------|
| grad_c | 当前行的梯度计算输出 | 无需额外缓存 |
| grad_u | 上一行梯度缓存 | 需要 1 行缓存 |
| grad_d | 下一行梯度缓存 (FIFO) | 需要 1 行缓存 |
| grad_l/r | 当前行横向邻居 | 移位寄存器 |

**数据流设计**：

```
时间线:
  Row j-1: Stage1 计算梯度 → 写入 FIFO [1]
  Row j:   Stage1 计算梯度 → 写入 FIFO [2] → Stage3 读取:
           - grad_u = FIFO [1] 读取
           - grad_c = 当前计算输出
           - grad_d = FIFO [2] 读取 (下一行)
           - grad_l/r = 移位寄存器
```

**FIFO 机制**：

```
梯度 FIFO 结构:
  FIFO[1]: 存储上一行梯度 (供 grad_u 使用)
  FIFO[2]: 存储下一行梯度 (供 grad_d 使用)

数据流:
  Row j:   Stage3 读取 FIFO[1](grad_u) + 实时(grad_c) + FIFO[2](grad_d)
           Stage1 输出写入 FIFO[1] (供 Row j+1 作为 grad_u)
           FIFO[2] 数据释放 (已在 Row j 使用完毕)

  Row j+1: FIFO 原位置更新，继续处理
```

**修正后的梯度行缓存设计**：

```verilog
// 2 行梯度 FIFO 缓存
// 用于存储上一行和下一行的梯度值

// FIFO 结构
reg [GRAD_WIDTH-1:0] grad_fifo_0 [0:IMG_WIDTH-1];  // 上一行梯度 (grad_u 来源)
reg [GRAD_WIDTH-1:0] grad_fifo_1 [0:IMG_WIDTH-1];  // 下一行梯度 (grad_d 来源)

// 读写控制
// 写入: Stage 1 输出当前行梯度
// 读取: Stage 3 读取上一行(grad_u)和下一行(grad_d)

// 数据流
// Row j:
//   - grad_u = grad_fifo_0[x] (上一行缓存)
//   - grad_c = Stage1 当前输出 (实时)
//   - grad_d = grad_fifo_1[x] (下一行缓存)
//   - 同时: Stage1 输出写入 grad_fifo_0 (供 Row j+1 作为 grad_u)
//   - grad_fifo_1 数据释放后，新的下一行数据填入
```

### 8.3 IIR 反馈机制（重要修正）

#### 8.3.1 正确的 IIR 理解

**IIR 特性的本质**：输出反馈为输入

```
迭代公式:
  output(i, j) = f(input(i, j), previous_output)

真正的 IIR 反馈:
  当前输出 → 写回输入存储 → 影响后续处理
```

#### 8.3.2 写回方案：复用像素 line buffer

**关键决策**：输出值写回像素 line buffer，作为下一轮迭代的输入使用。

**算法伪代码**：
```
for (h=-2; h<=2; h++)
    src_uv(i, j+h) = blend_uv(i, j)
```

**写回逻辑分析**：

1. **相邻像素 5x5 窗数据重叠**：
   - 处理像素 (i, j) 时，输出写入 (i, j-2) 到 (i, j+2) 位置
   - 处理像素 (i, j+1) 时，输出写入 (i, j-1) 到 (i, j+3) 位置
   - 存在重叠区域

2. **行扫描写回量**：
   - **常规像素**：只需写回 5x1 像素（当前列及其相邻 2 列）
   - **尾列像素**（最后 3 列）：需要写回 5x3 大小像素

3. **尾列定义**：图像最后 3 列需要特殊处理

```
写回示意 (行扫描):
  列 i:   写回 [i-2, i-1, i, i+1, i+2]
  列 i+1: 写回 [i-1, i, i+1, i+2, i+3]  (与前重叠)
  ...

尾列 (最后 3 列):
  列 W-3: 写回 [W-5, W-4, W-3, W-2, W-1]
  列 W-2: 写回 [W-4, W-3, W-2, W-1] + 额外处理
  列 W-1: 写回 [W-3, W-2, W-1] + 额外处理
```

#### 8.3.3 硬件实现方案

**像素 line buffer 复用架构**：

```verilog
// 像素 line buffer 同时作为:
// 1. 输入窗口缓存 (5x5 窗口生成)
// 2. IIR 反馈存储 (输出写回)

// 4 行像素循环缓存
reg [DATA_WIDTH-1:0] pixel_line_buf [0:3][0:IMG_WIDTH-1];

// 读操作: 生成 5x5 窗口
wire [DATA_WIDTH-1:0] window_0_0 = pixel_line_buf[rd_ptr][col-2];
// ...

// 写操作 (两路):
// 1. 输入写入: din 写入当前位置
// 2. IIR 写回: dout 写回窗口中心位置

always @(posedge clk) begin
    // 正常输入写入
    if (din_valid) begin
        pixel_line_buf[wr_ptr][col] <= din;
    end

    // IIR 反馈写回 (延迟 1 行)
    if (dout_valid && iir_writeback_en) begin
        pixel_line_buf[iir_wr_ptr][iir_col] <= dout;
    end
end
```

**写回时序**：

```
时间线:
  Row j:
    - 读取 pixel_line_buf 生成 5x5 窗口
    - Stage 1-4 处理
    - 输出 dout
    - dout 写回 pixel_line_buf (影响 Row j+2 及之后的处理)

  Row j+2:
    - 读取的窗口包含 Row j 的输出结果
    - 实现 IIR 反馈
```

**读写冲突处理**：

```
场景分析:
  - 读: 生成 5x5 窗口 (访问 5 行)
  - 写: 输入 din + IIR 写回 dout

冲突情况:
  - IIR 写回与窗口读取可能访问同一位置
  - 需要时序仲裁或双端口存储

解决方案:
  - 使用双端口 SRAM (一读一写)
  - 或使用时序错开 (写回延迟到行末)
```

### 8.4 行缓存需求修正（最终版）

#### 8.4.1 像素行缓存

| 需求 | 行数 | 原因 |
|-----|------|------|
| 5x5 窗口生成 | 4 行 | 输入流到达行 j+2 时才能处理行 j |
| IIR 反馈存储 | **复用** | 输出写回像素 line buffer |

**结论**：像素行缓存保持 **4 行**，但需支持写回操作。

#### 8.4.2 梯度行缓存

| 需求 | 行数 | 原因 |
|-----|------|------|
| grad_u (上一行) | 1 行 | FIFO 存储 |
| grad_d (下一行) | 1 行 | FIFO 存储 |
| **总计** | **2 行** | 支持 3x3 梯度窗 |

**结论**：梯度行缓存需要 **2 行**（修正原分析）。

#### 8.4.3 avg_u 缓存

| 需求 | 行数 | 原因 |
|-----|------|------|
| avg0_u / avg1_u | 1 行 | Stage 4 水平混合 |

**结论**：avg_u 缓存需要 **1 行**。

#### 8.4.4 总行缓存需求汇总

| 缓存类型 | 修正前行数 | 修正后行数 | 说明 |
|---------|----------|----------|------|
| 像素行缓存 | 4 | **4** | 复用为 IIR 反馈存储 |
| 梯度行缓存 | 1 | **2** | 支持 3x3 梯度窗 |
| avg_u 缓存 | 1 | **1** | Stage 4 水平混合 |
| **总计** | 6 | **7** | 修正后 |

### 8.5 数据流时序图

```
输入像素流:
Row 0: din --> Line Buf [0] --> (等待填充)
Row 1: din --> Line Buf [1] --> (等待填充)
Row 2: din --> Line Buf [2] --> (等待填充)
Row 3: din --> Line Buf [3] --> (等待填充)
Row 4: din --> Line Buf [4/0] --> Stage1(grad_4) --> GradFIFO[0] --> Stage2 --> Stage3 --> Stage4(dout_4)
                              \-> GradFIFO[1] (下一行)
                              \-> IIR 写回 Line Buf

Row 5: din --> Line Buf [5/1] --> Stage1(grad_5) --> GradFIFO[0] --> Stage2 --> Stage3 --> Stage4(dout_5)
         使用 Line Buf [0-4]      \-> GradFIFO[1]     使用 avg_u_4(缓存)
         生成 5x5 窗口               (实时供 Stage3)     IIR 写回 Line Buf
         包含 dout_4 (IIR 反馈)    使用 grad_4(FIFO)
```

**关键时序**：
1. Stage 3 处理行 j 时，需要访问 grad_u (行 j-1) 和 grad_d (行 j+1)
2. 2 行梯度 FIFO 缓存满足此需求
3. 输出 dout 写回像素 line buffer，影响后续行的处理窗口

### 8.6 尾列特殊处理

#### 8.6.1 尾列定义

尾列 = 图像最后 3 列 (列 W-3, W-2, W-1)

#### 8.6.2 尾列写回特点

```
常规列 (列 0 ~ W-4):
  写回范围: [col-2, col+2] = 5 个像素

尾列 W-3:
  写回范围: [W-5, W-1] = 5 个像素

尾列 W-2:
  写回范围: [W-4, W-1] = 4 个像素
  额外处理: 需要处理边界

尾列 W-1:
  写回范围: [W-3, W-1] = 3 个像素
  额外处理: 需要处理边界
```

#### 8.6.3 RTL 实现

```verilog
// 尾列检测
wire is_tail_col = (pixel_x >= IMG_WIDTH - 3);

// 写回宽度控制
wire [2:0] writeback_width = is_tail_col ? (IMG_WIDTH - pixel_x + 2) : 3'd5;

// 写回地址计算
wire [LINE_ADDR_WIDTH-1:0] wb_start_col = (pixel_x < 2) ? 0 : (pixel_x - 2);
wire [LINE_ADDR_WIDTH-1:0] wb_end_col = (pixel_x + 2 >= IMG_WIDTH) ? (IMG_WIDTH - 1) : (pixel_x + 2);
```

### 8.7 关键问题总结

#### 8.7.1 已确认的设计（v1.2 修正版）

| 项目 | 确认结果 |
|-----|---------|
| 4 行像素缓存 | **足够**，支持 5x5 窗口生成 + IIR 写回 |
| 梯度行缓存 | 需要 **2 行**，支持 3x3 梯度窗 |
| IIR 反馈机制 | **写回像素 line buffer**，复用存储 |
| avg_u 缓存 | 需要 **1 行** |

#### 8.7.2 实现要点

| 项目 | 实现建议 |
|-----|---------|
| 梯度 FIFO | 2 行 FIFO 结构，支持 grad_u 和 grad_d 访问 |
| IIR 写回 | 复用像素 line buffer，需要读写仲裁 |
| 尾列处理 | 特殊写回逻辑，处理边界情况 |

---

*本报告由 rtl-algo 职能代理生成，用于指导 RTL 实现的定点化设计。*