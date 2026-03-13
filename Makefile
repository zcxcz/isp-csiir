#-----------------------------------------------------------------------------
# Makefile for ISP-CSIIR RTL and Verification
#-----------------------------------------------------------------------------

# Project directories
RTL_DIR     = rtl
TB_DIR      = verification/tb
VERIF_DIR   = verification
BUILD_DIR   = build

# Simulator selection (override with SIM=<simulator>)
SIM ?= iverilog

# Compiler settings based on simulator
ifeq ($(SIM),vcs)
    VCS = vcs
    VCS_FLAGS = -full64 -sverilog -debug_access+all -kdb -lca
    VCS_RUN = ./simv
    SIM_FLAGS = $(VCS_FLAGS)
else ifeq ($(SIM),questa)
    VLOG = vlog
    VLOG_FLAGS = -sv
    VSIM = vsim
    VSIM_FLAGS = -c -do "run -all; quit"
    SIM_FLAGS = $(VLOG_FLAGS)
else ifeq ($(SIM),xcelium)
    XRUN = xrun
    XRUN_FLAGS = -sv -debug
    SIM_FLAGS = $(XRUN_FLAGS)
else ifeq ($(SIM),iverilog)
    IVERILOG = iverilog
    IVERILOG_FLAGS = -g2012 -Wall -I$(RTL_DIR)
    SIM_FLAGS = $(IVERILOG_FLAGS)
else
    $(error "Unknown simulator: $(SIM). Use vcs, questa, xcelium, or iverilog")
endif

# RTL source files
RTL_SOURCES = $(RTL_DIR)/isp_csiir_defines.vh \
              $(RTL_DIR)/isp_csiir_reg_block.v \
              $(RTL_DIR)/isp_csiir_line_buffer.v \
              $(RTL_DIR)/stage1_gradient.v \
              $(RTL_DIR)/stage2_directional_avg.v \
              $(RTL_DIR)/stage3_gradient_fusion.v \
              $(RTL_DIR)/stage4_iir_blend.v \
              $(RTL_DIR)/isp_csiir_top.v

# Verification source files
TB_SOURCES = $(TB_DIR)/isp_csiir_pixel_if.sv \
             $(TB_DIR)/isp_csiir_reg_if.sv \
             $(VERIF_DIR)/isp_csiir_pkg.sv \
             $(TB_DIR)/isp_csiir_tb_top.sv

# Test selection
TEST ?= isp_csiir_smoke_test

#-----------------------------------------------------------------------------
# Targets
#-----------------------------------------------------------------------------

.PHONY: all clean rtl_check sim wave

all: sim

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# RTL syntax check
rtl_check: $(RTL_SOURCES)
	@echo "Checking RTL syntax..."
ifeq ($(SIM),vcs)
	$(VCS) $(VCS_FLAGS) -lintonly $(RTL_SOURCES)
else ifeq ($(SIM),questa)
	$(VLOG) $(VLOG_FLAGS) $(RTL_SOURCES)
else ifeq ($(SIM),xcelium)
	$(XRUN) $(XRUN_FLAGS) -lint $(RTL_SOURCES)
else ifeq ($(SIM),iverilog)
	$(IVERILOG) $(IVERILOG_FLAGS) -t null $(RTL_SOURCES) 2>&1 | tee syntax_check.log
	@if [ ! -s syntax_check.log ] || ! grep -q "error" syntax_check.log; then \
		echo "Syntax check PASSED"; \
	else \
		echo "Syntax check FAILED"; \
	fi
endif

# Compile RTL only
rtl_compile: $(RTL_SOURCES)
	@echo "Compiling RTL..."
ifeq ($(SIM),vcs)
	$(VCS) $(VCS_FLAGS) $(RTL_SOURCES) -top isp_csiir_top
endif

# Compile and run simulation
sim: $(BUILD_DIR) $(RTL_SOURCES) $(TB_SOURCES)
	@echo "Running simulation with test: $(TEST)..."
