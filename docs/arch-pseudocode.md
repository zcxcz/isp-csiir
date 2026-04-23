# ISP-CSIIR 架构伪代码

## 0. 已知信息 (用户确认)

- **din格式**: YUV422, UV交替输入
- **数据宽度**: 1P = DATA_WIDTH bits
- **SRAM类型**: 全部使用 1P SRAM (禁止使用2P SRAM)
- **linebuffer控制**: gradient路径和filter路径各用独立模块控制
  - `lb_ctrl_g`: 控制原图linebuffer的gradient读端口
  - `lb_ctrl_f`: 控制原图linebuffer的filter读端口 + 滤波linebuffer
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

### 主线1: din → 原图Linebuffer → Gradient (可视域内梯度构建)

```
din (YUV422, UV交替, 1P/cycle)
  │
  ▼
u_s2p(common_s2p)           -- 1p_wi_fb_t -->
u_fifo(common_fifo)          -- 2p_wi_fb_t --> [反压链]
  │
  │ wr_2p = 2P数据 (原图)
  │ wr_row_ptr = EOL时递增 (0→1→2→3→0循环), 循环选行
  │ wr_col_ptr = 每像素递增, 控制waddr
  │ orig_valid_row_cnt = 有效数据行计数 (EOL时+1)
  ▼
u_lb_src(原图linebuffer)    [4×SRAM, 含内部distribution逻辑]
  │
  ├─→ [读端口G: grad_col5x1] ───────────────────────────────┐
  │     grad_row_rd_ptr: 当前读取的行指针 (circular)          │ grad_col5x1_wi_fb_t
  │     grad_col_rd_ptr: 列指针 (读地址)                      │ 4行老数据SRAM读出
  │     输出 col_0~col_3 (4行) + din (最新2P→拆分为col_4)   │ + 当前din拼为第5列
  │     有效条件: orig_valid_row_cnt >= 4                    │
  │                                                             ▼
  │                                                      u_asmb_g(common_assembler_5x1)
  │                                                           -- col5x1_wi_fb_t -->
  │                                                      u_grad(gradient) -- grad_wi_fb_t
  │                                                               │
  └───────────────────────────────────────────────────────────────┘

din --data_wi_fb(10b)--> u_s2p_din_1x2(common_s2p)
--data_wi_fb(20b)--> u_fifo_din_1x2(common_fifo) --data_wi_fb(20b)--> u_lb_ctrl_din_1x2(common_lb_ctrl)
--> u_lb_din_4x2(common_lb)
u_lb_din_4x2(common_lb) --data_wi_fb(80b) --> u_fifo_lb_din_4x2(common_fifo) --data_wi_fb(80b)-->
u_p2s_din_4x1(common_p2s) --data_wi_fb(40b) --> u_fifo_din_4x1(common_fifo) --data_wi_fb(40b)--> u_grad_calc_5x5(grad_calc_5x5) --data_wi_fb(30b?)--> dout
din --data_wi_fb(10b)--> u_fifo_din_1x1(common_fifo) --data_wi_fb(10b) --> u_grad_calc_5x5(grad_calc_5x5)

其中，u_grad_calc_5x5 开始计算依赖于 u_fifo_din_1x1 与 u_fifo_din_4x1 两个 fifo 的数据均 ready；

主线1输出: grad_h, grad_v, grad_max, win_size

**重要**: gradient/stage2 使用的 `src_uv_5x5` 来自原图 linebuffer，
          不是滤波 linebuffer —— 见 ref.md Section 2.3 和 3.4
```

**就绪条件**: `orig_valid_row_cnt >= 4` 后，4行+din可凑成5×5窗口，开始梯度计算。

### 主线2: 原图Linebuffer + 梯度值 → 滤波Linebuffer → Filter (滤波输出 + Patch写回)

