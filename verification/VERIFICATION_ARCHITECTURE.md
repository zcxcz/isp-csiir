# ISP-CSIIR Verification Architecture

## Overview

The verification framework follows UVM (Universal Verification Methodology) architecture, providing a comprehensive testbench for the ISP-CSIIR RTL design. The framework supports multiple test scenarios, automated checking via a reference model, and functional coverage collection.

## Directory Structure

```
verification/
├── isp_csiir_pkg.sv          # Package - includes all components
├── agents/                    # UVM Agents
│   ├── isp_csiir_pixel_agent.svh
│   ├── isp_csiir_pixel_driver.svh
│   ├── isp_csiir_pixel_monitor.svh
│   ├── isp_csiir_reg_agent.svh
│   ├── isp_csiir_reg_driver.svh
│   └── isp_csiir_reg_monitor.svh
├── env/                       # UVM Environment
│   ├── isp_csiir_config.svh
│   ├── isp_csiir_env.svh
│   ├── isp_csiir_scoreboard.svh
│   └── isp_csiir_coverage.svh
├── ref_model/                 # Golden Reference Model
│   └── isp_csiir_ref_model.svh
├── sequences/                 # Sequence Items & Tests
│   ├── isp_csiir_pixel_item.svh
│   ├── isp_csiir_reg_item.svh
│   ├── isp_csiir_pixel_sequence.svh
│   ├── isp_csiir_reg_sequence.svh
│   ├── isp_csiir_base_test.svh
│   ├── isp_csiir_smoke_test.svh
│   ├── isp_csiir_random_test.svh
│   └── isp_csiir_video_test.svh
└── tb/                        # Testbench Top
    ├── isp_csiir_tb_top.sv
    ├── isp_csiir_pixel_if.sv
    ├── isp_csiir_reg_if.sv
    └── isp_csiir_simple_tb.v
```

---

## Architecture Diagram

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    isp_csiir_env                         │
                    │                                                          │
┌──────────────┐    │  ┌──────────────────┐    ┌──────────────────┐           │
│  Sequencer   │────┼──│  pixel_agent     │    │    reg_agent     │           │
│  (Tests)     │    │  │ ┌─────┐┌───────┐ │    │ ┌─────┐┌───────┐ │           │
└──────────────┘    │  │ │driver││monitor│ │    │ │driver││monitor│ │           │
                    │  │ └─────┘└───────┘ │    │ └─────┘└───────┘ │           │
                    │  └────────┬─────────┘    └────────┬─────────┘           │
                    │           │                       │                      │
                    │           ▼                       │                      │
                    │  ┌──────────────────┐             │                      │
                    │  │   ref_model      │             │                      │
                    │  │ (Golden Model)   │             │                      │
                    │  └────────┬─────────┘             │                      │
                    │           │                       │                      │
                    │           ▼                       ▼                      │
                    │  ┌──────────────────┐    ┌──────────────────┐           │
                    │  │   scoreboard     │◄───│    coverage      │           │
                    │  │  (Comparator)    │    │  (Collector)     │           │
                    │  └──────────────────┘    └──────────────────┘           │
                    │                                                          │
                    └─────────────────────────────────────────────────────────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │   DUT (RTL)      │
                                    │  isp_csiir_top   │
                                    └──────────────────┘
