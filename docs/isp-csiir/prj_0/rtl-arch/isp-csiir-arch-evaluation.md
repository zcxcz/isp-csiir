# ISP-CSIIR 流水线架构评估报告

## 文档信息
| 项目 | 内容 |
|------|------|
| 项目名称 | ISP-CSIIR 图像信号处理核 |
| 文档版本 | v1.0 |
| 评估日期 | 2026-03-21 |
| 评估者 | rtl-arch 架构设计代理 |

---

## 1. 流水线架构分析

### 1.1 四阶段流水线概述

ISP-CSIIR 采用四阶段流水线架构，各阶段功能明确，数据流清晰。

```
+----------------+    +--------------------+    +--------------------+    +------------------+
|   Stage 1      |    |     Stage 2        |    |     Stage 3        |    |     Stage 4      |
|   梯度计算      | => |   方向性平均        | => |   梯度融合          | => |   IIR 滤波混合   |
|   窗口大小确定   |    |   多尺度核选择      |    |   加权融合          |    |   最终输出       |
+----------------+    +--------------------+    +--------------------+    +------------------+
     4 cycles              6 cycles                 4 cycles                4 cycles
```

### 1.2 各阶段详细分析

#### Stage 1: 梯度计算与窗口大小确定

**功能描述：**
- 5x5 Sobel 滤波窗进行梯度计算
- 计算 grad_h（水平梯度）和 grad_v（垂直梯度）
- 计算综合梯度 grad = |grad_h|/5 + |grad_v|/5
- 基于梯度 LUT 确定窗口大小 win_size_clip

**流水线延迟：** 4 cycles

**流水线级结构：**
| 级数 | 功能 | 组合逻辑描述 |
|------|------|-------------|
| S1 | Sobel 卷积 | row0_sum, row4_sum, col0_sum, col4_sum 计算 |
| S2 | 绝对值与除法 | grad_h_abs, grad_v_abs, grad_sum 计算 |
| S3 | 梯度最大值 | 横向 3 邻居梯度最大值计算 |
| S4 | LUT 查表 | win_size_clip 确定，边界裁剪 |

**关键数据路径：**
```
window[5x5] → grad_h/grad_v → grad → win_size_clip
```

**延迟对齐：**
- 需要 5x5 窗口数据（来自行缓存）
- 输出对齐：center_x_out, center_y_out 与 stage1_valid 同步

#### Stage 2: 多尺度方向性平均

**功能描述：**
- 根据 win_size_clip 选择核尺寸（2x2/3x3/4x4/5x5）
- 计算 5 个方向（中心/上/下/左/右）的加权平均
- 输出 avg0_* 和 avg1_* 两组平均值（共 10 个值）

**流水线延迟：** 6 cycles

**流水线级结构：**
| 级数 | 功能 | 关键操作 |
|------|------|----------|
| S1-S4 | 窗口延迟 | 4 级窗口数据延迟，对齐 Stage 1 输出 |
| S5 | 核选择与求和 | 根据 win_size 选择核，计算加权 sum 和 weight |
| S6 | 除法输出 | sum/weight 得到 avg0/avg1 各方向平均值 |

**关键数据路径：**
```
window[5x5] + win_size → kernel_select → sum + weight → avg0/avg1 (10 values)
```

**核选择逻辑：**
| win_size 范围 | avg0 核 | avg1 核 |
|---------------|---------|---------|
| < 16 | zeros | 2x2 |
| 16-24 | 2x2 | 3x3 |
| 24-32 | 3x3 | 4x4 |
| 32-40 | 4x4 | 5x5 |
| >= 40 | 5x5 | zeros |

#### Stage 3: 梯度加权方向融合

**功能描述：**
- 获取 5 个方向的梯度（grad_c/u/d/l/r）
- 对梯度进行逆序排序
- 加权融合：blend = Σ(avg * grad) / Σ(grad)

**流水线延迟：** 4 cycles

**流水线级结构：**
| 级数 | 功能 | 关键操作 |
|------|------|----------|
| S1 | 输入缓冲与梯度获取 | 从行缓存读取上一行梯度，边界处理 |
| S2 | 梯度排序 | 7 级比较网络完成 5 数排序 |
| S3 | 加权求和 | blend0_sum, blend1_sum, grad_sum 计算 |
| S4 | 除法输出 | blend0_dir_avg, blend1_dir_avg 输出 |

