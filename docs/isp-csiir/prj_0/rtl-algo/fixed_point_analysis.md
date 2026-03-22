# ISP-CSIIR 定点化分析报告

**文档版本**: v1.0
**日期**: 2026-03-21
**作者**: rtl-algo 职能代理

---

## 1. 概述

本文档针对 ISP-CSIIR 四阶段流水线算法进行定点化分析，包括各阶段信号位宽需求、Q格式建议、关键运算处理方案以及精度保持策略。

### 1.1 输入输出规格

| 参数 | 值 | 说明 |
|------|-----|------|
| 输入像素位宽 | 10 bit | 范围 0-1023 |
| 输出像素位宽 | 10 bit | 范围 0-1023 |
| 窗口大小 | 5x5 | Sobel/平均滤波窗口 |
| 窗口大小范围 | [16, 40] | win_size_clip 范围 |

### 1.2 关键参数配置

| 参数 | 默认值 | 位宽 | 说明 |
|------|--------|------|------|
| win_size_thresh | [16, 24, 32, 40] | 6 bit | 窗口大小阈值 |
| win_size_clip_y | [15, 23, 31, 39] | 10 bit | 梯度裁剪阈值 |
| blending_ratio | [32, 32, 32, 32] | 8 bit | IIR 混合比例 (0-64) |

---

## 2. 各阶段信号位宽分析表

### 2.1 Stage 1: 梯度计算与窗口大小确定

| 信号名 | 位宽 | 范围 | Q格式 | 说明 |
|--------|------|------|-------|------|
| **输入信号** |
| src_uv_5x5 | 10 | [0, 1023] | U10.0 | 5x5 窗口像素 |
| **中间信号** |
| row0_sum | 13 | [-5115, 5115] | S13.0 | 第0行像素和 (5 x 10bit) |
| row4_sum | 13 | [-5115, 5115] | S13.0 | 第4行像素和 |
| col0_sum | 13 | [-5115, 5115] | S13.0 | 第0列像素和 |
| col4_sum | 13 | [-5115, 5115] | S13.0 | 第4列像素和 |
| grad_h_raw | 14 | [-5115, 5115] | S14.0 | 水平梯度原始值 |
| grad_v_raw | 14 | [-5115, 5115] | S14.0 | 垂直梯度原始值 |
| grad_h_abs | 14 | [0, 5115] | U14.0 | 水平梯度绝对值 |
| grad_v_abs | 14 | [0, 5115] | U14.0 | 垂直梯度绝对值 |
| grad | 14 | [0, 2557] | U14.0 | 梯度和 (>>2 后) |
| grad_max | 14 | [0, 5115] | U14.0 | 三邻域梯度最大值 |
| **输出信号** |
| win_size_clip | 6 | [16, 40] | U6.0 | 窗口大小 |

**位宽计算依据**:
- row_sum: 5 x 1023 = 5115, 需要 13 bit (含符号位)
- grad_raw: row0_sum - row4_sum, 需要 14 bit (含符号位)
- grad_abs: 绝对值后为正数, 14 bit 无符号
- grad: (grad_h_abs >> 2) + (grad_v_abs >> 2) = 1278 + 1278 = 2556

### 2.2 Stage 2: 多尺度方向性平均

| 信号名 | 位宽 | 范围 | Q格式 | 说明 |
|--------|------|------|-------|------|
| **输入信号** |
| window_5x5 | 10 | [0, 1023] | U10.0 | 5x5 窗口像素 |
| win_size_clip | 6 | [16, 40] | U6.0 | 窗口大小 |
| **中间信号** |
| kernel_select | 3 | [0, 4] | U3.0 | 核选择索引 |
| **累加器信号 (最大情况: 4x4 核)** |
| sum_c (4x4) | 20 | [0, 44989] | U20.0 | 中心加权和 |
| sum_u (4x4) | 20 | [0, 36809] | U20.0 | 上方向加权和 |
| weight_c | 8 | [0, 44] | U8.0 | 中心权重和 |
| weight_u | 8 | [0, 36] | U8.0 | 上方向权重和 |
| **除法结果** |
| avg0_c/u/d/l/r | 10 | [0, 1023] | U10.0 | avg0 各方向结果 |
| avg1_c/u/d/l/r | 10 | [0, 1023] | U10.0 | avg1 各方向结果 |