```

---

## Component Details

### 1. Testbench Top (`tb/isp_csiir_tb_top.sv`)

**Function**: Top-level module that instantiates DUT, interfaces, and launches UVM test.

**Key Features**:
- 100MHz clock generation (period = 10ns)
- Reset sequence (100ns active low)
- DUT instance with configurable parameters (1920x1080, 8-bit)
- VCD waveform dump for debugging
- 100ms simulation timeout

**Typical Usage**:
```systemverilog
// Run specific test via UVM_TESTNAME
+UVM_TESTNAME=isp_csiir_smoke_test
```

---

### 2. Interfaces (`tb/`)

#### isp_csiir_pixel_if (`isp_csiir_pixel_if.sv`)

**Purpose**: Video streaming interface for pixel data I/O.

**Signals**:
| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| vsync | Input/Output | 1 | Vertical sync |
| hsync | Input/Output | 1 | Horizontal sync |
| din | Input | 8 | Input pixel data |
| din_valid | Input | 1 | Input data valid |
| dout | Output | 8 | Output pixel data |
| dout_valid | Output | 1 | Output data valid |
| dout_vsync | Output | 1 | Output vertical sync |
| dout_hsync | Output | 1 | Output horizontal sync |

**Clocking Blocks**:
- `driver_cb`: Active mode (outputs for driving signals)
- `monitor_cb`: Passive mode (inputs for sampling signals)

#### isp_csiir_reg_if (`isp_csiir_reg_if.sv`)

**Purpose**: APB (Advanced Peripheral Bus) interface for register configuration.

**Signals**:
| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| psel | Output | 1 | Peripheral select |
| penable | Output | 1 | Enable |
| pwrite | Output | 1 | Write (1) / Read (0) |
| paddr | Output | 8 | Address |
| pwdata | Output | 32 | Write data |
| prdata | Input | 32 | Read data |
| pready | Input | 1 | Transfer ready |
| pslverr | Input | 1 | Slave error |

---

### 3. Agents (`agents/`)

#### isp_csiir_pixel_agent (`isp_csiir_pixel_agent.svh`)

**Purpose**: Agent for video streaming interface.

**Components**:
- `driver`: Drives pixel data into DUT
- `monitor`: Observes input and output transactions
- `sequencer`: Manages transaction sequencing

**Active vs Passive**:
- Active mode: Creates driver + sequencer (for stimulation)
- Passive mode: Monitor only (for observation)

#### isp_csiir_pixel_driver (`isp_csiir_pixel_driver.svh`)

**Function**: Drives pixel transactions to DUT interface.

**Workflow**:
1. Get item from sequencer
2. Drive signals on clock edge
3. Signal completion

#### isp_csiir_pixel_monitor (`isp_csiir_pixel_monitor.svh`)

**Function**: Monitors both input and output streams.

**Parallel Tasks**:
- `collect_input()`: Captures din, din_valid, vsync, hsync
- `collect_output()`: Captures dout, dout_valid, dout_vsync, dout_hsync

#### isp_csiir_reg_agent (`isp_csiir_reg_agent.svh`)

**Purpose**: Agent for APB register interface.

**Components**: Similar structure to pixel_agent (driver, monitor, sequencer)

#### isp_csiir_reg_driver (`isp_csiir_reg_driver.svh`)

**Function**: Drives APB protocol transactions.

**APB Write Sequence**:
1. Setup phase: psel=1, pwrite=1, set paddr/pwdata
2. Access phase: penable=1
3. Wait for pready
4. Idle phase: psel=0, penable=0

**APB Read Sequence**: Same but pwrite=0, capture prdata

---

### 4. Sequence Items (`sequences/`)

#### isp_csiir_pixel_item (`isp_csiir_pixel_item.svh`)

**Fields**:
| Field | Type | Description |
|-------|------|-------------|
| pixel_data | rand bit[7:0] | Input pixel value |
| valid | rand bit | Data valid flag |
| vsync | rand bit | Vertical sync |
| hsync | rand bit | Horizontal sync |
| sof | rand bit | Start of frame |
| eol | rand bit | End of line |
| result_data | bit[7:0] | Output pixel (response) |
| result_valid | bit | Output valid (response) |

#### isp_csiir_reg_item (`isp_csiir_reg_item.svh`)

**Fields**:
| Field | Type | Description |
|-------|------|-------------|
| addr | rand bit[7:0] | Register address |
| data | rand bit[31:0] | Write data |
| write | rand bit | Write(1)/Read(0) |
| rdata | bit[31:0] | Read data (response) |
| pready | bit | Ready (response) |
| pslverr | bit | Error (response) |

---

### 5. Sequences (`sequences/`)

#### isp_csiir_pixel_sequence (`isp_csiir_pixel_sequence.svh`)

**Purpose**: Generates video frame data.

**Parameters**:
- `num_frames`: Number of frames (1-10)
- `frame_width`: Width (64-1920)
- `frame_height`: Height (64-1080)

**Workflow**:
```
For each frame:
  1. Send VSYNC pulse
  2. For each row (y):
     For each column (x):
       Send pixel with random data
       Set hsync on last column
  3. Send VSYNC pulse (end of frame)