ifeq ($(SIM),vcs)
	cd $(BUILD_DIR) && $(VCS) $(VCS_FLAGS) \
		+incdir+../$(VERIF_DIR)/env \
		+incdir+../$(VERIF_DIR)/agents \
		+incdir+../$(VERIF_DIR)/sequences \
		+incdir+../$(VERIF_DIR)/ref_model \
		+incdir+../$(RTL_DIR) \
		$(RTL_SOURCES) $(TB_SOURCES) \
		-top isp_csiir_tb_top \
		+UVM_TESTNAME=$(TEST) \
		-l compile.log
	cd $(BUILD_DIR) && $(VCS_RUN) -l sim.log
else ifeq ($(SIM),questa)
	cd $(BUILD_DIR) && $(VLOG) $(VLOG_FLAGS) \
		+incdir+../$(VERIF_DIR)/env \
		+incdir+../$(VERIF_DIR)/agents \
		+incdir+../$(VERIF_DIR)/sequences \
		+incdir+../$(VERIF_DIR)/ref_model \
		+incdir+../$(RTL_DIR) \
		$(RTL_SOURCES) $(TB_SOURCES)
	cd $(BUILD_DIR) && $(VSIM) $(VSIM_FLAGS) isp_csiir_tb_top +UVM_TESTNAME=$(TEST)
else ifeq ($(SIM),xcelium)
	cd $(BUILD_DIR) && $(XRUN) $(XRUN_FLAGS) \
		+incdir+../$(VERIF_DIR)/env \
		+incdir+../$(VERIF_DIR)/agents \
		+incdir+../$(VERIF_DIR)/sequences \
		+incdir+../$(VERIF_DIR)/ref_model \
		+incdir+../$(RTL_DIR) \
		$(RTL_SOURCES) $(TB_SOURCES) \
		+UVM_TESTNAME=$(TEST)
endif

# Run with waveform
wave: SIM_FLAGS += -debug_access+all -debug_region+cell
wave: sim
ifeq ($(SIM),vcs)
	cd $(BUILD_DIR) && verdi -dbdir DVE.db &
endif

# Run smoke test
smoke:
	$(MAKE) sim TEST=isp_csiir_smoke_test

# Run random test
random:
	$(MAKE) sim TEST=isp_csiir_random_test

# Run video test
video:
	$(MAKE) sim TEST=isp_csiir_video_test

# Run all tests
all_tests: smoke random video

# Simple testbench for Icarus Verilog (no UVM)
simple_tb: $(RTL_SOURCES)
	@echo "Running simple testbench with $(SIM)..."
ifeq ($(SIM),iverilog)
	@mkdir -p $(BUILD_DIR)
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(BUILD_DIR)/isp_csiir_sim \
		$(RTL_SOURCES) verification/tb/isp_csiir_simple_tb.v
	cd $(BUILD_DIR) && ./isp_csiir_sim
else
	@echo "Simple testbench is designed for iverilog. Use: make simple_tb SIM=iverilog"
endif

# View waveform
view_wave:
ifeq ($(SIM),iverilog)
	gtkwave $(BUILD_DIR)/isp_csiir_simple_tb.vcd &
else
	@echo "Use: make wave SIM=vcs for VCS waveform"
endif

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -rf simv* DVE* *.log *.vpd *.key *.vdb
	rm -rf csrc INCA_libs irun.key irun.log *.history

# Help
help:
	@echo "ISP-CSIIR RTL and Verification Makefile"
	@echo ""
	@echo "Usage: make [target] [SIM=simulator] [TEST=testname]"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build and run simulation (default)"
	@echo "  rtl_check  - Check RTL syntax only"
	@echo "  rtl_compile- Compile RTL only"
	@echo "  sim        - Compile and run simulation"
	@echo "  wave       - Run simulation with waveform dump"
	@echo "  smoke      - Run smoke test"
	@echo "  random     - Run random test"
	@echo "  video      - Run video test"
	@echo "  all_tests  - Run all tests"
	@echo "  clean      - Remove build artifacts"
	@echo "  help       - Show this help"
	@echo ""
	@echo "Simulators: vcs (default), questa, xcelium"
	@echo "Tests:      isp_csiir_smoke_test, isp_csiir_random_test, isp_csiir_video_test"
	@echo ""
	@echo "Example:"
	@echo "  make sim SIM=vcs TEST=isp_csiir_smoke_test"