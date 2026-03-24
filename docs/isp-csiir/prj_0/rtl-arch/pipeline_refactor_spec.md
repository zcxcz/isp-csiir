# ISP-CSIIR Pipeline Architecture Refactoring Specification

**Version**: v1.0
**Author**: rtl-arch
**Date**: 2026-03-24
**Status**: Draft

---

## 1. Overview

### 1.1 Purpose

This document defines the pipeline architecture specification for ISP-CSIIR project refactoring, including:

- `common_pipe` module interface with valid/ready handshake
- Pipeline code style guidelines
- Module interface standards
- Back-pressure support mechanism

### 1.2 Current Architecture Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| No ready signal | Cannot stall pipeline | Data loss under back-pressure |
| Manual pipeline implementation | Each stage has verbose always blocks | Poor readability, hard to debug |
| Inconsistent valid handling | Each module handles valid differently | Integration complexity |
| No data isolation | Valid signals mixed with data path | Timing closure difficulty |

### 1.3 Target Architecture Benefits

1. **Unified handshake**: All modules use valid/ready protocol
2. **Reusable pipeline**: `common_pipe` encapsulates register logic
3. **Clear separation**: Combinational logic + pipeline register pattern
4. **Back-pressure support**: Ready signal enables pipeline stalling

---

## 2. common_pipe Interface Specification

### 2.1 Module Interface

```verilog
//-----------------------------------------------------------------------------
// Module: common_pipe
// Purpose: Pipeline register with valid/ready handshake
// Author: rtl-arch
// Version: v2.0 - Added ready signal for back-pressure support
//-----------------------------------------------------------------------------
// Features:
//   - Configurable data width
//   - Multiple pipeline stages
//   - Optional reset value
//   - Valid/Ready handshake protocol
//   - Back-pressure support via ready signal
//-----------------------------------------------------------------------------

module common_pipe #(
    parameter DATA_WIDTH  = 10,
    parameter STAGES      = 1,
    parameter RESET_VAL   = 0,
    parameter REGISTER_IN = 1   // 1: Register input, 0: Direct pass
)(
    // Clock and Reset
    input  wire                      clk,
    input  wire                      rst_n,

    // Data Input
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      valid_in,
    output wire                      ready_out,    // Can accept new data

    // Data Output
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      valid_out,
    input  wire                      ready_in      // Downstream ready
);
```

### 2.2 Port Description

| Port | Direction | Description |
|------|-----------|-------------|
| `clk` | Input | System clock |
| `rst_n` | Input | Active-low asynchronous reset |
| `din[DATA_WIDTH-1:0]` | Input | Data input |
| `valid_in` | Input | Input data valid indicator |
| `ready_out` | Output | Ready to accept new data (always 1 for simple pipe) |
| `dout[DATA_WIDTH-1:0]` | Output | Data output (registered) |
| `valid_out` | Output | Output data valid indicator |
| `ready_in` | Input | Downstream ready signal (back-pressure) |

### 2.3 Parameter Description

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DATA_WIDTH` | 10 | Data bit width |
| `STAGES` | 1 | Number of pipeline stages (1-16) |
| `RESET_VAL` | 0 | Reset value for data registers |
| `REGISTER_IN` | 1 | 1: Input registered, 0: Combinational input |

### 2.4 Timing Diagram

#### 2.4.1 Normal Operation (No Back-pressure)

```
                  ____________________________________
clk      ________|                                    |_______
                  ^                ^                ^
                  |                |                |
din      ====D0===|====D1=========D2===============D3=======
                  |    |           |    |           |
valid_in  ________|____|___________|____|___________|_______
                       ^                ^
                       |                |
dout     ==========D0==|====D1=========D2===============
                       |    |           |
valid_out _____________|____|___________|_____________

ready_in  ================================================= (always high)
ready_out ================================================= (always high)
```

**Timing Notes**:
- `din` with `valid_in=1` is captured on rising clock edge
- `dout` appears after STAGES clock cycles
- `valid_out` follows same latency as data

#### 2.4.2 Back-pressure Operation

```
                  ____________________________________
