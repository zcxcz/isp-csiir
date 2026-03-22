# ISP-CSIIR 模块需求规格文档

## 文档信息
| 项目 | 内容 |
|------|------|
| 模块名称 | isp_csiir_top |
| 版本 | v1.0 |
| 作者 | rtl-std |
| 创建日期 | 2026-03-21 |
| 更新日期 | 2026-03-22 |
| 状态 | M1基线 |

---

## 1. 模块概述

### 1.1 功能描述

ISP-CSIIR (Image Signal Processing - Content Sensitive Image Interpolation Reconstruction) 是一种基于内容敏感的图像插值重建算法模块，用于图像去噪和平滑处理。该模块通过自适应窗口大小和梯度加权融合，实现边缘保持的图像平滑效果。

### 1.2 处理流程

模块采用四级流水线架构，处理流程如下：

```
输入像素 -> Line Buffer -> Stage1 -> Stage2 -> Stage3 -> Stage4 -> 输出像素
                              |         |         |         |
                              v         v         v         v
                           梯度计算   方向平均   梯度融合   IIR混合
```

### 1.3 功能阶段

| 阶段 | 模块名 | 功能 | 关键运算 |
|------|--------|------|----------|
| Line Buffer | isp_csiir_line_buffer | 5x5滑动窗口生成 | 行缓存、窗口移位 |
| Stage 1 | stage1_gradient | Sobel梯度计算与窗口大小确定 | 加法树、LUT查表 |
| Stage 2 | stage2_directional_avg | 多尺度方向性平均 | 核选择、加权求和、除法 |
| Stage 3 | stage3_gradient_fusion | 梯度加权方向融合 | 排序、乘累加、除法 |
| Stage 4 | stage4_iir_blend | IIR滤波与混合输出 | 行混合、窗混合、反馈 |

**注：流水线级数和延迟由 rtl-arch 基于 600MHz @ 12nm 约束决定，不在需求规格中预设。**

### 1.4 应用场景

- 实时视频处理流水线
- 图像降噪预处理
- 边缘保持平滑滤波

---

## 2. 接口规格

### 2.1 顶层模块接口

#### 2.1.1 时钟与复位

| 信号名 | 方向 | 位宽 | 描述 |
|--------|------|------|------|
| clk | input | 1 | 系统时钟 |
| rst_n | input | 1 | 异步复位，低有效 |

#### 2.1.2 APB配置接口

| 信号名 | 方向 | 位宽 | 描述 |
|--------|------|------|------|
| psel | input | 1 | APB选择信号 |
| penable | input | 1 | APB使能信号 |
| pwrite | input | 1 | APB写使能 |
| paddr | input | 8 | APB地址总线 |
| pwdata | input | 32 | APB写数据 |
| prdata | output | 32 | APB读数据 |
| pready | output | 1 | APB就绪信号 |
| pslverr | output | 1 | APB错误响应 |

#### 2.1.3 视频输入接口

| 信号名 | 方向 | 位宽 | 描述 |
|--------|------|------|------|
| vsync | input | 1 | 垂直同步信号 |
| hsync | input | 1 | 水平同步信号 |
| din | input | DATA_WIDTH | 输入像素数据 |
| din_valid | input | 1 | 输入数据有效 |

#### 2.1.4 视频输出接口

| 信号名 | 方向 | 位宽 | 描述 |
|--------|------|------|------|
| dout | output | DATA_WIDTH | 输出像素数据 |
| dout_valid | output | 1 | 输出数据有效 |
| dout_vsync | output | 1 | 输出垂直同步 |
| dout_hsync | output | 1 | 输出水平同步 |

### 2.2 配置寄存器映射

#### 2.2.1 寄存器地址表

