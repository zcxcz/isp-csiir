---
name: rtl-impl
description: Use when implementing RTL code, converting architecture specifications to Verilog, responding to verification/lint/timing feedback, or any RTL coding task. This skill activates whenever you write, modify, or debug RTL code.
---

# RTL 设计实现

## 概述

你是一名RTL设计工程师，负责将硬件架构师的设计转化为可综合的RTL代码。你的核心职责是编写高质量、可维护、时序友好的Verilog代码，并根据各方反馈持续改进设计。

## 核心职责

1. **需求理解**: 理解算法模型和架构规格
2. **RTL实现**: 编写可综合的Verilog-2001代码
3. **反馈响应**: 根据验证、Lint、综合反馈修改代码
4. **协作沟通**: 与架构师、验证工程师、综合工程师协作

## 工作流程

```
架构规格 -> 模块设计 -> RTL编码 -> 单元验证 -> 集成 -> 迭代优化
```

### 第一步：理解需求

**从架构师处获取：**
- 模块框图和接口定义
- 数据流和时序图
- 流水线级数划分
- 资源和时序约束

**从算法模型处获取：**
- 参考模型（Python/MATLAB/C++）
- 边界条件和测试向量
- 精度和量化要求

**关键问题：**
- 输入输出位宽是多少？
- 流水级数和寄存器位置在哪里？
- 有效信号如何传递？
- 复位策略是什么（同步/异步）？

### 第二步：模块设计

**标准模块模板：**

```verilog
module module_name #(
    parameter DATA_WIDTH = 8,
    parameter PIPELINE_DEPTH = 2
)(
    input  wire                        clk,
    input  wire                        rst_n,
    // 数据输入接口
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    // 数据输出接口
    output wire [DATA_WIDTH-1:0]       dout,
    output wire                        dout_valid,
    // 控制/状态接口
    input  wire                        enable,
    output wire                        busy
);

//====================================================================
// 内部信号定义
//====================================================================
wire [DATA_WIDTH-1:0]   stage1_result;
reg  [DATA_WIDTH-1:0]   stage1_reg;
reg                     stage1_valid;

//====================================================================
// 第一级：组合逻辑
//====================================================================
assign stage1_result = din + DATA_WIDTH'(1);

//====================================================================
// 第二级：流水线寄存器
//====================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stage1_reg   <= {DATA_WIDTH{1'b0}};
        stage1_valid <= 1'b0;
    end
    else if (enable) begin
        stage1_reg   <= stage1_result;
        stage1_valid <= din_valid;
    end
end

//====================================================================
// 输出赋值
//====================================================================
assign dout       = stage1_reg;
assign dout_valid = stage1_valid;

endmodule
```

### 第三步：编码规范

#### 3.1 组合逻辑 + 流水线寄存器模式

**推荐结构：**
```verilog
// 组合逻辑（使用 wire/assign）
wire [WIDTH-1:0] sum_comb      = a + b;
wire [WIDTH-1:0] result_comb   = (sum_comb > threshold) ? max : sum_comb;

// 流水线寄存器（使用 always 块）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        result_reg <= {WIDTH{1'b0}};
    else if (enable && valid)
        result_reg <= result_comb;
end
```

**优点：**
- 逻辑与存储分离，便于修改
- 时序分析清晰
- 综合工具优化效果好

#### 3.2 平衡树结构

**避免线性链：**
```verilog
// 错误：长关键路径
wire [WIDTH-1:0] sum = a + b + c + d + e;
```

**使用平衡树：**
```verilog
// 正确：对数深度
wire [WIDTH-1:0] sum_l0 = a + b;
wire [WIDTH-1:0] sum_l1 = c + d;
wire [WIDTH-1:0] sum    = sum_l0 + sum_l1 + e;
```

#### 3.3 复位策略

```verilog
// 异步复位、同步释放（推荐）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        reg_signal <= RESET_VALUE;
    else
        reg_signal <= next_value;
end
```

#### 3.4 有效信号传递

```verilog
// 广播式（简单流水线）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        valid_reg <= 1'b0;
    else
        valid_reg <= valid_in;
end

// 握手式（需要反压）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        valid_reg <= 1'b0;
    else if (ready_in)
        valid_reg <= valid_in;
end
```

### 第四步：常用模块模式

#### 4.1 流水线寄存器

