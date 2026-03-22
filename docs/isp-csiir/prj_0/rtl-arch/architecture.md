# ISP-CSIIR 架构设计文档

## 文档信息
| 项目 | 内容 |
|------|------|
| 模块名称 | isp_csiir_top |
| 版本 | v2.2 |
| 作者 | rtl-arch |
| 创建日期 | 2026-03-22 |
| 更新日期 | 2026-03-22 |
| 状态 | M3 架构评审 |
| 目标约束 | 600MHz @ 12nm |

---

## 1. 设计目标与约束

### 1.1 性能目标

| 参数 | 目标值 | 说明 |
|------|--------|------|
| 目标工艺 | 12nm | 目标制造工艺节点 |
| 时钟频率 | 600 MHz | 高约束时序目标 |
| 时钟周期 | 1.67 ns | 单周期约束 |
| 关键路径目标 | < 1.4 ns | 预留时序余量 |
| 建立时间余量 | > 0.1 ns | 时序收敛要求 |
| 吞吐量 | 1 pixel/clock | 流水线吞吐 |

### 1.2 数据规格

| 参数 | 值 | 说明 |
|------|-----|------|
| 输入像素位宽 | 10-bit | 无符号，范围 0-1023 |
| 输出像素位宽 | 10-bit | 无符号，范围 0-1023 |
| 梯度位宽 | 14-bit | 无符号 |
| 累加器位宽 | 20-bit | 无符号 |
| 最大分辨率 | 8K (7680x4320) | 支持最大图像尺寸 |

### 1.3 工艺约束分析

**12nm 工艺时序特性：**

| 参数 | 典型值 | 说明 |
|------|--------|------|
| FO4 延迟 | ~15-20 ps | 单元延迟基准 |
| 可用组合逻辑深度 | ~70-80 FO4 | 预留 setup/hold 余量 |
| 加法器延迟 | 6-8 FO4/bit | 进位链延迟 |
| 乘法器延迟 | 25-35 FO4 | 10x10 位乘法 |

**600MHz 时序预算：**
```
时钟周期: 1.67 ns = 83-110 FO4
建立时间预留: 0.1 ns
时钟偏斜预留: 0.1 ns
可用组合逻辑: 1.47 ns = ~73-95 FO4
安全设计目标: 60-70 FO4 单级组合逻辑深度
```

---

## 2. 流水线划分决策

### 2.1 流水线总体架构

基于 600MHz @ 12nm 时序约束，重新规划流水线深度：

```
输入像素 → Line Buffer → Stage1 → Stage2 → Stage3 → Stage4 → 输出像素
              |            |          |          |          |
              v            v          v          v          v
           5x5窗口      梯度计算    方向平均    梯度融合    IIR混合
            2行+5列      5 cycles   8 cycles   6 cycles   5 cycles
```

**总流水线延迟**: 24 cycles (从 din_valid 到 dout_valid)

### 2.2 流水线深度决策依据

| 阶段 | 原深度 | 新深度 | 增加原因 |
|------|--------|--------|----------|
| Stage 1 | 4 cycles | 5 cycles | 梯度最大值计算拆分 |
| Stage 2 | 6 cycles | 8 cycles | 除法操作需 2 cycles |
| Stage 3 | 4 cycles | 6 cycles | 排序+乘累加拆分 |
| Stage 4 | 3 cycles | 5 cycles | IIR混合拆分为 3 级 |

**关键决策点：**

1. **Stage 2 除法拆分**: 600MHz 下整数除法无法在单周期完成，拆分为 2 cycles
2. **Stage 3 加权求和拆分**: 10 个乘累加操作拆分为两级流水
3. **Stage 4 IIR 混合拆分**: 三级混合操作拆分为独立流水级

---

## 3. 各阶段详细设计

### 3.1 Stage 1: 梯度计算与窗口大小确定 (5 cycles)

#### 3.1.1 流水线结构

```
Cycle 0: Sobel 卷积
    window[5x5] → row_sum (5个加法并行) → col_sum (5个加法并行)
    组合逻辑深度: ~20 FO4

Cycle 1: 梯度差分
    row_sum → grad_h_raw = row0_sum - row4_sum
    col_sum → grad_v_raw = col0_sum - col4_sum
    组合逻辑深度: ~10 FO4

Cycle 2: 绝对值与求和
    grad_h_raw → grad_h_abs
    grad_v_raw → grad_v_abs
    grad = (grad_h_abs + grad_v_abs) >> 2
    组合逻辑深度: ~15 FO4

Cycle 3: 梯度最大值
    grad_neighbor[3] → grad_max (横向3邻居比较)
    组合逻辑深度: ~15 FO4

Cycle 4: LUT 查表
    grad_max → win_size_clip (阈值比较链)
    组合逻辑深度: ~10 FO4
```

#### 3.1.2 关键数据位宽