**关键数据路径：**
```
avg[10] + grad[5] → sort → weighted_sum → division → blend0/blend1
```

**跨行数据依赖：**
- grad_u（上邻梯度）需要从行缓存读取
- 需要梯度行缓存：grad_line_buf[IMG_WIDTH]

#### Stage 4: IIR 滤波与混合输出

**功能描述：**
- 水平 IIR 混合：blend_iir = ratio * blend + (64-ratio) * avg_u
- 窗混合：blend_win = blend_iir * factor + center * (4-factor)
- 最终混合：dout = blend0 * remainder + blend1 * (8-remainder)

**流水线延迟：** 4 cycles

**流水线级结构：**
| 级数 | 功能 | 关键操作 |
|------|------|----------|
| S1 | 输入缓冲 | 保存 blend0/1, avg_u, win_size 等 |
| S2 | IIR 混合 | 计算 blend0_iir_avg, blend1_iir_avg |
| S3 | 窗混合 | 应用 blend_factor 计算 blend0/1_out |
| S4 | 最终输出 | win_size_remain_8 加权输出 |

**关键数据路径：**
```
blend0/1 + avg_u → IIR_blend → win_blend → final_blend → dout
```

### 1.3 总流水线延迟分析

| 阶段 | 延迟 (cycles) | 输入有效信号 | 输出有效信号 |
|------|---------------|-------------|-------------|
| 行缓存 | 2 行 + 5 列 | din_valid | window_valid |
| Stage 1 | 4 | window_valid | stage1_valid |
| Stage 2 | 6 | stage1_valid | stage2_valid |
| Stage 3 | 4 | stage2_valid | stage3_valid |
| Stage 4 | 4 | stage3_valid | dout_valid |
| **总计** | **~18 cycles** | - | - |

**实际总延迟：** 约 17-18 cycles（行缓存延迟 + 各阶段流水线深度）

### 1.4 吞吐量分析

**设计目标：** 每周期输出 1 个像素

**吞吐量评估：**
- 流水线设计为无气泡运行
- 输入速率 = 输出速率（1 pixel/cycle）
- 满足实时处理需求

**瓶颈分析：**
- Stage 2 的除法操作是关键路径
- 当前使用直接整数除法，可考虑使用 DSP 或迭代除法器优化

### 1.5 流水线依赖关系

```
                    +------------------+
                    |   Line Buffer    |
                    |   (5x5 window)   |
                    +--------+---------+
                             |
                             v
+--------+  window_valid  +--+---+
| Stage1 +---------------->| Stage|
+---+----+                 |  1   |
    |                      +--+---+
    | win_size_clip           |
    | grad                    v
    |                    +----+----+
    +------------------->| Stage   |
                         |  2      |
                         +----+----+
                              |
                              v
+--------+  stage2_valid +----+----+
| Delay  +-------------->| Stage   |
| Chain  |  avg          |  3      |
| (grad) |               +----+----+
+--------+                    |
                              v
                         +----+----+
                         | Stage   |
                         |  4      |
                         +----+----+
                              |
                              v
                         +----+----+
                         | Output  |
                         +---------+
```

**跨阶段数据依赖：**
1. Stage 2 需要 Stage 1 的 win_size_clip（用于核选择）
2. Stage 3 需要 Stage 1 的 grad（需要延迟链对齐）
3. Stage 4 需要 Stage 2 的 avg_u（用于 IIR 反馈）

---

## 2. 模块划分建议

### 2.1 模块层次结构

```
isp_csiir_top
├── isp_csiir_reg_block          // 寄存器配置块
├── isp_csiir_line_buffer        // 行缓存（5x5 窗口生成）
├── stage1_gradient              // Stage 1: 梯度计算
├── stage2_directional_avg       // Stage 2: 方向性平均
├── stage3_gradient_fusion       // Stage 3: 梯度融合
└── stage4_iir_blend             // Stage 4: IIR 混合输出
```

### 2.2 各模块职责边界

#### 2.2.1 isp_csiir_reg_block（寄存器配置块）

| 项目 | 描述 |
|------|------|
| 功能 | APB 接口寄存器配置 |
| 输入 | APB 总线信号 |
| 输出 | 图像尺寸、阈值参数、使能信号 |
| 接口类型 | APB Slave |
| 地址宽度 | 8-bit |
| 数据宽度 | 32-bit |

