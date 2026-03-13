# ISP-CSIIR RTL Design

## 概述

ISP-CSIIR (Image Signal Processor - Chroma Spatial Interpolation and Impulse Removal) 模块，用于图像信号处理中的色度空间插值和脉冲噪声去除。

### 主要特性

- **纯 Verilog-2001 RTL 设计**：适用于主流 FPGA/ASIC 综合工具
- **4 级流水线架构**：梯度计算 → 方向性平均 → 梯度融合 → IIR 混合
- **5x5 滑动窗口处理**：支持最高 8K 分辨率 (5472x3076)
- **10-bit 数据位宽**：支持 YUV 三通道处理
- **全参数化设计**：分辨率、数据位宽、通道数可配置
- **UVM 验证环境**：完整的验证平台，包含参考模型和覆盖率收集

### 支持分辨率

| 分辨率 | 宽度 | 高度 | 行缓存大小 (每通道) |
|--------|------|------|---------------------|
| 1080p | 1920 | 1080 | ~8 KB |
| 4K | 3840 | 2160 | ~16 KB |
| 8K | 5472 | 3076 | ~22 KB |

## 目录结构

```
isp-csiir/
├── rtl/                           # RTL 设计文件
│   ├── isp_csiir_defines.vh       # 参数定义
│   ├── isp_csiir_top.v            # 顶层模块
│   ├── isp_csiir_reg_block.v      # 寄存器配置模块
│   ├── isp_csiir_line_buffer.v    # 行缓存模块
│   ├── stage1_gradient.v          # Stage 1: 梯度计算
│   ├── stage2_directional_avg.v   # Stage 2: 方向性平均
│   ├── stage3_gradient_fusion.v   # Stage 3: 梯度融合
│   ├── stage4_iir_blend.v         # Stage 4: IIR 混合
│   └── common/                    # 通用可复用模块
│       ├── common_pipe.v          # 流水寄存器
│       ├── common_counter.v       # 计数器
│       ├── common_fifo.v          # 同步 FIFO
│       ├── common_adder_tree.v    # 平衡加法树
│       ├── common_max_finder.v    # 最大值查找
│       └── common_delay_line.v    # 延迟线
├── verification/                  # 验证环境
│   ├── isp_csiir_pkg.sv           # UVM 包
│   ├── tb/                        # 测试平台
│   │   ├── isp_csiir_tb_top.sv    # 测试顶层
│   │   ├── isp_csiir_pixel_if.sv  # 像素接口
│   │   └── isp_csiir_reg_if.sv    # 寄存器接口
│   ├── agents/                    # UVM Agents
│   ├── env/                       # 环境组件
│   ├── sequences/                 # 序列和测试
│   └── ref_model/                 # 参考模型
├── Makefile                       # 构建脚本
└── README.md                      # 本文件
```

## 模块架构

```
isp_csiir_top
├── isp_csiir_reg_block           # APB 寄存器配置
├── isp_csiir_line_buffer         # 5x5 窗口生成
├── stage1_gradient               # Sobel 梯度 + 窗口大小
├── stage2_directional_avg        # 5方向 × 双尺度平均
├── stage3_gradient_fusion        # 梯度排序 + 加权融合
└── stage4_iir_blend              # IIR 滤波 + 最终输出
```

## 流水线延迟

| 阶段 | 周期数 | 功能 |
|------|--------|------|
| Line Buffer | 2 行 | 窗口生成 |
| Stage 1 | 4 | 梯度计算 |
| Stage 2 | 6 | 方向性平均 |
| Stage 3 | 4 | 梯度融合 |
| Stage 4 | 3 | 输出混合 |
| **总计** | **17** | (不含行缓存填充) |

## 参数配置

### RTL 参数 (isp_csiir_top)

| 参数 | 默认值 | 描述 |
|------|--------|------|
| IMG_WIDTH | 5472 | 图像宽度 (最大 8K) |
| IMG_HEIGHT | 3076 | 图像高度 |
| DATA_WIDTH | 10 | 像素数据位宽 (8/10/12) |
| GRAD_WIDTH | 14 | 梯度计算位宽 |
| LINE_ADDR_WIDTH | 14 | 行地址位宽 (log2(IMG_WIDTH)+1) |
| ROW_CNT_WIDTH | 13 | 行计数器位宽 |

### 不同分辨率配置示例

```verilog
// 1080p 8-bit
isp_csiir_top #(
    .IMG_WIDTH(1920),
    .IMG_HEIGHT(1080),
    .DATA_WIDTH(8),
    .GRAD_WIDTH(12),
    .LINE_ADDR_WIDTH(11),
    .ROW_CNT_WIDTH(11)
) dut_1080p (...);

// 4K 10-bit
isp_csiir_top #(
    .IMG_WIDTH(3840),
    .IMG_HEIGHT(2160),
    .DATA_WIDTH(10),
    .GRAD_WIDTH(14),
    .LINE_ADDR_WIDTH(13),
    .ROW_CNT_WIDTH(12)
) dut_4k (...);

// 8K 10-bit (默认)
isp_csiir_top dut_8k (...);
```

## 寄存器映射