| 信号 | 位宽 | Q格式 | 流水级 |
|------|------|-------|--------|
| row_sum | 13-bit | U13.0 | Cycle 0 |
| grad_h_raw | 14-bit | S14.0 | Cycle 1 |
| grad_h_abs | 14-bit | U14.0 | Cycle 2 |
| grad | 14-bit | U14.0 | Cycle 2 |
| grad_max | 14-bit | U14.0 | Cycle 3 |
| win_size_clip | 6-bit | U6.0 | Cycle 4 |

#### 3.1.3 关键路径分析

**最长路径**: Cycle 0 的 Sobel 卷积
- 5 行并行加法: 5 x (5 个加法) = 25 个加法
- 使用平衡加法树: log2(5) = 3 级
- 估算延迟: 3 x 6 FO4 = 18 FO4
- 时序裕量: 70 - 18 = 52 FO4 (充足)

### 3.2 Stage 2: 多尺度方向性平均 (8 cycles)

#### 3.2.1 流水线结构

```
Cycle 0-3: 窗口延迟对齐
    window[5x5] → 4 级延迟寄存器
    目的: 与 Stage 1 的 win_size_clip 对齐

Cycle 4: 核选择
    win_size_clip → kernel_select[3]
    组合逻辑: 阈值比较链，~8 FO4

Cycle 5: 加权求和 (第一级)
    window[5x5] × weight[核] → sum0_partial[5], sum1_partial[5]
    乘法: 10-bit × 4-bit = 14-bit
    加法树: 25 输入平衡树
    组合逻辑深度: ~35 FO4

Cycle 6: 加权求和 (第二级)
    sum_partial → sum0_c/u/d/l/r, sum1_c/u/d/l/r
    weight 求和: weight0_c/u/d/l/r, weight1_c/u/d/l/r
    组合逻辑深度: ~20 FO4

Cycle 7: 除法输出
    sum / weight → avg0_c/u/d/l/r, avg1_c/u/d/l/r
    除法: 迭代除法器 (基数 2, 10 位)
    组合逻辑深度: ~30 FO4 (2 级迭代)
```

#### 3.2.2 除法器设计

**迭代除法器方案:**

```verilog
// 基数 2 非恢复除法器
// 10 位商，单周期完成 2 位迭代
// 需要 5 个周期完成，此处采用压缩版 (2 cycles)

// Cycle 7a: 高 5 位商计算
// Cycle 7b: 低 5 位商计算 + 结果修正
```

**替代方案: 商近似除法**
```verilog
// 使用乘法近似除法
// result ≈ dividend × (1/divisor)
// 存储倒数 LUT 或 Newton-Raphson 迭代
```

#### 3.2.3 关键数据位宽

| 信号 | 位宽 | Q格式 | 流水级 |
|------|------|-------|--------|
| sum_partial | 14-bit | U14.0 | Cycle 5 |
| sum_c/u/d/l/r | 20-bit | U20.0 | Cycle 6 |
| weight_c/u/d/l/r | 8-bit | U8.0 | Cycle 6 |
| avg0/avg1 | 10-bit | U10.0 | Cycle 7 |

### 3.3 Stage 3: 梯度加权方向融合 (6 cycles)

#### 3.3.1 流水线结构

```
Cycle 0: 输入缓冲与梯度获取
    avg[10] + grad → 输入寄存器
    grad_u = grad_line_buf[pixel_x] (从行缓存读取)
    边界处理: grad_u = (row == 0) ? grad_c : grad_u
    组合逻辑深度: ~10 FO4

Cycle 1: 梯度排序网络 (第一级)
    grad_c/u/d/l/r → 比较交换网络
    Pass 1-3: 7 级比较网络
    组合逻辑深度: ~15 FO4

Cycle 2: 梯度排序网络 (第二级)
    Pass 4-7 完成排序
    输出: grad_s0 ≥ grad_s1 ≥ ... ≥ grad_s4
    组合逻辑深度: ~15 FO4

Cycle 3: 加权乘积 (第一级)
    avg0_s0-s4 × grad_s0-s4 → blend0_partial[5]
    avg1_s0-s4 × grad_s0-s4 → blend1_partial[5]
    乘法: 10-bit × 14-bit = 24-bit
    组合逻辑深度: ~30 FO4

Cycle 4: 加权求和 (第二级)
    blend_partial → blend0_sum, blend1_sum (平衡加法树)
    grad_s → grad_sum
    组合逻辑深度: ~20 FO4

Cycle 5: 除法输出
    blend_sum / grad_sum → blend0_dir_avg, blend1_dir_avg
    除法: 迭代除法器 (26-bit / 17-bit)
    组合逻辑深度: ~35 FO4
```

#### 3.3.2 梯度排序网络

**5 输入逆序排序网络设计:**

