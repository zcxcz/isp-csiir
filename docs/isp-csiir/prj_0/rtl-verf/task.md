# rtl-verf 任务记录

## 当前任务
- 项目: isp-csiir (prj_0)
- 任务: 按新验证原则继续子模块验证
- 状态: 进行中

## 当前验证默认原则
- 子模块验证与集成验证默认解耦；子模块 TB 先独立冻结 contract / sampling / stall 语义。
- 不为模块间接口预防性新增 pairwise 边界 case；边界专项默认只在集成失配后作为定位工具。
- 集成 compare 默认按 `valid && ready` 采样点对齐；若为原子提交，必须写全 fire 条件。
- compare object / sampling edge / valid-ready contract / metadata_scope 必须写入 TB 头部。
- 若存在重排、重编码、坐标/patch 重组，优先在集成 reference / compare 路径表达，不默认复制额外边界 TB。
- 子模块 TB 保留强制项：contract freeze、stall/backpressure、fixed-seed random、trace/replay。

## 当前优先级
1. 先冻结 repo 内验证原则与项目侧记录
2. 保持 `stage4_iir_blend` 子模块 reference TB 作为已知入口
3. 优先补 `isp_csiir_line_buffer` 子模块验证，聚焦 Stage4 之后最关键的 writeback / merge / stall contract
4. 在 line buffer 之外，优先补 `stage3_gradient_fusion` 子模块的 contract / stall / fixed-seed / trace 入口
5. `stage1_gradient` 已完成最小 stall trace / replay 闭环；若继续子模块主线且仍避开 top-level / line buffer，选择下一条非顶层验证入口

## 任务详情
| 任务ID | 描述 | 状态 |
|--------|------|------|
| T5.1 | 验证原则固化到 skill / 项目文档 | 完成 |
| T5.2 | `stage4_iir_blend` 子模块 reference TB 维持为主入口 | 进行中 |
| T5.3 | `isp_csiir_line_buffer` 子模块 contract TB 补强 | 进行中 |
| T5.4 | 集成 compare 规则按 `valid && ready` 显式冻结 | 进行中 |
| T5.5 | `stage3_gradient_fusion` 子模块 reference TB 按新原则补强 | 完成 |
| T5.6 | `stage2_directional_avg` 子模块 reference TB 按新原则补强并完成最小 stall trace / replay 闭环 | 完成 |
| T5.7 | `stage1_gradient` 子模块 reference TB 按同一原则补强并完成最小 stall trace / replay 闭环 | 完成 |
| T5.8 | 选择下一条非顶层、非 line-buffer 的子模块验证入口 | 待开始 |
