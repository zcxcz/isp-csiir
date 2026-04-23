# ISP-CSIIR Verification Makefile
# Unified management for Python and HLS model testing

# Configuration
WIDTH ?= 16
HEIGHT ?= 16
PATTERN ?= random
PYTHON_DIR = verification
HLS_DIR = hls
BUILD_DIR = build

# Input/Output files
INPUT_HEX = $(BUILD_DIR)/input_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex
PYTHON_OUT = $(BUILD_DIR)/python_output_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex
HLS_OUT = $(BUILD_DIR)/hls_output_$(WIDTH)x$(HEIGHT)_$(PATTERN).hex

.PHONY: all help clean clean_all config gen_input run_python run_hls compare run test

all: help

help:
	@echo "ISP-CSIIR Verification Makefile"
	@echo "================================"
	@echo ""
	@echo "Usage: make [target] WIDTH=16 HEIGHT=16 PATTERN=zeros|ramp|random|checkerboard|max|gradient"
	@echo ""
	@echo "Targets:"
	@echo "  config      - Show current configuration"
	@echo "  gen_input   - Generate input pattern hex file"
	@echo "  run_python  - Run Python fixed-point model"
	@echo "  run_hls     - Compile and run HLS model"
	@echo "  compare     - Compare Python vs HLS output"
	@echo "  run         - Run Python + HLS + compare (full pipeline)"
	@echo "  test        - Quick test with random pattern"
	@echo "  clean       - Remove build directory"
	@echo "  clean_all   - Remove build + HLS binaries"
	@echo ""
	@echo "Examples:"
	@echo "  make config WIDTH=32 HEIGHT=32 PATTERN=random"
	@echo "  make run_python WIDTH=16 HEIGHT=16 PATTERN=ramp"
	@echo "  make compare WIDTH=16 HEIGHT=16 PATTERN=random"
	@echo "  make run WIDTH=64 HEIGHT=64 PATTERN=checkerboard"

config:
	@echo "Current configuration:"
	@echo "  WIDTH=$(WIDTH)"
	@echo "  HEIGHT=$(HEIGHT)"
	@echo "  PATTERN=$(PATTERN)"
	@echo ""
	@echo "  INPUT=$(INPUT_HEX)"
	@echo "  PYTHON_OUT=$(PYTHON_OUT)"
	@echo "  HLS_OUT=$(HLS_OUT)"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

gen_input: $(BUILD_DIR)
	@echo "Generating input pattern: $(PATTERN) ($(WIDTH)x$(HEIGHT))"
	@python3 $(PYTHON_DIR)/gen_pattern.py \
		--pattern $(PATTERN) \
		--width $(WIDTH) \
		--height $(HEIGHT) \
		--output $(INPUT_HEX)

run_python: gen_input
	@echo ""
	@echo "Running Python fixed-point model..."
	@cd $(PYTHON_DIR) && python3 isp_csiir_fixed_model.py \
		--input ../$(INPUT_HEX) \
		--width $(WIDTH) \
		--height $(HEIGHT) \
		--output ../$(PYTHON_OUT) 2>&1
	@echo "Python output: $(PYTHON_OUT)"

run_hls: gen_input
	@echo ""
	@echo "Compiling HLS model..."
	@cd $(HLS_DIR) && $(MAKE) clean && $(MAKE) 2>&1 | tail -3
	@echo ""
	@echo "Running HLS model..."
	@cd $(HLS_DIR) && ./hls_top_tb $(shell realpath $(INPUT_HEX)) $(shell realpath $(HLS_OUT)) 2>&1 | grep -v "WARNING:" | head -20
	@echo ""
	@echo "HLS output: $(HLS_OUT)"

compare: run_python run_hls
	@echo ""
	@echo "Comparing outputs..."
	@python3 $(PYTHON_DIR)/compare_outputs.py --python $(PYTHON_OUT) --hls $(HLS_OUT)

run: run_python run_hls compare

test:
	@make run WIDTH=16 HEIGHT=16 PATTERN=random
	@echo ""
	@echo "Quick test complete"

clean:
	rm -rf $(BUILD_DIR)

clean_all: clean
	cd $(HLS_DIR) && $(MAKE) clean