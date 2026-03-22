# ISP-CSIIR 模块划分文档

## 文档信息
| 项目 | 内容 |
|------|------|
| 模块名称 | isp_csiir_top |
| 版本 | v1.0 |
| 作者 | rtl-arch |
| 创建日期 | 2026-03-22 |
| 状态 | 正式版 |

---

## 1. 子模块列表与职责

### 1.1 模块总览

| 模块名称 | 功能描述 | 流水深度 | 存储需求 |
|----------|----------|----------|----------|
| isp_csiir_top | 顶层模块，集成所有子模块 | - | - |
| isp_csiir_reg_block | APB 寄存器配置块 | 0 | 配置参数 |
| isp_csiir_line_buffer | 行缓存，5x5 窗口生成 | 1 | 4 lines |
| stage1_gradient | 梯度计算与窗口大小确定 | 4 | 无 |
| stage2_directional_avg | 多尺度方向性平均 | 6 | 无 |
| stage3_gradient_fusion | 梯度加权方向融合 | 4 | 1 line (梯度) |
| stage4_iir_blend | IIR 滤波与混合输出 | 4 | 无 |

### 1.2 模块职责详述

#### 1.2.1 isp_csiir_top (顶层模块)

**职责:**
- 集成所有子模块
- 视频时序生成
- 延迟链管理
- bypass 路径实现
- 输出选择

**关键功能:**
- 视频时序解析 (vsync/hsync 检测)
- 像素/行计数器管理
- 梯度延迟链 (对齐 Stage 2 输出)
- bypass 模式延迟链

#### 1.2.2 isp_csiir_reg_block (寄存器配置块)

**职责:**
- APB 协议接口实现
- 配置参数存储与管理
- 寄存器读写控制

**寄存器列表:**
| 地址 | 名称 | 位宽 | 描述 |
|------|------|------|------|
| 0x00 | CTRL | 32 | 控制寄存器 |
| 0x04 | PIC_SIZE | 32 | 图像尺寸 |
| 0x0C-0x18 | THRESH0-3 | 32 | 窗口大小阈值 |
| 0x1C | BLEND_RATIO | 32 | 混合比例 |
| 0x20 | CLIP_Y | 32 | 梯度裁剪阈值 |

#### 1.2.3 isp_csiir_line_buffer (行缓存模块)

**职责:**
- 存储历史行像素数据
- 生成 5x5 滑动窗口
- 边界处理 (复制模式)
- 窗口中心位置追踪

**存储结构:**
```
line_mem_0 [0:IMG_WIDTH-1]  // 第 -1 行
line_mem_1 [0:IMG_WIDTH-1]  // 第 -2 行
line_mem_2 [0:IMG_WIDTH-1]  // 第 -3 行
line_mem_3 [0:IMG_WIDTH-1]  // 第 -4 行

// 输出: window_0_0 ... window_4_4 (25 个像素)
//       window_center_x, window_center_y
```

**关键信号:**
| 信号 | 方向 | 描述 |
|------|------|------|
| din | input | 输入像素 |
| din_valid | input | 输入有效 |
| sof | input | 帧起始 |
| eol | input | 行结束 |
| window_0_0 ~ window_4_4 | output | 5x5 窗口像素 |
| window_valid | output | 窗口有效 |
| window_center_x/y | output | 窗口中心位置 |

#### 1.2.4 stage1_gradient (梯度计算模块)

**职责:**
- Sobel 水平/垂直梯度计算
- 综合梯度计算
- 窗口大小 LUT 查表
- 位置信息流水传递

**流水线结构:**
```
S1: Sobel 卷积 (row_sum, col_sum)
S2: 绝对值与除法 (grad_abs, grad_sum)
S3: 梯度最大值 (grad_max)
S4: LUT 查表输出 (win_size_clip)
```

