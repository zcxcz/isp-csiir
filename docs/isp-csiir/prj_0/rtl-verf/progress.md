# rtl-verf 工作进展

## 当前阶段
- 阶段: M6 集成验证首轮回归
- 状态: 进行中
- 更新时间: 2026-04-06

## 工作目标
1. 把新验证原则固化到 repo 内 skill / 项目文档
2. 按“子模块验证与集成验证默认解耦”的方式继续剩余子模块验证
3. 优先完成 Stage4 之后最相关的 `isp_csiir_line_buffer` contract 验证
4. 集成 compare 默认回到 `valid && ready` 采样点语义，而不是扩散式 pairwise 边界补 case

## 已完成
| 日期 | 任务 | 状态 |
|------|------|------|
| 04-05 | 在 `rtl-verf` skill / 项目验证文档中冻结新的验证默认原则 | ✓ |
| 04-05 | 运行 `tb_stage4_iir_blend_ref.sv`，CASE A-F 全部 PASS | ✓ |
| 04-05 | 补强 `tb_isp_csiir_line_buffer_eol_backpressure.sv` 的 TB contract，并跑出 stall/writeback 分层结论 | ✓ |
| 04-05 | 补强 `tb_stage3_gradient_fusion_ref.sv` 的 TB contract / directed stall / fixed-seed / trace replay，回归 PASS | ✓ |
| 04-06 | 补强 `tb_stage2_directional_avg_ref.sv` 的 TB contract，并拿到 directed PASS / stall-safe FAIL 结论 | ✓ |
| 04-06 | 用最小 trace/replay 复现并收敛 `stage2_directional_avg` CASE C；确认原 fail 为 TB stall 注入时机问题，修正后主 TB PASS | ✓ |
| 04-06 | 新增 `tb_stage1_gradient_ref.sv`，冻结 Stage1 compare object / sample edge / valid-ready contract，拿到 CASE A/B PASS、CASE C 首次 stall FAIL 基线 | ✓ |
| 04-06 | 用最小 stall trace 收敛 `stage1_gradient` CASE C；确认原 fail 为 TB stall 注入晚一拍，修正后主 TB PASS | ✓ |
| 04-02 | 运行 `tb_isp_csiir_stage4_align.sv` 并稳定复现 `u_stage4` 输入 `z/x` | ✓ |
| 04-02 | 运行 always-ready ramp compare 并定位 `actual.hex` 第3项起为 `xxx` | ✓ |
| 04-02 | 确认 runner 成功生成 `actual.hex`，主阻塞不在环境侧 | ✓ |
| 04-06 | 启动集成验证首轮回归：`ready_chain` PASS、`stage4_align` PASS、top-level `backpressure` PASS | ✓ |
| 04-06 | 启动 32x32 ramp golden compare，确认端到端功能 mismatch 仍存在 | ✓ |
| 04-06 | 为 width-dependent 子模块补 max-width directed case：`linebuffer` PASS、`stage3_gradient_fusion` PASS | ✓ |
| 04-06 | 为主链剩余子模块补 max-width directed case：`stage1_gradient` PASS、`stage2_directional_avg` PASS、`stage4_iir_blend` PASS | ✓ |
| 04-06 | 通过顶层 trace + Stage2 边界 trace 确认当前集成 fail 首因是 compare object 与 RTL contract 不一致，而不是握手/Stage4 transport 故障 | ✓ |

## 验证命令
- `iverilog -g2012 -f verification/iverilog_csiir.f -o verification/tb_stage4_align_red verification/tb/tb_isp_csiir_stage4_align.sv && vvp verification/tb_stage4_align_red`
- `python3 verification/run_golden_verification.py --output verification_results_always_ready_ramp --pattern ramp --width 32 --height 32 --seed 42 --keep`
- `iverilog -g2012 -o verification/stage4_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/stage4_iir_blend.v verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/stage4_ref_sim`
- `iverilog -g2012 -o verification/line_buffer_contract_sim rtl/isp_csiir_line_buffer.v verification/tb/tb_isp_csiir_line_buffer_eol_backpressure.sv && vvp verification/line_buffer_contract_sim`
- `iverilog -g2012 -o verification/tb_stage3_gradient_fusion_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage3_gradient_fusion.v verification/tb/tb_stage3_gradient_fusion_ref.sv && vvp verification/tb_stage3_gradient_fusion_ref_sim`
- `iverilog -g2012 -o verification/tb_stage3_casea_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage3_gradient_fusion.v verification/tb/tb_stage3_gradient_fusion_casea_ref.sv && vvp verification/tb_stage3_casea_ref_sim`
- `iverilog -g2012 -o verification/tb_stage3_fallback_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage3_gradient_fusion.v verification/tb/tb_stage3_gradient_fusion_fallback_ref.sv && vvp verification/tb_stage3_fallback_ref_sim`
- `iverilog -g2012 -o verification/tb_stage2_directional_avg_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage2_directional_avg.v verification/tb/tb_stage2_directional_avg_ref.sv && vvp verification/tb_stage2_directional_avg_ref_sim`
- `iverilog -g2012 -o verification/tb_stage2_stall_trace_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage2_directional_avg.v verification/tb/tb_stage2_directional_avg_stall_trace.sv && vvp verification/tb_stage2_stall_trace_sim`
- `iverilog -g2012 -o verification/tb_stage1_gradient_ref_sim rtl/common/common_pipe.v rtl/stage1_gradient.v verification/tb/tb_stage1_gradient_ref.sv && vvp verification/tb_stage1_gradient_ref_sim`
- `iverilog -g2012 -o verification/tb_stage1_stall_trace_sim rtl/common/common_pipe.v rtl/stage1_gradient.v verification/tb/tb_stage1_gradient_stall_trace.sv && vvp verification/tb_stage1_stall_trace_sim`
- `iverilog -g2012 -o verification/tb_linebuffer_max_width_ref_sim rtl/isp_csiir_line_buffer.v verification/tb/tb_isp_csiir_line_buffer_max_width_ref.sv && vvp verification/tb_linebuffer_max_width_ref_sim`
- `iverilog -g2012 -o verification/tb_stage3_max_width_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage3_gradient_fusion.v verification/tb/tb_stage3_gradient_fusion_max_width_ref.sv && vvp verification/tb_stage3_max_width_ref_sim`
- `iverilog -g2012 -o verification/tb_stage4_iir_blend_ref_sim rtl/common/common_ff.v rtl/common/common_pipe.v rtl/common/common_pipe_slice.v rtl/common/common_lut_divider.v rtl/stage4_iir_blend.v verification/tb/tb_stage4_iir_blend_ref.sv && vvp verification/tb_stage4_iir_blend_ref_sim`

