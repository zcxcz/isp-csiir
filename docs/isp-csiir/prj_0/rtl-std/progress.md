# rtl-std 工作进展

## 当前阶段
- 阶段: M1 需求基线
- 状态: 已完成
- 更新时间: 2026-03-22

## 工作目标
1. 分析 isp-csiir-ref.md 算法文档
2. 定义 CSIIR 模块接口规格
3. 文档化性能目标和数据格式

## 已完成
- [x] 分析算法四阶段处理流程
- [x] 定义输入输出接口
- [x] 量化性能指标
- [x] 生成需求规格文档 (spec.md)
- [x] 修正流水级数预设问题（去除预设，由 rtl-arch 决定）

## 输出文档
- `/home/sheldon/rtl_project/isp-csiir/docs/isp-csiir/prj_0/rtl-std/spec.md`

## 项目约束（已确认）
- 输入/输出位宽: 10-bit 无符号
- 目标频率: 600MHz
- 吞吐量: 1 pixel/clock
- 目标工艺: 12nm