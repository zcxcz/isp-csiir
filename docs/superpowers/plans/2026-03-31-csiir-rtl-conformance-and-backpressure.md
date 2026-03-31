# CSIIR RTL Conformance and Backpressure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 ISP-CSIIR RTL 以 `isp-csiir-ref.md` 为唯一功能基线，补齐 Stage2/3/4 与 line buffer 的算法一致性，并实现端到端 valid/ready backpressure。

**Architecture:** 先冻结规格与 golden model，再以“验证先行”的方式推进两条主线：功能一致性与 stall-safe 数据通路。Stage2/3/4 与 line buffer 的修改必须围绕 `isp-csiir-ref.md` 的语义展开；所有 stage 必须通过真实的 ready/valid 链路传播 backpressure，并在 `valid && !ready` 时保持状态与输出稳定。Stage4 产生的 patch 级反馈必须通过 `isp_csiir_line_buffer` 的滚动反馈缓存/提交机制回灌到后续窗口生成路径，而不是退化为单点 center mixing。

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Python 3 verification scripts, Icarus Verilog, existing `common_pipe`, `common_pipe_slice`, `common_skid_buffer`.

---

## 0. 不可谈判前提

1. `isp-csiir-ref.md` 是功能真值表，不再以“当前 RTL 行为”反向约束规格。
2. **backpressure 必须实现**：`dout_ready` 可任意拉低，影响必须逐级传回 `din_ready`。
3. 修改顺序必须是：`@rtl-std` → `@rtl-algo` → `@rtl-arch` → `@rtl-verf`（写 failing tests）→ `@rtl-impl` → `@rtl-verf`（回归）→ `@rtl-fmt`。
4. 所有“完成”声明都必须附带新鲜验证证据；不允许用“应该通过”替代测试输出。
5. 每个逻辑块完成后单独提交；不要把 Stage2/3/4/backpressure 混成一个大提交。

## 1. 文件结构与职责冻结

### 1.1 现有文件（本轮会涉及）

- `isp-csiir-ref.md`
  - **只读参考，不修改。** 它是功能基线；实现、golden model、testbench 与架构文档都必须对齐这里的算法语义。
- `docs/isp-csiir/prj_0/rtl-std/spec.md`
  - 更新接口契约、patch writeback 语义、`reg_edge_protect` 配置语义、backpressure 要求。
- `docs/isp-csiir/prj_0/rtl-pm/project_plan.md`
  - 记录本轮“对齐 ref + 强制 backpressure”的里程碑与优先级。
- `docs/isp-csiir/prj_0/rtl-arch/architecture.md`
  - 记录 stall-safe 流水线、patch feedback 架构，以及 5x5 patch / `grad_h` / `grad_v` 元数据如何送到 Stage4。
- `docs/isp-csiir/prj_0/rtl-arch/module_partition.md`
  - 明确各模块职责与新增接口边界。
- `docs/isp-csiir/prj_0/rtl-arch/pipeline_refactor_spec.md`
  - 记录 ready/valid 传播、patch-path 握手与状态冻结规则。
- `verification/isp_csiir_fixed_model.py`
  - 从“匹配当前 RTL”改为“匹配 `isp-csiir-ref.md`”。
- `verification/run_golden_verification.py`
  - 保留 full-pipeline **always-ready** golden compare；不承担 backpressure 验收。
- `verification/tb/tb_isp_csiir_random.sv`
  - 保留为 always-ready 的系统级 golden regression testbench。
- `rtl/isp_csiir_reg_block.v`
  - 将现有 `mot_protect` 配置路径对齐为 ref 中 `reg_edge_protect` 的语义，并对顶层导出。
- `rtl/isp_csiir_top.v`
  - 整体 ready/valid 串接、patch-path 握手集成、`reg_edge_protect`/`grad_h`/`grad_v`/5x5 patch 元数据跨 stage 对接。
- `rtl/isp_csiir_line_buffer.v`
  - 实现 stall-safe 输入/窗口输出；接收 Stage4 patch feedback；替换当前禁用 writeback 逻辑。
- `rtl/stage1_gradient.v`
  - 将 `window_ready` 与下游 `stage1_ready` 真实联动；作为 5x5 patch 与 `grad_h`/`grad_v` 元数据的起点。
- `rtl/stage2_directional_avg.v`
  - 实现真正的双路径 kernel select / mask / enable，并继续透传 Stage4 所需的 patch / 梯度元数据。
- `rtl/stage3_gradient_fusion.v`
  - 实现保持方向绑定的逆序梯度重映射；修复 `grad_r` 与 stall 行为；继续透传 Stage4 所需元数据。