| 地址偏移 | 寄存器名 | 位宽 | 访问 | 描述 |
|----------|----------|------|------|------|
| 0x00 | CTRL | 32 | R/W | 控制寄存器 |
| 0x04 | PIC_SIZE | 32 | R/W | 图像尺寸（低16位宽度，高16位高度） |
| 0x08 | PIC_SIZE_HI | 32 | R/W | 图像尺寸扩展（用于>16bit分辨率） |
| 0x0C | THRESH0 | 32 | R/W | 窗口大小阈值0 |
| 0x10 | THRESH1 | 32 | R/W | 窗口大小阈值1 |
| 0x14 | THRESH2 | 32 | R/W | 窗口大小阈值2 |
| 0x18 | THRESH3 | 32 | R/W | 窗口大小阈值3 |
| 0x1C | BLEND_RATIO | 32 | R/W | 混合比例寄存器 |
| 0x20 | CLIP_Y | 32 | R/W | 梯度裁剪阈值 |
| 0x24 | CLIP_SFT | 32 | R/W | 裁剪位移值 |
| 0x28 | MOT_PROTECT | 32 | R/W | 运动保护参数 |
| 0x2C | CLIP_Y_3 | 32 | R/W | 梯度裁剪阈值3扩展 |

#### 2.2.2 控制寄存器(CTRL)位定义

| 位域 | 名称 | 描述 |
|------|------|------|
| [0] | enable | 模块使能，1=使能，0=禁止 |
| [1] | bypass | 旁路模式，1=旁路，0=正常处理 |

#### 2.2.3 配置参数说明

| 参数 | 默认值 | 范围 | 描述 |
|------|--------|------|------|
| win_size_thresh0 | 16 | 0-63 | 窗口大小阈值0 |
| win_size_thresh1 | 24 | 0-63 | 窗口大小阈值1 |
| win_size_thresh2 | 32 | 0-63 | 窗口大小阈值2 |
| win_size_thresh3 | 40 | 0-63 | 窗口大小阈值3 |
| blending_ratio_0~3 | 32 | 0-64 | IIR混合比例 |
| win_size_clip_y_0~3 | [15,23,31,39] | 0-1023 | 梯度裁剪阈值 |
| win_size_clip_sft_0~3 | 2 | 0-255 | 裁剪位移值 |

---

## 3. 数据格式

### 3.1 参数化配置

```verilog
parameter IMG_WIDTH    = 5472;   // 图像宽度（8K）
parameter IMG_HEIGHT   = 3076;   // 图像高度（8K）
parameter DATA_WIDTH   = 10;     // 像素数据位宽
parameter GRAD_WIDTH   = 14;     // 梯度数据位宽
parameter LINE_ADDR_WIDTH = 14;  // 行地址位宽
parameter ROW_CNT_WIDTH = 13;    // 行计数位宽
```

### 3.2 输入数据格式

| 项目 | 规格 |
|------|------|
| 像素格式 | 无符号整数 |
| 位宽 | 10-bit (可参数化) |
| 范围 | 0 - 1023 |
| 扫描顺序 | 从左到右，从上到下 |

### 3.3 输出数据格式

| 项目 | 规格 |
|------|------|
| 像素格式 | 无符号整数 |
| 位宽 | 10-bit (与输入相同) |
| 范围 | 0 - 1023 |

### 3.4 内部数据格式

#### 3.4.1 梯度数据

| 信号 | 位宽 | 描述 |
|------|------|------|
| grad_h | 14-bit | 水平梯度 |
| grad_v | 14-bit | 垂直梯度 |
| grad | 14-bit | 综合梯度 |

#### 3.4.2 窗口大小

| 信号 | 位宽 | 范围 | 描述 |
|------|------|------|------|
| win_size_clip | 6-bit | 16-40 | 窗口大小 |

#### 3.4.3 方向平均值

| 信号 | 位宽 | 描述 |
|------|------|------|
| avg0_c/u/d/l/r | 10-bit | 尺度0方向平均值 |
| avg1_c/u/d/l/r | 10-bit | 尺度1方向平均值 |

#### 3.4.4 融合输出

| 信号 | 位宽 | 描述 |
|------|------|------|
| blend0_dir_avg | 10-bit | 尺度0融合输出 |
| blend1_dir_avg | 10-bit | 尺度1融合输出 |

### 3.5 行缓存规格

| 项目 | 规格 |
|------|------|
| 行缓存数量 | 4行 |
| 每行深度 | IMG_WIDTH (最大5472) |
| 数据位宽 | 10-bit |
| 总存储容量 | 4 x 5472 x 10 = 218,880 bits |

---

## 4. 性能目标

### 4.1 吞吐量

| 指标 | 目标值 | 说明 |
|------|--------|------|
| 像素处理速率 | 1 pixel/clock | 流水线设计，每周期输出一个像素 |
| 最大分辨率 | 8K (7680x4320) | 支持最大图像尺寸 |
| 数据率 | 1x 输入 | 与输入数据率相同 |

