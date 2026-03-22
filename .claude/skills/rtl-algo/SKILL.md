---
name: rtl-algo
description: |
  Use when developing algorithms for RTL/hardware implementation. This skill guides the complete algorithm engineering workflow: developing algorithm models, evaluating hardware feasibility with architects, creating fixed-point models, stage decomposition, bit-width analysis, and generating verification patterns.

  TRIGGER when: user mentions "算法模型", "定点化", "位宽分析", "精度评估", "硬件可行性", "stage decomposition", "verification pattern", or asks about developing algorithms for ASIC/FPGA implementation. Also trigger when starting new algorithm development, converting floating-point to fixed-point, or preparing models for RTL handoff.
---

# RTL 算法工程 Skill

## 职能边界

**rtl-algo 负责"算法定型"，为架构设计提供输入：**

| 属于 rtl-algo 职责 | 不属于 rtl-algo 职责 |
|------------------|-------------------|
| 浮点模型开发 | 流水线划分决策 |
| 定点化方案 | 寄存器位宽优化 |
| 位宽分析 | 时序收敛分析 |
| 精度评估 | 存储架构设计 |
| 数据依赖分析 | 模块接口定义 |
| 验证模式生成 | 验证环境搭建 |

**关键输出供 rtl-arch 使用：**
- 各运算的数据依赖关系（什么必须等待什么）
- 关键路径上的运算（高复杂度操作）
- 位宽需求分析（供架构师评估寄存器资源）
- 定点化方案（供 RTL 实现参考）

**与 rtl-arch 的协作边界：**
- rtl-algo 提供**数据依赖图**和**运算复杂度**
- rtl-arch 基于**工艺约束**和**时序目标**决定**流水线边界**

## 工作流程概览

```
需求分析 → 算法模型 → 硬件可行性评审 → 定点模型
              ↑                              ↓
              └────── 验证反馈 ←────── 模式生成
                                            ↓
                                    文档交付
```

---

## 阶段 1: 算法模型开发

### 1.1 需求分析

编写任何代码之前，先明确：

1. **功能需求**
   - 输入数据特征（格式、范围、速率）
   - 输出要求（格式、精度、延迟）
   - 处理约束（吞吐量、流水级数）

2. **质量指标**
   - 什么是"正确"输出？
   - 可接受的误差范围？
   - 是否有参考实现？

3. **硬件约束**（如已知）
   - 目标时钟频率
   - 可用逻辑资源
   - 存储器约束
   - 功耗预算

### 1.2 算法选择

记录算法选择及理由：

```markdown
## 算法选择

**选定算法**: [名称]
**选择理由**: [为什么该算法适合需求]

**备选方案**:
1. [备选方案1] - 放弃原因: [理由]
2. [备选方案2] - 放弃原因: [理由]

**复杂度分析**:
- 时间复杂度: O(?)
- 空间复杂度: O(?)
- 可并行性: [高/中/低]
```

### 1.3 浮点参考模型

创建 Python 浮点参考模型：

```python
# 文件: algorithm_float_model.py
# 这是验证的黄金参考

import numpy as np

class AlgorithmFloatModel:
    """
    [算法名称] 浮点参考模型

    该模型作为定点转换的黄金参考。
    所有中间结果均为浮点数以保证最大精度。
    """

    def __init__(self, config):
        """使用配置参数初始化"""
        self.config = config
        # 算法特定的初始化

    def process(self, input_data):
        """
        通过算法处理输入数据

        参数:
            input_data: 输入数组 [描述]

        返回:
            output_data: 输出数组 [描述]
            intermediates: 用于调试的中间值字典
        """
        intermediates = {}

        # 第1阶段: [描述]
        stage1_out = self._stage1(input_data)
        intermediates['stage1'] = stage1_out

        # 第2阶段: [描述]
        stage2_out = self._stage2(stage1_out)
        intermediates['stage2'] = stage2_out

        # ... 更多阶段

        return stageN_out, intermediates

    def _stage1(self, data):
        """第1阶段实现"""
        pass

    # ... 其他阶段方法
```

---

## 阶段 2: 硬件可行性评估

### 2.1 可行性检查清单

与硬件架构师一起审查每个算法组件：

| 组件 | 操作 | 硬件友好? | 关注点 | 缓解措施 |
|------|------|-----------|--------|----------|
| 阶段1 | [操作] | ✓/✗ | [关注点] | [解决方案] |
| ... | ... | ... | ... | ... |

### 2.2 需要关注的操作

**问题操作**（与架构师讨论简化方案）：