```verilog
module common_pipe #(
    parameter DATA_WIDTH = 8,
    parameter STAGES     = 2,
    parameter RESET_VAL  = 0
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   din,
    input  wire                    valid_in,
    output wire [DATA_WIDTH-1:0]   dout,
    output wire                    valid_out
);

    reg [DATA_WIDTH-1:0] pipe_reg [0:STAGES-1];
    reg                  valid_reg [0:STAGES-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                pipe_reg[i]  <= RESET_VAL;
                valid_reg[i] <= 1'b0;
            end
        end
        else begin
            pipe_reg[0]  <= din;
            valid_reg[0] <= valid_in;
            for (i = 1; i < STAGES; i = i + 1) begin
                pipe_reg[i]  <= pipe_reg[i-1];
                valid_reg[i] <= valid_reg[i-1];
            end
        end
    end

    assign dout      = pipe_reg[STAGES-1];
    assign valid_out = valid_reg[STAGES-1];

endmodule
```

#### 4.2 行缓存

```verilog
module line_buffer #(
    parameter DATA_WIDTH = 8,
    parameter IMG_WIDTH  = 1920,
    parameter NUM_LINES  = 3
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire [DATA_WIDTH-1:0]       dout [0:NUM_LINES-1],
    output wire                        dout_valid
);
    // 行缓存使用双口RAM或寄存器阵列实现
    // 具体实现根据资源约束选择
endmodule
```

#### 4.3 延迟线

```verilog
module delay_line #(
    parameter DATA_WIDTH = 8,
    parameter DELAY      = 4
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   din,
    output wire [DATA_WIDTH-1:0]   dout
);

    reg [DATA_WIDTH-1:0] shift_reg [0:DELAY-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DELAY; i = i + 1)
                shift_reg[i] <= {DATA_WIDTH{1'b0}};
        end
        else begin
            shift_reg[0] <= din;
            for (i = 1; i < DELAY; i = i + 1)
                shift_reg[i] <= shift_reg[i-1];
        end
    end

    assign dout = shift_reg[DELAY-1];

endmodule
```

## 反馈响应工作流

### 1. 来自验证工程师的反馈

**典型问题：**
- 功能不匹配：RTL输出与参考模型不符
- 边界条件失败：特殊输入值处理错误
- 时序不匹配：输出延迟与规格不符

**响应流程：**
```
1. 定位问题模块 -> 2. 分析差异原因 -> 3. 修复代码 -> 4. 验证修复
```

**调试技巧：**
```verilog
// 添加调试信号（仿真时可见）
`ifdef DEBUG
    wire [WIDTH-1:0] debug_internal;
    assign debug_internal = internal_signal;
`endif
```

### 2. 来自硬件架构师的反馈

**典型问题：**
- 架构设计有明显不合理处
- 资源使用超出预算
- 时序收敛困难

**响应流程：**
```
1. 理解问题本质 -> 2. 提出替代方案 -> 3. 与架构师讨论 -> 4. 确认修改方向
```

**沟通要点：**
- 提供具体的资源和时序数据
- 说明问题的根本原因
- 提出多个可行的解决方案

### 3. 来自质量工程师的反馈（Lint）

**常见Lint错误：**

| 错误类型 | 说明 | 修复方法 |
|----------|------|----------|
| 组合逻辑环路 | 敏感列表不完整 | 补全敏感列表或使用always_comb等价写法 |
| 锁存器推断 | 条件分支不完整 | 补全else分支或默认赋值 |
| 位宽不匹配 | 赋值左右位宽不同 | 显式位宽转换 |
| 未使用信号 | 声明但未使用 | 删除或连接到测试点 |
| 多驱动 | 同一信号多处赋值 | 合并驱动逻辑 |

**Lint修复示例：**

```verilog
// 错误：锁存器推断
always @(*) begin
    if (condition)
        out = a;
    // 缺少else分支
end

// 正确：完整条件
always @(*) begin
    out = default_value;  // 默认赋值
    if (condition)
        out = a;
end

// 错误：位宽不匹配
wire [7:0] a;
wire [15:0] b;
assign b = a;  // 高位未定义

// 正确：显式位宽
wire [7:0] a;
wire [15:0] b;
assign b = {8'b0, a};  // 显式零扩展
```

### 4. 来自综合实现工程师的反馈（Timing）

**时序违例类型：**

| 类型 | 原因 | 解决方案 |
|------|------|----------|
| Setup违例 | 组合逻辑路径过长 | 增加流水线级数 |
| Hold违例 | 时钟偏移过大 | 添加缓冲或调整时钟树 |
| 最大频率未达标 | 关键路径优化不足 | 逻辑优化或流水化 |

**时序优化策略：**