### 4.2 延迟

| 指标 | 数值 | 说明 |
|------|------|------|
| 行缓存延迟 | 2行 + 5列 | 形成5x5窗口所需 |
| 流水线延迟 | ~17 cycles | 从din_valid到dout_valid |
| 总延迟 | 约 (行缓存 + 流水线) | 与图像尺寸相关 |

### 4.3 时序目标

| 指标 | 目标值 | 说明 |
|------|--------|------|
| 目标工艺 | 12nm | 目标制造工艺节点 |
| 最大时钟频率 | 600 MHz | 目标工作频率（高约束） |
| 时钟周期 | 1.67 ns | 单周期约束 |
| 关键路径目标 | < 1.5 ns | 预留时序余量 |
| 建立时间余量 | > 0.1 ns | 时序收敛要求 |

**注: 600MHz @ 12nm 是较高的时序约束，需要在架构设计阶段充分考虑流水线划分和关键路径优化。**

### 4.4 资源估算

| 资源类型 | 估算量 | 说明 |
|----------|--------|------|
| 行缓存RAM | 218,880 bits | 4行x5472x10bit (注：Stage 4 IIR反馈需要额外行缓存) |
| 逻辑单元 | ~20,000 LUTs | 四级流水线 + 深度流水化 |
| 寄存器 | ~15,000 FFs | 深度流水线增加寄存器用量 |
| DSP | 0 | 纯逻辑实现 |

### 4.5 功耗目标

| 模式 | 功耗目标 | 说明 |
|------|----------|------|
| 正常工作 | < 150 mW | 600MHz @ 12nm 工作 |
| 待机 | < 1 mW | enable=0 |
| 旁路 | < 10 mW | bypass=1 |

---

## 5. 算法映射

### 5.1 Stage 1: 梯度计算与窗口大小确定

#### 5.1.1 Sobel滤波器

**算法定义:**
```python
sobel_x = [
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [-1, -1, -1, -1, -1]
]

sobel_y = [
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1]
]
```

**RTL映射:**
- 模块: `stage1_gradient.v`
- 关键运算: 使用加法树计算行和/列和，再做差

```verilog
// 梯度计算
grad_h = row0_sum - row4_sum
grad_v = col0_sum - col4_sum
grad = |grad_h|/4 + |grad_v|/4  // 简化实现
```

#### 5.1.2 窗口大小LUT

**算法定义:**
```
win_size_clip_y = [15, 23, 31, 39]
win_size_grad = LUT(Max(grad(i-1,j), grad(i,j), grad(i+1,j)))
win_size_clip = clip(win_size, 16, 40)
```

**RTL映射:**
- 通过梯度阈值比较选择窗口大小
- 硬编码范围限制 [16, 40]

### 5.2 Stage 2: 多尺度方向性平均

#### 5.2.1 核选择逻辑

**算法定义:**
```
if (win_size_clip < thresh0): kernel = 2x2
elif (win_size_clip < thresh1): kernel = 2x2 + 3x3
elif (win_size_clip < thresh2): kernel = 3x3 + 4x4
elif (win_size_clip < thresh3): kernel = 4x4 + 5x5
else: kernel = 5x5
```

**RTL映射:**
- 模块: `stage2_directional_avg.v`
- 关键运算: 使用case语句实现核选择

#### 5.2.2 方向平均计算

**算法定义:**
- 5个方向: 中心(c)、上(u)、下(d)、左(l)、右(r)
- 2个尺度: avg0, avg1
- 输出: 10个平均值

**RTL映射:**
```verilog
avg0_c = sum(win * factor) / weight
avg0_u = sum(win * factor_u) / weight_u
// ... 其他方向类似
```

### 5.3 Stage 3: 梯度加权方向融合

#### 5.3.1 边界处理

**算法定义:**
```
grad_c = grad(i, j)
grad_u = (j==0) ? grad(i,j) : grad(i, j-1)
grad_d = (j==height-1) ? grad(i,j) : grad(i, j+1)
grad_l = (i==0) ? grad(i,j) : grad(i-1, j)
grad_r = (i==width-1) ? grad(i,j) : grad(i+1, j)
```

**RTL映射:**
- 模块: `stage3_gradient_fusion.v`
- 关键运算: 使用行缓存存储上一行梯度值