clk      ________|                                    |_______
                  ^                ^                ^
                  |
din      ====D0===|====D1=========D2===============D3=======
                  |    |  (D1 held) |    |
valid_in  ________|____|____________|____|___________|_______
                       ^                ^
                       |                |
ready_in  =============|====___________|=====================
                       |    ^back-      |
                       |    pressure    |
dout     ==========D0==|====D1=========D2===============
                       |    |           |
valid_out _____________|____|___________|_____________

ready_out =================================================
```

**Back-pressure Behavior**:
- When `ready_in=0`, pipeline stalls
- Data and valid are preserved in pipeline registers
- Upstream sees `ready_out=1` (always ready for simple pipe)

### 2.5 Implementation Notes

#### 2.5.1 Simple Pipeline (No Skid Buffer)

For most pipeline stages, a simple shift register implementation is sufficient:

```verilog
// Internal pipeline registers
reg [DATA_WIDTH-1:0] pipe_reg [0:STAGES-1];
reg [STAGES-1:0]     valid_reg;

// Always ready to accept data (no skid buffer)
assign ready_out = 1'b1;

// Pipeline shift logic with back-pressure
integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < STAGES; i = i + 1) begin
            pipe_reg[i]  <= RESET_VAL[DATA_WIDTH-1:0];
            valid_reg[i] <= 1'b0;
        end
    end else if (ready_in) begin
        // Normal operation - shift pipeline
        pipe_reg[0]  <= din;
        valid_reg[0] <= valid_in;
        for (i = 1; i < STAGES; i = i + 1) begin
            pipe_reg[i]  <= pipe_reg[i-1];
            valid_reg[i] <= valid_reg[i-1];
        end
    end
    // else: hold values when ready_in=0 (back-pressure)
end

// Output assignment
assign dout     = pipe_reg[STAGES-1];
assign valid_out = valid_reg[STAGES-1];
```

#### 2.5.2 Pipeline with Skid Buffer (Optional)

For modules requiring guaranteed data acceptance, add a skid buffer at input:

```verilog
// Skid buffer for input
reg [DATA_WIDTH-1:0] skid_data;
reg                  skid_valid;

// Accept logic
wire accept_new = ready_out && (valid_in && !skid_valid || !valid_in);
assign ready_out = !skid_valid || ready_in;

// Skid buffer management
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        skid_data  <= {DATA_WIDTH{1'b0}};
        skid_valid <= 1'b0;
    end else if (ready_in) begin
        if (valid_in && !ready_out) begin
            // Skid new data when pipeline stalled
            skid_data  <= din;
            skid_valid <= 1'b1;
        end else begin
            skid_valid <= 1'b0;
        end
    end
end
```

---

## 3. Pipeline Code Style Guidelines

### 3.1 Core Principles

1. **Combinational Logic First**: All combinational logic uses `wire` and `assign`
2. **Pipeline Register Last**: Use `common_pipe` or explicit `always` block for registers
3. **Clear Naming Convention**: Use `_comb` suffix for combinational, `_sN` for stage N registers

### 3.2 Naming Conventions

| Signal Type | Suffix | Example |
|-------------|--------|---------|
| Combinational logic output | `_comb` | `sum_comb`, `result_comb` |
| Stage N pipeline register | `_sN` | `data_s0`, `valid_s2` |
| Module output | No suffix | `dout`, `valid_out` |
| Pass-through signal | `_dly` or `_out` | `pixel_x_out`, `center_dly` |

### 3.3 Stage Module Structure Template

```verilog
//-----------------------------------------------------------------------------
// Module: stageN_xxx
// Purpose: [Brief description]
// Pipeline Structure (M cycles):
//   Cycle 0: [Description]
//   Cycle 1: [Description]
//   ...
//   Cycle M-1: [Description]
//-----------------------------------------------------------------------------

module stageN_xxx #(
    parameter DATA_WIDTH = 10
)(
    // Clock and Reset
    input  wire                      clk,
    input  wire                      rst_n,

    // Data Input
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      valid_in,
    output wire                      ready_out,

    // Data Output
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      valid_out,
    input  wire                      ready_in,

    // Configuration (constants, not pipelined)
    input  wire [CONFIG_WIDTH-1:0]   config_param
);

    //=========================================================================
    // Stage 0: [Description]
    //=========================================================================
    // Combinational logic
    wire [DATA_WIDTH-1:0] result_s0_comb = din + config_param;

    // Pipeline register (using common_pipe)
    wire [DATA_WIDTH-1:0] result_s0;
    wire                  valid_s0;

    common_pipe #(
        .DATA_WIDTH (DATA_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s0 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (result_s0_comb),
        .valid_in  (valid_in),
        .ready_out (ready_out),
        .dout      (result_s0),
        .valid_out (valid_s0),
        .ready_in  (ready_in)
    );

    //=========================================================================
    // Stage 1: [Description]
    //=========================================================================
    // Combinational logic
    wire [DATA_WIDTH-1:0] result_s1_comb = result_s0 * 2;

    // Output register
    wire [DATA_WIDTH-1:0] dout_comb = result_s1_comb;

    common_pipe #(
        .DATA_WIDTH (DATA_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (dout_comb),
        .valid_in  (valid_s0),
        .ready_out (),
        .dout      (dout),
        .valid_out (valid_out),
        .ready_in  (ready_in)
    );

endmodule
```

### 3.4 Grouping Signals for common_pipe

When multiple signals need to be pipelined together:

**Option A: Pack into single vector**

```verilog
// Pack signals
wire [31:0] packed_in  = {pixel_x, pixel_y, data, valid_flag};
wire [31:0] packed_out;

common_pipe #(.DATA_WIDTH(32), .STAGES(1)) u_pipe (
    .din  (packed_in),
    .dout (packed_out)
    // ...
);