**寄存器列表：**
| 地址 | 名称 | 描述 |
|------|------|------|
| 0x00 | PIC_WIDTH_M1 | 图像宽度 - 1 |
| 0x04 | PIC_HEIGHT_M1 | 图像高度 - 1 |
| 0x08 | WIN_SIZE_THRESH0-3 | 窗口大小阈值 |
| 0x18 | BLENDING_RATIO_0-3 | IIR 混合比例 |
| 0x28 | WIN_SIZE_CLIP_Y_0-3 | 梯度裁剪阈值 |
| 0x38 | ENABLE | 模块使能 |
| 0x3C | BYPASS | 旁路模式 |

#### 2.2.2 isp_csiir_line_buffer（行缓存模块）

| 项目 | 描述 |
|------|------|
| 功能 | 生成 5x5 滑动窗口 |
| 输入 | din, din_valid, sof, eol |
| 输出 | window[5x5], window_valid, window_center_x/y |
| 行缓存数量 | 4 行 |
| 存储容量 | 4 × IMG_WIDTH × DATA_WIDTH bits |

**接口定义：**
```verilog
module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire                      sof,
    input  wire                      eol,
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      din_valid,
    output wire [DATA_WIDTH-1:0]     window_0_0 ... window_4_4,  // 25 个输出
    output reg                       window_valid,
    output wire [LINE_ADDR_WIDTH-1:0] window_center_x,
    output wire [ROW_CNT_WIDTH-1:0]   window_center_y,
    input  wire [1:0]                boundary_mode
);
```

#### 2.2.3 stage1_gradient（梯度计算模块）

| 项目 | 描述 |
|------|------|
| 功能 | Sobel 梯度计算、窗口大小确定 |
| 输入 | window[5x5], window_valid, 配置参数 |
| 输出 | grad_h, grad_v, grad, win_size_clip, stage1_valid |
| 流水线深度 | 4 cycles |

**接口定义：**
```verilog
module stage1_gradient #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter PIC_WIDTH_BITS  = 14,
    parameter PIC_HEIGHT_BITS = 13
)(
    input  wire                        clk, rst_n, enable,
    input  wire [DATA_WIDTH-1:0]       window_0_0 ... window_4_4,
    input  wire                        window_valid,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0-3,
    input  wire [7:0]                  win_size_clip_sft_0-3,
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x, pixel_y,
    output reg  [GRAD_WIDTH-1:0]       grad_h, grad_v, grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid,
    output reg  [PIC_WIDTH_BITS-1:0]   center_x_out,
    output reg  [PIC_HEIGHT_BITS-1:0]  center_y_out
);
```

#### 2.2.4 stage2_directional_avg（方向性平均模块）

| 项目 | 描述 |
|------|------|
| 功能 | 多尺度方向性平均计算 |
| 输入 | window[5x5], win_size_clip, stage1_valid |
| 输出 | avg0_c/u/d/l/r, avg1_c/u/d/l/r, stage2_valid |
| 流水线深度 | 6 cycles |

**接口定义：**
```verilog
module stage2_directional_avg #(
    parameter DATA_WIDTH     = 10,
    parameter ACC_WIDTH      = 20,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                        clk, rst_n, enable,
    input  wire [DATA_WIDTH-1:0]       window_0_0 ... window_4_4,
    input  wire                        window_valid,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire                        stage1_valid,
    input  wire [15:0]                 win_size_thresh0-3,
    output reg  [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    output reg  [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    output reg                         stage2_valid,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_out,
    input  wire [13:0]                 pixel_x_in,
    input  wire [12:0]                 pixel_y_in,
    output reg  [13:0]                 pixel_x_out,
    output reg  [12:0]                 pixel_y_out
);
```

#### 2.2.5 stage3_gradient_fusion（梯度融合模块）

| 项目 | 描述 |
|------|------|
| 功能 | 梯度排序、加权融合 |
| 输入 | avg[10], grad, stage2_valid |
| 输出 | blend0_dir_avg, blend1_dir_avg, stage3_valid |
| 流水线深度 | 4 cycles |
| 内部存储 | 梯度行缓存（4096 × 14-bit） |

