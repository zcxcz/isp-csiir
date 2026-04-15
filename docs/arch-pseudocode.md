# ISP-CSIIR 架构伪代码

## 0. 已知信息 (用户确认)

- **din格式**: YUV422, UV交替输入
- **数据宽度**: 1P = DATA_WIDTH bits
- **merge = common_s2p**: 1P/cycle → 2P/2cycle
- **写入粒度**: 2P/1T, linebuffer 数据宽度本来就是 2P, 不需要 half-write
- **linebuffer职责**: 仅保留5条独立1P SRAM读写接口, 不含 assembler
- **fifo_uv5x1**: 宽度 = 2P × 5 = 5个2P words
- **模块间传递**: 仅传递 assembler 输出的 col5x1, 组装在各自模块内部完成

---

## 1. 公共数据接口

### 1.1 接口抽象约定

接口是一组信号的集合，表现为结构体。可以是握手接口，也可以是一组数据。

**命名后缀规则：**
- `(in)` 后缀：输入端，发送方驱动
- `(out)` 后缀：输出端，接收方驱动
- 无后缀：默认为 `(in)`
- 接口时，`_valid` 和数据由发送方驱动，`_ready` 由接收方驱动
- 非接口数据（纯信号组）时，`(in)`/`(out)` 表示信号方向

**示例：**
```
// 握手接口 (in) — 输入方驱动 valid+data，输出方驱动 ready
data_wi_fb_t(in) {
    din_valid,     // in: 发送方驱动
    din,           // in: 发送方驱动
    din_ready      // out: 接收方驱动
}

// 握手接口 (out) — 输出方驱动 valid+data，输入方驱动 ready
data_wi_fb_t(out) {
    dout_valid,    // out: 发送方驱动
    dout,          // out: 发送方驱动
    dout_ready     // in: 接收方驱动
}

// 非接口数据 (in) — 纯信号组输入
coord_2d_t(in) {
    px[PX_WIDTH-1:0],   // in: 坐标 x 输入
    py[PY_WIDTH-1:0]    // in: 坐标 y 输入
}

// 非接口数据 (out) — 纯信号组输出
image_size_2d_t(out) {
    image_width[IW_WIDTH-1:0],  // out: 图像宽度输出
    image_height[IH_WIDTH-1:0]  // out: 图像高度输出
}
```

### 1.2 标准握手接口 (data_wi_fb_t)

```
interface data_wi_fb_t(in) {
    din_valid,     // 发送方: 数据有效
    din_ready,     // 接收方: 接收方已就绪
    din            // 数据载荷 (位宽自定义)
}
```

约定：
- `din_valid && din_ready` 在时钟上升沿同时为1时，数据传输成功
- `din_valid` 和 `din` 只能由发送方驱动
- `din_ready` 只能由接收方驱动
- 握手信号均为高有效
- 多bit数据 `din` 的位宽在接口名后标注，如 `data_10b_t`

### 1.3 UV5x1 矩阵格式

```
uv5x1: 5行×2分量×DATA_WIDTH bits
  bit [99:90] = u4 (row=4, newest)
  bit [89:80] = v4 (row=4, newest)
  bit [79:70] = u3
  bit [69:60] = v3
  bit [59:50] = u2
  bit [49:40] = v2
  bit [39:30] = u1
  bit [29:20] = v1
  bit [19:10] = u0 (row=0, oldest)
  bit [9:0]   = v0 (row=0, oldest)

每行2P格式: {v[9:0], u[9:0]} (20 bits)
```

### 1.4 列格式 (column)

```
column: 5像素并行, col_0=最老行, col_4=最新行
  col_0: row=0 (oldest)
  col_1: row=1
  col_2: row=2
  col_3: row=3
  col_4: row=4 (newest)
```

### 1.5 元数据接口 (meta_t)

```
interface meta_t(in) {
    center_x[LINE_ADDR_WIDTH-1:0],  // 当前列的x坐标 (PIXEL addr)
    center_y[ROW_CNT_WIDTH-1:0]     // 当前列的y坐标 (PIXEL addr)
}
```

---

## 2. 两条主线

### 主线1: din → Linebuffer → Gradient (可视域内梯度构建)