```

#### isp_csiir_reg_sequence (`isp_csiir_reg_sequence.svh`)

**Purpose**: Configures DUT registers via APB.

**Register Map**:
| Address | Register | Description |
|---------|----------|-------------|
| 0x00 | CTRL | Enable(0)/Bypass(1) |
| 0x04 | PIC_SIZE | Height[31:16], Width[15:0] |
| 0x08 | THRESH0 | Window size threshold 0 |
| 0x0C | THRESH1 | Window size threshold 1 |
| 0x10 | THRESH2 | Window size threshold 2 |
| 0x14 | THRESH3 | Window size threshold 3 |
| 0x18 | BLEND | Blending ratios |

---

### 6. Reference Model (`ref_model/isp_csiir_ref_model.svh`)

**Purpose**: Golden model implementing the ISP-CSIIR algorithm.

**Key Components**:
- **Line Buffer**: 5-line buffer for 5x5 window extraction
- **Sobel Kernels**: 5x5 kernels for gradient computation
- **4-Stage Pipeline**:
  1. Gradient computation (horizontal/vertical)
  2. Window size determination & directional averages
  3. Gradient fusion
  4. IIR blend and output

**Algorithm Flow**:
```
Input Pixel → Line Buffer → 5x5 Window →
  Stage1: grad = |grad_h| + |grad_v|
  Stage2: win_size = LUT(grad), compute averages
  Stage3: blend = gradient_fusion(averages)
  Stage4: output = iir_blend(blend0, blend1, center)
```

**Boundary Handling**: Replicate edge pixels

---

### 7. Scoreboard (`env/isp_csiir_scoreboard.svh`)

**Purpose**: Compares DUT output with reference model.

**Architecture**:
- Two analysis ports: `dut_ap` (from DUT) and `ref_ap` (from ref model)
- Dual queues for synchronization
- Tolerance-based comparison (default: 2)

**Comparison Logic**:
```systemverilog
diff = |dut_item.result_data - ref_item.result_data|
if (diff <= tolerance) → MATCH
else → MISMATCH
```

**Report Output**:
- Total comparisons
- Match count
- Mismatch count
- Match rate percentage

---

### 8. Coverage (`env/isp_csiir_coverage.svh`)

**Purpose**: Collects functional coverage metrics.

**Coverage Groups**:

#### pixel_cg (Input Coverage)
- `cp_pixel_value`: Bins for 0, [1:63], [64:191], [192:254], 255
- `cp_valid`: Valid/Invalid transactions
- `cp_vsync`: VSYNC transitions
- `cp_hsync`: HSYNC transitions
- Cross coverage: pixel_value × valid

#### output_cg (Output Coverage)
- `cp_result_value`: Same bins as input
- `cp_result_valid`: Output valid flag

---

### 9. Configuration (`env/isp_csiir_config.svh`)

**Purpose**: Centralized configuration object.

**Parameters**:
| Parameter | Type | Default/Constraint |
|-----------|------|-------------------|
| img_width | rand int | [64:1920] |
| img_height | rand int | [64:1080] |
| enable | rand bit | - |
| bypass | rand bit | - |
| win_size_thresh[0-3] | rand bit[15:0] | 16, 24, 32, 40 |
| blending_ratio[4] | rand bit[7:0] | [16:48] |
| win_size_clip_y[4] | rand bit[7:0] | 15, 23, 31, 39 |
| win_size_clip_sft[4] | rand bit[7:0] | 2 |

---

### 10. Environment (`env/isp_csiir_env.svh`)

**Purpose**: Top-level UVM environment container.

**Components Created**:
- `pixel_agent`: Video streaming agent
- `reg_agent`: Register interface agent
- `ref_model`: Golden reference model
- `scoreboard`: Result comparator
- `coverage`: Coverage collector

**Connection Map**:
```
pixel_agent.monitor.ap ──┬──► ref_model.input_ap ──► ref_model.output_ap ──► scoreboard.ref_ap
                         │
                         └──► scoreboard.dut_ap
                         └──► coverage.analysis_export