```
输入: g0, g1, g2, g3, g4

Pass 1: compare(g0,g1), compare(g2,g3)
Pass 2: compare(g1,g2), compare(g3,g4)
Pass 3: compare(g0,g2), compare(g1,g3)
Pass 4: compare(g2,g4), compare(g1,g2)
Pass 5: compare(g0,g1), compare(g3,g4)
Pass 6: compare(g1,g2), compare(g2,g3)
Pass 7: compare(g0,g1), compare(g3,g4)

输出: s0 ≥ s1 ≥ s2 ≥ s3 ≥ s4
```

**实现方式:** 分两级流水，Pass 1-4 在 Cycle 1，Pass 5-7 在 Cycle 2

#### 3.3.3 梯度行缓存设计

```verilog
// 梯度行缓存结构
// 容量: IMG_WIDTH × GRAD_WIDTH = 5472 × 14 = 76,608 bits

// 双缓冲结构
reg [GRAD_WIDTH-1:0] grad_line_buf_0 [0:IMG_WIDTH-1];  // 当前读
reg [GRAD_WIDTH-1:0] grad_line_buf_1 [0:IMG_WIDTH-1];  // 当前写

// 行切换时交换指针
wire grad_buf_sel;  // 行选择信号
assign grad_buf_sel = row_cnt[0];  // 奇偶行切换

// 写入: 当前行梯度
// 读取: 上一行梯度
```

### 3.4 Stage 4: IIR 滤波与混合输出 (5 cycles)

#### 3.4.1 流水线结构

```
Cycle 0: 输入缓冲
    blend0/1_dir_avg → 输入寄存器
    avg0/1_u = iir_line_buf[pixel_x] (从 IIR 行缓存读取)
    center_pixel → 输入寄存器
    win_size_clip → 输入寄存器
    组合逻辑深度: ~5 FO4

Cycle 1: 混合比例选择
    win_size_clip → blend_ratio[8]
    win_size_clip → blend_factor[3]
    win_size_remain_8 = win_size_clip % 8
    组合逻辑深度: ~10 FO4

Cycle 2: IIR 混合
    blend0_iir = (ratio × blend0 + (64-ratio) × avg0_u) / 64
    blend1_iir = (ratio × blend1 + (64-ratio) × avg1_u) / 64
    乘法: 8-bit × 10-bit = 18-bit
    加法: 18-bit + 18-bit = 19-bit
    除法: >> 6 (移位)
    组合逻辑深度: ~35 FO4

Cycle 3: 窗混合
    blend0_out = (blend0_iir × factor + center × (4-factor)) / 4
    blend1_out = (blend1_iir × factor + center × (4-factor)) / 4
    乘法: 10-bit × 2-bit = 12-bit
    组合逻辑深度: ~25 FO4

Cycle 4: 最终混合
    dout = (blend0_out × remainder + blend1_out × (8-remainder)) / 8
    乘法: 10-bit × 3-bit = 13-bit
    除法: >> 3 (移位)
    组合逻辑深度: ~20 FO4
```

#### 3.4.2 IIR 行缓存设计

**IIR 反馈特性分析:**

```
当前行处理:
    blend0_iir = f(blend0_current, avg0_u_prev_row)

反馈更新:
    输出像素 → 更新 src_uv 数组 → 影响后续 avg0_u

关键依赖:
    - avg0_u 需要从 IIR 行缓存读取
    - 输出需要写回 IIR 行缓存
    - 读写存在时序依赖
```

**IIR 行缓存架构:**

```verilog
// IIR 行缓存结构 (6 行架构)
// 用于存储 avg0_u, avg1_u, blend0_out, blend1_out 等

// 行缓存定义
reg [DATA_WIDTH-1:0] iir_avg0_u_line [0:IMG_WIDTH-1];   // avg0_u 存储
reg [DATA_WIDTH-1:0] iir_avg1_u_line [0:IMG_WIDTH-1];   // avg1_u 存储
reg [DATA_WIDTH-1:0] iir_blend0_line [0:IMG_WIDTH-1];   // blend0 输出
reg [DATA_WIDTH-1:0] iir_blend1_line [0:IMG_WIDTH-1];   // blend1 输出

// 读写时序
// 读取: Stage 4 Cycle 0 (组合逻辑读取)
// 写入: Stage 4 Cycle 4 (输出写回)
// 时序冲突: 无 (读写差 4 cycles)
```

#### 3.4.3 IIR 反馈路径处理

**反馈延迟分析:**

```
数据流:
    Stage 2 输出 avg0_u
    → Stage 3 传递 avg0_u
    → Stage 4 Cycle 0 读取 avg0_u
    → Stage 4 Cycle 2 IIR 混合
    → Stage 4 Cycle 4 输出 dout

反馈路径:
    输出 dout
    → 写回 IIR 行缓存
    → 下一行 Stage 2 使用
```

**实现方案:**