// Unpack signals
wire [15:0] pixel_x_out = packed_out[31:16];
wire [13:0] pixel_y_out = packed_out[15:2];
wire        valid_flag  = packed_out[0];
```

**Option B: Multiple common_pipe instances (preferred for readability)**

```verilog
// Separate pipe instances for different signal groups
common_pipe #(.DATA_WIDTH(16)) u_pipe_pixel_x (...);
common_pipe #(.DATA_WIDTH(14)) u_pipe_pixel_y (...);
common_pipe #(.DATA_WIDTH(10)) u_pipe_data (...);
```

### 3.5 Valid Signal Pipeline

The `valid` signal should be pipelined alongside data:

```verilog
// Data pipeline
wire [DATA_WIDTH-1:0] data_s0, data_s1;
common_pipe #(.DATA_WIDTH(DATA_WIDTH), .STAGES(1)) u_pipe_data_0 (...);
common_pipe #(.DATA_WIDTH(DATA_WIDTH), .STAGES(1)) u_pipe_data_1 (...);

// Valid pipeline (use DATA_WIDTH=1)
wire valid_s0, valid_s1;
common_pipe #(.DATA_WIDTH(1), .STAGES(1)) u_pipe_valid_0 (.din(valid_in), .dout(valid_s0), ...);
common_pipe #(.DATA_WIDTH(1), .STAGES(1)) u_pipe_valid_1 (.din(valid_s0), .dout(valid_s1), ...);
```

---

## 4. Module Interface Standards

### 4.1 Port Ordering Convention

All modules should follow this port ordering:

```verilog
module module_name #(
    // Parameters (alphabetical or by dependency)
    parameter DATA_WIDTH = 10
)(
    // Group 1: Clock and Reset
    input  wire clk,
    input  wire rst_n,

    // Group 2: Control Signals
    input  wire enable,
    input  wire sof,              // Start of frame (optional)
    input  wire eol,              // End of line (optional)

    // Group 3: Data Input (with handshake)
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  din_valid,
    output wire                  din_ready,

    // Group 4: Data Output (with handshake)
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  dout_valid,
    input  wire                  dout_ready,

    // Group 5: Configuration Parameters
    input  wire [CONFIG_WIDTH-1:0] config_param,

    // Group 6: Status/Debug (optional)
    output wire                  status_signal
);
```

### 4.2 Handshake Protocol

#### 4.2.1 Valid/Ready Timing

```
Valid/Ready Protocol:
---------------------
- Transfer occurs when valid=1 AND ready=1 on rising clock edge
- Source MUST hold data stable while valid=1 and ready=0
- Destination asserts ready when it can accept data
- valid MUST NOT depend on ready (avoid combinational loops)

