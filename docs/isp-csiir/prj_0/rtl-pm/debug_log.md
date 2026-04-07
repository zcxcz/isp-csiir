# ISP-CSIIR 项目 Debug 记录

## 问题记录

### 2026-04-02 Stage4 交叉验证范围收敛
- 现象: 用户要求停止继续堆任务，先基于现有运行结果给出明确结论
- 定位: Stage4 align RED bench + always-ready ramp compare
- 原因: 现有证据已足够锁定为 RTL top-level integration 缺口，无需继续扩范围
- 方案: 仅保留一个最小动作：补 `u_stage4` metadata 接线并重跑两项验证
- 决策: blocker 归属为 RTL；testbench 用于暴露问题；runner/环境非主阻塞
- 状态: 进行中
