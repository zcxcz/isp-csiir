# ISP-CSIIR 架构设计文档

## 文档信息
| 项目 | 内容 |
|------|------|
| 模块名称 | isp_csiir_top |
| 版本 | v2.3 |
| 作者 | rtl-arch |
| 创建日期 | 2026-03-22 |
| 更新日期 | 2026-03-31 |
| 状态 | M3 架构冻结 |
| 目标约束 | 600MHz @ 12nm |
| 功能基线 | `isp-csiir-ref.md` |

---

## 1. 设计目标与约束

### 1.1 强制目标

| 项目 | 要求 | 说明 |
|------|------|------|
| 功能基线 | `isp-csiir-ref.md` | RTL 与 golden model 都必须对齐该语义 |
| 输入/输出 | 10-bit u10 | 范围 0-1023 |
| 吞吐量 | 1 pixel/clock | 非 stall 时持续吞吐 |
| 回压能力 | 端到端 valid/ready | `dout_ready` 拉低必须最终影响 `din_ready` |
| 反馈语义 | patch 级 feedback | 当前中心 patch 更新必须影响后续光栅读取 |
| 工艺目标 | 12nm / 600MHz | 单级组合逻辑按 60-70 FO4 约束 |

### 1.2 架构冻结结论

本版冻结以下技术决策，不再允许 RTL 继续沿用旧的 simplified / always-ready 假设：

1. **stream path 与 patch path 同时存在**：像素主数据流负责吞吐，Stage4 另行输出 patch feedback 总线。
2. **所有 stage 都必须 stall-safe**：当 `valid && !ready` 时，输出数据、valid、坐标、window size、`grad_h`、`grad_v`、patch metadata 全部保持稳定。
3. **line buffer 是 feedback merge 的唯一归口**：Stage4 不能私自维护独立 IIR 行缓存来替代 ref 语义。
4. **Stage3 必须满足因果性**：不得在处理当前中心时直接读取“未来行/未来列”尚未产生的数据。

---

## 2. 总体架构

### 2.1 数据通路总览

```text
输入流:
  din / din_valid / din_ready
    -> isp_csiir_line_buffer
    -> stage1_gradient
    -> stage2_directional_avg
    -> stage3_gradient_fusion
    -> stage4_iir_blend
    -> dout / dout_valid / dout_ready

反馈流:
  stage4_iir_blend
    -> patch_valid / patch_ready
    -> patch_center_x / patch_center_y
    -> patch_5x5
    -> isp_csiir_line_buffer feedback merge
```

### 2.2 顶层必须显式连接的关键信号

| 信号 | 来源 | 去向 | 说明 |
|------|------|------|------|
| `din_ready` | `isp_csiir_top` | 输入端口 | 由整条流水线 backpressure 决定 |
| `window_ready` | Stage1 | line buffer | line buffer → Stage1 窗口边界的正式 ready 信号，必须真实反映 Stage1 可接收能力 |
| `stage1_ready` | Stage2 | Stage1 | Stage1 → Stage2 边界的 ready 信号，由 Stage2 回压决定 |
| `stage2_ready` | Stage3 | Stage2 | Stage2 → Stage3 边界的 ready 信号，由 Stage3 回压决定 |
| `stage3_ready` | Stage4 | Stage3 | Stage3 → Stage4 边界的 ready 信号，由 Stage4 原子提交条件决定 |
| `dout_ready` | 输出端口 | Stage4 | Stage4 stream 输出 sink ready |
| `patch_ready` | line buffer | Stage4 | Stage4 patch feedback sink ready；与 `dout_ready` 一起决定 Stage4 提交 |
| `patch_valid` | Stage4 | line buffer | patch feedback 数据有效 |
| `grad_h` / `grad_v` | Stage1 | Stage4 | Stage4 方向性 2x2 混合的必要输入 |
| `reg_edge_protect` | reg_block | Stage4 | Stage4 edge protection 配置 |