```
u_lb_src(原图linebuffer)
  │
  │ 读端口F: 5行原图 ─────────────────────────────────────────┐
  │ filt_row_rd_ptr: 读取行指针                               │ src_col5x1_wi_fb_t
  │ filt_col_rd_ptr: 读取列指针                                │ 5行原图SRAM读出
  │ 有效条件: orig_valid_row_cnt >= 5                        │
  │                                                             ▼
  │                                                    u_asmb_f(common_assembler_5x1)
  │                                                         -- col5x1_wi_fb_t -->
  │                                                    u_filt2(stage2) -- dir_avg_wi_fb_t -->
  │                                                                │
  │                                                    u_filt3(stage3) -- grad_fuse_wi_fb_t -->
  │                                                                │
  │                                                    u_filt4(stage4) -- dout_wi_fb_t
  │                                                                │
  │                                                                ├─→ dout
  │                                                                │
  │                                                                │ patch_wi_fb_t (滤波结果)
  └──────────────────────────────────────────────────────────────▼──┬
                                                                       │
  ┌──────────────────────────────────────────────────────────────────┘
  │
  ▼
u_lb_filt(滤波linebuffer)   [5×SRAM, 存滤波中间结果]
  │
  │ 读端口: 后续行读取 ──────────────────────────────────────────┐
  │ filt_row_rd_ptr (读取)                                        │ filt_col5x1_wi_fb_t
  │                                                                │ 后续行读出构成邻域
  └────────────────────────────────────────────────────────────────┘

**重要**: 滤波 linebuffer 存的是 stage4 输出的 blend_uv_5x5，
          后续像素读取时，用原图linebuffer的当前行 + 滤波linebuffer的4行老数据共同构成邻域
```

---

## 3. 完整模块级联

```
din (YUV422, 1P/cycle)
  │
  ▼
u_s2p(common_s2p)           -- 2p_wi_fb_t -->
u_fifo(common_fifo)          -- 2p_wi_fb_t --> [反压链]
  │
  │ wr_2p: FIFO输出2P (原图)
  │ EOL: 行结束信号 (驱动wr_row_ptr递增和orig_valid_row_cnt更新)
  ▼
u_lb_src(原图linebuffer)     [4×SRAM, 存原始图像数据]
  │
  ├─→ grad_col5x1_wi_fb_t ─→ u_asmb_g(common_assembler_5x1)
  │                           -- col5x1_wi_fb_t -->
  │                       u_grad(gradient)
  │                           -- grad_wi_fb_t  --> u_filt2 (stage2)
  │
  ├─→ src_col5x1_wi_fb_t ──────────────────────────────────────────┐
  │                                                                   │ 5行原图
  │                                                   u_asmb_f(common_assembler_5x1)
  │                                                        -- col5x1_wi_fb_t -->
  │                                                    u_filt2(stage2)
  │                                                        -- dir_avg_wi_fb_t -->
  │                                                    u_filt3(stage3)
  │                                                        -- grad_fuse_wi_fb_t -->
  │                                                    u_filt4(stage4)
  │                                                        ├─→ dout (1P/cycle)
  │                                                        └─→ patch_wi_fb_t (滤波结果)
  └───────────────────────────────────────────────────────────────┬
                                                                      │
  ┌──────────────────────────────────────────────────────────────────┘
  │
  ▼
u_lb_filt(滤波linebuffer)     [5×SRAM, 存滤波中间结果]
  │
  └─→ filt_col5x1_wi_fb_t ──→ (后续行读取，构成滤波邻域)
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
参数: DATA_WIDTH, DEPTH=N
输入: data_wi_fb_t(in) {
        din_valid, din_ready,      // wr侧握手
        din[DATA_WIDTH-1:0]        // 1P数据
      }
输出: data_wi_fb_t(out) {
        dout_valid, dout_ready,    // rd侧握手
        dout[DATA_WIDTH-1:0]        // 1P数据
      }
```

### 4.3 isp_csiir_linebuffer_core