Valid Timing:
-------------
   ____      ____      ____
__|    |____|    |____|    |__
       ^         ^
       |         |
valid sampled on rising edge

Ready Timing:
-------------
   ____      ____      ____
__|    |____|    |____|    |__
       ^         ^
       |         |
ready sampled on rising edge

Transfer:
---------
valid=1 && ready=1 -> data captured on clock edge
```

#### 4.2.2 Common Patterns

**Pattern 1: Always Ready Source**

```verilog
// Source can always accept new data
assign din_ready = 1'b1;
```

**Pattern 2: Conditional Ready**

```beginning
// Source ready depends on internal buffer state
assign din_ready = !buffer_full;
```

**Pattern 3: Back-pressure Propagation**

```verilog
// Ready propagates through pipeline
assign din_ready = internal_ready && !stall_condition;
```

### 4.3 Module Interface Examples

#### 4.3.1 Processing Stage (Stage 1-4)

```verilog
module stage1_gradient #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6
)(
    // Clock and Reset
    input  wire                        clk,
    input  wire                        rst_n,

    // Control
    input  wire                        enable,

    // 5x5 Window Input
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, /* ... */ window_4_4,
    input  wire                        window_valid,
    output wire                        window_ready,

    // Gradient Output
    output wire [GRAD_WIDTH-1:0]       grad_h,
    output wire [GRAD_WIDTH-1:0]       grad_v,
    output wire [GRAD_WIDTH-1:0]       grad,
    output wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output wire                        grad_valid,
    input  wire                        grad_ready,

    // Position Pass-through
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x_in,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y_in,
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Configuration
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_3
);
```

#### 4.3.2 Line Buffer Module

```verilog
module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    // Clock and Reset
    input  wire                        clk,
    input  wire                        rst_n,

    // Control
    input  wire                        enable,

    // Image Configuration
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,
    input  wire [12:0]                 img_height,

    // Pixel Input
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // 5x5 Window Output
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, /* ... */ window_4_4,
    output wire                        window_valid,
    input  wire                        window_ready,

    // Window Center Position
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                 center_y,

    // Writeback Interface (for IIR feedback)
    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset
);
```

#### 4.3.3 Top Module

```verilog
module isp_csiir_top #(
    parameter IMG_WIDTH       = 5472,
    parameter IMG_HEIGHT      = 3648,
    parameter DATA_WIDTH      = 10
)(
    // Clock and Reset
    input  wire                        clk,
    input  wire                        rst_n,

    // Pixel Input Stream
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // Pixel Output Stream
    output wire [DATA_WIDTH-1:0]       dout,
    output wire                        dout_valid,
    input  wire                        dout_ready,

    // Image Dimension Configuration
    input  wire [13:0]                 img_width,
    input  wire [12:0]                 img_height,

    // Algorithm Configuration
    input  wire [15:0]                 win_size_thresh0,
    input  wire [15:0]                 win_size_thresh1,
    /* ... more config ports ... */
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1
);
```

---

## 5. Refactoring Guidelines

### 5.1 Step-by-Step Refactoring Process

1. **Update common_pipe module**
   - Add `valid_in`, `valid_out`, `ready_in`, `ready_out` ports
   - Implement back-pressure logic

2. **Refactor each stage module**
   - Replace manual always blocks with common_pipe instantiation
   - Add handshake ports to module interface
   - Separate combinational logic from registers

3. **Update inter-stage connections**
   - Add ready signal routing
   - Ensure valid/ready timing alignment

4. **Update line buffer module**
   - Add handshake ports for input and output
   - Handle back-pressure for window output

5. **Update top module**
   - Connect all handshake signals
   - Ensure proper ready signal propagation

### 5.2 Signal Alignment

When refactoring, ensure proper signal alignment:

| Signal Type | Pipeline Depth | Notes |
|-------------|----------------|-------|
| Data signals | Follow algorithm | Same depth as processing pipeline |
| Valid signal | Same as data | 1-bit pipeline per data stage |
| Position (pixel_x/y) | Same as data | Pass-through with data |
| Configuration | Not pipelined | Constants, no delay needed |

### 5.3 Back-pressure Handling

For ISP-CSIIR pipeline:

```
          +-------------+     +-------------+     +-------------+