### 2.3 模块层次

```text
isp_csiir_top
├── isp_csiir_reg_block
├── isp_csiir_line_buffer
├── stage1_gradient
├── stage2_directional_avg
├── stage3_gradient_fusion
└── stage4_iir_blend
```

**冻结原则：**
- `isp_csiir_top` 负责 stream path 与 patch path 的 ready/valid 串接。
- `isp_csiir_line_buffer` 负责 5x5 窗口生成、patch feedback merge、输入回压。
- `stage1_gradient`/`stage2_directional_avg`/`stage3_gradient_fusion` 负责算法流水与 Stage4 所需 metadata 透传。
- `stage4_iir_blend` 负责 patch 级混合与 feedback 打包，不负责行缓存存储替代方案。

---

## 3. Stall-safe contract

### 3.1 握手铁律

以下规则适用于 `window_*`、Stage1/2/3/4、输出流与 patch feedback 流：

1. 当 `valid_out && !ready_in` 时，当前 stage 的 **data / valid / metadata / patch metadata** 必须保持稳定。
2. 所有内部计数器、行列指针、flush 状态、buffer 读写指针只能在本地 `fire = valid && ready` 时推进。
3. Stage4 对同一中心的 stream 输出与 patch feedback 采用**原子提交**：只有 `dout_ready && patch_ready` 同时满足时，当前中心事务才允许提交。
4. `dout_ready` 或 `patch_ready` 任一拉低时，stall 必须逐级传回 `stage3_ready`、`stage2_ready`、`stage1_ready`、`window_ready`，最终传回 `din_ready`。
5. 禁止任何 stage 再保留硬编码 `*_ready = 1'b1` 的实现。
6. `valid` 不能组合依赖 `ready`，避免 ready/valid 组合环。

### 3.2 各级 fire 定义

| 边界 | fire 条件 | 允许推进的状态 |
|------|-----------|----------------|
| 输入流 | `din_valid && din_ready` | line buffer 写指针、输入列计数 |
| 窗口到 Stage1 | `window_valid && window_ready` | 窗口中心坐标、window shift |
| Stage1 到 Stage2 | `stage1_valid && stage2_ready` | Stage1 输出寄存器、gradient metadata |
| Stage2 到 Stage3 | `stage2_valid && stage3_ready` | Stage2 双路径平均结果与 metadata |
| Stage3 到 Stage4 | `stage3_valid && stage4_ready` | Stage3 融合结果与 metadata |
| Stage4 原子提交 | `dout_valid && patch_valid && dout_ready && patch_ready` | Stage4 当前中心的 stream 输出与 patch feedback 共同提交 |
| feedback commit | `patch_valid && patch_ready` | line buffer feedback commit，仅在 Stage4 原子提交时发生 |

### 3.3 保持稳定的 metadata

在 stall 期间，以下流式信号与其对应的 valid 必须一起保持：

- `center_x / center_y`
- `win_size_clip`
- `grad_h / grad_v`
- 透传到 Stage4 的 `src_patch_5x5`
- `patch_center_x / patch_center_y`
- `patch_5x5`
- line buffer 内部 flush / row / col 指针状态

说明：`reg_edge_protect` 属于稳定配置输入，不属于随事务流动的 per-sample metadata，但 Stage4 在 stall 期间也不得对其采样语义产生歧义。

---

## 4. Stage3 因果性冻结

### 4.1 问题定义

Stage3 需要五方向梯度 `grad_u / grad_d / grad_l / grad_r / grad_c`。其中 `grad_d` 与 `grad_r` 若按“当前中心实时读取未来数据”实现，会违反因果性。

### 4.2 选定方案：delayed-center / look-back 架构

冻结采用 **delayed-center** 架构：Stage3 不对“当前输入中心”立刻做最终融合，而是对一个延迟后的中心做决策，等到五方向梯度都已经可用再提交。

