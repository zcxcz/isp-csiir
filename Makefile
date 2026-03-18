#-----------------------------------------------------------------------------
# Makefile for ISP-CSIIR RTL and Verification
#-----------------------------------------------------------------------------

# Project directories
RTL_DIR     = rtl
TB_DIR      = verification/tb
BUILD_DIR   = build

# Icarus Verilog settings
IVERILOG    = iverilog
IVERILOG_FLAGS = -g2012 -Wall -I$(RTL_DIR)

# RTL source files
RTL_SOURCES = $(RTL_DIR)/isp_csiir_defines.vh \
              $(RTL_DIR)/common/common_pipe.v \
              $(RTL_DIR)/common/common_counter.v \
              $(RTL_DIR)/common/common_fifo.v \
              $(RTL_DIR)/common/common_adder_tree.v \
              $(RTL_DIR)/common/common_delay_line.v \
              $(RTL_DIR)/common/common_max_finder.v \
              $(RTL_DIR)/isp_csiir_reg_block.v \
              $(RTL_DIR)/isp_csiir_line_buffer.v \
              $(RTL_DIR)/isp_csiir_iir_line_buffer.v \
              $(RTL_DIR)/stage1_gradient.v \
              $(RTL_DIR)/stage2_directional_avg.v \
              $(RTL_DIR)/stage3_gradient_fusion.v \
              $(RTL_DIR)/stage4_iir_blend.v \
              $(RTL_DIR)/isp_csiir_top.v

# Output files
SIM_EXE     = $(BUILD_DIR)/isp_csiir_sim
VCD_FILE    = $(BUILD_DIR)/isp_csiir_simple_tb.vcd
TEST_VECTORS = verification/test_vectors

#-----------------------------------------------------------------------------
# Targets
#-----------------------------------------------------------------------------

.PHONY: all clean sim wave rtl_check help patterns

all: sim

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Generate test patterns
patterns: $(BUILD_DIR)
	@echo "Generating test patterns..."
	python3 verification/test_pattern_generator.py --height 64 --width 64 --frames 2

# RTL syntax check
rtl_check: $(RTL_SOURCES)
	@echo "Checking RTL syntax..."
	$(IVERILOG) $(IVERILOG_FLAGS) -t null $(RTL_SOURCES) 2>&1 | tee $(BUILD_DIR)/syntax_check.log || true
	@if [ ! -s $(BUILD_DIR)/syntax_check.log ] || ! grep -q "error" $(BUILD_DIR)/syntax_check.log; then \
		echo "Syntax check PASSED"; \
	else \
		echo "Syntax check FAILED"; \
	fi

# Compile and run simulation (generates VCD waveform)
sim: $(BUILD_DIR) patterns $(RTL_SOURCES)
	@echo "Running simulation..."
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(SIM_EXE) $(RTL_SOURCES) $(TB_DIR)/isp_csiir_simple_tb.v
	cp -r $(TEST_VECTORS) $(BUILD_DIR)/
	cd $(BUILD_DIR) && ./isp_csiir_sim

# View waveform with GTKWave
wave: $(VCD_FILE)
	@echo "Opening waveform viewer..."
	gtkwave $(VCD_FILE) &

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

# Help
help:
	@echo "ISP-CSIIR RTL Simulation Makefile (Icarus Verilog)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  sim       - Compile and run simulation (default)"
	@echo "  wave      - View waveform with GTKWave (after sim)"
	@echo "  rtl_check - Check RTL syntax only"
	@echo "  clean     - Remove build artifacts"
	@echo "  help      - Show this help"
	@echo ""
	@echo "Output files:"
	@echo "  $(SIM_EXE)  - Simulation executable"
	@echo "  $(VCD_FILE) - Waveform file"
	@echo ""
	@echo "Example workflow:"
	@echo "  make sim    # Run simulation"
	@echo "  make wave   # View waveforms"
	@echo ""
	@echo "Note: UVM verification requires commercial simulators (VCS/Questa/Xcelium)"