- `rtl/stage4_iir_blend.v`
  - 消费 5x5 patch、`grad_h`、`grad_v` 与 `reg_edge_protect`，从标量 center mixing 改成 patch 级窗混合与 writeback 打包，同时支持 backpressure。

### 1.2 新增文件（本轮建议创建）

- `docs/isp-csiir/prj_0/rtl-std/ref_alignment_checklist.md`
  - 列出 ref 与当前 RTL 的 blocker 差异、验收项、责任职能。
- `verification/check_ref_semantics.py`
  - 纯 Python 语义自检：Stage2 双路径、Stage3 方向绑定、Stage4 patch 混合、`reg_edge_protect` 影响、feedback 迭代；失败时必须返回非零退出码。
- `verification/iverilog_csiir.f`
  - Icarus Verilog RTL filelist，固定 DUT/source 集合，避免 wildcard 编译漂移；所有 directed/system benches 都统一使用它。
- `verification/tb/tb_stage2_directional_avg_ref.sv`
  - Stage2 directed bench，验证 kernel select / avg0/avg1 区分 / zero-path disable。
- `verification/tb/tb_stage3_gradient_fusion_ref.sv`
  - Stage3 directed bench，验证方向绑定、`grad_sum==0` fallback、右邻点处理。
- `verification/tb/tb_stage4_iir_blend_ref.sv`
  - Stage4 directed bench，验证 patch mixing 与 writeback 打包。
- `verification/tb/tb_isp_csiir_backpressure.sv`
  - 系统级 backpressure bench，随机拉低 `dout_ready`，检查无丢数、无乱序、无状态前冲。

### 1.3 现成可复用模块（优先复用）

- `rtl/common/common_pipe.v`
- `rtl/common/common_pipe_slice.v`
- `rtl/common/common_skid_buffer.v`
- `rtl/common/common_adder_tree.v`
- `rtl/common/common_lut_divider.v`

> 原则：不要新造一套握手基础设施，优先复用 `common_pipe_slice` / `common_skid_buffer`，仅在现有模块无法表达需求时再扩展。

---

### Task 1: 冻结规格与对齐清单

**Owner:** `@rtl-std` + `@rtl-pm`

**Files:**
- Modify: `docs/isp-csiir/prj_0/rtl-std/spec.md`
- Modify: `docs/isp-csiir/prj_0/rtl-pm/project_plan.md`
- Create: `docs/isp-csiir/prj_0/rtl-std/ref_alignment_checklist.md`

- [ ] **Step 1: 先把规格里的强制约束写清楚**

在 `docs/isp-csiir/prj_0/rtl-std/spec.md` 中补齐并显式化以下条目：

```markdown
- 功能基线: `isp-csiir-ref.md`（只读）
- 输入/输出: 10-bit u10
- 吞吐: 1 pixel/clock
- 约束: 600MHz @ 12nm
- 强制要求: 端到端 valid/ready backpressure
- Stage2: avg0/avg1 为大小窗口两条不同路径
- Stage3: 梯度值逆序重映射但方向语义保持不变
- Stage4: 使用 5x5 patch、`grad_h`、`grad_v` 与 `reg_edge_protect` 完成窗混合后写回 line buffer
```

- [ ] **Step 2: 新建 ref 对齐清单，逐项列 blocker**

把当前已知 blocker 写入 `docs/isp-csiir/prj_0/rtl-std/ref_alignment_checklist.md`：

```markdown
- [ ] Stage2 双路径核选择与 enable/disable
- [ ] Stage3 方向绑定的逆序梯度映射
- [ ] Stage3 右方向梯度读取
- [ ] Stage4 patch 级混合
- [ ] Stage4 需要消费 5x5 patch、`grad_h`、`grad_v`、`reg_edge_protect`
- [ ] Stage4 → line buffer patch feedback handshake
- [ ] line buffer 真正消费 patch writeback
- [ ] end-to-end backpressure
```

- [ ] **Step 3: 运行文档检查，确认关键关键词都在规格里**

Run:
```bash
grep -n "backpressure\|valid/ready\|avg0\|avg1\|writeback\|isp-csiir-ref.md" docs/isp-csiir/prj_0/rtl-std/spec.md docs/isp-csiir/prj_0/rtl-std/ref_alignment_checklist.md docs/isp-csiir/prj_0/rtl-pm/project_plan.md
```

Expected: 三个文档都能搜到关键约束，且没有“always ready / simplified implementation”之类为当前 RTL 开脱的措辞。