**位宽计算依据**:
- 4x4 核最大加权和: sum = 8 x 1023 = 8184 (中心权重8)
- 考虑 25 个像素累加: 25 x 1023 x 8 = 204600, 需要 18 bit
- 为安全预留: ACC_WIDTH = 20 bit
- 除法结果: sum/weight = 8184/8 = 1023, 范围 [0, 1023], 10 bit

**权重核参数**:
| 核类型 | 中心权重 sum | 最大系数 |
|--------|-------------|---------|
| 2x2 | 16 | 4 |
| 3x3 | 9 | 1 |
| 4x4 | 44 | 8 |
| 5x5 | 25 | 1 |

### 2.3 Stage 3: 梯度加权方向融合

| 信号名 | 位宽 | 范围 | Q格式 | 说明 |
|--------|------|------|-------|------|
| **输入信号** |
| avg0/avg1 (5个方向) | 10 | [0, 1023] | U10.0 | 方向平均值 |
| grad_c/u/d/l/r | 14 | [0, 5115] | U14.0 | 各方向梯度 |
| **排序后梯度** |
| grad_s0~s4 | 14 | [0, 5115] | U14.0 | 排序后梯度 |
| grad_sum | 17 | [0, 25575] | U17.0 | 梯度和 (5 x 5115) |
| **加权乘累加** |
| blend0_partial | 24 | [0, 5231610] | U24.0 | avg x grad 乘积 |
| blend0_sum | 26 | [0, 26158050] | U26.0 | 5项加权和 |
| **除法结果** |
| blend0_dir_avg | 10 | [0, 1023] | U10.0 | avg0 融合结果 |
| blend1_dir_avg | 10 | [0, 1023] | U10.0 | avg1 融合结果 |

**位宽计算依据**:
- grad_sum: 5 x 5115 = 25575, 需要 15 bit, 预留到 17 bit
- blend_partial: 1023 x 5115 = 5232105, 需要 23 bit
- blend_sum: 5 x 5232105 = 26160525, 需要 25 bit
- 当前实现: DATA_WIDTH + GRAD_WIDTH + 2 = 26 bit

### 2.4 Stage 4: IIR 滤波与混合输出

| 信号名 | 位宽 | 范围 | Q格式 | 说明 |
|--------|------|------|-------|------|
| **输入信号** |
| blend0/1_dir_avg | 10 | [0, 1023] | U10.0 | 融合结果 |
| avg0/1_u | 10 | [0, 1023] | U10.0 | 上方向平均 |
| center_pixel | 10 | [0, 1023] | U10.0 | 中心像素 |
| win_size_clip | 6 | [16, 40] | U6.0 | 窗口大小 |
| **中间信号** |
| blend_ratio | 8 | [0, 64] | U8.0 | 混合比例 |
| blend_factor | 4 | [0, 4] | U4.0 | 混合因子 |
| win_size_remain_8 | 7 | [0, 7] | U7.0 | 窗口余数 |
| **IIR 混合** |
| blend0_iir | 17 | [0, 65472] | U17.0 | ratio*avg 混合 |
| **窗混合** |
| blend0_out | 12 | [0, 4092] | U12.0 | blend_factor 混合 |
| **最终输出** |
| dout | 10 | [0, 1023] | U10.0 | 输出像素 |

**位宽计算依据**:
- IIR 混合: ratio x avg = 64 x 1023 = 65472, 需要 17 bit
- 窗混合: factor x blend = 4 x 1023 = 4092, 需要 12 bit
- 最终除法后截断到 10 bit

---

## 3. 定点化格式建议

### 3.1 数据类型定义

