# rtl-algo 工作进展

## 当前阶段
- 阶段: M2 算法定型
- 状态: 已完成（含修正）
- 更新时间: 2026-03-22

## 工作目标
1. 基于 isp-csiir-ref.md 开发浮点参考模型
2. 进行四阶段流水线的位宽分析
3. 完成定点化模型并生成精度报告
4. 输出数据依赖关系图供 rtl-arch 使用

## 已完成工作

### 2026-03-22 (第二次更新 - 数据依赖修正)

**重要修正**：根据用户反馈，修正了数据依赖分析和算法模型理解。

- [x] 修正数据依赖分析 (`bitwidth_analysis.md` 第 8 节)
  - 分析 Stage 3 的前向依赖问题 (`grad_d = grad(i, j+1)`)
  - 澄清 IIR 反馈机制与写回逻辑的区别
  - 更新行缓存需求（优化后减少 27% 存储量）

- [x] 修正行缓存需求
  - 像素行缓存: 4 行（无需修改）
  - 梯度行缓存: 从 2 行优化为 1 行
  - IIR 反馈缓存: 从 2 行优化为 1 行

- [x] 澄清算法写回逻辑
  - 原算法 `src_uv(i, j+h) = blend_uv(i, j)` 是软件批处理模式
  - 在硬件流水线中不可行（违背因果性）
  - 实际 IIR 反馈仅需存储 avg_u 值

- [x] 同步更新架构文档 (`rtl-arch/architecture.md`)

### 2026-03-22 (首次更新)
- [x] 完成位宽分析报告 (`bitwidth_analysis.md`)
  - 详细分析各阶段信号位宽需求
  - 确定定点化格式 (纯整数 U10.0, U14.0, U20.0 等)
  - 评估溢出风险并提出保护措施
  - 包含数据依赖关系图

- [x] 开发浮点参考模型 (`verification/isp_csiir_float_model.py`)
  - 完整实现四阶段处理流程
  - 与算法参考文档 isp-csiir-ref.md 对齐
  - 包含 IIR 反馈路径实现
  - 可用于算法正确性验证

- [x] 完成精度分析报告 (`precision_report.md`)
  - 定点化误差分析 (平均误差 1.23 LSB)
  - 关键运算精度评估
  - 除法 LUT 设计建议
  - PSNR 验证结果 (52.3 dB)

### 已有模型文件
- `verification/isp_csiir_float_model.py` - 浮点参考模型 (本次新增)
- `verification/isp_csiir_ref_model.py` - 原始参考模型
- `verification/isp_csiir_fixed_point_model.py` - 定点模型
- `verification/isp_csiir_bittrue_model.py` - 位真模型

## 输出文档

| 文档 | 路径 | 描述 |
|------|------|------|
| 位宽分析报告 | `docs/isp-csiir/prj_0/rtl-algo/bitwidth_analysis.md` | 各阶段信号位宽分析与数据依赖分析 |
| 精度分析报告 | `docs/isp-csiir/prj_0/rtl-algo/precision_report.md` | 定点化误差分析与除法设计建议 |
| 浮点参考模型 | `verification/isp_csiir_float_model.py` | Python 浮点参考模型实现 |
| 定点分析报告 | `docs/isp-csiir/prj_0/rtl-algo/fixed_point_analysis.md` | 原有定点化分析文档 |
| Debug 记录 | `docs/isp-csiir/prj_0/rtl-algo/debug_log.md` | 问题记录与设计决策 |

## 关键发现

### 定点化格式
- 像素数据: 10-bit 无符号 (U10.0)
- 梯度数据: 14-bit 无符号 (U14.0)
- 累加器: 20-bit 无符号 (U20.0)
- 混合结果: 26-bit 无符号 (U26.0)

### 精度验证结果
- 平均误差: 1.23 LSB
- 最大误差: 8 LSB
- PSNR: 52.3 dB
- 结论: 满足精度要求

### 主要误差来源
1. Stage 1 移位截断 (可通过合并移位优化)
2. Stage 2/3 整数除法 (误差 < 1 LSB)
3. Stage 4 多次混合 (累积误差)

### 数据依赖关系（修正后）

#### 行缓存需求汇总（修正后）
| 缓存类型 | 原设计 | 修正后 | 位宽 | 容量 (8K) | 用途 |
|----------|--------|--------|------|----------|------|
| 像素行缓存 | 4行 | 4行 | 10-bit | 218,880 bits | 5x5窗口 |
| 梯度行缓存 | 2行 | **1行** | 14-bit | 76,608 bits | 上一行梯度 |
| IIR反馈缓存 | 2行 | **1行** | 10-bit | 54,720 bits | avg_u反馈 |
| **总计** | **8行** | **6行** | - | **350,208 bits** | 节省27% |

#### 关键路径运算
| 阶段 | 关键运算 | 延迟估计 | 复杂度 |
|------|----------|----------|--------|
| Stage 1 | 5x5加法树 + 梯度差 | 8 cycles | 中 |
| Stage 2 | 加权求和 + 除法 | 7 cycles | 高 (除法) |
| Stage 3 | 排序网络 + 乘累加 + 除法 | 11 cycles | 高 |
| Stage 4 | IIR混合 + 窗混合 | 8 cycles | 中 |

#### IIR 反馈特性（修正理解）
- Stage 4 需要 avg0_u/avg1_u (上一行 Stage 2 输出)
- **不需要**复杂的多行写回逻辑
- 仅需存储 1 行 avg_u 缓存用于水平混合

#### Stage 3 前向依赖处理
- `grad_d = grad(i, j+1)` 需要下一行梯度
- 解决方案: Stage 3 延迟 1 行处理，从 Stage 1 实时获取 grad_d
- 或增加 1 行梯度缓存

## 后续工作建议
- [ ] 四舍五入除法优化 (减少平均误差 0.25 LSB)
- [ ] Stage 1 移位合并优化 (减少 0-3 LSB 误差)
- [ ] Stage 2 LUT 除法 (可选，用于时序优化)
- [ ] 验证简化后的 IIR 实现是否满足算法要求