- [ ] **Step 4: 提交规格冻结文档**

```bash
git add docs/isp-csiir/prj_0/rtl-std/spec.md docs/isp-csiir/prj_0/rtl-std/ref_alignment_checklist.md docs/isp-csiir/prj_0/rtl-pm/project_plan.md
git commit -m "docs: freeze CSIIR conformance and backpressure requirements"
```

### Task 2: 更新 golden model 到 ref 语义

**Owner:** `@rtl-algo` + `@rtl-verf`

**Files:**
- Modify: `verification/isp_csiir_fixed_model.py`
- Create: `verification/check_ref_semantics.py`
- Modify: `verification/run_golden_verification.py`
- Create: `verification/iverilog_csiir.f`

- [ ] **Step 0: 先创建固定 filelist，避免 wildcard 编译漂移**

在 `verification/iverilog_csiir.f` 中显式列出当前 DUT 所需 RTL 文件，例如：

```text
rtl/common/common_pipe.v
rtl/common/common_pipe_slice.v
rtl/common/common_skid_buffer.v
rtl/common/common_lut_divider.v
rtl/common/common_adder_tree.v
rtl/common/common_delay_line.v
rtl/isp_csiir_reg_block.v
rtl/isp_csiir_line_buffer.v
rtl/stage1_gradient.v
rtl/stage2_directional_avg.v
rtl/stage3_gradient_fusion.v
rtl/stage4_iir_blend.v
rtl/isp_csiir_top.v
```

Expected: filelist 只包含 DUT 必需源文件，不依赖 `rtl/*.v` / `rtl/common/*.v` wildcard。

- [ ] **Step 1: 先写 model 语义自检，让当前模型先失败**

在 `verification/check_ref_semantics.py` 中加入最小自检，并使用**固定夹具**而不是随机输入。至少定义以下 4 组 deterministic fixtures：

```python
# fixture_stage2_split:
#   指定一个 5x5 window + win_size_clip=24（或另一个明确跨桶值），
#   使 ref 下 avg0_factor_c=3x3, avg1_factor_c=2x2，且两路输出必须不同。
# fixture_stage3_direction_map:
#   指定 avg0/avg1 五方向值 + 五个互不相同的梯度，
#   明确写出期望的 grad_inv_{c,u,d,l,r} 与方向绑定结果。
# fixture_stage4_orientation:
#   指定 5x5 patch + grad_h/grad_v + reg_edge_protect，
#   使 G_H > G_V（再补一组 G_H <= G_V），验证 2x2 方向性 patch 选择确定。
# fixture_feedback_raster:
#   指定先处理坐标 (x0,y0) 再处理后续坐标 (x1,y1)，
#   断言第一个 patch writeback 会改变后者读取到的窗口内容。

assert avg0_tuple != avg1_tuple, "Stage2 dual-path kernels collapsed"
assert blend_dir_preserved == expected_dir_preserved, "Stage3 direction binding broken"
assert patch_out.shape == (5, 5), "Stage4 must output 5x5 patch semantics"
assert edge_protect_mix == expected_edge_protect_mix, "reg_edge_protect path missing or wrong"
assert feedback_next_window != original_next_window, "Feedback path not taking effect"
```

- [ ] **Step 2: 运行语义自检，确认当前模型暴露 ref 语义缺口**

Run:
```bash
python3 verification/check_ref_semantics.py
```

Expected: 返回码非 0，并显式标出至少一个固定夹具失败；例如：
- `fixture_stage2_split: Stage2 dual-path kernels collapsed`
- `fixture_stage3_direction_map: Stage3 direction binding broken`
- `fixture_stage4_orientation: Stage4 must output 5x5 patch semantics`
- `fixture_stage4_orientation: reg_edge_protect path missing`
- `fixture_feedback_raster: Feedback path not taking effect`

- [ ] **Step 3: 把 `verification/isp_csiir_fixed_model.py` 改成 ref 语义**

必须完成：
- Stage2：按 `win_size_clip` 选择 `avg0/avg1` 两套不同核与 enable
- Stage3：梯度排序后只重映射权重值，不打乱方向对应关系
- Stage4：使用 5x5 patch、`grad_h`、`grad_v`、`reg_edge_protect` 输出 patch 级窗混合结果，而不是标量 center 混合
- feedback：后续窗口读取到的是更新后的数据

- [ ] **Step 4: 再跑语义自检，确认模型通过**

Run:
```bash
python3 verification/check_ref_semantics.py
```

Expected: PASS，输出类似 `PASS: reference semantics verified`。