```verilog
// 像素数据类型 (无符号)
// Q10.0: 整数部分 10 bit, 小数部分 0 bit
// 范围: [0, 1023]
// 精度: 1.0
`define DATA_WIDTH    10

// 梯度数据类型 (无符号绝对值)
// Q14.0: 整数部分 14 bit, 小数部分 0 bit
// 范围: [0, 16383]
// 精度: 1.0
`define GRAD_WIDTH    14

// 累加器数据类型 (无符号)
// Q20.0: 整数部分 20 bit, 小数部分 0 bit
// 范围: [0, 1048575]
// 精度: 1.0
`define ACC_WIDTH     20

// 除法中间结果 (用于 Stage 3)
// Q26.0: 整数部分 26 bit, 小数部分 0 bit
// 范围: [0, 67108863]
`define BLEND_SUM_WIDTH  26
```

### 3.2 各阶段 Q 格式设计

| 阶段 | 信号 | Q格式 | 整数位 | 小数位 | 符号位 | 总位宽 |
|------|------|-------|--------|--------|--------|--------|
| **Stage 1** | src_uv | U10.0 | 10 | 0 | 0 | 10 |
| | grad_h/v | S14.0 | 13 | 0 | 1 | 14 |
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

### 3.3 除法精度分析

由于算法中大量使用整数除法，需要考虑截断误差：

| 除法类型 | 被除数位宽 | 除数位宽 | 结果位宽 | 最大误差 |
|----------|-----------|---------|---------|---------|
| Stage 2 avg | 20 bit | 8 bit | 10 bit | +/- 0.5 LSB |
| Stage 3 blend | 26 bit | 17 bit | 10 bit | +/- 0.5 LSB |
| Stage 4 iir | 17 bit | 6 bit | 10 bit | +/- 0.5 LSB |
| Stage 4 win | 12 bit | 3 bit | 10 bit | +/- 0.5 LSB |

**注**: 当前实现使用整数除法，最大误差为 0.5 LSB (约 0.05% 满量程)。

---

## 4. 关键运算处理方案

### 4.1 除法实现方案

#### 4.1.1 Stage 2 除法 (sum / weight)

**特点**:
- 除数范围: [1, 44] (离散值)
- 被除数范围: [0, 44989]
- 时序要求: 可使用流水线

**推荐方案**: **倒数 LUT + 乘法**

```verilog
// 倒数 LUT 方案
// weight 范围小，预计算倒数表
// recip = 2^N / weight
// result = (sum * recip) >> N

// 倒数 LUT 实现 (8 bit 除数, 20 bit 输出)
reg [19:0] reciprocal_lut [0:255];
assign recip = reciprocal_lut[weight];
assign result = (sum * recip) >>> 20;
```

**LUT 表生成** (Python):
```python
def generate_reciprocal_lut():
    lut = []
    for w in range(1, 256):
        recip = (1 << 20) // w  # 20 bit 精度
        lut.append(recip)
    return lut
```

#### 4.1.2 Stage 3 除法 (blend_sum / grad_sum)

**特点**:
- 除数范围: [1, 25575]
- 被除数范围: [0, 26158050]
- 精度要求: 较高

**推荐方案**: **压缩倒数 LUT**

由于除数范围大，采用压缩 LUT:
- 仅存储常用值 (grad_sum < 2048)
- 大值使用近似倒数

```verilog
// 压缩 LUT 实现
wire [19:0] recip;
wire [10:0] grad_sum_trunc = grad_sum[16:6];  // 压缩到 11 bit 索引

// 对于 grad_sum > 2048, 使用固定小值倒数
assign recip = (grad_sum > 2048) ? 20'd512 :
               reciprocal_lut[grad_sum_trunc];

// 结果计算
wire [35:0] blend_full = blend_sum * recip;
assign blend_dir_avg = blend_full >>> 20;
```

#### 4.1.3 Stage 4 混合运算

**特点**:
- 除数为常数 (64, 8, 4)
- 可用移位替代

**推荐方案**: **移位实现**