**关键信号:**
| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| window_0_0 ~ window_4_4 | input | 10 | 5x5 窗口 |
| window_valid | input | 1 | 窗口有效 |
| grad_h | output | 14 | 水平梯度 |
| grad_v | output | 14 | 垂直梯度 |
| grad | output | 14 | 综合梯度 |
| win_size_clip | output | 6 | 窗口大小 |
| stage1_valid | output | 1 | 输出有效 |

#### 1.2.5 stage2_directional_avg (方向性平均模块)

**职责:**
- 根据 win_size 选择核尺寸
- 计算 5 方向加权平均
- 输出 avg0/avg1 两组平均值
- 流水传递 center_pixel 和 win_size

**核选择逻辑:**
| win_size | avg0 核 | avg1 核 |
|----------|---------|---------|
| < 16 | zeros | 2x2 |
| 16-24 | 2x2 | 3x3 |
| 24-32 | 3x3 | 4x4 |
| 32-40 | 4x4 | 5x5 |
| >= 40 | 5x5 | zeros |

**关键信号:**
| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| window[5x5] | input | 10 | 5x5 窗口 |
| win_size_clip | input | 6 | 窗口大小 |
| stage1_valid | input | 1 | 输入有效 |
| avg0_c/u/d/l/r | output | 10 | avg0 各方向 |
| avg1_c/u/d/l/r | output | 10 | avg1 各方向 |
| center_pixel_out | output | 10 | 中心像素 |
| win_size_out | output | 6 | 窗口大小 |
| stage2_valid | output | 1 | 输出有效 |

#### 1.2.6 stage3_gradient_fusion (梯度融合模块)

**职责:**
- 获取 5 方向梯度 (从行缓存读取 grad_u)
- 梯度逆序排序
- 加权融合计算
- 维护梯度行缓存

**存储结构:**
```
grad_line_buf [0:4095]   // 上一行梯度
grad_shadow_buf [0:4095] // 当前行梯度影子缓冲
grad_left_buf            // 左邻居梯度
```

**关键信号:**
| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| avg0_c/u/d/l/r | input | 10 | avg0 各方向 |
| avg1_c/u/d/l/r | input | 10 | avg1 各方向 |
| grad | input | 14 | 当前梯度 |
| grad_h/v | input | 14 | 方向梯度 |
| stage2_valid | input | 1 | 输入有效 |
| grad_instant | input | 14 | 即时梯度 (写行缓存) |
| stage1_valid | input | 1 | 行缓存写使能 |
| blend0_dir_avg | output | 10 | avg0 融合结果 |
| blend1_dir_avg | output | 10 | avg1 融合结果 |
| avg0_u_out | output | 10 | avg0_u (用于 IIR) |
| avg1_u_out | output | 10 | avg1_u (用于 IIR) |
| stage3_valid | output | 1 | 输出有效 |

#### 1.2.7 stage4_iir_blend (IIR 混合输出模块)

**职责:**
- 水平 IIR 混合
- 窗混合 (blend_factor)
- 最终混合输出
- 输出饱和截断

**关键信号:**
| 信号 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| blend0_dir_avg | input | 10 | avg0 融合结果 |
| blend1_dir_avg | input | 10 | avg1 融合结果 |
| avg0_u | input | 10 | avg0_u (IIR 输入) |
| avg1_u | input | 10 | avg1_u (IIR 输入) |
| win_size_clip | input | 6 | 窗口大小 |
| center_pixel | input | 10 | 中心像素 |
| stage3_valid | input | 1 | 输入有效 |
| dout | output | 10 | 输出像素 |
| dout_valid | output | 1 | 输出有效 |

---

## 2. 模块接口定义

### 2.1 isp_csiir_top 接口