```

---

### 11. Tests (`sequences/`)

#### isp_csiir_base_test (`isp_csiir_base_test.svh`)

**Purpose**: Base class for all tests.

**Default Configuration**:
- 320x240 image
- Enable mode
- No bypass

**Report**: PASSED if zero errors, FAILED otherwise

#### isp_csiir_smoke_test (`isp_csiir_smoke_test.svh`)

**Purpose**: Quick sanity check.

**Test Flow**:
1. Configure registers (64x64 image)
2. Wait 100ns
3. Send 1 frame
4. Wait 1us

#### isp_csiir_random_test (`isp_csiir_random_test.svh`)

**Purpose**: Randomized multi-configuration test.

**Test Matrix**:
| Iteration | Width | Height |
|-----------|-------|--------|
| 0 | 16 | 16 |
| 1 | 64 | 64 |
| 2 | 128 | 128 |
| 3 | 320 | 240 |
| 4 | 640 | 480 |

**Flow**: Configure → Send frame → Wait → Repeat

#### isp_csiir_video_test (`isp_csiir_video_test.svh`)

**Purpose**: Multi-frame video simulation.

**Configuration**:
- 320x240 resolution
- 5 consecutive frames

---

## Typical Workflow

### Running Tests

```bash
# Smoke test (quick)
+UVM_TESTNAME=isp_csiir_smoke_test

# Random test (medium)
+UVM_TESTNAME=isp_csiir_random_test

# Video test (long)
+UVM_TESTNAME=isp_csiir_video_test
```

### Simulation Flow

```
1. Build Phase
   └── Create all components
   └── Get/set configuration

2. Connect Phase
   └── Connect TLM ports
   └── Link agents to interfaces

3. Run Phase
   ┌─────────────────────────────────────┐
   │ Loop:                               │
   │   reg_sequence → Configure DUT      │
   │   pixel_sequence → Stimulate DUT    │
   │   monitor → Capture transactions    │
   │   ref_model → Compute expected      │
   │   scoreboard → Compare results      │
   │   coverage → Sample metrics         │
   └─────────────────────────────────────┘

4. Report Phase
   └── Print coverage report
   └── Print comparison results
   └── PASS/FAIL verdict
```

---

## Key Design Patterns

1. **Factory Pattern**: All UVM components use `type_id::create()`
2. **TLM Communication**: Analysis ports for monitor→scoreboard/coverage
3. **Configuration Database**: `uvm_config_db` for interface handles
4. **Phasing**: Standard UVM phases (build→connect→run→report)
5. **Active/Passive Agents**: Configurable driver presence

---

## Register Summary

| Address | Name | Bits | Description |
|---------|------|------|-------------|
| 0x00 | CTRL | [0]: enable, [1]: bypass | Control register |
| 0x04 | PIC_SIZE | [31:16]: height-1, [15:0]: width-1 | Image dimensions |
| 0x08 | THRESH0 | [15:0] | Gradient threshold for window size 0 |
| 0x0C | THRESH1 | [15:0] | Gradient threshold for window size 1 |
| 0x10 | THRESH2 | [15:0] | Gradient threshold for window size 2 |
| 0x14 | THRESH3 | [15:0] | Gradient threshold for window size 3 |
| 0x18 | BLEND | [31:24],[23:16],[15:8],[7:0] | Blending ratios |

---

## File Dependencies

```
isp_csiir_pkg.sv
    │
    ├── isp_csiir_config.svh
    │
    ├── isp_csiir_pixel_item.svh
    ├── isp_csiir_reg_item.svh
    │
    ├── isp_csiir_pixel_sequence.svh
    ├── isp_csiir_reg_sequence.svh
    │
    ├── isp_csiir_pixel_driver.svh      ─┐
    ├── isp_csiir_pixel_monitor.svh      │
    ├── isp_csiir_pixel_agent.svh       ─┴─ Requires pixel_item
    │
    ├── isp_csiir_reg_driver.svh        ─┐
    ├── isp_csiir_reg_monitor.svh        │
    ├── isp_csiir_reg_agent.svh         ─┴─ Requires reg_item
    │
    ├── isp_csiir_ref_model.svh
    ├── isp_csiir_scoreboard.svh
    ├── isp_csiir_coverage.svh
    │
    ├── isp_csiir_env.svh               (requires all above)
    │
    ├── isp_csiir_base_test.svh
    ├── isp_csiir_smoke_test.svh
    ├── isp_csiir_random_test.svh
    └── isp_csiir_video_test.svh
```

---

## Notes

- The reference model uses simplified directional averages (center only) for demonstration
- Tolerance of 2 allows for rounding differences between RTL and reference
- Waveform dump enabled by default (`isp_csiir_tb.vcd`)
- Simulation timeout set to 100ms