```verilog
// Stage 4 内部的 IIR 行缓存
module stage4_iir_blend (
    // 输入
    input  wire [DATA_WIDTH-1:0] blend0_dir_avg,
    input  wire [DATA_WIDTH-1:0] blend1_dir_avg,
    // ...

    // IIR 行缓存 (内部存储)
    output reg  [DATA_WIDTH-1:0] dout,
    output reg                   dout_valid
);

    // 内部 IIR 行缓存
    reg [DATA_WIDTH-1:0] avg0_u_buf [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] avg1_u_buf [0:IMG_WIDTH-1:0];

    // 读取上一行 avg_u
    wire [DATA_WIDTH-1:0] avg0_u_prev = avg0_u_buf[pixel_x];
    wire [DATA_WIDTH-1:0] avg1_u_prev = avg1_u_buf[pixel_x];

    // 行切换时更新行缓存
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset
        end else if (eol && dout_valid) begin
            // 行结束时，将当前 avg_u 存入缓存
            avg0_u_buf[pixel_x] <= avg0_u_current;
            avg1_u_buf[pixel_x] <= avg1_u_current;
        end
    end
endmodule
```

---

## 4. 模块层次设计

### 4.1 模块层次结构

```
isp_csiir_top
├── isp_csiir_reg_block          // APB 寄存器配置块
├── isp_csiir_line_buffer        // 像素行缓存 (5x5 窗口生成)
│   └── common_fifo [4]          // 4 行缓存 FIFO
├── stage1_gradient              // Stage 1: 梯度计算 (5 cycles)
│   ├── sobel_conv               // Sobel 卷积
│   ├── grad_diff                // 梯度差分
│   ├── grad_abs_sum             // 绝对值求和
│   ├── grad_max_finder          // 梯度最大值
│   └── win_size_lut             // 窗口大小 LUT
├── stage2_directional_avg       // Stage 2: 方向平均 (8 cycles)
│   ├── window_delay             // 窗口延迟对齐
│   ├── kernel_selector          // 核选择器
│   ├── weighted_sum             // 加权求和
│   └── div_unit                 // 除法单元
├── stage3_gradient_fusion       // Stage 3: 梯度融合 (6 cycles)
│   ├── grad_fetch               // 梯度获取
│   ├── sort_network             // 排序网络
│   ├── weighted_mul             // 加权乘积
│   ├── weighted_sum             // 加权求和
│   └── div_unit                 // 除法单元
└── stage4_iir_blend             // Stage 4: IIR 混合 (5 cycles)
    ├── input_buffer             // 输入缓冲
    ├── ratio_selector           // 比例选择
    ├── iir_mixer                // IIR 混合器
    ├── win_mixer                // 窗混合器
    ├── final_mixer              // 最终混合器
    └── iir_line_buffer          // IIR 行缓存
```

### 4.2 模块接口定义

#### 4.2.1 顶层模块接口

```verilog
module isp_csiir_top #(
    parameter IMG_WIDTH       = 5472,
    parameter IMG_HEIGHT      = 3076,
    parameter DATA_WIDTH      = 10,
    parameter GRAD_WIDTH      = 14,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    // 时钟与复位
    input  wire                      clk,
    input  wire                      rst_n,

    // APB 配置接口
    input  wire                      psel,
    input  wire                      penable,
    input  wire                      pwrite,
    input  wire [7:0]                paddr,
    input  wire [31:0]               pwdata,
    output reg  [31:0]               prdata,
    output wire                      pready,
    output wire                      pslverr,

    // 视频输入接口
    input  wire                      vsync,
    input  wire                      hsync,
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      din_valid,

    // 视频输出接口
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      dout_valid,
    output wire                      dout_vsync,
    output wire                      dout_hsync
);
```

#### 4.2.2 Stage 模块接口

**stage1_gradient:**
```verilog
module stage1_gradient #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 窗口输入
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, ..., window_4_4,
    input  wire                        window_valid,

    // 配置参数
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_3,

    // 输出
    output reg  [GRAD_WIDTH-1:0]       grad_h,
    output reg  [GRAD_WIDTH-1:0]       grad_v,
    output reg  [GRAD_WIDTH-1:0]       grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid,

    // 位置信息
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  center_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    center_y_out
);
```

**stage4_iir_blend:**
```verilog
module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter IMG_WIDTH      = 5472
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 输入数据
    input  wire [DATA_WIDTH-1:0]       blend0_dir_avg,
    input  wire [DATA_WIDTH-1:0]       blend1_dir_avg,
    input  wire                        stage3_valid,

    // 来自 Stage 2 的 avg_u (用于 IIR)
    input  wire [DATA_WIDTH-1:0]       avg0_u,
    input  wire [DATA_WIDTH-1:0]       avg1_u,

    // 配置参数
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2,
    input  wire [7:0]                  blending_ratio_3,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // 输出
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid,

    // 位置信息
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // 行控制
    input  wire                        sof,
    input  wire                        eol
);
```

---

## 5. 行缓存架构设计

### 5.1 行缓存总览

**修正说明 (v2.2)**：根据数据依赖分析确认，行缓存需求更新如下：

