# ISP-CSIIR Stall-Safe 流水线与 Feedback 重构规范

**版本**: v2.0
**作者**: rtl-arch
**日期**: 2026-03-31
**状态**: 架构冻结
**功能基线**: `isp-csiir-ref.md`

---

## 1. 目标

本规范只回答一件事：**如何让 CSIIR 流水线在 ref 语义不变的前提下，实现端到端 backpressure 与 patch feedback。**

冻结后的实现目标：

1. `dout_ready` 拉低时，Stage4 到 line buffer 的所有状态都能安全冻结。
2. `din_ready` 必须真实反映整条流水线是否还能接收新像素。
3. Stage4 的 patch feedback 必须通过 `patch_valid / patch_ready` 与 line buffer 交互。
4. `grad_h`、`grad_v`、`reg_edge_protect`、`src_patch_5x5` 必须被纳入同一套 stall-safe metadata 通路。

---

## 2. 握手协议规范

### 2.1 基本定义

```verilog
wire fire = valid && ready;
```

**统一规则：**
- 只有 `fire` 时，当前边界的数据传输才算成功。
- 只有 `fire` 时，当前边界相关的状态才能推进。
- 当 `valid && !ready` 时，发送端必须保持 data/metadata/valid 不变。

### 2.2 不允许的实现

以下写法在 CSIIR 中全部禁止：

```verilog
assign din_ready = 1'b1;
assign stage1_ready = 1'b1;
assign stage2_ready = 1'b1;
assign stage3_ready = 1'b1;
assign patch_ready = 1'b1;   // 若 line buffer 无法实时 merge，不允许常高占位
```

### 2.3 Stream path 握手链

```text
line_buffer.window_valid / window_ready
stage1_valid / stage2_ready
stage2_valid / stage3_ready
stage3_valid / stage4_ready
dout_valid / dout_ready
```

**要求：**
- `window_ready` 是 line buffer → Stage1 边界的正式 ready 名称。
- `stage1_ready` 由 Stage2 下游回压决定，并回传给 Stage1。
- `stage2_ready` 由 Stage3 下游回压决定，并回传给 Stage2。
- `stage3_ready` 由 Stage4 原子提交条件决定，并回传给 Stage3。
- `stage4_ready` 在文档中仅作为 `stage3_valid / stage4_ready` 边界语义描述；RTL 端口命名冻结为 Stage4 输出 `stage3_ready`。
- `din_ready` 由 line buffer 可否继续接收新像素决定，且必须最终受 `dout_ready` 与 `patch_ready` 共同影响。

### 2.4 Patch path 握手链

```text
patch_valid / patch_ready
patch_center_x / patch_center_y
patch_5x5
```

**要求：**
- `patch_valid` 与 `patch_5x5`、坐标同周期对齐。
- `patch_valid && !patch_ready` 时，Stage4 必须保持 `patch_center_x`、`patch_center_y`、`patch_5x5` 稳定。
- `patch_fire = patch_valid && patch_ready` 之前，line buffer 不得提前 merge。

---

## 3. 必须保持稳定的信号集合

### 3.1 Stage 间 metadata

以下**流式信号**在 `valid && !ready` 时必须保持：

| 类别 | 信号 |
|------|------|
| 坐标 | `center_x` / `center_y` |
| 梯度 | `grad_h` / `grad_v` / `grad` |
| 窗口 | `src_patch_5x5` |
| 配置相关 | `win_size_clip` |
| feedback | `patch_center_x` / `patch_center_y` / `patch_5x5` |

补充说明：
- `reg_edge_protect` 属于稳定配置输入，不属于随事务流动的 per-sample metadata。
- 但 Stage4 在 stall 期间仍必须保持其对当前事务的采样语义一致，不允许因回压导致配置解释漂移。

### 3.2 状态推进条件

| 模块 | 只能在何时推进 |
|------|----------------|
| `isp_csiir_line_buffer` | `din_valid && din_ready` 或 `patch_valid && patch_ready` |
| `stage1_gradient` | `stage1_valid && stage2_ready` |
| `stage2_directional_avg` | `stage2_valid && stage3_ready` |
| `stage3_gradient_fusion` | `stage3_valid && stage4_ready` |
| `stage4_iir_blend` | `dout_valid && patch_valid && dout_ready && patch_ready` |

---

## 4. 推荐实现骨架

### 4.1 Stage 边界