```text
Row N-1 gradient 已写入 buffer
Row N   gradient 正在流过 Stage1/Stage2
Row N+1 尚未需要被当前提交点直接读取

Stage3 提交点 = 已满足五方向数据可用的 delayed center
```

### 4.3 数据可用性表

| 输入梯度 | 来源 | 可用性 | 架构说明 |
|---------|------|--------|----------|
| `grad_u` | 已提交上一行 buffer | 已可用 | 从 buffer 读取 |
| `grad_c` | 当前 delayed center | 已可用 | 来自对齐后的当前中心 |
| `grad_d` | 下一条已到达的相邻行数据 | 已可用后再提交 | 不允许直接读未来未产生值 |
| `grad_l` | delayed center 左邻点 | 已可用 | 通过移位/缓存获得 |
| `grad_r` | delayed center 右邻点 | 已可用后再提交 | 不允许复制 `grad_c` 代替 |

### 4.4 结论

- `grad_r = grad_c` 属于错误占位实现，不再接受。
- Stage3 文档与 RTL 必须体现“**先满足数据可用，再提交中心结果**”的因果性方案。
- 若实现选择具体为一行延迟、一列延迟、或等价的 shadow/row buffer 结构，必须满足上表，不得改变 ref 语义。

---

## 5. Stage4 → line buffer patch feedback 架构

### 5.1 接口冻结

本轮冻结采用如下 feedback 总线形状：

```text
patch_valid
patch_ready
patch_center_x
patch_center_y
patch_5x5    // 25 x DATA_WIDTH，表示当前中心计算得到的输出 patch
```

如 RTL 实现采用等价打包向量，也必须等价表达上述五项语义。

### 5.2 Stage4 必须消费的输入

Stage4 不再允许退化为单点 center mixing。其输入必须至少包含：

- `blend0_dir_avg`
- `blend1_dir_avg`
- `win_size_clip`
- `src_patch_5x5`
- `grad_h`
- `grad_v`
- `reg_edge_protect`
- `center_x / center_y`

### 5.3 feedback merge 语义

line buffer 的 feedback merge 必须满足：

1. Stage4 对同一中心的 `dout` 与 `patch_5x5` 采用原子提交；提交条件固定为 `dout_valid && patch_valid && dout_ready && patch_ready`。
2. 当前中心 `(x, y)` 生成的新 `patch_5x5` 只允许在原子提交成功时写入 line buffer。
3. **只有 handshake 成功才允许 commit**；`patch_valid && !patch_ready` 或 `dout_valid && !dout_ready` 时，patch 数据保持稳定，且 line buffer 不得提前写入。
4. 后续光栅顺序中所有位于 `(x, y)` 之后的窗口读取，必须看到已提交的最新 patch 覆盖值。
5. 同一地址若既有原始输入写入又有 patch feedback，必须按 ref 语义定义的 raster order 选取“最新生效值”。

### 5.4 line buffer 内部职责边界

line buffer 内部可以采用以下任一微架构：

- 直接 RAM 覆盖
- overlay / merge 表
- 分阶段提交缓存
- 其他等价结构

**但无论实现形式如何，都必须满足：**
- patch feedback 影响后续窗口读取
- patch 与 stream 共用 stall-safe 规则
- 输入写指针与 feedback commit 都只在各自 fire 时更新

---

## 6. 模块职责冻结

### 6.1 `isp_csiir_reg_block`
- 导出所有配置寄存器。
- `reg_edge_protect` 必须从此模块显式连到 `isp_csiir_top` 再到 `stage4_iir_blend`。

### 6.2 `isp_csiir_line_buffer`
- 生成 5x5 输入窗口。
- 接收 `patch_valid / patch_ready / patch_center_x / patch_center_y / patch_5x5`。
- 对窗口输出和输入吞吐实施真实 backpressure。
- 不负责 Stage4 算法混合，只负责 merge 与窗口生成。