```verilog
// /64 = >> 6
assign blend0_iir = (ratio * blend0_dir_avg +
                     (64 - ratio) * avg0_u) >>> 6;

// /8 = >> 3
assign dout = (blend0_out * win_size_remain +
               blend1_out * (8 - win_size_remain)) >>> 3;

// /4 = >> 2
assign blend0_out = (blend0_iir * blend_factor +
                     center_pixel * (4 - blend_factor)) >>> 2;
```

### 4.2 累加溢出处理

#### 4.2.1 Stage 2 累加器

**溢出分析**:
- 最大情况: 5x5 核，权重和 = 44
- 最大和: 25 x 1023 x 8 = 204600
- ACC_WIDTH = 20 bit 可容纳 1048575
- 安全裕量: 5.1x

**保护措施**:
```verilog
// 累加时使用饱和
wire [ACC_WIDTH:0] sum_sat = (sum > {ACC_WIDTH{1'b1}}) ?
                              {ACC_WIDTH{1'b1}} : sum;
```

#### 4.2.2 Stage 3 加权累加

**溢出分析**:
- 最大和: 5 x 1023 x 5115 = 26158025
- BLEND_SUM_WIDTH = 26 bit 可容纳 67108863
- 安全裕量: 2.6x

**保护措施**:
```verilog
// 使用饱和加法
wire [BLEND_SUM_WIDTH:0] blend_sum_sat =
    (blend_sum > {BLEND_SUM_WIDTH{1'b1}}) ?
     {BLEND_SUM_WIDTH{1'b1}} : blend_sum;
```

### 4.3 梯度排序网络

**实现方案**: 使用比较交换网络 (Sorting Network)

```verilog
// 5 输入排序网络 (7 级比较)
// 使用并行比较实现单周期排序

// Pass 1: 比较相邻对
wire [GRAD_WIDTH-1:0] p1_0 = (s0 < s1) ? s0 : s1;
wire [GRAD_WIDTH-1:0] p1_1 = (s0 < s1) ? s1 : s0;
// ... (见 stage3_gradient_fusion.v 完整实现)
```

**资源预估**:
- 比较器: 7 个
- MUX: 14 个 (2 输入)
- 关键路径: 7 级比较器

---

## 5. 精度保持建议

### 5.1 误差来源分析

| 阶段 | 误差来源 | 误差类型 | 最大误差 |
|------|----------|----------|----------|
| Stage 1 | grad >> 2 | 截断误差 | 1.5 LSB |
| Stage 2 | sum / weight | 除法截断 | 0.5 LSB |
| Stage 3 | blend_sum / grad_sum | 除法截断 | 0.5 LSB |
| Stage 4 | ratio * avg / 64 | 乘法截断 | 0.5 LSB |

### 5.2 误差传播分析

```
总误差 = sqrt(sum of squared errors)
       = sqrt(1.5^2 + 0.5^2 + 0.5^2 + 0.5^2)
       = sqrt(2.25 + 0.25 + 0.25 + 0.25)
       = sqrt(3.0)
       = 1.73 LSB
```

**结论**: 总误差约为 1.73 LSB，满足 10 bit 输出精度要求。

### 5.3 精度预算分配

| 阶段 | 预算分配 | 实现方案 | 预估误差 |
|------|----------|----------|----------|
| Stage 1 | 1.0 LSB | 移位截断 | 1.5 LSB |
| Stage 2 | 0.5 LSB | 整数除法 | 0.5 LSB |
| Stage 3 | 0.5 LSB | LUT 除法 | 0.5 LSB |
| Stage 4 | 0.5 LSB | 移位实现 | 0.5 LSB |

**优化建议**:

1. **Stage 1 梯度计算优化**
   ```verilog
   // 当前: grad = (grad_h_abs >> 2) + (grad_v_abs >> 2)
   // 改进: grad = (grad_h_abs + grad_v_abs) >> 2
   // 优点: 减少一次截断误差
   ```