| 行缓存类型 | 原设计 | 修正后 | 位宽 | 容量 (8K) | 用途 |
|-----------|--------|--------|------|----------|------|
| 像素行缓存 | 4 行 | **5 行** | 10-bit | 273,600 bits | 5x5 窗口 + 梯度3x3可视域 + IIR 反馈写回 |
| 梯度行缓存 | 1 行 | **2 行** | 14-bit | 153,216 bits | 3x3 梯度窗 (FIFO) |
| avg_u 缓存 | 1 行 | **0 行** | - | - | 从当前 5x5 窗口直接计算，无需缓存 |
| **总计** | 6 行 | **7 行** | - | **426,816 bits** | - |

**关键修正**：
1. 像素行缓存：需要 **5 行**，因为梯度 3x3 可视域需要访问中心像素上下各2行
2. 梯度行缓存：需要 **2 行** FIFO 结构，支持 3x3 梯度窗（上一行、当前行、下一行）
3. avg_u：**无需缓存**，可从当前 5x5 窗口直接计算得出
4. IIR 反馈机制：**输出写回像素 line buffer**，复用存储作为下一轮迭代输入
5. 尾列处理：最后 3 列需要特殊写回逻辑

### 5.2 像素行缓存设计

**修正说明 (v2.2)**：像素行缓存需要 **5 行**，因为梯度 3x3 可视域需要访问中心像素上下各 2 行。

```verilog
// isp_csiir_line_buffer.v
// 5 行循环缓存架构

module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 输入
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    input  wire                        sof,
    input  wire                        eol,

    // 输出: 5x5 窗口
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, ..., window_4_4,
    output reg                         window_valid,
    output reg  [LINE_ADDR_WIDTH-1:0]  center_x,
    output reg  [12:0]                 center_y
);

    // 5 行循环缓存
    reg [DATA_WIDTH-1:0] line_mem_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_3 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_4 [0:IMG_WIDTH-1];

    // 行选择指针 (循环)
    reg [2:0] wr_line_ptr;  // 写入行指针 (0-4)
    reg [2:0] rd_line_ptr;  // 读取行指针 (0-4)

    // 列地址
    reg [LINE_ADDR_WIDTH-1:0] wr_col_ptr;
    reg [LINE_ADDR_WIDTH-1:0] rd_col_ptr;

    // 5x5 窗口移位寄存器
    reg [DATA_WIDTH-1:0] window_sr [0:4][0:4];  // 5x5 移位寄存器

    // 写入逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_line_ptr <= 0;
            wr_col_ptr <= 0;
        end else if (enable && din_valid) begin
            case (wr_line_ptr)
                3'd0: line_mem_0[wr_col_ptr] <= din;
                3'd1: line_mem_1[wr_col_ptr] <= din;
                3'd2: line_mem_2[wr_col_ptr] <= din;
                3'd3: line_mem_3[wr_col_ptr] <= din;
                3'd4: line_mem_4[wr_col_ptr] <= din;
            endcase

            // 更新指针
            if (eol) begin
                wr_line_ptr <= (wr_line_ptr == 3'd4) ? 3'd0 : wr_line_ptr + 1;
                wr_col_ptr <= 0;
            end else begin
                wr_col_ptr <= wr_col_ptr + 1;
            end
        end
    end

    // 窗口生成逻辑
    // ... (详见实现)

endmodule
```

### 5.3 梯度行缓存设计

**修正说明 (v2.1)**：根据数据依赖分析确认，需要 **2 行梯度缓存**。

**关键需求**：
- Stage 3 需要访问 3x3 梯度窗（上一行、当前行、下一行）
- 需要 2 行 FIFO 缓存支持 `grad_u` 和 `grad_d` 的访问

```verilog
// 2 行梯度 FIFO 缓存结构
// 位于 stage3_gradient_fusion 内部或顶层

// FIFO 结构 (2 行循环)
reg [GRAD_WIDTH-1:0] grad_fifo_0 [0:IMG_WIDTH-1];  // 行 j-1 梯度 (grad_u 来源)
reg [GRAD_WIDTH-1:0] grad_fifo_1 [0:IMG_WIDTH-1];  // 行 j+1 梯度 (grad_d 来源)

// FIFO 指针
reg fifo_wr_ptr;  // 写入指针 (交替)
reg fifo_rd_ptr;  // 读取指针 (交替)

// 数据流时序：
// Row j:
//   Stage1 输出 grad_j --> 写入 grad_fifo_0
//   Stage3 读取:
//     - grad_u = grad_fifo_1[x] (行 j-1)
//     - grad_c = Stage1 实时输出
//     - grad_d = grad_fifo_0[x] (行 j+1，从 Stage1 下一行写入)
//     - grad_l/r = 移位寄存器 (当前行横向邻居)
//
// Row j+1:
//   FIFO 交替，grad_fifo_0 成为 grad_u 来源
//   grad_fifo_1 成为新的 grad_d 写入位置

// 读取逻辑
wire [GRAD_WIDTH-1:0] grad_u = grad_fifo_1[pixel_x];  // 上一行梯度
wire [GRAD_WIDTH-1:0] grad_d = grad_fifo_0[pixel_x];  // 下一行梯度

// 写入逻辑
always @(posedge clk) begin
    if (stage1_valid) begin
        if (fifo_wr_ptr == 0)
            grad_fifo_0[pixel_x] <= grad;
        else
            grad_fifo_1[pixel_x] <= grad;
    end

    // 行切换时切换指针
    if (eol)
        fifo_wr_ptr <= ~fifo_wr_ptr;
end
```