- [ ] **Step 5: 跑一次带断言退出码的 model-only 冒烟，确认范围与接口没坏**

先在 `verification/check_ref_semantics.py` 中加入一个最小 smoke 入口，确保范围/shape/关键语义失败时返回非 0；然后运行：

Run:
```bash
python3 verification/check_ref_semantics.py --smoke --pattern checker --width 32 --height 32
```

Expected: PASS，显式打印固定夹具与 smoke 都通过；例如 `PASS: fixture_stage2_split`, `PASS: fixture_stage3_direction_map`, `PASS: fixture_stage4_orientation`, `PASS: fixture_feedback_raster`, `PASS: smoke semantics and output range verified`；若任一夹具或范围检查失败必须返回非 0。

- [ ] **Step 6: 提交 golden model 更新**

```bash
git add verification/isp_csiir_fixed_model.py verification/check_ref_semantics.py verification/run_golden_verification.py verification/iverilog_csiir.f
git commit -m "feat: align CSIIR golden model with reference semantics"
```

### Task 3: 定义 stall-safe 与 patch feedback 架构

**Owner:** `@rtl-arch`

**Files:**
- Modify: `docs/isp-csiir/prj_0/rtl-arch/architecture.md`
- Modify: `docs/isp-csiir/prj_0/rtl-arch/module_partition.md`
- Modify: `docs/isp-csiir/prj_0/rtl-arch/pipeline_refactor_spec.md`

- [ ] **Step 1: 把 backpressure contract 写成逐级接口规则**

必须明确：

```markdown
- 当 `valid_out && !ready_in` 时，当前 stage 的输出数据、valid、metadata 必须保持稳定
- 所有内部计数器、行列指针、flush 状态只能在本地 handshake 成功时前进
- `dout_ready` 拉低最终必须传回 `din_ready`
- 禁止任何 stage 再使用硬编码 `*_ready = 1'b1`
```

- [ ] **Step 2: 选定 Stage4 → line buffer feedback 微架构**

把实现约束写入架构文档，不要只在脑子里：

```markdown
- 接受标准只有一条：必须满足 `isp-csiir-ref.md` 的 patch feedback 语义——当前中心生成的新 5x5 patch 必须影响后续光栅顺序中的窗口读取
- Stage4 必须消费: 5x5 source patch、`grad_h`、`grad_v`、`reg_edge_protect`
- `isp_csiir_top.v` 必须把 patch-path 握手、`grad_h`/`grad_v` 元数据和 `reg_edge_protect` 配置线显式接到 Stage4
- `patch_valid / patch_ready / patch_center_x / patch_center_y / patch_5x5` 是**一个可接受的 RTL 接口形状**；若采用其他等价接口，也必须在文档中说明
- line buffer / feedback merge 可以采用滚动缓存、直接覆盖、分阶段提交或其他微架构；但不得改变 ref 语义
- patch/stream 两条路径共用同一套 stall 规则
```

- [ ] **Step 3: 标注每个模块的改造边界**

至少要在 `module_partition.md` 写清：
- `stage1_gradient` 负责 Stage1 计算、真实传播 `stage1_ready`，并作为 5x5 patch / `grad_h` / `grad_v` 元数据起点
- `stage2_directional_avg` 负责双路径方向平均，并**保持/透传** Stage4 所需 patch / 梯度元数据
- `stage3_gradient_fusion` 负责方向融合，并**保持/透传** Stage4 所需 patch / 梯度元数据
- `stage4_iir_blend` 负责 IIR + patch 混合 + `reg_edge_protect` 参与的 2x2 方向性混合 + patch 打包
- `isp_csiir_reg_block` 负责导出 `reg_edge_protect` 配置到顶层/Stage4
- `isp_csiir_top` 负责 patch-path 握手、配置线与跨 stage 元数据总集成
- `isp_csiir_line_buffer` 只负责窗口生成 + patch feedback merge + 输入回压

- [ ] **Step 4: 检查架构文档包含所有关键接口名**

Run:
```bash
grep -n "patch_valid\|patch_ready\|stage1_ready\|stage2_ready\|stage3_ready\|dout_ready\|din_ready\|grad_h\|grad_v\|reg_edge_protect" docs/isp-csiir/prj_0/rtl-arch/architecture.md docs/isp-csiir/prj_0/rtl-arch/module_partition.md docs/isp-csiir/prj_0/rtl-arch/pipeline_refactor_spec.md
```

Expected: 文档里能看到完整的 ready/valid 与 feedback 接口契约。

- [ ] **Step 5: 提交架构冻结文档**

```bash
git add docs/isp-csiir/prj_0/rtl-arch/architecture.md docs/isp-csiir/prj_0/rtl-arch/module_partition.md docs/isp-csiir/prj_0/rtl-arch/pipeline_refactor_spec.md
git commit -m "docs: define stall-safe CSIIR feedback architecture"
```

### Task 4: 先写 failing verification benches

**Owner:** `@rtl-verf`

**Files:**
- Create: `verification/tb/tb_stage2_directional_avg_ref.sv`
- Create: `verification/tb/tb_stage3_gradient_fusion_ref.sv`
- Create: `verification/tb/tb_stage4_iir_blend_ref.sv`
- Create: `verification/tb/tb_isp_csiir_backpressure.sv`
- Modify: `verification/tb/tb_isp_csiir_random.sv`

- [ ] **Step 1: 写 Stage2 directed bench**

bench 至少覆盖：

```systemverilog
// case A: win_size 落在 avg0!=avg1 的区间，断言两路输出不相同
// case B: 某一路 kernel 为 zeros(5,5)，断言该路 disable / 输出不被错误计算
// case C: stall 一个周期后输出必须保持稳定
```

- [ ] **Step 2: 写 Stage3 directed bench**

bench 至少覆盖：

```systemverilog
// case A: 五个方向梯度都不同，检查排序后仍与原方向 avg 一一对应
// case B: grad_sum==0，检查 fallback 为五方向等权平均
// case C: grad_r 使用独立右邻点，而不是复制 center
```

- [ ] **Step 3: 写 Stage4 directed bench**

bench 至少覆盖：

```systemverilog
// case A: patch 输出是 5x5，而不是单个 center 混合值
// case B: 不同 win_size 桶走不同 blend 规则
// case C: valid && !ready 时 patch 和 metadata 保持稳定
```

- [ ] **Step 4: 写系统级 backpressure bench**

bench 至少覆盖：

```systemverilog
// downstream 随机拉低 dout_ready
// 检查像素不丢失、不重复、不乱序
// 检查 line buffer / flush / 行列计数在 stall 期间不前冲
```

- [ ] **Step 5: 跑四个 bench，确认当前 RTL 暴露预期缺口**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage4_ref_sim verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/backpressure_sim verification/tb/tb_isp_csiir_backpressure.sv && vvp verification/backpressure_sim
```