din ------>   Stage 1   |---->|   Stage 2   |---->|   Stage 3   |----> dout
          |             |     |             |     |             |
ready <---|             |<----|             |<----|             |<---- ready
          +-------------+     +-------------+     +-------------+

Pipeline Stages:
- Stage 1-4: Processing stages with ready propagation
- Line Buffer: Can generate back-pressure when output stalled
```

**Back-pressure Propagation Rule**:
- Each stage's `ready_out` connects to previous stage's `ready_in`
- Final stage's `ready_out` determines entire pipeline stalling

---

## 6. Verification Checklist

### 6.1 Module-Level Verification

- [ ] All handshake signals properly connected
- [ ] Valid signal correctly propagates through pipeline
- [ ] Ready signal correctly stalls pipeline
- [ ] Data integrity maintained during back-pressure
- [ ] Reset behavior verified

### 6.2 Integration Verification

- [ ] Inter-stage handshake timing correct
- [ ] Pipeline latency matches specification
- [ ] Throughput achieved (1 pixel/clock when not stalled)
- [ ] Back-pressure propagates correctly through all stages
- [ ] Line buffer window generation correct with back-pressure

### 6.3 Timing Verification

- [ ] Setup/hold time met for all registers
- [ ] No combinational loops in ready path
- [ ] Critical path within clock period
- [ ] Reset recovery time met

---

## 7. Appendix

### 7.1 Common Pipeline Patterns

#### A. Simple Data Pipeline

```verilog
common_pipe #(.DATA_WIDTH(10), .STAGES(3)) u_pipe (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (data_in),
    .valid_in  (valid_in),
    .ready_out (ready_out),
    .dout      (data_out),
    .valid_out (valid_out),
    .ready_in  (ready_in)
);
```

#### B. Multi-Signal Pipeline

```verilog
// Pack multiple signals
wire [TOTAL_WIDTH-1:0] packed_in = {signal_a, signal_b, signal_c};
wire [TOTAL_WIDTH-1:0] packed_out;

common_pipe #(.DATA_WIDTH(TOTAL_WIDTH), .STAGES(2)) u_pipe (...);

// Unpack
assign {signal_a_out, signal_b_out, signal_c_out} = packed_out;
```

#### C. Conditional Pipeline

```verilog
// Gated pipeline enable
wire pipe_enable = valid_in && ready_out;

// Use enable signal with register-based implementation
reg [DATA_WIDTH-1:0] pipe_reg;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        pipe_reg <= {DATA_WIDTH{1'b0}};
    else if (pipe_enable)
        pipe_reg <= din;
end
```

### 7.2 Timing Parameters Reference

| Module | Pipeline Depth | Latency (cycles) |
|--------|----------------|------------------|
| common_pipe | STAGES parameter | STAGES |
| stage1_gradient | 5 cycles | 5 |
| stage2_directional_avg | 8 cycles | 8 |
| stage3_gradient_fusion | 6 cycles | 6 + 1 row |
| stage4_iir_blend | 5 cycles | 5 |
| line_buffer | 2 rows + 2 cols | Variable |
| **Total** | - | **24 + 1 row** |

### 7.3 Glossary

| Term | Definition |
|------|------------|
| Back-pressure | Downstream stalling mechanism preventing data overflow |
| Handshake | Protocol using valid/ready signals for data transfer |
| Pipeline stage | One clock cycle delay register |
| Skid buffer | Input buffer allowing data capture during stall |
| Valid | Signal indicating data is available |
| Ready | Signal indicating ability to accept data |

---

## 8. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| v1.0 | 2026-03-24 | rtl-arch | Initial specification |

---

**End of Document**