**Stage 3 时序要求**：
- Stage 3 处理行 j 时，需要访问：
  - `grad_u`: 从 FIFO 读取上一行梯度
  - `grad_c`: 从 Stage 1 实时获取当前行梯度
  - `grad_d`: 从 FIFO 读取下一行梯度（由 Stage 1 延迟写入）
  - `grad_l/r`: 从当前行梯度的移位寄存器获取
- 2 行 FIFO 缓存确保数据可用性

### 5.4 IIR 反馈缓存设计

**修正说明 (v2.1)**：IIR 反馈通过**写回像素 line buffer** 实现，复用存储。

**IIR 反馈机制核心**：
- 输出值 `dout` 写回像素 line buffer
- 写回的数据作为下一轮迭代的输入使用
- 这是真正的 IIR 特性：输出反馈为输入

**算法伪代码**：
```
for (h=-2; h<=2; h++)
    src_uv(i, j+h) = blend_uv(i, j)
```

**写回逻辑分析**：

1. **相邻像素 5x5 窗数据重叠**：
   - 处理像素 (i, j) 时，输出写入 (i, j-2) 到 (i, j+2) 位置
   - 存在数据重叠，可优化写回量

2. **行扫描写回量**：
   - **常规像素**：只需写回 5x1 像素
   - **尾列像素**（最后 3 列）：需要写回 5x3 大小像素

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

    // IIR 反馈写回
    // 写回窗口中心列的上下相邻列
    if (dout_valid && iir_writeback_en) begin
        // 写回范围: [i-2, i+2]
        for (int h = -2; h <= 2; h++) begin
            if ((pixel_x + h) >= 0 && (pixel_x + h) < IMG_WIDTH) begin
                pixel_line_buf[iir_wr_ptr][pixel_x + h] <= dout;
            end
        end
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
    - dout 写回 pixel_line_buf (影响后续行的处理窗口)

  Row j+2:
    - 读取的窗口可能包含 Row j 的输出结果
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
  - 或使用时序错开 (写回延迟处理)
```

**avg_u 缓存 (已取消)**：

**修正说明 (v2.2)**：avg_u 可从当前 5x5 窗口直接计算，**无需单独缓存**。

```verilog
// avg_u 直接从当前 5x5 窗口计算
// 不需要额外的行缓存

// Stage 2 计算 avg_u 的方式:
// avg_u = 方向平均的上方向结果
// 可直接从 5x5 窗口中的上方行像素计算得出

// 实现逻辑:
wire [DATA_WIDTH-1:0] window_row_0 = {window_0_0, window_0_1, window_0_2, window_0_3, window_0_4};
// avg_u 可从 window_row_0 计算得出，无需额外缓存

// 优势:
// 1. 减少存储资源 (~54,720 bits)
// 2. 简化设计复杂度
// 3. 消除读写冲突风险
```

### 5.5 尾列特殊处理

**尾列定义**：图像最后 3 列 (列 W-3, W-2, W-1)

**尾列写回特点**：

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

**RTL 实现**：

```verilog
// 尾列检测
wire is_tail_col = (pixel_x >= IMG_WIDTH - 3);

// 写回宽度控制
wire [2:0] writeback_width = is_tail_col ? (IMG_WIDTH - pixel_x + 2) : 3'd5;

// 写回地址计算
wire [LINE_ADDR_WIDTH-1:0] wb_start_col = (pixel_x < 2) ? 0 : (pixel_x - 2);
wire [LINE_ADDR_WIDTH-1:0] wb_end_col = (pixel_x + 2 >= IMG_WIDTH) ? (IMG_WIDTH - 1) : (pixel_x + 2);

// 尾列特殊处理
always @(posedge clk) begin
    if (dout_valid && iir_writeback_en) begin
        if (is_tail_col) begin
            // 尾列特殊写回逻辑
            for (int h = 0; h < writeback_width; h++) begin
                pixel_line_buf[iir_wr_ptr][wb_start_col + h] <= dout;
            end
        end else begin
            // 常规写回
            for (int h = -2; h <= 2; h++) begin
                pixel_line_buf[iir_wr_ptr][pixel_x + h] <= dout;
            end
        end
    end