Expected: 每个 bench 至少暴露一个对应缺口，形式可以是断言失败、显式 mismatch 报告，或因缺接口/缺语义导致的 compile/runtime failure；把观察到的失败记录到 bench 日志里，再进入修复。

- [ ] **Step 6: 提交 failing tests**

```bash
git add verification/tb/tb_stage2_directional_avg_ref.sv verification/tb/tb_stage3_gradient_fusion_ref.sv verification/tb/tb_stage4_iir_blend_ref.sv verification/tb/tb_isp_csiir_backpressure.sv verification/tb/tb_isp_csiir_random.sv
git commit -m "test: add failing CSIIR conformance and backpressure benches"
```

### Task 5: 实现 Stage2 双路径方向平均

**Owner:** `@rtl-impl`

**Files:**
- Modify: `rtl/stage2_directional_avg.v`
- Test: `verification/tb/tb_stage2_directional_avg_ref.sv`

- [ ] **Step 1: 先跑 Stage2 bench，记录当前失败信息**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
```

Expected: FAIL，至少出现以下一种：
- `avg1 collapsed onto avg0`
- `wrong kernel selected`
- `disabled path still active`

- [ ] **Step 2: 最小实现 Stage2 真正的双路径 kernel 逻辑**

`rtl/stage2_directional_avg.v` 必须完成：

```verilog
// 1. 按 thresh0/1/2/3 选择 avg0_factor_* 与 avg1_factor_*
// 2. 每一路独立计算 weight sum
// 3. kernel 为零时该路径不参与计算
// 4. 删除 duplicated `assign stage1_ready = 1'b1;`
// 5. 为后续 Stage4 使用，保持/透传 5x5 patch、`grad_h`、`grad_v` 与坐标/控制元数据
// 6. 为后续 backpressure 保留真实 ready 传播接口
```

- [ ] **Step 3: 再跑 Stage2 bench，确认通过**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
```

Expected: PASS，输出类似 `PASS: stage2 reference cases`。