## 当前方法冻结
- 子模块验证与集成验证默认解耦
- 集成 compare 默认按 `valid && ready` 采样点 compare
- compare object / sample edge / valid-ready contract 必须显式写清
- 不为每个模块间接口预防性新增 pairwise 边界 case
- 重排/重编码优先在 reference / compare 路径表达
- 边界专项验证仅作为集成失配后的定位工具
- 子模块 TB 继续保留 contract freeze、stall/backpressure、fixed-seed random、trace/replay
- `IMG_WIDTH=5472` 最大图宽基础功能已在 `linebuffer/stage1/stage2/stage3/stage4` 子模块入口显式补测

## 当前聚焦
- 集成结构链路：
  - `tb_isp_csiir_ready_chain_ref.sv` PASS
  - `tb_isp_csiir_stage4_align.sv` PASS
  - `tb_isp_csiir_backpressure.sv` PASS
- 端到端功能 compare：
  - `run_golden_verification.py --pattern ramp --width 32 --height 32 --seed 42` FAIL
  - 当前结果：1024 像素中 `27` 项匹配，first mismatch 从 `index 27` 左右开始
- first failing boundary 候选：
  - 已冻结 `Stage4 patch stream` compare object，并确认首个失配先发生在 `idx=1` 的 patch 内容，不是坐标，也不是 linebuffer row dump 的 tail metadata
  - 当前 RTL `idx=1` patch 等于 no-feedback 模式下的定点模型结果，说明前级看到的仍是 stale pre-feedback image
  - 反馈不是完全没进，而是约 `27` 个 center 后才开始可见；这属于架构级 delayed-feedback 语义，不是单纯 linebuffer merge/tail bug
  - naive 单窗串行化已证伪：会让 `window_fire=1`、`patch_fire=0`，因为 Stage3 本身需要连续 neighborhood context
  - 下一步不应继续只修 linebuffer；需要在“按算法 spec 重构 RTL 调度/架构”与“正式发起模型重评估”之间做决策

## 待处理
- [x] 运行并记录 `stage4_iir_blend` 子模块 TB 当前状态
- [x] 补强 `isp_csiir_line_buffer` 子模块 TB 头部 contract 和关键 directed cases
- [x] 跑 line buffer stall / fixed-seed / writeback cases，记录 pass/fail
- [x] 补强 `stage3_gradient_fusion` 子模块 TB 的 contract / stall / fixed-seed / trace replay
- [x] 补强 `stage2_directional_avg` 子模块 TB 的 contract，并完成最小 stall trace / replay 闭环
- [x] 补强 `stage1_gradient` 子模块 TB 的 contract，并完成最小 stall trace / replay 闭环
- [x] 完成 line buffer 最小 RTL 修复并重跑 writeback contract
- [x] 启动集成验证首轮回归
- [x] 为 width-dependent 子模块补 max-width directed case 并回归
- [x] 为主链其余 metadata / writeback 相关子模块补 max-width directed case 并回归
- [x] 通过 Stage2 focused trace 验证当前 golden compare 与 RTL contract 的首个分歧点
- [ ] 为 `isp_csiir_line_buffer` 补 trace/replay
- [ ] 若继续做 line buffer，围绕 feedback merge 可见性设计最小闭环 case
- [x] 冻结集成 compare object，并把首失配边界前移到 `Stage4 patch stream`
- [ ] 评估当前 streaming RTL 是否能在不重构架构的前提下满足 fixed-model 的 immediate feedback 语义
- [ ] 若不能满足，整理证据并发起算法/架构重评估
