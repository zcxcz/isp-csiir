# ISP-CSIIR 模块划分文档

## 文档信息
| 项目 | 内容 |
|------|------|
| 模块名称 | isp_csiir_top |
| 版本 | v1.1 |
| 作者 | rtl-arch |
| 创建日期 | 2026-03-22 |
| 更新日期 | 2026-03-31 |
| 状态 | 架构冻结 |
| 功能基线 | `isp-csiir-ref.md` |

---

## 1. 子模块列表与职责

### 1.1 模块总览

| 模块名称 | 功能描述 | 流水角色 | 关键新增职责 |
|----------|----------|----------|--------------|
| `isp_csiir_top` | 顶层集成与握手汇总 | 控制/集成 | 串接 stream path 与 patch path，导出 `din_ready`，接入 `dout_ready` |
| `isp_csiir_reg_block` | 寄存器配置块 | 配置 | 导出 `reg_edge_protect` 到 Stage4 |
| `isp_csiir_line_buffer` | 5x5 窗口生成与反馈归并 | 存储/入口 | patch feedback merge、窗口输出回压、输入回压 |
| `stage1_gradient` | 梯度计算与窗口大小确定 | Stage1 | 输出 `grad_h` / `grad_v`，提供 Stage4 所需 metadata 起点 |
| `stage2_directional_avg` | 双路径方向平均 | Stage2 | 真正实现 avg0/avg1 双路径，并透传 patch/gradient metadata |
| `stage3_gradient_fusion` | 方向绑定梯度融合 | Stage3 | 因果性安全的 delayed-center 融合，并透传 metadata |
| `stage4_iir_blend` | patch 级混合与输出 | Stage4 | 消费 `src_patch_5x5`、`grad_h`、`grad_v`、`reg_edge_protect`，输出 `patch_valid` |

### 1.2 设计边界总原则

1. 功能语义以 `isp-csiir-ref.md` 为唯一基线。
2. 所有模块都必须遵守 valid/ready stall-safe contract。
3. `stage4_iir_blend` 不允许以独立 IIR 行缓存替代 patch feedback 语义。
4. `isp_csiir_line_buffer` 只负责 **窗口生成 + feedback merge + 输入回压**，不承担 Stage4 算法决策。

---

## 2. 各模块职责详述

### 2.1 `isp_csiir_top`

**职责：**
- 集成所有子模块。
- 连接 `din_ready`、`window_ready`、`stage1_ready`、`stage2_ready`、`stage3_ready`、`dout_ready`、`patch_ready`。
- 汇总并转发 `src_patch_5x5`、`grad_h`、`grad_v`、`win_size_clip`、坐标等 metadata。
- 将 `reg_edge_protect` 从寄存器块显式送入 Stage4。
- 串接 Stage4 → line buffer 的 patch feedback 总线。
- 确保 Stage4 对同一中心的 stream 输出与 patch feedback 采用原子提交语义。

**不负责：**
- 不在顶层重新实现 Stage2/3/4 算法。
- 不在顶层复制一套 feedback merge 存储。

### 2.2 `isp_csiir_reg_block`

**职责：**
- 提供寄存器读写接口。
- 输出阈值、blend ratio、clip 参数。
- 导出 `reg_edge_protect`。

**接口边界：**
- `reg_edge_protect` 必须作为稳定配置输入送至 `isp_csiir_top` 和 `stage4_iir_blend`。

### 2.3 `isp_csiir_line_buffer`

**职责：**
- 接收 `din / din_valid / din_ready`。
- 生成 5x5 `src_patch_5x5` 窗口。
- 输出 `window_valid`，接收 `window_ready`。
- 接收 `patch_valid / patch_ready / patch_center_x / patch_center_y / patch_5x5`。
- 在不改变 ref 语义前提下，把 patch feedback merge 到后续窗口读取路径。

**命名冻结：**
- line buffer → Stage1 窗口边界的正式 ready 名称固定为 `window_ready`。
- `stage1_ready` 仅用于 Stage1 → Stage2 边界，不再混用于 line buffer 输出边界。

**冻结约束：**
- 行列指针、flush 状态只能在本地 handshake 成功时前进。
- `patch_valid && !patch_ready` 时不得提前 commit patch。
- `din_ready` 不得只依赖 frame_started；必须受下游回压影响。

### 2.4 `stage1_gradient`

**职责：**
- 从 5x5 `src_patch_5x5` 计算 `grad_h`、`grad_v`、`grad`、`win_size_clip`。
- 起始打包并透传中心坐标、window size、source patch。
- 输出 `stage1_valid`，接收 `stage1_ready`。

**冻结约束：**
- `stage1_ready` 真实参与回压，不能硬编码常高。
- stall 时 Stage1 输出寄存器与 metadata 保持稳定。

### 2.5 `stage2_directional_avg`

**职责：**
- 根据 `win_size_clip` 选择 avg0/avg1 两条不同 kernel 路径。
- 输出 avg0/avg1 五方向结果。
- 继续透传 `src_patch_5x5`、`grad_h`、`grad_v`、坐标、window size。
- 输出 `stage2_valid`，接收 `stage2_ready`。

**冻结约束：**
- avg0 与 avg1 不允许塌缩为同一路。
- kernel 为 zero-path 时，该路径必须 disable。
- stall 时双路径结果与 metadata 保持稳定。

### 2.6 `stage3_gradient_fusion`

**职责：**
- 对五方向梯度做方向绑定的逆序权重重映射。
- 输出 `blend0_dir_avg`、`blend1_dir_avg`。
- 继续透传 `src_patch_5x5`、`grad_h`、`grad_v`、坐标、window size。
- 输出 `stage3_valid`，接收 `stage3_ready`。