- [ ] **Step 4: 跑一次全工程编译，确保 Stage2 改动没有破坏顶层**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/top_compile_smoke verification/tb/tb_isp_csiir_random.sv
```

Expected: compile 成功，返回码 0。

- [ ] **Step 5: 提交 Stage2 修复**

```bash
git add rtl/stage2_directional_avg.v
git commit -m "fix: implement CSIIR stage2 dual-path directional averaging"
```

### Task 6: 实现 Stage3 方向绑定的梯度融合

**Owner:** `@rtl-impl`

**Files:**
- Modify: `rtl/stage3_gradient_fusion.v`
- Test: `verification/tb/tb_stage3_gradient_fusion_ref.sv`

- [ ] **Step 1: 先跑 Stage3 bench，记录当前失败信息**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
```

Expected: FAIL，至少覆盖以下一种：
- `direction association lost`
- `grad_r duplicated from grad_c`
- `grad_sum zero fallback mismatch`

- [ ] **Step 2: 最小实现 Stage3 正确的方向绑定逻辑**

`rtl/stage3_gradient_fusion.v` 必须完成：

```verilog
// 1. 保留每个方向的标签，排序后只重映射梯度值，不打乱 avg 对应方向
// 2. 右方向梯度必须来自真正的右邻点/边界复制规则
// 3. grad_sum==0 时两路都回退到五方向等权平均
// 4. 保持/透传 Stage4 所需的 5x5 patch、`grad_h`、`grad_v` 与坐标/控制元数据
// 5. 所有状态在 stall 时保持稳定
```

- [ ] **Step 3: 再跑 Stage3 bench，确认通过**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
```

Expected: PASS，输出类似 `PASS: stage3 reference cases`。

- [ ] **Step 4: 跑 Stage2 + Stage3 bench，确认没有回归**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
```

Expected: 两个 bench 都 PASS。

- [ ] **Step 5: 提交 Stage3 修复**

```bash
git add rtl/stage3_gradient_fusion.v
git commit -m "fix: preserve direction binding in CSIIR stage3 fusion"
```

### Task 7: 实现 Stage4 patch 级混合与 feedback 打包

**Owner:** `@rtl-impl`

**Files:**
- Modify: `rtl/stage4_iir_blend.v`
- Modify: `rtl/isp_csiir_top.v`
- Modify: `rtl/isp_csiir_reg_block.v`
- Modify: `rtl/stage1_gradient.v`
- Modify: `rtl/stage2_directional_avg.v`
- Modify: `rtl/stage3_gradient_fusion.v`
- Test: `verification/tb/tb_stage4_iir_blend_ref.sv`

- [ ] **Step 1: 先跑 Stage4 bench，记录当前失败信息**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage4_ref_sim verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim
```

Expected: 暴露至少一种 Stage4/ref 缺口；例如：
- `scalar center mixing detected`
- `missing 5x5 patch output`
- `missing grad_h/grad_v metadata`
- `reg_edge_protect path missing`
- `patch metadata unstable under stall`

- [ ] **Step 2: 最小实现 Stage4 patch 混合输出**

`rtl/stage4_iir_blend.v` 必须完成：

```verilog
// 1. 先做 blend*_hor
// 2. 消费 5x5 source patch、`grad_h`、`grad_v`、`reg_edge_protect`
// 3. 实现 ref 中 2x2 方向性 patch 与 2x2 对称 patch 的混合逻辑
// 4. 再与 5x5 patch / spatial mask 做窗混合，不允许退化成单个 center_pixel
// 5. `patch_valid / patch_ready / patch_center_x / patch_center_y / patch_5x5` 是一个可接受的接口形状；若采用其他等价接口，也必须证明满足 ref 的 feedback 语义
// 6. valid && !ready 时 patch 与 metadata 保持稳定
```

- [ ] **Step 3: 在顶层接入新的 Stage4 feedback 接口定义**

`rtl/isp_csiir_top.v` / `rtl/isp_csiir_reg_block.v` / 上游 stage 至少要完成：

```verilog
// Stage4 patch feedback bus <-> line buffer
// top-level ready/valid wiring for patch path
// transport 5x5 patch and `grad_h` / `grad_v` metadata into Stage4
// hook `reg_edge_protect` from reg block to Stage4
// remove `assign lb_wb_row_offset = 3'd0;` style placeholder behavior
```

- [ ] **Step 4: 再跑 Stage4 bench，确认通过**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage4_ref_sim verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim
```

Expected: PASS，输出类似 `PASS: stage4 reference cases`。