end
```

**存储容量对比**：

| 项目 | 原设计 | 修正后 | 说明 |
|-----|--------|--------|------|
| 像素行缓存 | 4 行 | **5 行** (复用 IIR 写回) | 梯度 3x3 可视域需求 |
| 梯度行缓存 | 1 行 | **2 行** | 支持 3x3 梯度窗 |
| avg_u 缓存 | 1 行 | **0 行** | 从 5x5 窗口直接计算 |
| **总计** | 6 行 | **7 行** | - |

---

## 6. IIR 反馈路径处理方案

### 6.1 IIR 反馈机制

**重要说明 (v2.1)**：IIR 反馈通过**输出写回像素 line buffer** 实现。

**算法原始定义**：
```
for (h=-2; h<=2; h++)
    src_uv(i, j+h) = blend_uv(i, j)
```

**硬件实现方案**：

1. **写回位置**：像素 line buffer
2. **写回时机**：输出 dout 有效时
3. **写回范围**：窗口中心列及其相邻列

### 6.2 数据依赖关系

**修正后的数据依赖关系:**

```
行 N:
    - 处理输入窗口 (可能包含之前行的输出结果)
    - 生成输出 dout_N
    - dout_N 写回像素 line buffer

行 N+2:
    - 处理输入窗口 (可能包含行 N 的输出结果)
    - 实现 IIR 反馈特性
```

**关键时序点:**

| 事件 | 时序位置 | 说明 |
|------|----------|------|
| 窗口读取 | Stage 1 Cycle 0 | 从像素 line buffer 读取 5x5 窗口 |
| IIR 写回 | Stage 4 Cycle 4 | 输出写回像素 line buffer |
| 反馈生效 | 后续行处理 | 写回数据影响后续处理窗口 |

### 6.3 行缓存时序对齐

**修正后的时序图**:

```
像素流 (逐行):
Row 0: din → ... → dout_0 → 写回 line buffer
Row 1: din → ... → dout_1 → 写回 line buffer
Row 2: din → ... → dout_2 → 写回 line buffer
        (读取的窗口可能包含 Row 0 的输出结果)

IIR 反馈延迟: 约 2 行
```

### 6.4 行首/尾处理

**第一行特殊情况:**

```verilog
// 第一行没有之前的 IIR 反馈数据，正常处理
wire is_first_row = (row_cnt < 2);
// 第一、二行读取原始输入数据
```

**尾列特殊处理:**

```verilog
// 尾列 = 最后 3 列
wire is_tail_col = (pixel_x >= IMG_WIDTH - 3);

// 尾列写回范围调整
wire [2:0] writeback_width = is_tail_col ? (IMG_WIDTH - pixel_x + 2) : 3'd5;
```

### 6.5 反馈路径时序约束

**时序要求:**

```
Stage 4 输出 dout
→ 写回像素 line buffer
→ 后续行读取时使用
→ 时序关系: 相差约 2 行时间 (2 x IMG_WIDTH cycles)
→ 需要处理读写冲突
```

**读写冲突解决方案:**

```verilog
// 方案 1: 双端口 SRAM
// 使用双端口存储器，一端口读，一端口写

// 方案 2: 时序错开
// 写回操作延迟到行末进行
// 避免与窗口读取冲突

// 方案 3: 写缓存
// 使用写缓存暂存 IIR 写回数据
// 在合适的时机写入 line buffer
```

---

## 7. 寄存器位宽定义

### 7.1 全局参数定义

```verilog
// isp_csiir_defines.vh

// 数据位宽定义
`define DATA_WIDTH        10
`define GRAD_WIDTH        14
`define ACC_WIDTH         20
`define BLEND_SUM_WIDTH   26
`define WIN_SIZE_WIDTH    6

// 图像尺寸
`define IMG_WIDTH         5472
`define IMG_HEIGHT        3076
`define LINE_ADDR_WIDTH   14
`define ROW_CNT_WIDTH     13

// 流水线深度
`define STAGE1_DEPTH      5
`define STAGE2_DEPTH      8
`define STAGE3_DEPTH      6
`define STAGE4_DEPTH      5
`define TOTAL_LATENCY     24  // 从 din_valid 到 dout_valid
```

### 7.2 各阶段寄存器位宽

**Stage 1:**
```verilog
// Cycle 0: Sobel 卷积
reg [12:0] row0_sum, row1_sum, row2_sum, row3_sum, row4_sum;  // 13-bit
reg [12:0] col0_sum, col1_sum, col2_sum, col3_sum, col4_sum;  // 13-bit

// Cycle 1: 梯度差分
reg signed [13:0] grad_h_raw, grad_v_raw;  // 14-bit signed

// Cycle 2: 绝对值求和
reg [13:0] grad_h_abs, grad_v_abs;  // 14-bit unsigned
reg [13:0] grad_sum;                // 14-bit

// Cycle 3: 梯度最大值
reg [13:0] grad_max;                // 14-bit