**冻结约束：**
- `grad_r` 必须来自真正的右邻点，不允许复制 `grad_c`。
- 不得直接读取未来未产生的梯度；必须采用因果性安全的 delayed-center 架构。
- `grad_sum == 0` 时必须走等权 fallback。

### 2.7 `stage4_iir_blend`

**职责：**
- 消费 `blend0_dir_avg`、`blend1_dir_avg`、`src_patch_5x5`、`grad_h`、`grad_v`、`reg_edge_protect`。
- 完成 IIR + 方向性 2x2 + patch 窗混合。
- 输出 `dout / dout_valid`，接收 `dout_ready`。
- 输出 `patch_valid / patch_center_x / patch_center_y / patch_5x5`，接收 `patch_ready`。

**冻结约束：**
- 不允许退化为单个 center_pixel 的 scalar mixing。
- Stage4 对同一中心的 `dout` 与 `patch_5x5` 采用原子提交；提交条件固定为 `dout_valid && patch_valid && dout_ready && patch_ready`。
- `dout_valid && !dout_ready` 时，输出像素与 metadata 必须保持稳定。
- `patch_valid && !patch_ready` 时，patch 总线必须保持稳定。
- 不允许 stream path 已提交但 patch path 未提交，或 patch path 已提交但 stream path 未提交。

---

## 3. 模块接口边界

### 3.1 Stream path 接口链

```text
din / din_valid / din_ready
  -> line_buffer(window_valid / window_ready)
  -> stage1(stage1_valid / stage2_ready)
  -> stage2(stage2_valid / stage3_ready)
  -> stage3(stage3_valid / stage4_ready)
  -> stage4(dout_valid / dout_ready, patch_valid / patch_ready)
```

说明：
- `window_ready` 是 line buffer → Stage1 边界的正式 ready 命名。
- `stage1_ready` 在实现命名上保留给 Stage2 回传到 Stage1 的 ready，文档语义上不再等同于 `window_ready`。

### 3.2 Patch metadata 透传链

```text
line_buffer: src_patch_5x5, center_x, center_y
  -> stage1: grad_h, grad_v, grad, win_size_clip
  -> stage2: avg0/avg1 + metadata passthrough
  -> stage3: blend0/1 + metadata passthrough
  -> stage4: patch mix input set
```

### 3.3 Feedback path 接口链

```text
stage4_iir_blend
  -> patch_valid
  -> patch_ready
  -> patch_center_x
  -> patch_center_y
  -> patch_5x5
  -> isp_csiir_line_buffer
```

### 3.4 Stage4 必须看到的输入集合

| 信号 | 来源模块 | 用途 |
|------|----------|------|
| `src_patch_5x5` | line_buffer 经 Stage1/2/3 透传 | patch 级空间混合输入 |
| `grad_h` | Stage1 | 方向性判断 |
| `grad_v` | Stage1 | 方向性判断 |
| `reg_edge_protect` | reg_block | edge protect 混合系数 |
| `win_size_clip` | Stage1 经 Stage2/3 透传 | bucket 选择 |
| `center_x / center_y` | line_buffer 经各 stage 透传 | feedback 提交坐标 |

---

## 4. 跨模块依赖关系

### 4.1 关键依赖

| 源模块 | 目标模块 | 依赖内容 | 说明 |
|--------|----------|----------|------|
| line_buffer | Stage1 | `src_patch_5x5` + `window_valid` | Stage1 输入窗口 |
| Stage1 | Stage2 | `grad_h` / `grad_v` / `win_size_clip` / patch metadata | Stage2 计算与透传 |
| Stage2 | Stage3 | avg0/avg1 + patch metadata | Stage3 方向融合 |
| Stage3 | Stage4 | blend0/1 + `grad_h` / `grad_v` / `src_patch_5x5` | Stage4 patch 混合 |
| reg_block | Stage4 | `reg_edge_protect` | edge protect 配置 |
| Stage4 | line_buffer | `patch_valid` / `patch_ready` / `patch_5x5` | feedback merge |

### 4.2 Causality 备注

Stage3 是唯一必须显式做因果性保护的模块：
- `grad_u`、`grad_c`、`grad_d` 必须在提交点全部可用。
- 文档与 RTL 都不得出现“直接读取下一行未来梯度”的表述。
- 若需要延迟中心点提交，这是架构允许且推荐的实现方式。

---

## 5. 验收导向的模块划分结论

### 5.1 本轮 RTL 改造边界

- `stage1_gradient`：接入真实 `stage1_ready`，并提供 `grad_h` / `grad_v` / source patch metadata 起点。
- `stage2_directional_avg`：实现双路径 avg0/avg1，并保留 metadata。
- `stage3_gradient_fusion`：实现方向绑定和因果性安全的邻域梯度组织。
- `stage4_iir_blend`：实现 patch 级混合与 feedback 打包。
- `isp_csiir_line_buffer`：实现 feedback merge 与输入回压。
- `isp_csiir_top`：把 stream path 与 patch path 真正串通。

### 5.2 明确不允许的职责漂移

- 不允许把 patch feedback merge 临时塞进 Stage4 内部存储绕过 line buffer。
- 不允许让 top 直接替 Stage2/3 保存算法状态。
- 不允许由 line buffer 决定 Stage4 的混合算法。

---

## 6. 修订历史

| 版本 | 日期 | 作者 | 描述 |
|------|------|------|------|
| v1.0 | 2026-03-22 | rtl-arch | 初始版本 |
| v1.1 | 2026-03-31 | rtl-arch | 冻结 stall-safe 模块边界、patch feedback 接口与 Stage4 输入责任 |
