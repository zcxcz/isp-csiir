---
name: rtl-verf
description: |
  Use when setting up RTL verification environments, creating testbenches, or validating hardware designs. This skill guides the complete verification workflow: building SystemVerilog testbenches (non-UVM), interfacing with DUT modules, comparing outputs against fixed-point golden models, creating testplans, running regression tests, and collecting coverage metrics.

  TRIGGER when: user mentions "验证环境", "testbench", "testplan", "回归测试", "覆盖率", "golden model", "数据比对", "功能覆盖", "代码覆盖", "SV验证平台", or asks about verifying RTL designs, setting up simulation environments, or comparing RTL output with algorithm models.
---

# RTL 验证工程 Skill

本 skill 指导验证工程师使用 SystemVerilog testbench（非UVM）完成 RTL 设计验证的完整工作流程，包括黄金模型比对、测试计划创建、回归测试和覆盖率收集。

## 工作流程概览

```
DUT分析 → 测试平台架构 → 黄金模型集成 → 测试计划
    ↓           ↓              ↓            ↓
 接口      激励生成       数据比对       测试用例
    ↓           ↓              ↓            ↓
    └───────────→ 回归测试 ←────────────────┘
                       ↓
               覆盖率分析 → 报告
```

---

## 阶段 1: DUT分析

### 1.1 DUT接口分析

创建testbench前，彻底分析DUT：

```verilog
// 创建DUT分析文档
/*
模块: <模块名称>
文件: <RTL文件路径>

接口:
| 端口 | 方向 | 位宽 | 描述 |
|------|------|------|------|
| clk  | 输入 | 1    | 时钟 |
| rst_n| 输入 | 1    | 低有效复位 |
| ...  | ...  | ...  | ...  |

时序:
- 流水深度: N周期
- Valid/ready握手: 是/否
- 数据速率: M采样/时钟

内部信号 (用于调试):
| 信号 | 位宽 | 阶段 | 描述 |
|------|------|------|------|
| stage1_out | 16 | S1 | 第1阶段输出 |
| ...    | ...   | ...   | ...         |
*/
```

### 1.2 流水线阶段提取

识别所有流水阶段及其接口：

```markdown
## 流水线阶段分析

| 阶段 | 名称 | 输入 | 输出 | 延迟 | Valid信号 |
|------|------|------|------|------|-----------|
| S0 | 输入缓存 | din | s0_out | 1 | valid_in |
| S1 | 处理 | s0_out | s1_out | 2 | valid_s1 |
| ... | ... | ... | ... | ... | ... |
```

### 1.3 读取RTL文件

```verilog
// 始终先读取DUT RTL以理解:
// 1. 模块端口
// 2. 参数
// 3. 内部状态机
// 4. 流水结构
// 5. 时钟域
```

---

## 阶段 2: 测试平台架构

### 2.1 标准测试平台结构

```
verification/
├── tb/
│   ├── <模块>_tb.sv          # 顶层testbench
│   ├── <模块>_if.sv          # 接口定义
│   ├── <模块>_pkg.sv         # 包 (类型, 函数)
│   └── <模块>_gold_model.sv  # 黄金模型 (可选SV版本)
├── tests/
│   ├── <模块>_test_basic.sv  # 基本测试
│   ├── <模块>_test_edge.sv   # 边界测试
│   └── <模块>_test_random.sv # 随机测试
├── scripts/
│   ├── run_regression.tcl    # 回归脚本
│   └── coverage_merge.tcl    # 覆盖率合并脚本
└── golden/
    └── <模块>_gold.py        # Python黄金模型 (来自算法团队)
```

### 2.2 接口定义

```systemverilog
// <模块>_if.sv
interface <模块>_if #(parameter DATA_WIDTH = 8) (
    input logic clk,
    input logic rst_n
);

    // DUT信号
    logic [DATA_WIDTH-1:0] din;
    logic                  din_valid;
    logic                  din_ready;
    logic [DATA_WIDTH-1:0] dout;
    logic                  dout_valid;
    logic                  dout_ready;

    // 内部调试信号 (如可访问)
    // logic [WIDTH-1:0] stage1_out;
    // logic [WIDTH-1:0] stage2_out;

    // 时钟块
    clocking cb @(posedge clk);
        default input #1ns output #1ns;
        input  din, din_valid, dout, dout_valid, dout_ready;
        output din_ready;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1ns;
        input din, din_valid, dout, dout_valid;
    endclocking

    // 模式端口
    modport DUT (
        input  clk, rst_n, din, din_valid, dout_ready,
        output din_ready, dout, dout_valid
    );

    modport TB (
        clocking cb
    );

    modport MONITOR (
        clocking mon_cb
    );

endinterface
```