// Cycle 4: LUT 输出
reg [13:0] grad_out;                // 14-bit
reg [5:0]  win_size_clip;           // 6-bit
```

**Stage 2:**
```verilog
// Cycle 5: 加权求和
reg [19:0] sum0_c, sum0_u, sum0_d, sum0_l, sum0_r;  // 20-bit
reg [19:0] sum1_c, sum1_u, sum1_d, sum1_l, sum1_r;  // 20-bit
reg [7:0]  weight0_c, weight0_u, weight0_d, weight0_l, weight0_r;  // 8-bit
reg [7:0]  weight1_c, weight1_u, weight1_d, weight1_l, weight1_r;  // 8-bit

// Cycle 7: 除法输出
reg [9:0]  avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;  // 10-bit
reg [9:0]  avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;  // 10-bit
```

**Stage 3:**
```verilog
// Cycle 3: 加权乘积
reg [23:0] blend0_partial [0:4];  // 24-bit
reg [23:0] blend1_partial [0:4];  // 24-bit

// Cycle 4: 加权求和
reg [25:0] blend0_sum, blend1_sum;  // 26-bit
reg [16:0] grad_sum;                // 17-bit

// Cycle 5: 除法输出
reg [9:0]  blend0_dir_avg, blend1_dir_avg;  // 10-bit
```

**Stage 4:**
```verilog
// Cycle 1: 比例选择
reg [7:0]  blend_ratio;     // 8-bit
reg [2:0]  blend_factor;    // 3-bit
reg [2:0]  win_remain;      // 3-bit

// Cycle 2: IIR 混合
reg [16:0] blend0_iir, blend1_iir;  // 17-bit

// Cycle 3: 窗混合
reg [11:0] blend0_out, blend1_out;  // 12-bit

// Cycle 4: 最终输出
reg [9:0]  dout;            // 10-bit
```

---

## 8. 设计约束与优化

### 8.1 时序约束

```tcl
# 时钟约束
create_clock -period 1.67 [get_ports clk]

# 输入延迟
set_input_delay -clock clk 0.3 [get_ports din*]
set_input_delay -clock clk 0.3 [get_ports vsync]
set_input_delay -clock clk 0.3 [get_ports hsync]

# 输出延迟
set_output_delay -clock clk 0.3 [get_ports dout*]

# 行缓存多周期路径
set_multicycle_path 2 -to [get_cells line_mem_*]

# 除法器多周期路径
set_multicycle_path 2 -to [get_cells -hier *div_*]
```

### 8.2 面积优化策略

1. **行缓存共享**: 像素行缓存使用循环指针，减少数据复制
2. **乘法器复用**: Stage 2/3 的乘法器可考虑时分复用
3. **除法器优化**: 使用迭代除法器减少面积

### 8.3 功耗优化策略

1. **时钟门控**: 各阶段内部使用时钟门控
2. **数据门控**: 无效数据时不切换寄存器
3. **行缓存低功耗**: 使用低功耗 SRAM

---

## 9. 资源估算

### 9.1 存储资源

**修正后的存储资源估算 (v2.2)**:

| 资源类型 | 原设计 | 修正后 | 说明 |
|----------|--------|--------|------|
| 像素行缓存 | 218,880 bits | **273,600 bits** | 5 行 x 5472 x 10-bit (复用 IIR 写回) |
| 梯度行缓存 | 76,608 bits | **153,216 bits** | 2 行 x 5472 x 14-bit |
| avg_u 缓存 | 54,720 bits | **0 bits** | 从 5x5 窗口直接计算，无需缓存 |
| **总计** | **350,208 bits** | **426,816 bits** | 像素缓存增加，avg_u 取消 |

### 9.2 逻辑资源

| 资源类型 | 预估用量 | 说明 |
|----------|----------|------|
| 组合逻辑 | ~25,000 LUTs | 四级流水线 + 深度流水 |
| 寄存器 | ~20,000 FFs | 深度流水增加寄存器 |
| 乘法器 | ~15 个 | 可复用 |
| 除法器 | 3 个 | 迭代除法器 |

---

## 10. 附录

### 10.1 参考文献

- docs/isp-csiir/prj_0/rtl-std/spec.md - 需求规格文档
- docs/isp-csiir/prj_0/rtl-algo/bitwidth_analysis.md - 位宽分析报告（含数据依赖分析）
- docs/isp-csiir/prj_0/rtl-arch/isp-csiir-arch-evaluation.md - 架构评估文档

### 10.2 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-22 | rtl-arch | 初始版本 (200MHz) |
| v2.0 | 2026-03-22 | rtl-arch | 更新为 600MHz 设计 |
| v2.1 | 2026-03-22 | rtl-algo/rtl-arch | 修正行缓存为 7 行，明确 IIR 写回机制 |
| v2.2 | 2026-03-22 | rtl-pm/rtl-arch | 修正像素行缓存为 5 行，取消 avg_u 缓存 |