```
din (YUV422, UV交替, 1P/cycle)
  │
  ▼
u_s2p(common_s2p)           -- 1p_wi_fb_t -->
u_fifo(common_fifo)          -- 2p_wi_fb_t -->
u_dist(common_distributor)   -- 2p_wi_fb_t -->
  │
  │ wr_row = center_y (当前像素所在行)
  │ wr_addr = center_x * 2 (PIXEL addr)
  │ wr_data = 2P
  ▼
u_lb(linebuffer)             [纯SRAM存储, 无逻辑]
  │
  ├─→ [读端口A: 4行 + din] ──────────────────────────────┐
  │     rd_row = center_y - 4, -3, -2, -1 (4行老数据)    │ 4r_din_wi_fb_t
  │     rd_addr = center_x                               │ 4行SRAM读出
  │     din (最新2P)                                    │
  │                                                       ▼
  │                                              u_asmb_g(common_assembler_5x1)
  │                                                   -- col5x1_wi_fb_t -->
  │                                              u_grad(gradient) -- grad_wi_fb_t
  │                                                       │
  └───────────────────────────────────────────────────────┘

主线1输出: grad_h, grad_v, grad_max, win_size
```

**就绪条件**: row>=4 后，4行+din可凑成5×5窗口，开始梯度计算。

### 主线2: Linebuffer + 梯度值 → Filter (滤波输出 + Patch写回)

```
u_lb(linebuffer)
  │
  ├─→ [读端口B: 5行] ────────────────────────────────┐
  │     rd_row = center_y-4 ~ center_y (5行)          │ 5r_wi_fb_t
  │     rd_addr = center_x                            │ 5行SRAM读出
  │                                                       ▼
  │                                              u_asmb_f(common_assembler_5x1)
  │                                                   -- col5x1_wi_fb_t -->
  │                                              u_filt2(stage2) -- dir_avg_wi_fb_t -->
  │                                                           │
  │                                              u_filt3(stage3) -- grad_fuse_wi_fb_t -->
  │                                                           │
  │                                              u_filt4(stage4) -- dout_wi_fb_t
  │                                                           │
  │                                                           ├─→ dout
  │                                                           │
  │                                                           │ patch_wi_fb_t
  └──────────────────────────────────────────────────────────▼──→ u_lb (Patch写回)
```

---

## 3. 完整模块级联

```
din (YUV422, 1P/cycle)
  │
  ▼
u_s2p(common_s2p)           -- 2p_wi_fb_t -->
u_fifo(common_fifo)          -- 2p_wi_fb_t --> [反压链]
u_dist(common_distributor)   -- 2p_wi_fb_t -->
  │
  │ wr_1p_t {wr_en, wr_addr, wr_data, wr_row_sel}
  ▼
u_lb(linebuffer)             [5×1P SRAM, 纯存储]
  │
  ├─→ 4r_din_wi_fb_t ─→ u_asmb_g(common_assembler_5x1)
  │                       -- col5x1_wi_fb_t -->
  │                   u_grad(gradient)
  │                       -- grad_wi_fb_t  --> 方向2
  │
  └─→ 5r_wi_fb_t ─→ u_asmb_f(common_assembler_5x1)
                          -- col5x1_wi_fb_t -->
                      u_filt2(stage2)
                          -- dir_avg_wi_fb_t -->
                      u_filt3(stage3)
                          -- grad_fuse_wi_fb_t -->
                      u_filt4(stage4)
                          ├─→ dout (1P/cycle)
                          └─→ patch_wi_fb_t --> u_lb (Patch写回)
```

---

### 3.2 主线2详细: Filter链

```
u_grad(isp_csiir_gradient)
  │
  │ grad_wi_fb_t {grad_h, grad_v, grad_max, grad_u/v/d/c/l/r}
  │
  ▼
u_filt2(stage2_directional_avg)
  │
  │ dir_avg_wi_fb_t {avg0_c/u/d/l/r, avg1_c/u/d/l/r, grad}
  │
  ▼
u_filt3(stage3_gradient_fusion)
  │
  │ grad_fusion_wi_fb_t {blend0, blend1, avg0_u, avg1_u}
  │
  ▼
u_filt4(stage4_iir_blend)
  │
  ├─→ dout (1P/cycle)
  │
  │ patch_wi_fb_t {patch_5x5, center_x, center_y}
  ▼
u_lb(isp_csiir_linebuffer_5row)   [Patch写回]
```

---

## 4. 各模块接口定义

### 4.1 common_s2p (merge)