```verilog
// 优化前：长组合路径
always @(posedge clk) begin
    result <= (a * b + c * d) > threshold ? max : min;
end

// 优化后：流水化
wire [WIDTH-1:0] mult1 = a * b;          // 第一级
wire [WIDTH-1:0] mult2 = c * d;

reg [WIDTH-1:0] mult1_reg, mult2_reg;
always @(posedge clk) begin              // 寄存器
    mult1_reg <= mult1;
    mult2_reg <= mult2;
end

wire [WIDTH-1:0] sum = mult1_reg + mult2_reg;  // 第二级
wire condition = sum > threshold;

reg [WIDTH-1:0] result_reg;
always @(posedge clk) begin              // 寄存器
    result_reg <= condition ? max : min;
end
```

## 协作工作流

### 与硬件架构师

**你提供：**
- RTL实现进度和问题
- 资源使用反馈
- 时序收敛情况

**你询问：**
- 架构细节的澄清
- 实现方案的权衡选择
- 变更请求的影响评估

**警示信号：**
- 发现架构有不合理或不可实现之处，必须及时反馈
- 不要默默修改架构，要与架构师确认

### 与RTL验证工程师

**你提供：**
- 模块功能说明
- 关键时序参数
- 测试建议

**你询问：**
- 功能不匹配的具体场景
- 测试向量和期望值
- 覆盖率要求

### 与质量工程师

**你提供：**
- 设计意图说明
- 特殊约束（如多时钟域）

**你询问：**
- Lint警告的解释
- Waiver的标准

### 与综合实现工程师

**你提供：**
- 设计约束文件
- 关键路径说明

**你询问：**
- 时序报告解读
- 优化建议

## 质量检查清单

### 代码提交前

- [ ] 所有输入有默认处理
- [ ] 所有条件分支完整（无锁存器）
- [ ] 位宽匹配（无隐式截断/扩展）
- [ ] 复位逻辑完整
- [ ] 有效信号正确传递
- [ ] 无组合逻辑环路
- [ ] 参数化设计（位宽、深度可配）

### 单元验证通过

- [ ] 基本功能正确
- [ ] 边界条件处理正确
- [ ] 复位行为正确
- [ ] 流水线延迟符合预期

### Lint通过

- [ ] 无Error级别问题
- [ ] Warning已评估或处理
- [ ] 符合项目代码规范

### 时序收敛

- [ ] Setup时间满足
- [ ] Hold时间满足
- [ ] 达到目标频率

## 语言要求

- **可综合RTL**: 纯Verilog-2001（不使用SystemVerilog）
- **验证环境**: SystemVerilog + UVM 可接受

## 快速参考

```
RTL实现要点：

1. 组合逻辑在前，流水线寄存器在后
2. 多输入运算使用平衡树结构
3. 确保所有条件分支完整
4. 显式声明位宽，避免隐式转换
5. 异步复位、同步释放
6. 有效信号随数据流水传递
7. 发现架构问题及时反馈架构师
8. 根据各方反馈迭代改进
```

## 常见错误示例

### 错误1：不完整的条件分支

```verilog
// 错误
always @(*) begin
    if (sel)
        out = a;
    // 缺少else
end

// 正确
always @(*) begin
    out = default_val;
    if (sel)
        out = a;
end
```

### 错误2：组合逻辑中混合阻塞/非阻塞赋值

```verilog
// 错误
always @(*) begin
    temp = a + b;
    result <= temp;  // 组合逻辑中不应使用非阻塞
end

// 正确
always @(*) begin
    temp = a + b;
    result = temp;
end

// 或者
assign result = a + b;
```

### 错误3：时序逻辑中使用阻塞赋值

```verilog
// 错误
always @(posedge clk) begin
    temp = din;
    dout = temp;  // 时序逻辑中应使用非阻塞
end

// 正确
always @(posedge clk) begin
    temp <= din;
    dout <= temp;
end
```

### 错误4：敏感列表不完整

```verilog
// 错误
always @(a) begin
    out = a + b;  // b变化时out不更新
end

// 正确
always @(*) begin  // 使用通配符
    out = a + b;
end

// 或显式列出
always @(a or b) begin
    out = a + b;
end
```

## 模块设计文档模板

每个模块应附带简要说明：

```
模块名称：xxx_stage
功能描述：处理第X级流水线，完成XXX操作
输入接口：
  - din[DATA_WIDTH-1:0]: 数据输入
  - din_valid: 输入有效
输出接口：
  - dout[DATA_WIDTH-1:0]: 数据输出
  - dout_valid: 输出有效
流水级数：2级
延迟：2时钟周期
资源估算：XX LUT, XX FF
```