```
集成distribution逻辑的5行1P SRAM存储

配置参数:
  NUM_ROWS     = 5
  IMG_WIDTH, DATA_WIDTH, LINE_ADDR_WIDTH
  SRAM_TYPE    = "1P"  // 1P SRAM，禁止使用2P

内部状态:
  wr_row_ptr:     行写指针 (EOL时0→1→2→3→4→0循环)
  wr_col_ptr:     列写指针 (每像素+1)
  fifo_valid_row_cnt: 有效数据行计数 (0~5, EOL时+1)

写端口 (来自FIFO, 1P):
  输入: data_wi_fb_t(in) {
          din_valid, din_ready,
          din[DATA_WIDTH-1:0]    // 1P数据
        }
        eol                      // in: 行结束信号 (驱动wr_row_ptr递增)
        sof                      // in: 帧开始信号 (复位指针)

  逻辑:
    - din_valid && din_ready 时写入 SRAM
    - wr_row_ptr 控制片选 (wr_row = wr_row_ptr)
    - wr_col_ptr 生成 SRAM 写地址
    - EOL时 wr_row_ptr++, wr_col_ptr<=0, fifo_valid_row_cnt++

  SRAM内部:
    - wr_data = din[DATA_WIDTH-1:0] (1P packing)
    - 每行独立使能: wr_row_N_en = (wr_row_ptr == N)
```

### 4.3.1 lb_ctrl_g (Gradient读控制模块)

```
独立控制原图linebuffer的gradient读端口

职责:
  - 管理原图linebuffer的读端口G
  - 提供4行老数据 + 当前din组成的col5x1
  - 独立反压链

输出: grad_col5x1_wi_fb_t {
        grad_col_valid, grad_col_ready,  // 握手
        grad_col_0~grad_col_3,           // 4行老数据 (1P)
        grad_col_4,                       // 当前din (最新像素)
        grad_center_x, grad_center_y     // 元数据
      }

关键约束:
  - 外部管理 grad_row_rd_ptr 和 grad_col_rd_ptr
  - 有效条件: orig_valid_row_cnt >= 4
  - 独立反压: grad_col_ready → assembler_ready
```

### 4.3.2 lb_ctrl_f (Filter读控制模块)

```
独立控制原图linebuffer的filter读端口 + 滤波linebuffer

职责:
  - 管理原图linebuffer的读端口F (5行原图)
  - 管理滤波linebuffer的读端口 (后续行滤波结果)
  - 提供5行原图组成的col5x1

输出: src_col5x1_wi_fb_t {
        filt_col_valid, filt_col_ready,  // 握手
        filt_col_0~filt_col_4,           // 5行 (1P, 原图)
        filt_center_x, filt_center_y     // 元数据
      }

关键约束:
  - 外部管理 filt_row_rd_ptr 和 filt_col_rd_ptr
  - 有效条件: orig_valid_row_cnt >= 5
  - 独立反压: filt_col_ready → assembler_ready
```

### 4.4 isp_csiir_linebuffer (wrapper)

```
isp_csiir_linebuffer_core 的外层封装

封装内容:
  - Patch写回FSM (将patch_5x5转换为列写)
  - 元数据管理 (sof/eol传递)
  - 包含 lb_ctrl_g 和 lb_ctrl_f 两个独立控制模块

对外接口:
  - 1P输入: din, din_valid, din_ready, sof, eol
  - Gradient输出: grad_col_0~grad_col_4, grad_col_valid, grad_col_ready
  - Filter输出: filt_col_0~filt_col_4, filt_col_valid, filt_col_ready
  - Patch反馈输入: patch_valid, patch_ready, patch_5x5, center_x/y
  - 配置: img_width, img_height
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
  ← u_lb.grad_col_ready          // linebuffer gradient读端口
  ← (filter路径独立反压)
  ← fifo_uv5x1.uv5x1_ready
  ← fifo_uv5x1.din_2p_ready (← fifo.rd_ready)
  ← fifo.dout_ready (← s2p.dout_ready)
  ← s2p.din_ready (← din_ready, 外部输入)

注意: linebuffer 内部写侧无反压 — FIFO控制写入节奏
      两读端口各自独立反压
      assembler 不产生独立反压 — backpressure通过win_ready传递
```

### 5.2 行级流控 (Row Credit)