| 操作 | 硬件成本 | 典型简化方法 |
|------|----------|--------------|
| 除法 | 很高 | 倒数LUT、移位减法 |
| 平方根 | 高 | Newton-Raphson、LUT |
| 指数 | 高 | LUT、分段线性 |
| 对数 | 高 | LUT、分段线性 |
| 三角函数 | 高 | CORDIC、LUT |
| 浮点运算 | 高 | 定点转换 |
| 变长迭代 | 中 | 固定迭代次数 |

### 2.3 算法简化

当硬件实现困难时：

1. **数学简化**
   - 泰勒级数近似
   - 分段线性近似
   - 查找表

2. **算法替代方案**
   - 用乘法代替除法
   - 使用迭代近似方法
   - 降低精度要求

3. **记录权衡**

```markdown
## 硬件简化权衡

**原始操作**: [操作]
**简化方案**: [新方案]
**精度影响**: [误差分析]
**资源节省**: [估算节省]
**审批人**: [架构师姓名] (日期: YYYY-MM-DD)
```

---

## 阶段 3: 定点模型开发

### 3.1 阶段分解

将算法分解为适合流水线的阶段：

```markdown
## 流水线阶段定义

| 阶段 | 功能 | 输入 | 输出 | 延迟 |
|------|------|------|------|------|
| S1 | [功能] | [类型] | [类型] | [周期] |
| S2 | [功能] | [类型] | [类型] | [周期] |
| ... | ... | ... | ... | ... |

**总流水深度**: [N]阶段, [M]周期延迟
```

### 3.2 定点数表示

为每个信号定义：

```python
class FixedPointConfig:
    """每个信号的定点配置"""

    # 格式: Q[m.n] 其中 m = 整数位, n = 小数位
    # 总位数 = m + n + 1 (符号位)

    # 示例: Q8.7 表示 1符号 + 8整数 + 7小数 = 16位

    signals = {
        'input_data':     {'int_bits': 8, 'frac_bits': 0,  'signed': True},
        'coeff_a':        {'int_bits': 2, 'frac_bits': 14, 'signed': True},
        'stage1_output':  {'int_bits': 10, 'frac_bits': 6, 'signed': True},
        # ... 定义所有信号
    }
```

### 3.3 位宽分析

为每个阶段分析位宽需求：

```python
def analyze_bit_width(stage_name, float_values, signal_range=None):
    """
    分析信号的位宽需求

    参数:
        stage_name: 阶段/信号名称
        float_values: 浮点参考值
        signal_range: 已知信号范围 (min, max)

    返回:
        位宽建议及精度分析
    """
    import numpy as np

    # 确定范围
    if signal_range:
        min_val, max_val = signal_range
    else:
        min_val = float_values.min()
        max_val = float_values.max()

    # 整数位需求
    int_bits = max(
        int(np.ceil(np.log2(abs(min_val) + 1))) if min_val < 0 else 0,
        int(np.ceil(np.log2(max_val + 1)))
    )

    # 测试不同小数位宽
    print(f"\n=== {stage_name} 位宽分析 ===")
    print(f"范围: [{min_val:.6f}, {max_val:.6f}]")

    for frac_bits in [4, 8, 12, 16]:
        total_bits = int_bits + frac_bits + 1  # +1为符号位

        # 量化
        scale = 2 ** frac_bits
        quantized = np.round(float_values * scale) / scale

        # 计算指标
        error = float_values - quantized
        mse = np.mean(error ** 2)
        max_error = np.max(np.abs(error))

        # 信噪比
        signal_power = np.mean(float_values ** 2)
        noise_power = mse
        snr_db = 10 * np.log10(signal_power / noise_power) if noise_power > 0 else float('inf')

        print(f"  Q{int_bits}.{frac_bits} ({total_bits}位): "
              f"MSE={mse:.2e}, 最大误差={max_error:.6f}, SNR={snr_db:.1f}dB")

    return {
        'int_bits': int_bits,
        'recommended_frac_bits': 8,  # 基于分析
        'range': (min_val, max_val)
    }
```

### 3.4 定点模型实现