```
将两个1P合并为一个2P输出
输入: u_1p_wi_fb_t {din_valid, din_ready, din[DATA_WIDTH-1:0]}
输出: u_2p_wi_fb_t {dout_valid, dout_ready, dout[DATA_WIDTH*2-1:0]}
      + even_cycle (1=even/第1像素, 0=odd/第2像素)

时序:
  Cycle N:   din_valid=1, din=pixelA → buffer pixelA, dout_valid=0
  Cycle N+1: din_valid=1, din=pixelB → output {pixelB, pixelA}, dout_valid=1
  Cycle N+2: din_valid=1, din=pixelC → buffer pixelC, dout_valid=0
  ...

握手: s2p.din_ready ← fifo.din_ready
      s2p.dout_valid && fifo.din_ready → 数据写入fifo
```

### 4.2 common_fifo

```
参数: DATA_WIDTH=20 (2P), DEPTH=N
输入: data_wi_fb_t(in) {
        din_valid, din_ready,      // wr侧握手
        din[DATA_WIDTH*2-1:0]       // 2P数据
      }
输出: data_wi_fb_t(out) {
        dout_valid, dout_ready,    // rd侧握手
        dout[DATA_WIDTH*2-1:0]      // 2P数据
      }
```

### 4.3 common_distributor

```
根据 px/py 将2P数据路由到 linebuffer 的对应行

输入: data_wi_fb_t(in) {
        din_valid,              // in: 2P数据有效
        din,                    // in: 2P数据 [DATA_WIDTH*2-1:0]
        din_ready               // out: 接收方已就绪
      }
      coord_2d_t(in) {
        px[LINE_ADDR_WIDTH-1:0],  // in: 当前像素x (PIXEL addr)
        py[ROW_CNT_WIDTH-1:0]     // in: 当前像素y (PIXEL addr)
      }
      image_size_2d_t(in) {
        img_width_cfg[IMG_W_WIDTH-1:0],
        img_height_cfg[IMG_H_WIDTH-1:0]
      }

输出: 1psram_t(out) — 5路独立写端口 (每路对应一行)
      wr_row_N_en:     wr_row_N的写使能
      wr_row_N_even:   wr_row_N的偶像素数据 (对应px)
      wr_row_N_odd:    wr_row_N的奇像素数据 (对应px+1)

      N ∈ {0, 1, 2, 3, 4}

逻辑:
  wr_row_sel = py % NUM_ROWS    // 循环buffer选行
  wr_data = din                  // 2P: {odd, even}
  wr_row_sel对应的行 = 1          // 其他行 = 0
  每周期最多写一行, py%NUM_ROWS决定写哪行

内部: wr_row_sel = py[log2(NUM_ROWS)-1:0]
      din_even = din[0 +: DATA_WIDTH]   // px对应像素
      din_odd  = din[DATA_WIDTH +: DATA_WIDTH] // px+1对应像素
```

### 4.4 isp_csiir_linebuffer_5row

```
纯SRAM存储, 仅暴露5条独立1P SRAM读写接口

配置参数:
  NUM_ROWS = 5
  IMG_WIDTH, DATA_WIDTH, LINE_ADDR_WIDTH

写端口 (来自distributor, 1psram_t(in)):
  输入: wr_row_N_en
        wr_row_N_even    // px对应像素
        wr_row_N_odd     // px+1对应像素

  N ∈ {0, 1, 2, 3, 4}
  每周期最多一行写使能=1
  内部: wr_data = {odd, even}, 按行独立写入

读端口A (主线1: 4行老数据 + din2P):
  输入: rd_req_wi_fb_t {rd_req, rd_addr}
        rd_addr: PIXEL addr
  输出: 4路读数据 (lb_row_0~lb_row_3)

读端口B (主线2: 5行完整窗口):
  输入: rd_req_wi_fb_t {rd_req, rd_addr}
        rd_addr: PIXEL addr
  输出: 5路读数据 (lb_row_0~lb_row_4)

Patch写回端口 (主线2→主线1):
  输入: patch_wi_fb_t {
          patch_valid, patch_ready,    // handshake
          patch_center_x,              // PIXEL addr
          patch_center_y,              // PIXEL addr
          patch_5x5[DATA_WIDTH*25-1:0]
        }

就绪条件:
  read_ready = (valid_row_count >= 5)  // 5行都写满才可读
  valid_row_count 由 distributor 写入的行号计算
```

