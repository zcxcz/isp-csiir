# ISP-CSIIR 项目工作进展

## 当前阶段
- 阶段: M4/M5 返修闭环
- 状态: 进行中
- 更新时间: 2026-04-02

## 工作目标
1. 完成 Stage4 顶层最小修复的交叉验证
2. 基于已有证据收敛 blocker 归属，不扩大修复范围
3. 维持 docs 归档与下一步动作一致

## 已完成
| 日期 | 任务 | 状态 |
|------|------|------|
| 04-02 | 确认 always-ready ramp `actual.hex` 第3项起为 `xxx` | ✓ |
| 04-02 | 确认 Stage4 align bench 直接暴露 `u_stage4` 输入 `z/x` | ✓ |
| 04-02 | 判定主阻塞属于 RTL top-level wiring，runner/环境不是主阻塞 | ✓ |

## 进行中
| 任务 | 进度 | 预计完成 |
|------|------|----------|
| Stage4 顶层最小修复协调 | 根因已锁定，等待 RTL 最小改动后复测 | 修复后立即闭环 |

## 当前 blocker
- `rtl/isp_csiir_top.v` 未将 Stage4 必需 metadata 接入 `u_stage4`

## 剩余风险
- 若最小补线后仍失败，说明还存在 metadata transport 对齐问题，需要二次定位

## 待处理
- [ ] 补齐 Stage4 top-level metadata 接线
- [ ] 重跑 Stage4 align bench
- [ ] 重跑 always-ready ramp golden compare
