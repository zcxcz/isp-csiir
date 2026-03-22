# ISP-CSIIR 验证环境 Makefile
#
# 使用方法:
#   make sim          - 运行仿真
#   make sim-simple   - 运行简单测试
#   make sim-full     - 运行完整测试
#   make golden       - 运行 Golden Model
#   make wave         - 查看波形
#   make clean        - 清理生成文件

# 配置
SIMULATOR ?= iverilog
IMG_WIDTH ?= 64
IMG_HEIGHT ?= 64
DATA_WIDTH ?= 10

# 目录
RTL_DIR = ../rtl
TB_DIR = tb
OUT_DIR = out

# RTL 文件
RTL_SRCS = $(wildcard $(RTL_DIR)/*.v) $(wildcard $(RTL_DIR)/common/*.v)

# Testbench 文件
TB_SIMPLE = $(TB_DIR)/tb_isp_csiir_simple.sv
TB_FULL = $(TB_DIR)/tb_isp_csiir_top.sv

# 输出文件
SIM_OUT = isp_csiir_sim
VCD_FILE = $(OUT_DIR)/wave.vcd

# 默认目标
.PHONY: all
all: sim-simple

# 创建输出目录
$(OUT_DIR):
	mkdir -p $(OUT_DIR)

# Icarus Verilog 编译
compile-simple: $(RTL_SRCS) $(TB_SIMPLE)
	@echo "编译简单测试平台..."
	iverilog -g2012 -o $(SIM_OUT) \
		-DIMG_WIDTH=$(IMG_WIDTH) \
		-DIMG_HEIGHT=$(IMG_HEIGHT) \
		-DDATA_WIDTH=$(DATA_WIDTH) \
		-I$(RTL_DIR) \
		$(RTL_SRCS) $(TB_SIMPLE)

compile-full: $(RTL_SRCS) $(TB_FULL)
	@echo "编译完整测试平台..."
	iverilog -g2012 -o $(SIM_OUT) \
		-DIMG_WIDTH=$(IMG_WIDTH) \
		-DIMG_HEIGHT=$(IMG_HEIGHT) \
		-DDATA_WIDTH=$(DATA_WIDTH) \
		-I$(RTL_DIR) \
		$(RTL_SRCS) $(TB_FULL)

# 运行仿真
sim-simple: compile-simple
	@echo "运行简单测试..."
	vvp $(SIM_OUT)

sim-full: compile-full
	@echo "运行完整测试..."
	vvp $(SIM_OUT)

sim: sim-simple

# Golden Model 测试
golden:
	@echo "运行 Golden Model..."
	python3 run_verification.py --golden-only --width $(IMG_WIDTH) --height $(IMG_HEIGHT)

# 完整验证
verify: golden sim-full

# 波形查看
wave: $(VCD_FILE)
	gtkwave $(VCD_FILE) &

# 清理
clean:
	rm -rf $(SIM_OUT) *.vcd $(OUT_DIR)
	rm -f *.vcd *.log

# 帮助
help:
	@echo "ISP-CSIIR 验证环境"
	@echo ""
	@echo "目标:"
	@echo "  sim-simple   - 运行简单测试 (默认)"
	@echo "  sim-full     - 运行完整测试"
	@echo "  golden       - 运行 Golden Model"
	@echo "  verify       - 运行完整验证"
	@echo "  wave         - 查看波形"
	@echo "  clean        - 清理生成文件"
	@echo ""
	@echo "参数:"
	@echo "  IMG_WIDTH    - 图像宽度 (默认: 64)"
	@echo "  IMG_HEIGHT   - 图像高度 (默认: 64)"
	@echo "  DATA_WIDTH   - 数据位宽 (默认: 10)"
	@echo ""
	@echo "示例:"
	@echo "  make sim-simple IMG_WIDTH=32 IMG_HEIGHT=32"
	@echo "  make golden"