### 4.5 common_fifo_uv5x1

```
将5行2P + 当前din2P组装为UV5x1矩阵

输入:
  din_2p_wi_fb_t {
    din_2p_valid, din_2p_ready,
    din_2p[DATA_WIDTH*2-1:0]  // 当前2P (来自fifo)
  }
  col_wi_fb_t {
    col_valid, col_ready,
    col_0~col_4 (5×2P)
  }

输出: uv5x1_wi_fb_t {
        uv5x1_valid, uv5x1_ready,
        uv5x1[DATA_WIDTH*10-1:0]  // UV5x1矩阵
      }

逻辑:
  当 col_valid && col_ready 时:
    - 从fifo读取当前2P (din_from_fifo)
    - 从col读取5×2P (lb_row_0~lb_row_4)
    - 组装: row0=lb_row_0最老, row4=din_from_fifo最新
    - uv5x1_valid ← 1

  当 uv5x1_valid && uv5x1_ready 时:
    - uv5x1_valid ← 0
    - fifo.rd_en ← 1
    - col_ready ← 1 (列已消费)
```

### 4.6 common_assembler_5x1

```
列 → 5×5窗口组装, 内部实现列延迟线

参数: DATA_WIDTH, WIN_DELAY (窗口延迟级数)

输入: col5x1_wi_fb_t {
        col_valid, col_ready,
        col_0~col_4 (5个1P, 当前列),
        center_x, center_y
      }

输出: win5x5_wi_fb_t {
        win_valid, win_ready,
        win_5x5[DATA_WIDTH*25-1:0],  // 按列排: col0~col4, 每列5像素
        center_x, center_y
      }

内部: 延迟线寄存器组 (WIN_DELAY × 5 × DATA_WIDTH bits)
      通过 common_delay_matrix 或 register file 实现

握手: assembler_ready ← 下游ready
      assembler_valid → col_ready

注: 需两个独立实例:
    - u_asmb_g: gradient路径
    - u_asmb_f: filter路径
```

### 4.7 common_p2s

```
将UV5x1矩阵拆分为列输出

输入: uv5x1_wi_fb_t {uv5x1_valid, uv5x1_ready, uv5x1[99:0]}
输出: u_col_wi_fb_t {
        col_valid, col_ready,
        col_0~col_4,
        is_v_column  // 0=u列, 1=v列
      }

时序 (2周期):
  Cycle 0: 输出u列 (col_0~col_4 = u0~u4), is_v_column=0
  Cycle 1: 输出v列 (col_0~col_4 = v0~v4), is_v_column=1

握手:
  din_ready ← uv5x1_valid之前为0, 等列消费完
  col_valid 跟随内部状态机
```

### 4.7 common_col_buffer

```
将1P/cycle流缓冲为列格式

输入: 1P_wi_fb_t {din_valid, din_ready, din[DATA_WIDTH-1:0]}
输出: grad_col_wi_fb_t {
        col_valid, col_ready,
        col_0~col_4,
        center_x, center_y  // 元数据透传
      }

逻辑:
  收集5个1P像素形成一列
  当收集满5个: col_valid ← 1
  当 col_valid && col_ready: col_valid ← 0, 重置计数器
```

### 4.8 isp_csiir_gradient

```
计算Sobel梯度 + 邻域最大 + LUT插值

输入: col5x1_wi_fb_t {
        col_valid, col_ready,
        col_0~col_4 (5×5窗口的当前列),
        center_x, center_y
      }

输出: grad_wi_fb_t {
        grad_valid, grad_ready,
        grad_h[GRAD_WIDTH-1:0],
        grad_v[GRAD_WIDTH-1:0],
        grad_max[GRAD_WIDTH-1:0],
        win_size_clip[WIN_SIZE_WIDTH-1:0],
        center_pixel[DATA_WIDTH-1:0],
        center_x, center_y
      }

内部: 包含 delay_matrix 将列延迟形成5×5窗口
流水线: 5级 (S0 Sobel sum → S1 delay → S2 abs/max → S3 LUT)
Backpressure: grad_ready → assembler_ready → col5x1_ready
```

### 4.9 stage2_directional_avg