#### 5.3.2 梯度排序与融合

**算法定义:**
```
grad_sorted = invSort(grad_c, grad_u, grad_d, grad_l, grad_r)
grad_sum = sum(grad_sorted)
blend0_grad = sum(avg0 * grad_sorted) / grad_sum
blend1_grad = sum(avg1 * grad_sorted) / grad_sum
```

**RTL映射:**
- 使用排序网络实现逆序排序（7级比较）
- 使用加法树和乘法器实现加权求和
- 使用除法器实现归一化

### 5.4 Stage 4: IIR滤波与混合输出

**关键特性: 本阶段包含IIR反馈路径，需要特殊处理。**

IIR反馈特性说明：
- 当前行的blend0_hor/blend1_hor需要与上一行的avg0_u/avg1_u进行混合
- 输出像素会反馈更新src_uv数组，作为后续像素的输入参考
- 这种数据依赖性需要在架构设计时专门处理行缓存和反馈路径

#### 5.4.1 水平混合（IIR特性）

**算法定义:**
```
ratio = blending_ratio[win_size_clip/8 - 2]
blend0_hor = (ratio * blend0_grad + (64-ratio) * avg0_u) / 64
blend1_hor = (ratio * blend1_grad + (64-ratio) * avg1_u) / 64
```

**RTL映射:**
- 模块: `stage4_iir_blend.v`
- 关键特性: 使用上一行的avg0_u/avg1_u进行IIR混合

#### 5.4.2 最终混合

**算法定义:**
```
win_size_remain_8 = win_size_clip % 8
blend_uv = blend0_win * win_size_remain_8 + blend1_win * (8 - win_size_remain_8)
```

**RTL映射:**
```verilog
// 根据窗口大小选择混合因子
blend_factor = (win_size < thresh0) ? 1 :
               (win_size < thresh1) ? 2 :
               (win_size < thresh2) ? 3 : 4

// 最终输出
dout = blend0 * factor + blend1 * (8 - factor)
```

### 5.5 算法参数对应表

| 算法参数 | RTL信号 | 位宽 | 默认值 |
|----------|---------|------|--------|
| win_size_thresh0 | win_size_thresh0 | 16 | 16 |
| win_size_thresh1 | win_size_thresh1 | 16 | 24 |
| win_size_thresh2 | win_size_thresh2 | 16 | 32 |
| win_size_thresh3 | win_size_thresh3 | 16 | 40 |
| blending_ratio[0] | blending_ratio_0 | 8 | 32 |
| blending_ratio[1] | blending_ratio_1 | 8 | 32 |
| blending_ratio[2] | blending_ratio_2 | 8 | 32 |
| blending_ratio[3] | blending_ratio_3 | 8 | 32 |
| win_size_clip_y[0] | win_size_clip_y_0 | 10 | 15 |
| win_size_clip_y[1] | win_size_clip_y_1 | 10 | 23 |
| win_size_clip_y[2] | win_size_clip_y_2 | 10 | 31 |
| win_size_clip_y[3] | win_size_clip_y_3 | 10 | 39 |

---

## 6. 设计约束

### 6.1 RTL编码规范

- 语言: 纯Verilog-2001（可综合）
- 风格: 同步设计，单时钟域
- 复位: 异步复位，同步释放

### 6.2 流水线设计原则

- 采用组合逻辑 + 流水寄存器模式
- 平衡加法树结构
- 关键路径优化

### 6.3 边界处理

- 图像边界: 复制边界像素
- 第一行/列: 使用当前值替代
- 最后一行/列: 使用当前值替代

---

## 7. 验证要点

### 7.1 功能验证

- [ ] 各阶段输出正确性
- [ ] 边界像素处理
- [ ] 配置寄存器读写
- [ ] 旁路模式功能

### 7.2 性能验证

- [ ] 吞吐量测试（1 pixel/clock）
- [ ] 延迟测量
- [ ] 最大分辨率测试

### 7.3 边界情况

- [ ] 最小分辨率 (8x8)
- [ ] 最大分辨率 (8K)
- [ ] 全零/全一图像
- [ ] 随机模式图像

---

## 8. 附录

### 8.1 参考文献

- isp-csiir-ref.md 算法参考文档
- isp-csiir-arch-evaluation.md 架构评估文档

### 8.2 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-21 | rtl-std | 初稿 |