**接口定义：**
```verilog
module stage3_gradient_fusion #(
    parameter DATA_WIDTH      = 10,
    parameter GRAD_WIDTH      = 14,
    parameter PIC_WIDTH_BITS  = 14,
    parameter PIC_HEIGHT_BITS = 13
)(
    input  wire                        clk, rst_n, enable,
    input  wire [DATA_WIDTH-1:0]       avg0_c-u-r, avg1_c-u-r,  // 10 个输入
    input  wire                        stage2_valid,
    input  wire [GRAD_WIDTH-1:0]       grad, grad_h, grad_v,
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x, pixel_y,
    input  wire [GRAD_WIDTH-1:0]       grad_instant,
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x_instant, pixel_y_instant,
    input  wire                        stage1_valid,
    input  wire [DATA_WIDTH-1:0]       center_pixel_in,
    input  wire [5:0]                  win_size_clip_in,
    output reg  [DATA_WIDTH-1:0]       blend0_dir_avg, blend1_dir_avg,
    output reg                         stage3_valid,
    output reg  [DATA_WIDTH-1:0]       avg0_u_out, avg1_u_out,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [5:0]                  win_size_clip_out
);
```

#### 2.2.6 stage4_iir_blend（IIR 混合输出模块）

| 项目 | 描述 |
|------|------|
| 功能 | IIR 滤波、最终输出混合 |
| 输入 | blend0/1_dir_avg, avg_u, win_size_clip, stage3_valid |
| 输出 | dout, dout_valid |
| 流水线深度 | 4 cycles |

**接口定义：**
```verilog
module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                        clk, rst_n, enable,
    input  wire [DATA_WIDTH-1:0]       blend0_dir_avg, blend1_dir_avg,
    input  wire                        stage3_valid,
    input  wire [GRAD_WIDTH-1:0]       grad_h, grad_v,
    input  wire [DATA_WIDTH-1:0]       avg0_u, avg1_u,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [7:0]                  blending_ratio_0-3,
    input  wire [15:0]                 win_size_thresh0-3,
    input  wire [DATA_WIDTH-1:0]       center_pixel,
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid,
    output reg  [13:0]                 pixel_x_out,
    output reg  [12:0]                 pixel_y_out
);
```

### 2.3 模块间数据流

```
                            配置接口 (APB)
                                 |
                                 v
+-------------------------------------------------------------------------+
|                          isp_csiir_top                                   |
|                                                                          |
|  +---------------+      +----------------+      +------------------+    |
|  | reg_block     |----->| 所有阶段模块    |      |                  |    |
|  +---------------+      +----------------+      |                  |    |
|                                                  |                  |    |
|  +---------------+      +----------------+      +----------------+  |    |
|  | line_buffer   |----->| stage1_gradient|--+-->| stage2_        |  |    |
|  |               |      |                |  |   | directional_avg|  |    |
|  +---------------+      +----------------+  |   +--------+-------+  |    |
|           ^                                 |            |          |    |
|           |                                 |            v          |    |
|           |                                 |   +----------------+  |    |
|           |  +------------------------------+   | stage3_        |  |    |
|           |  |                                  | gradient_fusion|  |    |
|           |  |  +-------------------------------+--------+-------+  |    |
|           |  |  |                                        |          |    |
|           |  |  |   +------------------------------------+          |    |
|           |  |  |   |                                               |    |
|           |  |  |   v                                               |    |
|           |  |  |  +------------------+                             |    |
|           |  |  |  | stage4_iir_blend |                             |    |
|           |  |  |  +--------+---------+                             |    |
|           |  |  |           |                                       |    |
|  din --->-+--+--+-----------+------------------------------------->--+--->|
|              |              | dout                                   |    |
|              |              v                                        |    |
|              |         +----------+                                  |    |
|              +-------->| Bypass   |--------------------------------->+    |
|                        | Path     |  din_delay[17]                   |    |
|                        +----------+                                  |    |
+-------------------------------------------------------------------------+
```

---

## 3. 接口时序设计

### 3.1 输入视频接口

| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| clk | input | 1 | 系统时钟 |
| rst_n | input | 1 | 异步复位，低有效 |
| vsync | input | 1 | 垂直同步 |
| hsync | input | 1 | 水平同步 |
| din | input | DATA_WIDTH | 输入像素数据 |
| din_valid | input | 1 | 输入数据有效 |

**时序要求：**
- din 与 din_valid 同步
- vsync/hsync 为高电平有效脉冲
- sof（帧起始）由 vsync 上升沿检测
- eol（行结束）由 hsync 上升沿或列计数器检测

### 3.2 输出视频接口

| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| dout | output | DATA_WIDTH | 输出像素数据 |
| dout_valid | output | 1 | 输出数据有效 |
| dout_vsync | output | 1 | 输出垂直同步 |
| dout_hsync | output | 1 | 输出水平同步 |

**输出延迟：**
- 流水线总延迟约 17-18 cycles
- bypass 模式下延迟 17 cycles（数据对齐）

### 3.3 APB 配置接口

| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| psel | input | 1 | 外设选择 |
| penable | input | 1 | 传输使能 |
| pwrite | input | 1 | 写使能 |
| paddr | input | 8 | 地址总线 |
| pwdata | input | 32 | 写数据 |
| prdata | output | 32 | 读数据 |
| pready | output | 1 | 传输就绪 |
| pslverr | output | 1 | 传输错误 |

**APB 时序：**
```
        ____    ____    ____    ____    ____
clk  __|    |__|    |__|    |__|    |__|    |__

          __________________
psel  ____|                |__________________

               ____________
paddr ________|            |__________________

               ____________
pwdata _______|            |__________________

                    ____
penable ___________|    |_____________________

                        ____
pready ________________|    |_________________
```

### 3.4 内部流水线握手协议

**Valid 信号传递：**
```
stage1_valid ──> stage2_valid ──> stage3_valid ──> dout_valid
     |                 |                 |              |
     +─ 4 cycles ──────+─ 6 cycles ──────+─ 4 cycles ───+─ 4 cycles
```

**数据对齐策略：**
- 各阶段内部采用流水线寄存器
- valid 信号与数据同步传递
- 无 back-pressure（假设输入连续）

### 3.5 关键时序路径

**最长路径分析：**

| 路径 | 组合逻辑 | 预估延迟 | 优化建议 |
|------|----------|----------|----------|
| Stage 1 Sobel | 25 个加法 | 中等 | 已使用平衡加法树 |
| Stage 2 核选择 | 25 个乘累加 | 较高 | 可插入流水级 |
| Stage 3 排序 | 7 级比较 | 低 | 排序网络高效 |
| Stage 3 加权 | 10 个乘累加 | 较高 | 已使用平衡树 |
| Stage 4 IIR | 乘累加 | 中等 | 可考虑 DSP |

**除法操作：**
- Stage 2 和 Stage 3 均有除法
- 当前使用直接整数除法
- 建议使用 DSP 或迭代除法器优化

---

## 4. 存储资源评估

### 4.1 行缓存需求分析

#### 4.1.1 主要行缓存（isp_csiir_line_buffer）

**存储结构：**
```
line_mem_0 [0:IMG_WIDTH-1]  // 第 -1 行
line_mem_1 [0:IMG_WIDTH-1]  // 第 -2 行
line_mem_2 [0:IMG_WIDTH-1]  // 第 -3 行
line_mem_3 [0:IMG_WIDTH-1]  // 第 -4 行
```

**容量计算：**
| 分辨率 | IMG_WIDTH | DATA_WIDTH | 行缓存容量 |
|--------|-----------|------------|------------|
| 8K | 5472 | 10 | 4 × 5472 × 10 = 218,880 bits |
| 4K | 3840 | 10 | 4 × 3840 × 10 = 153,600 bits |
| 1080p | 1920 | 10 | 4 × 1920 × 10 = 76,800 bits |

#### 4.1.2 梯度行缓存（stage3_gradient_fusion 内部）

**存储结构：**
```
grad_line_buf [0:4095]   // 上一行梯度
grad_shadow_buf [0:4095] // 当前行梯度影子缓冲
```

**容量计算：**
- 4096 × 14-bit × 2 = 114,688 bits（最大支持 4K 宽度）

### 4.2 寄存器资源评估

#### 4.2.1 各阶段流水线寄存器

| 模块 | 关键寄存器 | 数量估算 |
|------|-----------|----------|
| line_buffer | 5×5 窗口移位寄存器 | 25 × DATA_WIDTH |
| stage1 | 4 级流水线寄存器 | ~100 × 14-bit |
| stage2 | 6 级流水线 + 窗口延迟 | ~300 × 20-bit |
| stage3 | 4 级流水线 + 排序寄存器 | ~200 × 14-bit |
| stage4 | 4 级流水线寄存器 | ~100 × 10-bit |

#### 4.2.2 延迟链寄存器