### 6.3 `stage1_gradient`
- 负责 Stage1 梯度计算。
- 输出 `grad_h`、`grad_v`、`grad`、`win_size_clip`。
- 作为 `src_patch_5x5`、位置与梯度 metadata 的起点。
- `stage1_ready` 必须真实参与回压。

### 6.4 `stage2_directional_avg`
- 负责真正的 avg0/avg1 双路径方向平均。
- 保持并透传 `src_patch_5x5`、`grad_h`、`grad_v`、位置、`win_size_clip` 等 Stage4 所需 metadata。
- `stage2_ready` 必须真实参与回压。

### 6.5 `stage3_gradient_fusion`
- 负责方向绑定的梯度融合。
- 采用满足因果性的 delayed-center 方案。
- 保持并透传 Stage4 所需 metadata。
- `stage3_ready` 必须真实参与回压。

### 6.6 `stage4_iir_blend`
- 消费 `src_patch_5x5`、`grad_h`、`grad_v`、`reg_edge_protect`。
- 完成 IIR + 方向性 2x2 + patch 窗混合。
- 输出 stream pixel 与 patch feedback 总线。
- Stage4 内部不得另立“替代 ref 语义”的专用 IIR 行缓存。

### 6.7 `isp_csiir_top`
- 负责整条 stream path 的 ready/valid 串接。
- 负责 patch path 的 ready/valid 串接。
- 负责 `grad_h`、`grad_v`、`src_patch_5x5`、`reg_edge_protect` 的跨 stage 接线。

---

## 7. 关键路径与实现约束

### 7.1 明确需要 RTL 落地的高风险运算

| 模块 | 高风险操作 | 架构要求 |
|------|------------|----------|
| Stage2 | 双路径求和 + 除法 | 变量除法不得直接 `/`，必须迭代或近似方案 |
| Stage3 | 排序网络 + 加权和 | 排序与乘加拆分流水，满足 stalled-state 保持 |
| Stage4 | patch 级混合 | patch 混合与输出寄存分级，避免单级超深组合逻辑 |
| line buffer | 读窗 + feedback merge | merge 只在 handshake 成功时生效 |

### 7.2 时序预算原则

- 单级组合逻辑目标：60-70 FO4。
- 所有 ready 路径优先使用 slice/skid buffer 打断，避免跨多级的长组合反压链。
- Stage2/Stage3 的除法器必须在文档和 RTL 中显式说明实现方式，禁止文档说“迭代除法器”而 RTL 直接写 `/`。

---

## 8. 验证检查点

### 8.1 架构级检查

- [ ] 文档中明确出现 `din_ready` / `dout_ready` / `stage1_ready` / `stage2_ready` / `stage3_ready`
- [ ] 文档中明确出现 `patch_valid` / `patch_ready` / `patch_center_x` / `patch_center_y` / `patch_5x5`
- [ ] 文档中明确 Stage4 消费 `grad_h` / `grad_v` / `reg_edge_protect`
- [ ] 文档中明确 Stage3 采用因果性安全方案，不再读取未来未产生值

### 8.2 RTL 落地前置检查

- [ ] 不再接受 `*_ready = 1'b1` 的硬编码占位
- [ ] 不再接受 `if (0 && lb_wb_en)` 一类被禁用的 feedback 路径
- [ ] 不再接受 `grad_r = grad_c` 一类方向占位实现
- [ ] 不再接受 Stage4 仅输出 scalar center mixing 的架构

---

## 9. 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-22 | rtl-arch | 初始版本 |
| v2.0 | 2026-03-22 | rtl-arch | 更新为 600MHz 设计 |
| v2.1 | 2026-03-22 | rtl-algo/rtl-arch | 修正行缓存与 IIR 写回描述 |
| v2.2 | 2026-03-22 | rtl-pm/rtl-arch | 修正像素行缓存为 5 行 |
| v2.3 | 2026-03-31 | rtl-arch | 冻结 stall-safe backpressure、Stage3 因果性与 Stage4 patch feedback 架构 |