```
根据梯度值选择方向性核, 计算多方向平均

输入: col5x1_wi_fb_t {              // 来自u_asmb_g
        col_valid, col_ready,
        col_0~col_4 (5×5窗口的当前列),
        center_x, center_y
      }
      grad_wi_fb_t {               // 梯度值 {grad_h, grad_v, grad_max, win_size}
        grad_valid, grad_ready,
        ...
      }

输出: dir_avg_wi_fb_t {
        avg_valid, avg_ready,
        avg0_c/u/d/l/r,           // s11, 5个方向
        avg1_c/u/d/l/r,           // s11, 5个方向
        grad_max, win_size_clip,
        center_pixel, center_x, center_y
      }

握手: stage2_ready ← stage3_ready
```

### 4.10 stage3_gradient_fusion

```
梯度加权方向融合

输入: dir_avg_wi_fb_t {
        avg_valid, avg_ready,
        avg0_c/u/d/l/r, avg1_c/u/d/l/r,
        grad_max, win_size_clip,
        center_pixel, center_x, center_y
      }
输出: grad_fusion_wi_fb_t {
        blend0, blend1,           // s11
        avg0_u, avg1_u,           // s11, 通过pipeline到stage4
        grad_sum,
        center_pixel, center_x, center_y
      }

关键: 1行延迟 (使用2行BRAM)
      需要 grad_u(上一行), grad_c(当前行), grad_d(下一行)
      row_delay使能: stage2_valid → 写BRAM
```

### 4.11 stage4_iir_blend

```
IIR滤波 + Patch级混合 + Patch写回

输入: grad_fusion_wi_fb_t {
        blend0, blend1,
        avg0_u, avg1_u,
        grad_sum,
        center_pixel, center_x, center_y
      }
输出:
  ├─→ dout (1P/cycle, u10)
  │
  └─→ patch_wi_fb_t {
          patch_valid, patch_ready,
          patch_5x5, center_x, center_y
        }

握手: stage4_ready ← (dout_ready && patch_ready)
```

---

## 5. 流控与反压链

### 5.1 Backpressure 链路

```
dout_ready (外部消费者)
  ← stage4.dout_ready
  ← stage3.dout_ready
  ← stage2.dout_ready
  ← gradient.dout_ready
  ← u_asmb_g.win_ready           // assembler(gradient路径)
  ← fifo_uv5x1.uv5x1_ready
  ← fifo_uv5x1.din_2p_ready (← fifo.rd_ready)
  ← fifo.dout_ready (← distributor.din_ready)
  ← s2p.dout_ready
  ← s2p.din_ready (← din_ready, 外部输入)

注意: distributor 不产生反压 — 它被动接受数据
      linebuffer 写端也无反压 — distributor控制写入节奏
      assembler 不产生独立反压 — backpressure通过win_ready传递
```

### 5.2 行级流控 (Row Credit)

```
前端 (distributor) 写入行号 = center_y
后端 (stage4 patch写回) 完成行号 = patch_center_y

约束: 写行号领先于完成行号不超过 N 行 (N=4, 5行buffer减1行安全余量)
      → 防止BRAM被覆盖

实现: max_center_y_allow = feedback_committed_row + N
      当 center_y > max_center_y_allow 时, 阻塞distributor写入
```

---

## 6. 存储资源

| 模块 | 类型 | 大小 (bit) | 说明 |
|------|------|------------|------|
| linebuffer | 5×SRAM 1P | 5×W×DATA_WIDTH | 纯SRAM, 2P packing |
| fifo (2P缓冲) | sync FIFO | DEPTH×20 | 解耦s2p和distributor |
| common_fifo_uv5x1 | 4-entry FIFO | 4×20 | 缓冲din2P直到列读出 |
| common_assembler (×2) | reg延迟线 | WIN_DELAY×5×DATA_WIDTH×2 | gradient+filter各1份 |
| stage3 | 2×BRAM row | 2×W×(grad+avg) | 1行延迟 |

---

## 7. Q&A 已确认

### Q1: din 格式?
**A**: YUV422, UV交替输入, u,v,u,v...

### Q2: merge 模块?
**A**: merge = common_s2p, 无需 half-write, 2P/1T

### Q3: distributor 写入粒度?
**A**: 2P/1T, linebuffer 数据宽度本来就是 2P, 不需要 half-write

### Q4: assembler 放在哪里?
**A**: 外部, 两份:
- u_asmb_g: gradient路径
- u_asmb_f: filter路径

### Q5: 模块间传递什么?
**A**: 仅传递 assembler 输出的 col5x1, 组装在各自模块内部完成