| 延迟链 | 长度 | 数据宽度 | 用途 |
|--------|------|----------|------|
| grad_delay | 6 | 14-bit | 梯度对齐 |
| grad_h/v_delay | 6 | 14-bit | 方向梯度对齐 |
| pixel_x/y_delay | 6 | 14/13-bit | 像素位置对齐 |
| bypass_delay | 18 | 10-bit | bypass 路径 |

### 4.3 存储带宽分析

#### 4.3.1 行缓存读写时序

**写入：**
- 每周期写入 1 个像素到当前行缓存
- 写地址：wr_ptr（列计数器）

**读取：**
- 每周期从 4 个行缓存各读取 1 个像素
- 读地址：wr_ptr（与写地址相同）

**读写冲突：**
- 读写在同一地址，但不同行
- 无冲突，可直接实现

#### 4.3.2 梯度行缓存读写时序

**写入：**
- 当 stage1_valid 有效时写入 grad_shadow_buf
- 在行切换时复制到 grad_line_buf

**读取：**
- 当 stage2_valid 有效时读取 grad_line_buf[pixel_x]

**时序要求：**
- 写入比读取早约 5 个周期
- 无冲突风险

### 4.4 存储实现建议

#### 4.4.1 行缓存实现选项

| 选项 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| 寄存器数组 | 时序最优 | 面积大 | 小分辨率 |
| 单端口 SRAM | 面积小 | 需仲裁 | 大分辨率 |
| 双端口 SRAM | 带宽高 | 面积中等 | 推荐 |
| Block RAM | FPGA 友好 | 固定容量 | FPGA 实现 |

#### 4.4.2 优化建议

**对于 ASIC 实现：**
1. 使用双端口 SRAM 实现行缓存
2. 考虑行缓存指针轮转而非数据复制
3. 梯度缓存可使用单端口 SRAM（读写时序错开）

**对于 FPGA 实现：**
1. 使用 Block RAM 实现行缓存
2. 利用 BRAM 的双端口特性
3. 注意 BRAM 输出需要寄存

### 4.5 存储容量汇总

**8K 分辨率 (5472 × 3076)，10-bit 数据：**

| 存储类型 | 容量 | 实现 |
|----------|------|------|
| 主行缓存 | 218,880 bits | SRAM/BRAM |
| 梯度缓存 | 114,688 bits | SRAM/BRAM |
| 流水寄存器 | ~10,000 bits | 寄存器 |
| **总计** | **~344 kbits** | - |

---

## 5. 架构评估总结

### 5.1 设计优点

1. **流水线设计合理**
   - 四阶段流水线清晰分离各功能
   - 每阶段内部采用子流水线优化时序
   - 无流水线气泡，吞吐量最大化

2. **模块划分清晰**
   - 各模块职责明确
   - 接口定义清晰
   - 便于独立验证

3. **参数化设计**
   - 支持多种分辨率
   - 数据宽度可配置
   - 灵活性高

4. **边界处理完善**
   - 边界复制模式
   - 流水线位置追踪
   - 第一行/最后一行处理

### 5.2 潜在改进点

1. **除法操作优化**
   - 当前使用直接整数除法
   - 建议使用 DSP 或迭代除法器
   - 可显著降低关键路径延迟

2. **行缓存架构**
   - 考虑使用指针轮转替代数据复制
   - 可减少存储带宽和功耗

3. **IIR 反馈路径**
   - 当前设计中 IIR 反馈路径较复杂
   - 可考虑使用 isp_csiir_iir_line_buffer 模块
   - 简化顶层连线

4. **back-pressure 支持**
   - 当前设计假设输入连续
   - 可考虑添加 ready 信号支持背压

### 5.3 资源预估（8K 分辨率）

| 资源类型 | 预估用量 |
|----------|----------|
| 存储器 | ~350 kbits |
| 乘法器 | ~20 个（可复用） |
| 加法器 | ~100 个 |
| 寄存器 | ~5,000 bits |
| 组合逻辑 | 中等规模 |

### 5.4 时序预估

| 工艺 | 预估频率 |
|------|----------|
| 28nm | 300-400 MHz |
| 40nm | 250-300 MHz |
| FPGA | 150-200 MHz |

---

## 附录

### A. 参考文献

1. isp-csiir-ref.md - 算法参考文档
2. MEMORY.md - RTL 编码规范

### B. 文档修订历史

| 版本 | 日期 | 修改内容 |
|------|------|----------|
| v1.0 | 2026-03-21 | 初始版本 |