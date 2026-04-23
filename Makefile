# ISP-CSIIR Verification Makefile
# Unified management for Python and HLS model testing

# Configuration
WIDTH ?= 16
HEIGHT ?= 16
PATTERN ?= random
SEED ?= 42
PYTHON_DIR = python
SCRIPTS_DIR = scripts
HLS_DIR = hls
BUILD_DIR = build
CONFIG ?=  # Optional: config file (JSON)

# Input/Output files
CONFIG_FILE = $(BUILD_DIR)/config.json
INPUT_HEX = $(BUILD_DIR)/input_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex
PYTHON_OUT = $(BUILD_DIR)/python_output_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex
HLS_OUT = $(BUILD_DIR)/hls_output_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex

.PHONY: all help clean clean_all config gen_input run_python run_hls compare run test gen_config

all: help

help:
	@echo "ISP-CSIIR Verification Makefile"
	@echo "================================"
	@echo ""
	@echo "Usage: make [target] [WIDTH=16] [HEIGHT=16] [PATTERN=random] [SEED=42]"
	@echo "       make [target] CONFIG=build/config.json  # Use config file"
	@echo ""
	@echo "Patterns: zeros, ramp, random, checkerboard, max, gradient"
	@echo ""
	@echo "Targets:"
	@echo "  gen_config   - Generate random config file"
	@echo "  gen_input    - Generate input pattern hex file"
	@echo "  run_python   - Run Python fixed-point model"
	@echo "  run_hls      - Compile and run HLS model"
	@echo "  compare      - Compare Python vs HLS output"
	@echo "  run          - Run Python + HLS + compare (full pipeline)"
	@echo "  test         - Quick test with random pattern"
	@echo "  clean        - Remove build directory"
	@echo "  clean_all    - Remove build + HLS binaries"
	@echo ""
	@echo "Examples:"
	@echo "  make gen_config SEED=123 WIDTH=16 HEIGHT=16"
	@echo "  make run CONFIG=build/config.json"
	@echo "  make run WIDTH=32 HEIGHT=32 PATTERN=checkerboard"
	@echo "  make test"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

gen_config: $(BUILD_DIR)
	@echo "Generating random config..."
	@python3 $(SCRIPTS_DIR)/gen_config.py \
		--seed $(SEED) \
		--width $(WIDTH) \
		--height $(HEIGHT) \
		--output $(CONFIG_FILE)
	@echo ""

gen_input: $(BUILD_DIR)
	@echo "Generating input pattern: $(PATTERN) ($(WIDTH)x$(HEIGHT))"
ifneq ($(CONFIG),)
	@python3 $(PYTHON_DIR)/gen_pattern.py \
		--config $(CONFIG) \
		--output $(INPUT_HEX)
else
	@python3 $(PYTHON_DIR)/gen_pattern.py \
		--pattern $(PATTERN) \
		--width $(WIDTH) \
		--height $(HEIGHT) \
		--seed $(SEED) \
		--output $(INPUT_HEX)
endif

run_python: gen_input
	@echo ""
	@echo "Running Python fixed-point model..."
ifneq ($(CONFIG),)
	@cd $(PYTHON_DIR) && python3 isp_csiir_fixed_model.py \
		--config ../$(CONFIG) \
		--input ../$(INPUT_HEX) \
		--output ../$(PYTHON_OUT) 2>&1
else
	@cd $(PYTHON_DIR) && python3 isp_csiir_fixed_model.py \
		--input ../$(INPUT_HEX) \
		--width $(WIDTH) \
		--height $(HEIGHT) \
		--output ../$(PYTHON_OUT) 2>&1
endif
	@echo "Python output: $(PYTHON_OUT)"

run_hls: gen_input
	@echo ""
	@echo "Compiling HLS model..."
	@cd $(HLS_DIR) && $(MAKE) clean && $(MAKE) 2>&1 | tail -3
	@echo ""
	@echo "Running HLS model..."
ifneq ($(CONFIG),)
	@cd $(HLS_DIR) && ./hls_top_tb $(shell realpath $(INPUT_HEX)) $(shell realpath $(HLS_OUT)) $(shell realpath $(CONFIG)) 2>&1 | grep -v "WARNING:" | head -20
else
	@cd $(HLS_DIR) && ./hls_top_tb $(shell realpath $(INPUT_HEX)) $(shell realpath $(HLS_OUT)) 2>&1 | grep -v "WARNING:" | head -20
endif
	@echo ""
	@echo "HLS output: $(HLS_OUT)"

compare: run_python run_hls
	@echo ""
	@echo "Comparing outputs..."
	@python3 $(SCRIPTS_DIR)/compare_outputs.py --python $(PYTHON_OUT) --hls $(HLS_OUT)

run: run_python run_hls compare

test:
	@make run WIDTH=16 HEIGHT=16 PATTERN=random SEED=42
	@echo ""
	@echo "Quick test complete"

clean:
	rm -rf $(BUILD_DIR)

clean_all: clean
	cd $(HLS_DIR) && $(MAKE) clean