```python
# 文件: algorithm_fixed_model.py

import numpy as np

class AlgorithmFixedModel:
    """
    [算法名称] 定点模型

    该模型与RTL行为完全匹配用于验证。
    所有算术运算使用正确的量化。
    """

    def __init__(self, config):
        self.config = config

        # 定义每个信号的位宽
        self.fxp_config = {
            'input':       {'int': 8, 'frac': 0,  'signed': True},
            'stage1_out':  {'int': 10, 'frac': 6, 'signed': True},
            'stage2_out':  {'int': 12, 'frac': 4, 'signed': True},
            # ... 所有信号
        }

    def quantize(self, value, int_bits, frac_bits, signed=True, round_mode='floor'):
        """
        将值量化为定点表示

        参数:
            value: 浮点值
            int_bits: 整数位数
            frac_bits: 小数位数
            signed: 是否有符号
            round_mode: 'floor', 'round', 或 'ceil'

        返回:
            量化值 (浮点便于比较)
            整数表示 (用于模式输出)
        """
        scale = 2 ** frac_bits
        total_bits = int_bits + frac_bits + (1 if signed else 0)
        max_val = (2 ** (total_bits - 1)) - 1 if signed else (2 ** total_bits) - 1
        min_val = -(2 ** (total_bits - 1)) if signed else 0

        # 缩放和舍入
        if round_mode == 'floor':
            scaled = np.floor(value * scale)
        elif round_mode == 'round':
            scaled = np.round(value * scale)
        else:
            scaled = np.ceil(value * scale)

        # 饱和
        scaled = np.clip(scaled, min_val, max_val)

        return scaled / scale, scaled.astype(np.int64)

    def process(self, input_data):
        """
        通过所有阶段处理输入

        返回:
            output: 最终输出
            patterns: 每个阶段的十六进制模式字典
            precision_report: 精度指标字典
        """
        patterns = {}
        precision_report = {}
        current_data, int_rep = self.quantize(
            input_data,
            self.fxp_config['input']['int'],
            self.fxp_config['input']['frac']
        )
        patterns['input'] = self._to_hex(int_rep, self.fxp_config['input'])

        # 阶段1
        stage1_data, stage1_int = self._stage1_fixed(current_data)
        patterns['stage1_output'] = self._to_hex(
            stage1_int, self.fxp_config['stage1_out']
        )
        precision_report['stage1'] = self._compute_precision(
            current_data, stage1_data, 'stage1'
        )
        current_data = stage1_data

        # ... 更多阶段

        return current_data, patterns, precision_report

    def _to_hex(self, int_values, fxp_config):
        """将整数表示转换为十六进制字符串"""
        total_bits = fxp_config['int'] + fxp_config['frac'] + 1
        format_str = f'{{:0{total_bits // 4 + 1}X}}'

        if np.isscalar(int_values):
            return format_str.format(int_values & ((1 << total_bits) - 1))
        else:
            return [format_str.format(v & ((1 << total_bits) - 1)) for v in int_values]

    def _compute_precision(self, input_data, output_data, stage_name):
        """计算阶段的精度指标"""
        # 与浮点参考比较
        # ...
        pass
```

---

## 阶段 4: 模式生成

### 4.1 模式输出格式

为每个阶段生成CSV文件：

```python
def generate_patterns(fixed_model, test_inputs, output_dir):
    """
    生成CSV格式的验证模式

    输出格式:
    - 每个阶段一个文件
    - 十六进制值
    - 每行一个值
    """
    import os
    os.makedirs(output_dir, exist_ok=True)

    for i, input_data in enumerate(test_inputs):
        output, patterns, _ = fixed_model.process(input_data)

        # 写入每个阶段的模式
        for stage_name, hex_values in patterns.items():
            filename = f"{output_dir}/{stage_name}_pattern_{i:04d}.csv"
            with open(filename, 'w') as f:
                f.write(f"# 阶段: {stage_name}\n")
                f.write(f"# 测试用例: {i}\n")
                f.write(f"# 格式: 十六进制\n")
                for val in hex_values if isinstance(hex_values, list) else [hex_values]:
                    f.write(f"{val}\n")
```

### 4.2 模式文件格式

```csv
# 阶段: stage1_output
# 测试用例: 0001
# 格式: Q10.6, 有符号, 十六进制
# 位宽: 17位 (1符号 + 10整数 + 6小数)
0A3C
1B7F
0D21
...
```

### 4.3 完整模式集

生成覆盖以下内容的模式：

1. **边界情况**
   - 最大正值
   - 最小负值
   - 零
   - 边界值

2. **典型情况**
   - 随机代表性输入
   - 真实数据样本

3. **边缘情况**
   - 溢出场景
   - 精度边界条件

---

## 阶段 5: 精度分析报告

### 5.1 报告结构