```verilog
module isp_csiir_top #(
    parameter IMG_WIDTH    = 5472,
    parameter IMG_HEIGHT   = 3076,
    parameter DATA_WIDTH   = 10,
    parameter GRAD_WIDTH   = 14,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH = 13
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
    output wire [31:0]               prdata,
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

### 2.2 isp_csiir_reg_block 接口

```verilog
module isp_csiir_reg_block #(
    parameter APB_ADDR_WIDTH = 8,
    parameter PIC_WIDTH_BITS = 14,
    parameter PIC_HEIGHT_BITS = 13,
    parameter DATA_WIDTH = 10
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // APB 接口
    input  wire                        psel,
    input  wire                        penable,
    input  wire                        pwrite,
    input  wire [APB_ADDR_WIDTH-1:0]   paddr,
    input  wire [31:0]                 pwdata,
    output wire [31:0]                 prdata,
    output wire                        pready,
    output wire                        pslverr,

    // 配置输出
    output wire [PIC_WIDTH_BITS-1:0]   pic_width_m1,
    output wire [PIC_HEIGHT_BITS-1:0]  pic_height_m1,
    output wire [15:0]                 win_size_thresh0,
    output wire [15:0]                 win_size_thresh1,
    output wire [15:0]                 win_size_thresh2,
    output wire [15:0]                 win_size_thresh3,
    output wire [7:0]                  blending_ratio_0,
    output wire [7:0]                  blending_ratio_1,
    output wire [7:0]                  blending_ratio_2,
    output wire [7:0]                  blending_ratio_3,
    output wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    output wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    output wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    output wire [DATA_WIDTH-1:0]       win_size_clip_y_3,
    output wire [7:0]                  win_size_clip_sft_0,
    output wire [7:0]                  win_size_clip_sft_1,
    output wire [7:0]                  win_size_clip_sft_2,
    output wire [7:0]                  win_size_clip_sft_3,
    output wire                        enable,
    output wire                        bypass,
    output wire                        regs_updated
);
```

### 2.3 isp_csiir_line_buffer 接口

```verilog
module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire                        sof,
    input  wire                        eol,
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,

    // 5x5 窗口输出
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,

    // 窗口中心位置
    output wire [LINE_ADDR_WIDTH-1:0]  window_center_x,
    output wire [ROW_CNT_WIDTH-1:0]    window_center_y,

    // 边界模式
    input  wire [1:0]                  boundary_mode
);
```

### 2.4 stage1_gradient 接口

```verilog
module stage1_gradient #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter PIC_WIDTH_BITS  = 14,
    parameter PIC_HEIGHT_BITS = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 窗口输入
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    // ... (共 25 个窗口像素)
    input  wire                        window_valid,

    // 配置参数
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0, win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2, win_size_clip_y_3,
    input  wire [7:0]                  win_size_clip_sft_0, win_size_clip_sft_1,
    input  wire [7:0]                  win_size_clip_sft_2, win_size_clip_sft_3,

    // 位置信息
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x, pixel_y,
    input  wire [PIC_WIDTH_BITS-1:0]   pic_width_m1, pic_height_m1,
    input  wire [PIC_WIDTH_BITS-1:0]   window_center_x,
    input  wire [PIC_HEIGHT_BITS-1:0]  window_center_y,

    // 输出
    output reg  [GRAD_WIDTH-1:0]       grad_h, grad_v, grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid,
    output reg  [PIC_WIDTH_BITS-1:0]   center_x_out,
    output reg  [PIC_HEIGHT_BITS-1:0]  center_y_out
);
```

### 2.5 stage2_directional_avg 接口

```verilog
module stage2_directional_avg #(
    parameter DATA_WIDTH     = 10,
    parameter ACC_WIDTH      = 20,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 窗口输入
    input  wire [DATA_WIDTH-1:0]       window_0_0, /* ... */, window_4_4,
    input  wire                        window_valid,

    // Stage 1 输出
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire                        stage1_valid,

    // 配置阈值
    input  wire [15:0]                 win_size_thresh0, win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2, win_size_thresh3,

    // 位置输入
    input  wire [13:0]                 pixel_x_in,
    input  wire [12:0]                 pixel_y_in,

    // 输出: 5 方向 x 2 尺度 = 10 个平均值
    output reg  [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    output reg  [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    output reg                         stage2_valid,

    // 流水传递
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_out,
    output reg  [13:0]                 pixel_x_out,
    output reg  [12:0]                 pixel_y_out
);
```

### 2.6 stage3_gradient_fusion 接口

```verilog
module stage3_gradient_fusion #(
    parameter DATA_WIDTH      = 10,
    parameter GRAD_WIDTH      = 14,
    parameter PIC_WIDTH_BITS  = 14,
    parameter PIC_HEIGHT_BITS = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 2 输出 (10 个平均值)
    input  wire [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    input  wire [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    input  wire                        stage2_valid,

    // 梯度输入 (延迟对齐)
    input  wire [GRAD_WIDTH-1:0]       grad, grad_h, grad_v,

    // 位置信息
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x, pixel_y,
    input  wire [PIC_WIDTH_BITS-1:0]   pic_width_m1, pic_height_m1,

    // 即时信号 (用于行缓存写)
    input  wire [GRAD_WIDTH-1:0]       grad_instant,
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x_instant, pixel_y_instant,
    input  wire                        stage1_valid,

    // 流水传递
    input  wire [DATA_WIDTH-1:0]       center_pixel_in,
    input  wire [5:0]                  win_size_clip_in,

    // 输出
    output reg  [DATA_WIDTH-1:0]       blend0_dir_avg, blend1_dir_avg,
    output reg                         stage3_valid,
    output reg  [PIC_WIDTH_BITS-1:0]   pixel_x_out,
    output reg  [PIC_HEIGHT_BITS-1:0]  pixel_y_out,

    // IIR 相关输出
    output reg  [DATA_WIDTH-1:0]       avg0_u_out, avg1_u_out,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [5:0]                  win_size_clip_out
);
```

### 2.7 stage4_iir_blend 接口

```verilog
module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 3 输出
    input  wire [DATA_WIDTH-1:0]       blend0_dir_avg, blend1_dir_avg,
    input  wire                        stage3_valid,

    // 梯度 (用于方向判断)
    input  wire [GRAD_WIDTH-1:0]       grad_h, grad_v,

    // IIR 输入
    input  wire [DATA_WIDTH-1:0]       avg0_u, avg1_u,

    // 窗口大小与中心像素
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // 配置参数
    input  wire [7:0]                  blending_ratio_0, blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2, blending_ratio_3,
    input  wire [15:0]                 win_size_thresh0, win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2, win_size_thresh3,

    // 位置输入
    input  wire [13:0]                 pixel_x_in,
    input  wire [12:0]                 pixel_y_in,

    // 输出
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid,
    output reg  [13:0]                 pixel_x_out,
    output reg  [12:0]                 pixel_y_out
);
```

---

## 3. 模块间依赖关系

### 3.1 数据依赖图

```
                          +----------------+
                          |   reg_block    |
                          +-------+--------+
                                  |
                    +-------------+-------------+
                    |             |             |
                    v             v             v
            +-------+--------+   |   +---------+--------+
            | win_size_thresh|   |   | blending_ratio  |
            | clip_y params  |   |   | params          |
            +----------------+   |   +----------------+
                                 |
+--------+     +-----------------+------------------+     +--------+
|  din   | --> |              line_buffer             | -->| window |
+--------+     +-----------------+------------------+     | 5x5    |
                                 |                        +--------+
                                 v                             |
                        +--------+--------+                    |
                        |   stage1_       |<-------------------+
                        |   gradient      |
                        +--------+--------+
                                 |
                    +------------+------------+
                    |             |             |
                    v             v             v
              +-----+-----+ +-----+-----+ +-----+-----+
              | win_size  | |   grad    | | center_pos|
              +-----------+ +-----+-----+ +-----------+
                                  |
                                  v
                        +--------+--------+
                        |   grad_delay    | (延迟链)
                        +--------+--------+
                                 |
                                 v
+----------------+     +--------+--------+
| window_5x5     | --> |   stage2_       |
| (delayed)      |     |   directional   |
+----------------+     |   _avg          |
                       +--------+--------+
                                |
                    +-----------+-----------+
                    |           |           |
                    v           v           v
              +-----+-----+ +---+---+ +-----+-----+
              | avg0[5]   | |avg1[5]| |center_pos |
              +-----------+ +-------+ +-----------+
                    |           |
                    v           v
              +-----+-----------+-----+
              |     grad_fusion       |
              |      (stage3)         |
              +-----+-----------+-----+
                    |           |
                    v           v
              +-----+-----+ +---+---+
              |blend0/1   | |avg_u  |
              +-----------+ +-------+
                    |           |
                    v           v
              +-----+-----------+-----+
              |     iir_blend         |
              |       (stage4)        |
              +----------+------------+
                         |
                         v
                    +----+----+
                    |   dout  |
                    +---------+
```

### 3.2 时序依赖关系

| 源模块 | 目标模块 | 数据 | 延迟对齐需求 |
|--------|----------|------|--------------|
| line_buffer | stage1 | window[5x5] | 同周期 |
| stage1 | stage2 | win_size_clip | 0 cycles (组合逻辑) |
| stage1 | stage2 | window (delayed) | 4 cycles |
| stage1 | stage3 | grad (delayed) | 6 cycles (delay chain) |
| stage2 | stage3 | avg[10] | 同周期 |
| stage2 | stage4 | avg_u (delayed) | 4 cycles |
| stage3 | stage4 | blend0/1 | 同周期 |
| stage3 | stage4 | avg_u_out | 同周期 |

### 3.3 跨模块延迟链

```verilog
// 在顶层模块中实现

// 1. 梯度延迟链 (Stage 1 -> Stage 3)
// Stage 2 有 6 cycles 延迟，需要延迟 grad 信号
reg [GRAD_WIDTH-1:0] grad_delay [0:5];
always @(posedge clk) begin
    if (enable) begin
        grad_delay[0] <= stage1_valid ? grad_s1 : 0;
        for (k = 1; k <= 5; k = k + 1)
            grad_delay[k] <= grad_delay[k-1];
    end
end

// 2. 位置延迟链
reg [PIC_WIDTH_BITS-1:0] pixel_x_delay [0:5];
reg [PIC_HEIGHT_BITS-1:0] pixel_y_delay [0:5];

// 3. Bypass 延迟链 (17 cycles)
reg [DATA_WIDTH-1:0] din_delay [0:20];
reg [20:0] din_valid_delay;
```

### 3.4 行缓存依赖

| 行缓存位置 | 所属模块 | 用途 | 容量 |
|------------|----------|------|------|
| line_mem_0-3 | line_buffer | 5x5 窗口生成 | 4 x IMG_WIDTH x 10-bit |
| grad_line_buf | stage3 | 上一行梯度 | IMG_WIDTH x 14-bit |
| grad_shadow_buf | stage3 | 当前行梯度 | IMG_WIDTH x 14-bit |

### 3.5 模块实例化顺序

```
1. isp_csiir_reg_block    (配置最先初始化)
2. isp_csiir_line_buffer  (数据通路起点)
3. stage1_gradient        (Stage 1)
4. stage2_directional_avg (Stage 2)
5. stage3_gradient_fusion (Stage 3)
6. stage4_iir_blend       (Stage 4)
```

---

## 4. 附录

### 4.1 参数汇总

| 参数名 | 默认值 | 描述 |
|--------|--------|------|
| IMG_WIDTH | 5472 | 最大图像宽度 (8K) |
| IMG_HEIGHT | 3076 | 最大图像高度 (8K) |
| DATA_WIDTH | 10 | 像素数据位宽 |
| GRAD_WIDTH | 14 | 梯度数据位宽 |
| ACC_WIDTH | 20 | 累加器位宽 |
| WIN_SIZE_WIDTH | 6 | 窗口大小位宽 |
| LINE_ADDR_WIDTH | 14 | 行地址位宽 |
| ROW_CNT_WIDTH | 13 | 行计数位宽 |

### 4.2 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-22 | rtl-arch | 初始版本 |