### 2.3 顶层Testbench

```systemverilog
// <模块>_tb.sv
`timescale 1ns/1ps

module <模块>_tb;

    // 参数
    parameter DATA_WIDTH = 8;
    parameter CLK_PERIOD = 5;  // 200 MHz

    // 信号
    logic clk;
    logic rst_n;

    // 接口实例
    <模块>_if #(.DATA_WIDTH(DATA_WIDTH)) dut_if (
        .clk(clk),
        .rst_n(rst_n)
    );

    // DUT实例
    <模块>_dut #(.DATA_WIDTH(DATA_WIDTH)) dut (
        .clk        (dut_if.clk),
        .rst_n      (dut_if.rst_n),
        .din        (dut_if.din),
        .din_valid  (dut_if.din_valid),
        .din_ready  (dut_if.din_ready),
        .dout       (dut_if.dout),
        .dout_valid (dut_if.dout_valid),
        .dout_ready (dut_if.dout_ready)
    );

    // 时钟生成
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 测试变量
    int test_count;
    int pass_count;
    int fail_count;
    int error_count;

    // 黄金模型 (从文件加载)
    logic [DATA_WIDTH-1:0] golden_queue [$];
    logic [DATA_WIDTH-1:0] golden_data;

    // 测试激励
    logic [DATA_WIDTH-1:0] stimulus_queue [$];

    // 覆盖率
    covergroup cg_dout;
        coverpoint dut_if.dout {
            bins zero = {0};
            bins max = {255};
            bins mid = {[1, 254]};
        }
    endcovergroup

    // ============================================
    // 任务
    // ============================================

    // 复位任务
    task reset_dut();
        rst_n <= 0;
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        error_count = 0;
    endtask

    // 驱动输入
    task drive_input(input logic [DATA_WIDTH-1:0] data);
        @(dut_if.cb);
        dut_if.cb.din <= data;
        dut_if.cb.din_valid <= 1;
        @(dut_if.cb);
        while (!dut_if.cb.din_ready) @(dut_if.cb);
        dut_if.cb.din_valid <= 0;
    endtask

    // 等待输出
    task wait_output(output logic [DATA_WIDTH-1:0] data);
        @(dut_if.cb);
        while (!dut_if.cb.dout_valid) @(dut_if.cb);
        data = dut_if.cb.dout;
    endtask

    // 从文件加载黄金模型
    task load_golden_model(string filename);
        int fd;
        logic [DATA_WIDTH-1:0] val;
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $error("无法打开黄金文件: %s", filename);
            $finish;
        end
        while (!$feof(fd)) begin
            $fscanf(fd, "%h\n", val);
            golden_queue.push_back(val);
        end
        $fclose(fd);
        $display("从 %s 加载了 %0d 个黄金值", filename, golden_queue.size());
    endtask

    // 比较输出与黄金值
    task check_output(input logic [DATA_WIDTH-1:0] actual, input logic [DATA_WIDTH-1:0] expected, input int sample_idx);
        test_count++;
        if (actual == expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[失败] 样本 %0d: 期望 0x%02X, 实际 0x%02X", sample_idx, expected, actual);
        end
    endtask

    // ============================================
    // 测试序列
    // ============================================

    // 基本健全性测试
    task test_sanity();
        $display("\n=== 运行健全性测试 ===");
        reset_dut();

        // 简单单值测试
        drive_input(8'h80);
        // 等待流水线刷新
        repeat(dut.PIPELINE_DEPTH) wait_output(golden_data);

        $display("健全性测试完成");
    endtask

    // 遍历所有值
    task test_walk();
        logic [DATA_WIDTH-1:0] val;
        $display("\n=== 运行遍历测试 ===");
        reset_dut();

        for (int i = 0; i < 256; i++) begin
            drive_input(i);
        end

        // 收集输出
        for (int i = 0; i < 256; i++) begin
            wait_output(val);
            if (golden_queue.size() > 0) begin
                golden_data = golden_queue.pop_front();
                check_output(val, golden_data, i);
            end
        end

        $display("遍历测试: %0d 通过, %0d 失败", pass_count, fail_count);
    endtask

    // 随机测试
    task test_random(int num_samples);
        logic [DATA_WIDTH-1:0] val, expected;
        $display("\n=== 运行随机测试 (%0d 样本) ===", num_samples);
        reset_dut();
        pass_count = 0;
        fail_count = 0;

        for (int i = 0; i < num_samples; i++) begin
            val = $urandom_range(0, 255);
            drive_input(val);
        end

        for (int i = 0; i < num_samples; i++) begin
            wait_output(val);
            if (golden_queue.size() > 0) begin
                expected = golden_queue.pop_front();
                check_output(val, expected, i);
            end
        end

        $display("随机测试: %0d 通过, %0d 失败", pass_count, fail_count);
    endtask

    // ============================================
    // 主测试
    // ============================================

    initial begin
        $display("========================================");
        $display("  <模块名称> Testbench");
        $display("========================================");

        // 加载黄金模型
        load_golden_model("golden/output_pattern.hex");

        // 运行测试
        test_sanity();
        test_walk();
        test_random(1000);

        // 最终报告
        $display("\n========================================");
        $display("  测试摘要");
        $display("========================================");
        $display("总测试数:    %0d", test_count);
        $display("通过:        %0d", pass_count);
        $display("失败:        %0d", fail_count);
        $display("通过率:      %.2f%%", real'(pass_count)/test_count*100);
        $display("========================================");

        if (fail_count > 0)
            $display("测试失败");
        else
            $display("测试通过");

        $finish;
    end

    // 超时
    initial begin
        #100000;
        $display("错误: 仿真超时");
        $finish;
    end

endmodule
```

---

## 阶段 3: 黄金模型集成

### 3.1 Python黄金模型接口

当算法团队提供Python定点模型时，创建桥接：

```python
# golden_model_interface.py
"""
Python黄金模型与RTL testbench之间的接口

用法:
    python golden_model_interface.py --input input.hex --output output.hex
"""

import argparse
import sys

# 从算法团队导入定点模型
from fixed_point_model import FixedPointModel

def read_hex_file(filename):
    """从文件读取十六进制值，每行一个"""
    values = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                values.append(int(line, 16))
    return values

def write_hex_file(filename, values, width=8):
    """写入十六进制值到文件"""
    with open(filename, 'w') as f:
        for v in values:
            fmt = f'{{:0{(width+3)//4}X}}'
            f.write(fmt.format(v & ((1<<width)-1)) + '\n')

def main():
    parser = argparse.ArgumentParser(description='黄金模型接口')
    parser.add_argument('--input', required=True, help='输入十六进制文件')
    parser.add_argument('--output', required=True, help='输出十六进制文件')
    parser.add_argument('--config', help='配置文件 (可选)')
    args = parser.parse_args()

    # 加载输入数据
    input_data = read_hex_file(args.input)

    # 创建模型实例
    model = FixedPointModel()

    # 运行模型
    output_data = []
    for val in input_data:
        result = model.process_single(val)
        output_data.append(result)

    # 写入输出
    write_hex_file(args.output, output_data)

    print(f"处理了 {len(input_data)} 个样本")

if __name__ == '__main__':
    main()
```

### 3.2 预计算黄金模式

```python
# generate_golden_patterns.py
"""
预计算用于验证的黄金模式
此脚本调用算法团队的定点模型
"""

import numpy as np
from fixed_point_model import FixedPointModel

def generate_patterns():
    model = FixedPointModel()

    # 生成测试模式
    patterns = {
        'corner_cases': [0x00, 0x7F, 0x80, 0xFF],
        'walk': list(range(256)),
        'random_1k': [np.random.randint(0, 256) for _ in range(1000)],
        'random_10k': [np.random.randint(0, 256) for _ in range(10000)],
    }

    # 处理每个模式
    for name, inputs in patterns.items():
        outputs = []
        for val in inputs:
            result = model.process_single(val)
            outputs.append(result)

        # 写入文件
        write_hex_pattern(f'golden/input_{name}.hex', inputs)
        write_hex_pattern(f'golden/output_{name}.hex', outputs)
        print(f"生成 {name}: {len(inputs)} 个样本")

def write_hex_pattern(filename, values, width=8):
    with open(filename, 'w') as f:
        f.write(f"# 位宽: {width} 位\n")
        for v in values:
            fmt = f'{{:0{(width+3)//4}X}}'
            f.write(fmt.format(int(v) & ((1<<width)-1)) + '\n')

if __name__ == '__main__':
    generate_patterns()
```

### 3.3 逐阶段比较

用于调试，比较中间流水阶段：

```systemverilog
// 内部信号的调试接口
`ifdef DEBUG_STAGES
    // 绑定到DUT内部信号
    logic [WIDTH-1:0] stage_outputs [0:NUM_STAGES-1];

    // 监控所有阶段
    always @(posedge clk) begin
        if (dut_if.dout_valid) begin
            $write("样本 %0d: ", sample_count);
            for (int i = 0; i < NUM_STAGES; i++) begin
                $write("S%d=0x%04X ", i, stage_outputs[i]);
            end
            $write("\n");
        end
    end
`endif
```

---

## 阶段 4: 测试计划创建

### 4.1 测试计划模板

```markdown
# 测试计划: <模块名称>

## 1. 功能列表

| ID | 功能 | 优先级 | 描述 |
|----|------|--------|------|
| F01 | 复位 | 高 | 验证复位行为 |
| F02 | 正常操作 | 高 | 验证正常数据处理 |
| F03 | 背压 | 中 | 验证ready/valid握手 |
| F04 | 溢出 | 中 | 验证饱和行为 |
| F05 | 边界 | 高 | 验证最小/最大输入值 |

## 2. 测试用例

| ID | 测试名称 | 功能 | 描述 | 状态 |
|----|----------|------|------|------|
| T01 | test_reset | F01 | 施加复位，验证输出 | |
| T02 | test_single | F02 | 单样本处理 | |
| T03 | test_burst | F02 | 样本突发 | |
| T04 | test_backpressure | F03 | 验证ready取消 | |
| T05 | test_overflow | F04 | 验证饱和 | |
| T06 | test_min_max | F05 | 最小和最大输入值 | |
| T07 | test_random | F02,F05 | 随机输入模式 | |
| T08 | test_walk | F02,F05 | 遍历所有值 | |
| T09 | test_corner | F05 | 边界情况 (0, 127, 128, 255) | |
| T10 | test_long | F02 | 长序列 (1M样本) | |

## 3. 覆盖率目标

| 覆盖类型 | 目标 | 描述 |
|----------|------|------|
| 行覆盖 | 100% | 所有RTL行执行 |
| 翻转覆盖 | 100% | 所有位翻转 |
| FSM覆盖 | 100% | 所有状态和转换 |
| 功能覆盖 | 100% | 所有功能覆盖 |

## 4. 回归级别

| 级别 | 测试 | 时长 | 触发条件 |
|------|------|------|----------|
| 冒烟 | T01, T02, T03 | < 1 分钟 | 每次提交 |
| 基本 | T01-T09 | ~ 5 分钟 | 每次PR |
| 完整 | T01-T10 | ~ 30 分钟 | 每晚 |

## 5. 签核标准

- [ ] 所有测试通过
- [ ] 行覆盖 >= 95%
- [ ] 翻转覆盖 >= 90%
- [ ] 功能覆盖 100%
- [ ] 无未解决bug
- [ ] 黄金模型匹配率 100%
```

### 4.2 测试用例分类

```markdown
## 测试分类

### 1. 健全性测试
- 基本连通性
- 复位验证
- 时钟验证

### 2. 功能测试
- 正常操作
- 功能特定测试
- 配置测试

### 3. 边界测试
- 最小/最大值
- 溢出/下溢
- 边缘情况

### 4. 压力测试
- 最大吞吐量
- 连续事务
- 长序列

### 5. 随机测试
- 约束随机
- 随机种子
- 覆盖驱动

### 6. 错误测试
- 无效输入
- 协议违规
- 恢复测试
```

---

## 阶段 5: 回归测试

### 5.1 回归脚本 (TCL)

```tcl
# run_regression.tcl
# 运行回归测试并收集覆盖率

# 配置
set DUT_NAME "<模块名称>"
set TEST_LIST {
    "test_reset"
    "test_single"
    "test_burst"
    "test_backpressure"
    "test_overflow"
    "test_min_max"
    "test_random"
    "test_walk"
    "test_corner"
    "test_long"
}

set SEED_LIST {1 2 3 4 5}
set COVERAGE_DIR "coverage"

# 创建覆盖率目录
file mkdir $COVERAGE_DIR

# 运行每个测试
foreach test $TEST_LIST {
    foreach seed $SEED_LIST {
        puts "运行 $test 种子 $seed"

        # 编译
        vlog -cover bst -work work \
            rtl/${DUT_NAME}.v \
            verification/tb/${DUT_NAME}_tb.sv

        # 仿真
        vsim -coverage -seed $seed work.${DUT_NAME}_tb \
            +UVM_TESTNAME=$test \
            +UVM_VERBOSITY=UVM_MEDIUM \
            -do "run -all; quit"

        # 保存覆盖率
        coverage save ${COVERAGE_DIR}/${test}_seed${seed}.ucdb
    }
}

# 合并覆盖率
puts "合并覆盖率..."
vcover merge ${COVERAGE_DIR}/merged.ucdb ${COVERAGE_DIR}/*.ucdb

# 生成报告
vcover report -html ${COVERAGE_DIR}/merged.ucdb -output ${COVERAGE_DIR}/html
vcover report -text ${COVERAGE_DIR}/coverage_report.txt ${COVERAGE_DIR}/merged.ucdb

puts "回归完成. 覆盖率报告: ${COVERAGE_DIR}/html/index.html"
```

### 5.2 回归Makefile

```makefile
# RTL验证Makefile

DUT = isp_csiir
SIMULATOR = modelsim  # 或 vcs, xcelium

# 源文件
RTL_SRCS = $(wildcard rtl/*.v)
TB_SRCS = $(wildcard verification/tb/*.sv)

# 测试类别
SMOKE_TESTS = test_reset test_single
BASIC_TESTS = $(SMOKE_TESTS) test_burst test_walk test_corner
FULL_TESTS = $(BASIC_TESTS) test_random test_long

# 默认目标
all: compile run_basic

# 编译
compile:
	vlog -work work $(RTL_SRCS) $(TB_SRCS)

# 运行测试
run_smoke:
	@for test in $(SMOKE_TESTS); do \
		vsim -c work.$(DUT)_tb +TEST=$$test -do "run -all; quit"; \
	done

run_basic:
	@for test in $(BASIC_TESTS); do \
		vsim -c work.$(DUT)_tb +TEST=$$test -do "run -all; quit"; \
	done

run_full:
	@for test in $(FULL_TESTS); do \
		vsim -coverage work.$(DUT)_tb +TEST=$$test -do "run -all; quit"; \
	done

# 带覆盖率的回归
regression:
	rm -rf coverage/*
	mkdir -p coverage
	@for test in $(FULL_TESTS); do \
		echo "运行 $$test..."; \
		vsim -coverage -c work.$(DUT)_tb +TEST=$$test \
			-do "coverage save coverage/$$test.ucdb; quit"; \
	done
	vcover merge coverage/merged.ucdb coverage/*.ucdb
	vcover report -html coverage/merged.ucdb -output coverage/html

# 清理
clean:
	rm -rf work coverage *.wlf *.log

.PHONY: all compile run_smoke run_basic run_full regression clean
```

---

## 阶段 6: 覆盖率分析

### 6.1 代码覆盖类型

| 类型 | 描述 | 目标 |
|------|------|------|
| 行/分支 | 行执行, 分支选择 | 100% |
| 翻转 | 位翻转 0→1 和 1→0 | 95%+ |
| FSM | 状态访问, 转换选择 | 100% |
| 条件 | 布尔表达式评估 | 95%+ |

### 6.2 功能覆盖

```systemverilog
// 功能覆盖定义
covergroup cg_input_values @(posedge clk);
    option.per_instance = 1;

    cp_din: coverpoint dut_if.din {
        bins zero = {0};
        bins one = {1};
        bins max = {255};
        bins min_1 = {1};
        bins mid = {[2, 253]};
        bins mid_gray = {128};
    }

    cp_valid: coverpoint dut_if.din_valid {
        bins asserted = {1};
        bins deasserted = {0};
    }

    // 交叉覆盖
    cross cp_din, cp_valid;
endcovergroup

covergroup cg_output_values @(posedge clk);
    cp_dout: coverpoint dut_if.dout {
        bins zero = {0};
        bins max = {255};
        bins mid = {[1, 254]};
    }

    cp_valid: coverpoint dut_if.dout_valid {
        bins asserted = {1};
        bins deasserted = {0};
    }
endcovergroup

covergroup cg_handshake @(posedge clk);
    // Ready-valid握手
    cp_in_handshake: coverpoint {dut_if.din_valid, dut_if.din_ready} {
        bins idle = {2'b00};
        bins wait = {2'b10};
        bins accept = {2'b11};
        bins ready_no_valid = {2'b01};
    }
endcovergroup

covergroup cg_pipeline_timing @(posedge clk);
    // 追踪流水利用率
    cp_valid_sequence: coverpoint dut_if.dout_valid {
        bins single = (0 => 1 => 0);
        bins burst_2 = (1 => 1);
        bins burst_3 = (1 => 1 => 1);
    }
endcovergroup
```

### 6.3 覆盖率报告分析

```markdown
## 覆盖率分析报告模板

### 代码覆盖率摘要

| 类型 | 达成 | 目标 | 状态 |
|------|------|------|------|
| 行 | XX% | 100% | ✓/✗ |
| 分支 | XX% | 100% | ✓/✗ |
| 翻转 | XX% | 95% | ✓/✗ |
| FSM | XX% | 100% | ✓/✗ |

### 未覆盖项

| 文件 | 行 | 类型 | 原因 | 操作 |
|------|-----|------|------|------|
| file.v | 123 | 行 | 死代码 | 豁免 |
| file.v | 456 | 分支 | 错误路径 | 添加测试 |

### 功能覆盖率摘要

| 覆盖组 | 达成 | 目标 | 状态 |
|--------|------|------|------|
| 输入值 | XX% | 100% | ✓/✗ |
| 输出值 | XX% | 100% | ✓/✗ |
| 握手 | XX% | 100% | ✓/✗ |

### 覆盖漏洞

1. **输入值 0x7F**: 未覆盖
   - 需要测试: test_corner 使用 0x7F 输入
   - 优先级: 高

2. **背压**: 未完全覆盖
   - 需要测试: test_backpressure
   - 优先级: 中

### 建议

1. 为未覆盖输入值 0x7F 添加测试用例
2. 增加随机测试迭代次数
3. 为 [特定条件] 添加断言
```

---

## 阶段 7: 调试与不匹配解决

### 7.1 不匹配调查流程

```
RTL != 黄金模型
        ↓
检查时序对齐
        ↓
    匹配? → 否 → 调整流水延迟
        ↓ 是
检查位宽对齐
        ↓
    匹配? → 否 → 验证量化
        ↓ 是
检查舍入模式
        ↓
    匹配? → 否 → 对齐舍入
        ↓ 是
检查饱和处理
        ↓
    匹配? → 否 → 模型添加饱和
        ↓ 是
报告为bug
```

### 7.2 调试基础设施

```systemverilog
// 调试模块 - 绑定到DUT
module <模块>_debug;
    // 样本计数器
    int sample_count;
    int mismatch_count;

    // 日志文件
    int log_fd;

    initial begin
        log_fd = $fopen("debug.log", "w");
    end

    // 监控所有事务
    always @(posedge dut_if.clk) begin
        if (dut_if.din_valid && dut_if.din_ready) begin
            $fwrite(log_fd, "输入[%0d]: 0x%02X\n",
                    sample_count, dut_if.din);
        end

        if (dut_if.dout_valid) begin
            $fwrite(log_fd, "输出[%0d]: 0x%02X (期望: 0x%02X)\n",
                    sample_count, dut_if.dout, expected_queue[sample_count]);

            if (dut_if.dout != expected_queue[sample_count]) begin
                mismatch_count++;
                $fwrite(log_fd, "样本 %0d 不匹配!\n", sample_count);
            end
        end
    end

    final begin
        $fclose(log_fd);
        $display("总不匹配数: %0d", mismatch_count);
    end

endmodule
```

### 7.3 与算法团队沟通

发现不匹配时，发送给算法团队：

```markdown
## 验证问题报告

**日期**: YYYY-MM-DD
**模块**: <模块名称>
**测试用例**: <测试名称>
**样本索引**: <N>

### RTL输出
```
值: 0x7F3A
二进制: 0111_1111_0011_1010
```

### 黄金模型输出
```
值: 0x7F3B
二进制: 0111_1111_0011_1011
```

### 差异
```
1 LSB差异 (位0)
```

### 输入上下文
```
输入: 0xXX
之前输入: [...]
流水状态: [...]
```

### RTL中间值
```
阶段1: 0x....
阶段2: 0x....
阶段3: 0x....
```

### 请求
请验证:
1. 黄金模型是否使用相同舍入模式？
2. 模型中是否有中间截断？
3. 模型是否匹配RTL饱和行为？
```

---

## 阶段 8: 验证报告

### 8.1 签核报告模板

```markdown
# 验证签核报告

## 项目信息
- 模块: <名称>
- 版本: <版本>
- 日期: <日期>
- 工程师: <姓名>

## 测试执行摘要

| 测试类别 | 总数 | 通过 | 失败 | 通过率 |
|----------|------|------|------|--------|
| 健全性 | X | X | 0 | 100% |
| 功能 | X | X | 0 | 100% |
| 边界 | X | X | 0 | 100% |
| 随机 | X | X | 0 | 100% |
| 回归 | X | X | 0 | 100% |
| **总计** | **X** | **X** | **0** | **100%** |

## 覆盖率摘要

| 覆盖类型 | 达成 | 目标 | 状态 |
|----------|------|------|------|
| 行 | XX% | 100% | ✓ |
| 分支 | XX% | 100% | ✓ |
| 翻转 | XX% | 95% | ✓ |
| FSM | XX% | 100% | ✓ |
| 功能 | XX% | 100% | ✓ |

## 黄金模型比较

- 总比较样本数: X
- 不匹配数: 0
- 匹配率: 100%

## 已知问题

| ID | 描述 | 状态 | 豁免 |
|----|------|------|------|
| - | - | - | - |

## 签核标准

- [x] 所有测试通过
- [x] 代码覆盖达标
- [x] 功能覆盖 100%
- [x] 黄金模型比较 100%
- [x] 无未解决关键bug
- [x] 回归连续3次稳定

## 结论

**批准流片**

---

验证人: _________________ 日期: _________
评审人: _________________ 日期: _________
```

---

## 快速参考: Testbench检查清单

### 验证前
- [ ] 读取并理解DUT RTL
- [ ] 识别所有输入/输出端口
- [ ] 文档化流水阶段
- [ ] 从算法团队获取黄金模型

### Testbench创建
- [ ] 创建接口文件
- [ ] 创建顶层testbench
- [ ] 实现复位任务
- [ ] 实现驱动/等待任务
- [ ] 实现比较逻辑

### 黄金模型集成
- [ ] 生成黄金模式
- [ ] 在testbench中加载模式
- [ ] 验证对齐 (流水延迟)
- [ ] 用已知值测试

### 测试计划
- [ ] 列出所有功能
- [ ] 为每个功能定义测试用例
- [ ] 设置覆盖目标
- [ ] 定义回归级别

### 回归
- [ ] 创建运行脚本
- [ ] 配置覆盖率收集
- [ ] 设置CI集成
- [ ] 文档化豁免流程

### 覆盖率
- [ ] 定义功能覆盖组
- [ ] 设置覆盖目标
- [ ] 创建覆盖率报告
- [ ] 分析覆盖漏洞

### 签核
- [ ] 所有测试通过
- [ ] 覆盖达标
- [ ] 黄金模型 100% 匹配
- [ ] 文档完整