```markdown
# 定点精度分析报告

## 1. 概述
- 算法: [名称]
- 总流水级数: [N]
- 建议总位宽: [M]
- 可达精度: [指标]

## 2. 逐阶段分析

### 阶段1: [名称]
| 指标 | 值 |
|------|-----|
| 输入格式 | Q[?][?] |
| 输出格式 | Q[?][?] |
| SNR | [X] dB |
| MSE | [X] |
| 最大误差 | [X] |
| 溢出风险 | [低/中/高] |

### 阶段2: [名称]
...

## 3. 精度预算
- 阶段1误差贡献: [X]%
- 阶段2误差贡献: [X]%
- ...

## 4. 建议
- [建议1]
- [建议2]

## 5. 测试结果
- 所有测试用例通过: [是/否]
- 最坏情况误差: [X]
- 最坏测试用例: [ID]
```

### 5.2 精度指标

为每个阶段计算并报告：

```python
def compute_precision_metrics(float_ref, fixed_result, stage_name):
    """计算综合精度指标"""

    error = float_ref - fixed_result

    metrics = {
        'stage': stage_name,
        'mse': np.mean(error ** 2),
        'rmse': np.sqrt(np.mean(error ** 2)),
        'max_error': np.max(np.abs(error)),
        'mean_error': np.mean(error),

        # 信噪比
        'signal_power': np.mean(float_ref ** 2),
        'noise_power': np.mean(error ** 2),
        'snr_db': 10 * np.log10(
            np.mean(float_ref ** 2) / np.mean(error ** 2)
        ),

        # 百分位数
        'error_p99': np.percentile(np.abs(error), 99),
        'error_p95': np.percentile(np.abs(error), 95),
    }

    return metrics
```

---

## 阶段 6: 验证支持

### 6.1 不匹配调试

当验证报告模式不匹配时：

```markdown
## 不匹配调查模板

**报告问题**: [描述]
**阶段**: [阶段名称]
**测试用例**: [ID]

### 调查步骤

1. **定位不匹配**
   - 哪个确切值不同？
   - RTL输出是什么？
   - 模型输出是什么？

2. **向后追踪**
   - 检查导致此输出的所有中间值
   - 确定分歧开始的位置

3. **可能原因**
   - [ ] 位宽不匹配
   - [ ] 舍入模式差异
   - [ ] 溢出处理差异
   - [ ] 符号扩展错误
   - [ ] 流水时序不匹配

4. **解决方案**
   - 根因: [描述]
   - 修复: [需要更改什么]
   - 更新: [模型/RTL/两者]
```

### 6.2 模型调整

如果定点模型需要调整：

1. **记录更改**
2. **更新位宽配置**
3. **重新生成模式**
4. **更新精度报告**

---

## 阶段 7: 文档交付

### 7.1 必需文档

1. **算法规格** (`algorithm_spec.md`)
   - 数学描述
   - 框图
   - 信号流

2. **定点规格** (`fixed_point_spec.md`)
   - 每个信号的位宽
   - 量化规则
   - 溢出处理

3. **精度分析报告** (`precision_report.md`)
   - 逐阶段分析
   - 误差预算
   - 建议

4. **验证模式描述** (`pattern_spec.md`)
   - 模式文件格式
   - 测试用例覆盖
   - 预期结果

### 7.2 评审检查清单

```markdown
## 交付检查清单

### 算法模型
- [ ] 浮点参考模型完成
- [ ] 所有阶段清晰定义
- [ ] 与架构师完成硬件可行性评审

### 定点模型
- [ ] 所有信号位宽已指定
- [ ] 精度分析完成
- [ ] 边界情况已验证

### 验证支持
- [ ] 模式文件已生成
- [ ] 格式已文档化
- [ ] 测试覆盖已文档化

### 文档
- [ ] 算法规格
- [ ] 定点规格
- [ ] 精度分析报告
- [ ] 模式规格

### 审批
- [ ] 硬件架构师签核
- [ ] RTL工程师评审
- [ ] 验证工程师确认
```

---

## 快速参考: 定点算术

### 位宽传播

| 操作 | 整数位 | 小数位 |
|------|--------|--------|
| A + B | max(A.int, B.int) + 1 | max(A.frac, B.frac) |
| A - B | max(A.int, B.int) + 1 | max(A.frac, B.frac) |
| A × B | A.int + B.int | A.frac + B.frac |
| A / B | A.int + B.frac | A.frac + B.int |

### 常用量化方案

1. **截断**: 直接丢弃低位 (有偏)
2. **舍入**: 截断前加0.5 LSB (无偏)
3. **收敛舍入**: 舍入到偶数 (无偏, 无直流偏置)

### 溢出处理

1. **饱和**: 限制到最大/最小可表示值
2. **回绕**: 让值循环 (RTL典型做法)
3. **检测**: 标记溢出条件

## 铁律