- [ ] **Step 5: 跑 Stage2/3/4 三个 directed bench，确认无回归**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage4_ref_sim verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim
```

Expected: 三个 bench 都 PASS。

- [ ] **Step 6: 提交 Stage4 修复**

```bash
git add rtl/stage4_iir_blend.v rtl/isp_csiir_top.v rtl/isp_csiir_reg_block.v rtl/stage1_gradient.v rtl/stage2_directional_avg.v rtl/stage3_gradient_fusion.v
git commit -m "feat: add CSIIR stage4 patch feedback interface"
```

### Task 8: 实现 line buffer feedback 与端到端 backpressure

**Owner:** `@rtl-impl`

**Files:**
- Modify: `rtl/isp_csiir_line_buffer.v`
- Modify: `rtl/stage1_gradient.v`
- Modify: `rtl/stage2_directional_avg.v`
- Modify: `rtl/stage3_gradient_fusion.v`
- Modify: `rtl/stage4_iir_blend.v`
- Modify: `rtl/isp_csiir_top.v`
- Test: `verification/tb/tb_isp_csiir_backpressure.sv`

- [ ] **Step 1: 先跑系统级 backpressure bench，记录当前失败信息**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/backpressure_sim verification/tb/tb_isp_csiir_backpressure.sv && vvp verification/backpressure_sim
```

Expected: 暴露至少一种 backpressure/ref 缺口；例如：
- `upstream advanced while stalled`
- `pixel dropped or duplicated`
- `output changed while valid && !ready`
- `patch committed while patch_ready low`

- [ ] **Step 2: 在 line buffer 中实现 stall-safe 输入/窗口冻结与 feedback merge**

`rtl/isp_csiir_line_buffer.v` 必须完成：

```verilog
// 1. `din_ready` 不能只依赖 frame_started，必须受下游 stall 影响
// 2. row/col/flush 指针只在 handshake 成功时前进
// 3. 删除 `if (0 && enable && lb_wb_en)` 禁用逻辑
// 4. patch feedback merge 优先返回最新覆盖值
```

- [ ] **Step 3: 把 ready/valid 真正串通整条流水线**

必须至少修掉这些“常高 ready”问题，并把 patch-path 握手一路串到顶层：
- `rtl/stage1_gradient.v`
- `rtl/stage2_directional_avg.v`
- `rtl/stage3_gradient_fusion.v`
- `rtl/stage4_iir_blend.v`
- `rtl/isp_csiir_top.v`
- `rtl/isp_csiir_line_buffer.v`

优先策略：

```verilog
// 在 stage 边界使用 common_pipe_slice/common_skid_buffer
// 将 local state update 条件统一为 fire = valid && ready
// stall 期间保持 data/valid/meta 全稳定
// patch_valid/patch_ready 与 stream valid/ready 使用同一套 stall-safe 契约
```

- [ ] **Step 4: 再跑 backpressure bench，确认通过**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/backpressure_sim verification/tb/tb_isp_csiir_backpressure.sv && vvp verification/backpressure_sim
```

Expected: PASS，输出类似 `PASS: end-to-end backpressure preserved ordering and state stability`。

- [ ] **Step 5: 跑 directed benches + backpressure bench，确认全部通过**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage2_ref_sim verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/stage2_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage3_ref_sim verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/stage3_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/stage4_ref_sim verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/backpressure_sim verification/tb/tb_isp_csiir_backpressure.sv && vvp verification/backpressure_sim
```

Expected: 四个 bench 都 PASS。

- [ ] **Step 6: 提交 feedback/backpressure 修复**

```bash
git add rtl/isp_csiir_line_buffer.v rtl/stage1_gradient.v rtl/stage2_directional_avg.v rtl/stage3_gradient_fusion.v rtl/stage4_iir_blend.v rtl/isp_csiir_top.v
git commit -m "fix: add stall-safe CSIIR feedback and backpressure path"
```

### Task 9: 跑系统级 golden regression 与项目归档

**Owner:** `@rtl-verf` + `@rtl-pm` + `@rtl-fmt`

**Files:**
- Modify: `verification/run_golden_verification.py`
- Modify: `docs/isp-csiir/prj_0/rtl-verf/progress.md`
- Modify: `docs/isp-csiir/prj_0/rtl-verf/debug_log.md`
- Modify: `docs/isp-csiir/prj_0/rtl-impl/progress.md`
- Modify: `docs/isp-csiir/prj_0/rtl-impl/debug_log.md`
- Modify: `docs/isp-csiir/prj_0/rtl-pm/progress.md`
- Modify: `docs/isp-csiir/prj_0/rtl-pm/debug_log.md`
- Modify: `docs/isp-csiir/prj_0/rtl-pm/milestone/M5_snapshot.md`

- [ ] **Step 1: 跑系统级 golden compare（always-ready 模式）**