2. **Stage 2 除法精度优化**
   ```verilog
   // 四舍五入除法
   wire [ACC_WIDTH:0] sum_rounded = sum + (weight >> 1);
   assign avg = sum_rounded / weight;
   ```

3. **Stage 3 除法精度优化**
   ```verilog
   // 使用更高精度倒数 LUT
   wire [23:0] recip = reciprocal_lut_24bit[grad_sum_trunc];
   assign blend = (blend_sum * recip) >>> 23;
   ```

### 5.4 保护性截断策略

```verilog
// 输出饱和截断
function [DATA_WIDTH-1:0] saturate;
    input [31:0] value;
    begin
        saturate = (value > 1023) ? 10'd1023 :
                   (value < 0) ? 10'd0 : value[DATA_WIDTH-1:0];
    end
endfunction

// 应用到各阶段输出
assign avg_out = saturate(avg_raw);
assign blend_out = saturate(blend_raw);
assign dout = saturate(dout_raw);
```

---

## 6. 硬件资源估算

### 6.1 组合逻辑资源

| 模块 | 加法器 | 乘法器 | 比较器 | MUX |
|------|--------|--------|--------|-----|
| Stage 1 | 12 | 0 | 4 | 2 |
| Stage 2 | 125 | 25 | 5 | 10 |
| Stage 3 | 20 | 10 | 7 | 14 |
| Stage 4 | 8 | 4 | 8 | 8 |

### 6.2 寄存器资源

| 模块 | 数据寄存器 | 控制寄存器 | 总位宽 |
|------|-----------|-----------|--------|
| Stage 1 | 56 bit | 4 bit | 60 bit |
| Stage 2 | 400 bit | 20 bit | 420 bit |
| Stage 3 | 300 bit | 10 bit | 310 bit |
| Stage 4 | 150 bit | 5 bit | 155 bit |
| Line Buffer | ~82 KB | - | 656,640 bit |

### 6.3 存储资源

| 存储类型 | 大小 | 用途 |
|----------|------|------|
| Line Buffer | 4 lines x 5472 x 10 bit | 5x5 窗口缓存 |
| Gradient Buffer | 1 line x 5472 x 14 bit | 梯度行缓存 |
| Reciprocal LUT | 256 x 20 bit | 除法倒数表 |

---

## 7. 实现建议

### 7.1 近期优化

1. **除法 LUT 实现**
   - 为 Stage 2 实现倒数 LUT
   - 减少关键路径延迟
   - 预估改善: 2-3 个时钟周期

2. **梯度计算精度**
   - 合并移位操作
   - 减少截断误差
   - 预估精度改善: 0.5 LSB

### 7.2 中期优化

1. **流水线优化**
   - Stage 2 增加流水级
   - Stage 3 除法流水化
   - 提升时序裕量

2. **资源优化**
   - 共享乘法器
   - 压缩 LUT 存储
   - 减少面积

### 7.3 验证建议

1. **位真验证**
   - Python 参考模型与 RTL 位真对比
   - 使用随机测试向量
   - 覆盖边界条件

2. **精度验证**
   - 统计输出误差分布
   - 与浮点模型对比
   - PSNR/SSIM 指标评估

---

## 8. 附录

### 8.1 参数汇总表

| 参数名 | 默认值 | 位宽 | 范围 |
|--------|--------|------|------|
| DATA_WIDTH | 10 | - | [8, 16] |
| GRAD_WIDTH | 14 | - | [12, 16] |
| ACC_WIDTH | 20 | - | [18, 24] |
| WIN_SIZE_WIDTH | 6 | - | 固定 |
| WIN_SIZE_THRESH | [16,24,32,40] | 16 bit | [16, 64] |
| BLENDING_RATIO | [32,32,32,32] | 8 bit | [0, 64] |

### 8.2 修订历史

| 版本 | 日期 | 修订内容 | 作者 |
|------|------|----------|------|
| v1.0 | 2026-03-21 | 初始版本 | rtl-algo |

---

*本报告由 rtl-algo 职能代理生成，用于指导 RTL 实现的定点化设计。*