```
1. 每个近似操作必须量化误差（绝对误差 + 相对误差）
2. 相对误差超过 5% 必须上报 rtl-pm，由用户决策
3. 定点化方案必须有误差预算分析
4. 除法操作必须明确硬件实现方案（迭代除法器/近似/LUT）
5. 精度评估报告必须包含边界条件测试
```

## 精度评估铁律（重要）

### 必须量化的操作

| 操作类型 | 必须分析 | 示例 |
|----------|----------|------|
| 除法近似 | 除数替换的相对误差 | 除5→除4: +25% 误差 |
| 移位替代除法 | 截断误差 + 系统偏差 | x/5 → x>>2 |
| 乘法近似除法 | 系数误差 | x/5 → (x×205)>>10 |
| 定点量化 | 范围 + 精度损失 | 浮点→定点 |

### 误差分析模板

```markdown
## 操作近似分析

**原始操作**: [如: grad = (|grad_h| + |grad_v|) / 5]
**近似方案**: [如: grad = (|grad_h| >> 2) + (|grad_v| >> 2)]

### 误差计算
- 系统偏差: [如: +25%]
- 截断误差: [如: 0-6 LSB]
- 综合误差: [如: 25% + 截断]

### 影响评估
- 对后续阶段影响: [描述]
- 是否影响功能正确性: [是/否]

### 结论
- 误差是否可接受: [是/否]
- 如不可接受，推荐方案: [方案]
```

### 上报阈值

| 误差范围 | 处理方式 |
|----------|----------|
| < 1% | 可直接采用，记录到报告 |
| 1% - 5% | 需 rtl-arch 确认，记录到报告 |
| > 5% | **必须上报 rtl-pm**，由用户决策 |

### 算法评估铁律（重要）

#### 1. 必须评估架构师推荐方案

**问题案例**：
- rtl-algo 推荐 14080 entries 方案，评估了精度
- rtl-arch 推荐 256 entries 方案
- rtl-algo **未评估** rtl-arch 推荐方案的精度
- 结果：256 entries 方案被采纳但有严重设计缺陷

**正确做法**：
```markdown
## 架构师推荐方案评估

**rtl-arch 推荐方案**: [方案描述]
**必须评估项**:
1. 精度误差（最大/平均/分布）
2. 索引映射正确性（LUT 设计）
3. 边界条件处理
4. 与定点模型对齐验证

**评估结论**: [通过/不通过/需修改]
```

#### 2. 定点模型独立验证

**错误做法**：
- 定点模型直接实现与 RTL 一致的逻辑
- 未对 RTL 实现进行独立验证

**正确做法**：
- 定点模型应实现**理想算法**
- 用定点模型验证 RTL 实现的正确性
- 发现偏差时，检查是 RTL 错误还是算法权衡

#### 3. LUT 设计验证清单

对于查找表类设计，必须验证：

| 检查项 | 说明 | 验证方法 |
|--------|------|----------|
| 索引无重叠 | 每个输入映射到唯一索引 | 遍历所有输入值 |
| 覆盖完整 | 所有输入都有对应索引 | 边界条件测试 |
| 精度达标 | 误差在允许范围内 | 仿真统计 |
| 定点模型对齐 | 模型与 RTL 一致 | 对比测试 |

### 铁律示例

**错误做法**（导致 25% 误差未上报）:
```
原始: grad = sum / 5
实现: grad = sum >> 2  // 直接实现，未评估误差
```

**正确做法**:
```markdown
## 除5近似分析

**原始操作**: grad = (|grad_h| + |grad_v|) / 5
**近似方案**: grad = (|grad_h| >> 2) + (|grad_v| >> 2)

### 误差计算
- 系统偏差: +25%（1/4 vs 1/5）
- 截断误差: 0-6 LSB

### 影响评估
- 对窗口大小 LUT 影响: 阈值等效降低
- 对 Stage 3 融合影响: 无（等比放大后抵消）

### 结论
- 误差 25% > 5%，**上报 rtl-pm**
```

---

## 示例: 完整工作流程

```bash
# 1. 开发浮点模型
python algorithm_float_model.py --test

# 2. 运行硬件可行性评审
# (与硬件架构师讨论)

# 3. 开发定点模型并进行位宽分析
python algorithm_fixed_model.py --analyze-bitwidths

# 4. 生成验证模式
python algorithm_fixed_model.py --generate-patterns --output patterns/

# 5. 运行精度分析
python algorithm_fixed_model.py --precision-report --output docs/

# 6. 支持验证 (根据需要迭代)
# 发现不匹配时, 调试并更新模型

# 7. 最终交付
# 打包所有文档交付RTL团队
```