优先使用现有公共模块：

- `common_pipe`
- `common_pipe_slice`
- `common_skid_buffer`

**推荐模式：**

```verilog
wire fire_in;
wire fire_out;

assign fire_in  = valid_in  && ready_out;
assign fire_out = valid_out && ready_in;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_reg <= 1'b0;
    end else if (fire_in || !valid_reg || ready_in) begin
        valid_reg <= valid_in;
        if (valid_in)
            data_reg <= data_next;
    end
end
```

### 4.2 Ready 路径原则

- ready 可以向上游组合传播，但不能跨过过多层级形成超长组合路径。
- 必要时在 stage 边界加入 `common_pipe_slice` 或 `common_skid_buffer` 打断。
- patch path 与 stream path 使用同样的 ready/valid 设计哲学。

---

## 5. Stage4 patch feedback 规范

### 5.1 选定接口

本项目冻结采用如下命名：

```text
patch_valid
patch_ready
patch_center_x
patch_center_y
patch_5x5
```

### 5.2 Stage4 输入集合

Stage4 必须在同一条对齐后的 metadata 通路中拿到：

- `src_patch_5x5`
- `grad_h`
- `grad_v`
- `win_size_clip`
- `reg_edge_protect`
- `center_x / center_y`

### 5.3 Stage4 输出与 line buffer merge

```text
Stage4 patch_fire
  -> line buffer commit patch
  -> 后续窗口读取看到更新后的像素值
```

**约束：**
- Stage4 对同一中心的 `dout` 与 `patch_5x5` 采用原子提交，提交条件固定为 `dout_valid && patch_valid && dout_ready && patch_ready`。
- patch commit 只允许发生在原子提交成功后的 `patch_fire`。
- 若 line buffer 尚不能 merge，则必须通过 `patch_ready=0` 回压 Stage4，而不是吞下后延迟处理却不保持稳定。
- stream path stall 与 patch path stall 必须一致，不允许一个路径冻结、另一个路径偷偷前冲。
- 不允许 stream 输出先于对应 patch 提交，也不允许 patch 先于对应 stream 输出提交。

---

## 6. line buffer 规范

### 6.1 输入侧

`din_ready` 需要同时考虑：
- 当前窗口生成是否可继续推进
- 下游 `window_ready` 是否允许继续消费窗口
- patch merge 是否导致本地状态必须冻结

### 6.2 输出侧

`window_valid` 仅表示当前窗口可交给 Stage1。只有 `window_valid && window_ready` 时，窗口中心坐标和窗口内容才允许前进。

### 6.3 feedback merge 侧

line buffer 至少需要满足以下语义：

1. patch feedback 优先于旧值参与后续窗口读取。
2. merge 后的新值必须按光栅顺序影响后续中心。
3. patch merge 与输入流写入的仲裁规则必须显式且稳定。

---

## 7. Stage3 因果性规范

### 7.1 规则

- 不允许在“当前提交中心”直接读取未来未产生的 `grad_d`。
- 不允许把 `grad_r` 简化为 `grad_c`。
- 若邻域梯度要依赖未来像素，必须把提交中心延迟到所有方向梯度都可用的时刻。

### 7.2 架构结论

Stage3 采用 **因果性安全的 delayed-center** 方案。具体是：
- 允许通过行缓存/影子缓存/移位寄存器持有邻域梯度；
- 不允许通过“读取未来数据占位”来伪造邻域；
- stall 时这些缓存的读写推进也必须冻结。

---

## 8. 验证清单

### 8.1 文档级关键字检查

以下关键字必须出现在相关架构文档中：

- `patch_valid`
- `patch_ready`
- `stage1_ready`
- `stage2_ready`
- `stage3_ready`
- `dout_ready`
- `din_ready`
- `grad_h`
- `grad_v`
- `reg_edge_protect`

### 8.2 RTL 落地前必须确认

- [ ] 没有常高 `*_ready` 占位
- [ ] 没有被禁用的 feedback 写回逻辑
- [ ] Stage4 不是 scalar center-only mixing
- [ ] Stage3 邻域梯度组织满足因果性
- [ ] `valid && !ready` 时输出与 metadata 稳定

---

## 9. 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-24 | rtl-arch | 初始规范 |
| v2.0 | 2026-03-31 | rtl-arch | 按 ref 语义重写为 stall-safe 与 patch feedback 规范 |
