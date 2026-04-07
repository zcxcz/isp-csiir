# rtl-impl 工作进展

## 当前阶段
- 阶段: M4 RTL返修
- 状态: 进行中
- 更新时间: 2026-04-02

## 工作目标
1. 完成 Stage4 顶层最小接线修复
2. 保持修复范围仅限 top-level metadata path
3. 支持验证侧重跑 Stage4 align 与 ramp golden compare

## 已完成
| 日期 | 任务 | 状态 |
|------|------|------|
| 04-02 | 复核 `rtl/stage4_iir_blend.v` 必需输入接口 | ✓ |
| 04-02 | 对比 `rtl/isp_csiir_top.v` 的 `u_stage4` 实例并锁定缺失接线 | ✓ |
| 04-02 | 确认问题优先级为 top-level integration，而非 Stage4 算法本体 | ✓ |

## 进行中
| 任务 | 进度 | 预计完成 |
|------|------|----------|
| Stage4 metadata 最小接线修复 | 根因已定位，待改 RTL | 修复后立即复测 |

## 待处理
- [ ] 补齐 `src_patch_5x5 / grad_h / grad_v / reg_edge_protect`
- [ ] 重跑 `tb_isp_csiir_stage4_align.sv`
- [ ] 如对齐通过，再重跑 always-ready ramp golden compare