Run:
```bash
python3 verification/run_golden_verification.py --pattern ramp --width 32 --height 32 --tolerance 0
python3 verification/run_golden_verification.py --pattern checker --width 32 --height 32 --tolerance 0
python3 verification/run_golden_verification.py --pattern gradient --width 32 --height 32 --tolerance 0
python3 verification/run_golden_verification.py --pattern random --width 32 --height 32 --seed 42 --tolerance 0
```

Expected: 每次都输出 `PASS: All outputs match golden model!`。

- [ ] **Step 2: 跑系统级 backpressure regression**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/backpressure_sim verification/tb/tb_isp_csiir_backpressure.sv && vvp verification/backpressure_sim
```

Expected: PASS，且 bench 报告零丢包、零重复、零乱序。

- [ ] **Step 3: 做一次顶层 testbench 编译冒烟（仅 always-ready smoke，不用于 backpressure 验收）**

Run:
```bash
iverilog -g2012 -f verification/iverilog_csiir.f -o verification/top_smoke verification/tb/tb_isp_csiir_top.sv
```

Expected: compile 成功，返回码 0。注意：`tb_isp_csiir_top.sv` 当前是 always-ready smoke，只用于顶层连线/编译检查；backpressure 验收只看 `tb_isp_csiir_backpressure.sv`。

- [ ] **Step 4: 更新 rtl-verf / rtl-impl / rtl-pm 进展与 debug 日志**

每个文件单次更新不超过 10 行，必须包含：
- 完成的里程碑
- 关键 blocker 的关闭状态
- 剩余风险（如果有）
- 用过的验证命令

- [ ] **Step 5: 用 `@rtl-fmt` 自查计划/归档文档的中文质量**

Run:
```bash
grep -n "backpressure\|反馈\|方向\|golden\|PASS\|FAIL" docs/isp-csiir/prj_0/rtl-verf/progress.md docs/isp-csiir/prj_0/rtl-impl/progress.md docs/isp-csiir/prj_0/rtl-pm/progress.md
```

Expected: 术语统一、中文描述完整，没有遗留“TODO later / temporary disabled”一类未闭环说明。

- [ ] **Step 6: 提交最终回归与归档更新**

```bash
git add verification/run_golden_verification.py docs/isp-csiir/prj_0/rtl-verf/progress.md docs/isp-csiir/prj_0/rtl-verf/debug_log.md docs/isp-csiir/prj_0/rtl-impl/progress.md docs/isp-csiir/prj_0/rtl-impl/debug_log.md docs/isp-csiir/prj_0/rtl-pm/progress.md docs/isp-csiir/prj_0/rtl-pm/debug_log.md docs/isp-csiir/prj_0/rtl-pm/milestone/M5_snapshot.md
git commit -m "test: verify CSIIR conformance and backpressure end-to-end"
```

---

## 2. 关键验收标准

### 功能一致性
- [ ] Stage2：`avg0` 与 `avg1` 真正代表不同窗口路径，不再相互复制。
- [ ] Stage3：梯度逆序映射后仍保持方向绑定；`grad_r` 来自右邻点/边界复制规则。
- [ ] Stage4：基于 5x5 patch、`grad_h`、`grad_v` 与 `reg_edge_protect` 做窗混合与最终插值，不再退化成中心点标量混合。
- [ ] feedback：line buffer 的后续窗口读取到更新后的像素值。

### Backpressure
- [ ] `dout_ready` 拉低时，Stage4 输出保持稳定。
- [ ] stall 能传播到 Stage3 / Stage2 / Stage1 / line buffer。
- [ ] `din_ready` 会在必要时拉低，输入端不会继续吞像素。
- [ ] line buffer 行列指针、flush 状态在 stall 期间冻结。

### 回归
- [ ] 四个 directed benches 全 PASS。
- [ ] 至少 4 组 full-pipeline golden compare 全 PASS。
- [ ] 顶层 testbench compile smoke 通过。

## 3. 明确不做的事

- 不在本计划中引入 UVM。
- 不为“一次性 debug”再新增长期保留的 `debug_*` testbench。
- 不在功能未对齐前做纯 timing 微优化。
- 不在未完成 golden/model 对齐前修改阈值或算法行为。

## 4. 执行建议

- 推荐执行模式：**Task 1-4 串行，Task 5-8 每个任务独立子代理执行，Task 9 主会话统一验收。**
- 每完成一个 impl 任务都立刻跑对应 directed bench，不要攒到最后一起看。
- 若任何一次 full-pipeline golden compare 失败，先定位是 model / bench / RTL 哪一层偏差，再继续下一个任务。