```
前端写入: wr_row_ptr (EOL时递增)
后端完成: patch_center_y (patch写回完成行号)

约束: wr_row_ptr 领先于 patch写回行号不超过 N 行 (N=4)
      → 防止BRAM被覆盖

实现: max_center_y_allow = patch_center_y + N
      当 wr_row_ptr > max_center_y_allow 时, 阻塞FIFO→linebuffer写入
```

---

## 6. 存储资源

| 模块 | 类型 | 大小 (bit) | 说明 |
|------|------|------------|------|
| u_lb_src (原图) | 4×SRAM 1P | 4×W×DATA_WIDTH | 存原始图像，gradient/stage2共读 |
| u_lb_filt (滤波) | 5×SRAM 1P | 5×W×DATA_WIDTH | 存滤波中间结果，stage4写回 |
| fifo (1P缓冲) | sync FIFO | DEPTH×DATA_WIDTH | 解耦输入和原图linebuffer |
| common_assembler (×2) | reg延迟线 | WIN_DELAY×5×DATA_WIDTH | gradient+filter各1份 |
| stage3 | 2×BRAM row | 2×W×(grad+avg) | 1行延迟 |

**注**:
- 全部使用 1P SRAM，禁止使用 2P SRAM
- 两路 linebuffer 均使用 1P SRAM (1PORT 或 1P 2PORT)

---

## 7. Q&A 已确认

### Q1: din 格式?
**A**: YUV422, UV交替输入, u,v,u,v...

### Q2: merge 模块?
**A**: merge = common_s2p, 无需 half-write, 2P/1T

### Q3: distributor 去掉了，放在哪里?
**A**: distributor 逻辑集成到 linebuffer 内部:
- `row_wr_ptr`: EOL 时递增，控制 SRAM 片选
- `col_wr_ptr`: 每像素递增，控制写地址
- FIFO 直接接 linebuffer，无需中间模块

### Q4: 为什么需要两个 linebuffer?
**A**: ref.md 明确要求（Section 2.3, 3.4）:
- **gradient (S1)**: `grad_h = src_uv_u10_5x5 * sobel` → 用**原图**
- **stage2 (S2)**: `avg_value = sum(src_uv_s11_5x5 * factor)` → 用**原图**
- **stage4 (S4)**: `blend_uv_5x5` 写回 → 存的是**滤波结果**

因此:
- `u_lb_src`（4行）：存**原图**，gradient 和 stage2 都读原图
- `u_lb_filt`（5行）：存**滤波结果**，stage4 写滤波 patch，后续行读取构成邻域

### Q5: 两路 linebuffer 的读端口如何独立?
**A**: 两路独立控制模块 + 1P SRAM (1PORT):
- `lb_ctrl_g`: 控制原图linebuffer的gradient读端口，输出4行+din
- `lb_ctrl_f`: 控制原图linebuffer的filter读端口 + 滤波linebuffer
- 各控制模块独立管理自己的 `*_row_rd_ptr` 和 `*_col_rd_ptr`
- 原图linebuffer: gradient和filter各需读5行，但可分时复用同一SRAM或用1P 2PORT
- 滤波linebuffer: 读端口(后续行)和写端口(stage4 patch)需分时复用

### Q6: 为什么禁止使用2P SRAM?
**A**: 用户约束，全部使用1P SRAM:
- 每个SRAM单元宽度 = DATA_WIDTH (1P)
- 地址深度 = IMG_WIDTH
- 原先2P SRAM方案已被否定，统一改为1P
- FIFO也改为1P宽度缓冲

### Q7: assembler 放在哪里?
**A**: 外部, 两份:
- u_asmb_g: gradient路径（读原图linebuffer）
- u_asmb_f: filter路径（读原图linebuffer的5行）

### Q8: 模块间传递什么?
**A**: 仅传递 assembler 输出的 col5x1, 组装在各自模块内部完成

### Q9: 后续行如何读取滤波邻域?
**A**: 滤波邻域的构成方式:
- 原图 linebuffer 提供当前行的 5 个像素（原图）
- 滤波 linebuffer 提供上方 4 行的 5 个像素（滤波结果）
- 共同构成 5×5 邻域用于后续像素的滤波计算