| 地址 | 名称 | 描述 |
|------|------|------|
| 0x00 | ENABLE | [0]: enable, [1]: bypass |
| 0x04 | PIC_SIZE | [15:0]: width-1, [31:16]: height-1 |
| 0x08 | THRESH0 | 窗口大小阈值 0 |
| 0x0C | THRESH1 | 窗口大小阈值 1 |
| 0x10 | THRESH2 | 窗口大小阈值 2 |
| 0x14 | THRESH3 | 窗口大小阈值 3 |
| 0x18 | BLEND_RATIO | 混合比例 [4×8bit] |
| 0x1C | CLIP_Y | 梯度裁剪值 [4×8bit] |
| 0x20 | CLIP_SFT | 裁剪移位 [4×8bit] |
| 0x24 | MOT_PROTECT | 运动保护 [4×8bit] |

## 快速开始

### RTL 语法检查

```bash
make rtl_check SIM=vcs
```

### 运行仿真

```bash
# 运行冒烟测试
make smoke SIM=vcs

# 运行随机测试
make random SIM=vcs

# 运行视频测试
make video SIM=vcs

# 指定测试用例
make sim SIM=vcs TEST=isp_csiir_smoke_test
```

### 支持的仿真器

- **Synopsys VCS** (推荐): `SIM=vcs`
- **Mentor Questa**: `SIM=questa`
- **Cadence Xcelium**: `SIM=xcelium`
- **Icarus Verilog** (语法检查): `iverilog`

### 使用 Icarus Verilog 语法检查

```bash
# 检查 RTL 语法
iverilog -t null -g2001 -I rtl rtl/isp_csiir_top.v rtl/*.v rtl/common/*.v

# 检查 common 模块
iverilog -t null -g2001 rtl/common/*.v
```

## Common 模块

通用可复用模块位于 `rtl/common/` 目录，遵循以下设计原则：

### 模块列表

| 模块 | 功能 | 关键参数 |
|------|------|----------|
| `common_pipe` | 流水寄存器 | DATA_WIDTH, STAGES, RESET_VAL |
| `common_counter` | 上下计数器 | DATA_WIDTH, COUNT_MIN, COUNT_MAX |
| `common_fifo` | 同步 FIFO | DATA_WIDTH, DEPTH |
| `common_adder_tree` | 平衡加法树 | NUM_INPUTS, DATA_WIDTH, PIPELINE |
| `common_max_finder` | 最大值查找 | NUM_INPUTS, DATA_WIDTH |
| `common_delay_line` | 延迟线 | DATA_WIDTH, DELAY |

### 使用示例

```verilog
// 4级流水寄存器
common_pipe #(.DATA_WIDTH(12), .STAGES(4)) u_pipe (
    .clk(clk), .rst_n(rst_n), .enable(1'b1),
    .din(data_in), .dout(data_out)
);

// 5输入加法树（带流水）
common_adder_tree #(.NUM_INPUTS(5), .DATA_WIDTH(8), .PIPELINE(1)) u_adder (
    .clk(clk), .rst_n(rst_n), .enable(1'b1),
    .din({d4, d3, d2, d1, d0}),  // 扁平化输入
    .valid_in(valid), .dout(sum), .valid_out(valid_sum)
);
```

## 资源估算

### 逻辑资源 (8K 10-bit)

| 资源 | Stage 1 | Stage 2 | Stage 3 | Stage 4 | 总计 |
|------|---------|---------|---------|---------|------|
| LUTs | 600 | 3,000 | 1,000 | 700 | ~5,300 |
| 寄存器 | 300 | 800 | 400 | 300 | ~1,800 |
| DSP | 0 | 30 | 0 | 6 | ~36 |

### 存储资源 (每通道)

| 分辨率 | 行缓存 | 说明 |
|--------|--------|------|
| 1080p 8-bit | ~8 KB | 4 行 × 1920 × 8 bit |
| 4K 10-bit | ~19 KB | 4 行 × 3840 × 10 bit |
| 8K 10-bit | ~27 KB | 4 行 × 5472 × 10 bit |

### YUV 三通道总资源

| 分辨率 | 行缓存 | DSP | LUT |
|--------|--------|-----|-----|
| 1080p | ~24 KB | ~108 | ~16K |
| 4K | ~57 KB | ~108 | ~16K |
| 8K | ~81 KB | ~108 | ~16K |

## 算法参考

详细算法描述参见 `isp-csiir-algorithm-reference.md`。

### Stage 1: 梯度计算

```
grad_h = sum(window * sobel_x) / 5
grad_v = sum(window * sobel_y) / 5
grad = |grad_h| + |grad_v|
win_size = LUT(max(grad_above, grad, grad_below))
```

### Stage 2: 方向性平均

根据窗口大小选择核 (2x2, 3x3, 4x4, 5x5)，计算 5 个方向的加权平均。

### Stage 3: 梯度融合

梯度排序后，加权融合各方向平均值：
```
blend_avg = sum(avg_i * grad_i) / sum(grad_i)
```

### Stage 4: IIR 混合

```
iir_avg = ratio * dir_avg + (64 - ratio) * prev_avg
final_out = blend(iir_avg, center_pixel)
```

## 验证策略

- **模块级验证**: 各阶段独立功能测试
- **集成验证**: 全流水线功能测试
- **覆盖率目标**: 代码覆盖率 95%+, 功能覆盖率 90%+
- **参考模型**: SystemVerilog 黄金参考模型

## 许可证

MIT License

## 作者

RTL Design Team