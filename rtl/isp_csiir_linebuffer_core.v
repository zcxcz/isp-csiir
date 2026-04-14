//////
// Module:     isp_csiir_linebuffer_core
// Author:    rtl-impl
// Date:      2026-04-07
// Modified:  2026-04-14
//////
// Purpose:
//   5-row line buffer with 1-port SRAM, 2P (2-pixel) packing.
//
// Architecture:
//   - SRAM: DATA_WIDTH = 2*pixel, DEPTH = IMG_WIDTH/2
//     Each addr stores {odd_pixel, even_pixel} (upper, lower).
//   - Addr step = +1 (col addr / 2 = SRAM addr, col%2 = half select).
//   - row_depth (0-5): push on EOL, pop when patch finishes one image-width.
//   - col_depth (0-5): +1 on patch read start, -1 on patch write complete.
//   - din path: direct write when row_depth<5; 4T bypass when row_depth=5.
//   - wr_row_ptr: circular 0→1→2→3→4→0, points to next row to write.
//   - Patch reads all 5 rows at same addr → 5x1 column.
//   - Patch write-back: even_col → all 5 rows at addr. Odd_col → padding.
//     Right boundary: 2 writes (2T), second write has odd_col=padding.
//////

module isp_csiir_linebuffer_core #(
    parameter IMG_WIDTH        = 5472,
    parameter DATA_WIDTH       = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter BYPASS_STAGES   = 4
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    input  wire [LINE_ADDR_WIDTH-1:0] img_width,
    input  wire [12:0]               img_height,

    // Pixel input stream (2P packing: even_col in lower, odd_col in upper)
    input  wire [DATA_WIDTH-1:0]      din_even,
    input  wire [DATA_WIDTH-1:0]      din_odd,
    input  wire                        din_valid,
    input  wire                        din_col_even,  // 1=even_col, 0=odd_col
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // Patch column read
    input  wire                        patch_col_req,
    output wire                        patch_col_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_col_addr,  // col addr / 2

    // Patch column write-back
    input  wire                        patch_col_wr,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_col_wr_addr,  // col addr / 2
    input  wire [DATA_WIDTH*5-1:0]    patch_col_wr_data,   // 5 rows, 1 pixel each

    // Column output (5x1)
    output wire [DATA_WIDTH-1:0]      col_0,
    output wire [DATA_WIDTH-1:0]      col_1,
    output wire [DATA_WIDTH-1:0]      col_2,
    output wire [DATA_WIDTH-1:0]      col_3,
    output wire [DATA_WIDTH-1:0]      col_4,
    output wire                        col_valid,
    input  wire                        col_ready,
    output wire [LINE_ADDR_WIDTH-1:0] col_center_x,
    output wire [12:0]               col_center_y,

    // Bypass path (din → gradient when linebuffer full)
    output wire [DATA_WIDTH-1:0]     bypass_even,
    output wire [DATA_WIDTH-1:0]     bypass_odd,
    output wire                        bypass_valid,
    input  wire                        bypass_ready
);

    //=========================================================================
    // localparam
    //=========================================================================
    localparam NUM_ROWS     = 5;
    localparam SRAM_DW      = DATA_WIDTH * 2;  // 2P packing
    localparam SRAM_AW      = LINE_ADDR_WIDTH - 1;  // IMG_WIDTH/2 depth

    //=========================================================================
    // Reg/Wire Declarations
    //=========================================================================
    //----- Row FSM -----
    reg [3:0]                   row_depth;
    reg [2:0]                   wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]  wr_pixel_col;   // pixel col addr (not SRAM addr)
    reg [12:0]                 row_cnt;
    reg                         frame_started;
    reg                         eol_pending;

    //----- Column FSM -----
    reg [3:0]                  col_depth;
    reg                         patch_reading;
    reg [LINE_ADDR_WIDTH-1:0]  patch_rd_pixel_col;  // pixel col addr
    reg [12:0]                 patch_rd_y;
    reg [2:0]                  patch_rd_row_0;
    reg [2:0]                  patch_rd_row_1;
    reg [2:0]                  patch_rd_row_2;
    reg [2:0]                  patch_rd_row_3;
    reg [2:0]                  patch_rd_row_4;

    //----- Column output -----
    reg                         col_valid_r;
    reg [DATA_WIDTH-1:0]        col_0_r, col_1_r, col_2_r, col_3_r, col_4_r;
    reg [LINE_ADDR_WIDTH-1:0]  col_center_x_r;
    reg [12:0]                 col_center_y_r;

    //----- SRAM write control (per-row, for parallel 5-row write) -----
    reg                          sram_0_wr_en;
    reg                          sram_1_wr_en;
    reg                          sram_2_wr_en;
    reg                          sram_3_wr_en;
    reg                          sram_4_wr_en;
    reg [SRAM_AW-1:0]           sram_wr_addr;
    reg [SRAM_DW-1:0]            sram_wr_data;   // {odd, even}

    //----- SRAM read -----
    wire [SRAM_AW-1:0]          sram_rd_addr;
    wire                        sram_rd_en = 1'b1;

    //----- Bypass pipeline -----
    reg [DATA_WIDTH-1:0]         bypass_even_pipe [0:BYPASS_STAGES];
    reg [DATA_WIDTH-1:0]         bypass_odd_pipe  [0:BYPASS_STAGES];
    reg                           bypass_valid_pipe [0:BYPASS_STAGES];

    //=========================================================================
    // SRAM Read Data
    //=========================================================================
    wire [DATA_WIDTH-1:0] sram_row_0_even, sram_row_0_odd;
    wire [DATA_WIDTH-1:0] sram_row_1_even, sram_row_1_odd;
    wire [DATA_WIDTH-1:0] sram_row_2_even, sram_row_2_odd;
    wire [DATA_WIDTH-1:0] sram_row_3_even, sram_row_3_odd;
    wire [DATA_WIDTH-1:0] sram_row_4_even, sram_row_4_odd;

    //=========================================================================
    // Combinational logic
    //=========================================================================
    assign din_ready = enable && frame_started;

    wire din_shake    = din_valid && din_ready;
    wire eol_fire     = eol && din_ready && !eol_pending;
    wire patch_col_fire = patch_col_req && patch_col_ready;

    // din can write to linebuffer: row_depth<5 OR (row_depth==5 && col_depth==0)
    wire din_can_write_lb = (row_depth < NUM_ROWS) ||
                             ((row_depth == NUM_ROWS) && (col_depth == 4'd0));
    // din goes to bypass when linebuffer full
    wire din_to_bypass    = (row_depth == NUM_ROWS);

    // Pixel col addr → SRAM addr and half-select
    wire [LINE_ADDR_WIDTH-1:0] din_pixel_col = wr_pixel_col;
    wire [SRAM_AW-1:0] din_sram_addr = din_pixel_col[LINE_ADDR_WIDTH-1:1];  // /2
    wire din_is_even = ~din_pixel_col[0];  // even=1, odd=0

    // Next write row
    wire [2:0] next_wr_row = (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;

    // Circular row: base - delta (mod 5)
    function [2:0] row_sub(input [2:0] base, input [2:0] delta);
        row_sub = (base >= delta) ? (base - delta) : (base + 3'd5 - delta);
    endfunction

    // 5 rows for current patch: newest=wr_row_ptr, oldest=wr_row_ptr-4
    wire [2:0] rd_row_0 = row_sub(wr_row_ptr, 3'd4);
    wire [2:0] rd_row_1 = row_sub(wr_row_ptr, 3'd3);
    wire [2:0] rd_row_2 = row_sub(wr_row_ptr, 3'd2);
    wire [2:0] rd_row_3 = row_sub(wr_row_ptr, 3'd1);
    wire [2:0] rd_row_4 = wr_row_ptr;

    // Patch pixel col → SRAM addr
    wire [SRAM_AW-1:0] patch_sram_addr = patch_rd_pixel_col[LINE_ADDR_WIDTH-1:1];
    wire patch_col_is_even = ~patch_rd_pixel_col[0];

    // Patch write-back: even col → all 5 rows at addr
    wire [SRAM_AW-1:0] patch_wr_sram_addr = patch_col_wr_addr[LINE_ADDR_WIDTH-1:1];
    wire patch_wr_col_is_even = ~patch_col_wr_addr[0];

    assign sram_rd_addr = patch_reading ? patch_sram_addr : {SRAM_AW{1'b0}};

    //=========================================================================
    // FSM_WR: Write pointer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr   <= 3'd0;
            wr_pixel_col <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
            eol_pending  <= 1'b0;
            frame_started <= 1'b0;
        end else if (sof) begin
            wr_row_ptr   <= 3'd0;
            wr_pixel_col <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
            eol_pending  <= 1'b0;
            frame_started <= 1'b1;
        end else if (enable) begin
            if (eol && !din_ready)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            if (eol_fire) begin
                wr_pixel_col <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= next_wr_row;
                row_cnt    <= row_cnt + 1'b1;
            end

            if (din_valid && din_ready) begin
                // Advance pixel col regardless (for din stream tracking)
                wr_pixel_col <= wr_pixel_col + 1'b1;
            end
        end
    end

    //=========================================================================
    // row_depth FSM
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_depth <= 4'd0;
        end else if (sof) begin
            row_depth <= 4'd0;
        end else if (enable) begin
            // Push: new row written
            if (eol_fire && !(patch_reading && col_depth == 4'd1 && patch_col_wr))
                row_depth <= row_depth + 1'b1;
            // Pop: patch finished one image-width (all cols processed)
            else if (!eol_fire && patch_reading && col_depth == 4'd1 && patch_col_wr)
                row_depth <= row_depth - 1'b1;
        end
    end

    //=========================================================================
    // col_depth FSM
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_depth <= 4'd0;
        end else if (sof) begin
            col_depth <= 4'd0;
        end else if (enable) begin
            if (patch_col_fire && !patch_col_wr)
                col_depth <= col_depth + 1'b1;
            else if (!patch_col_fire && patch_col_wr && col_depth > 4'd0)
                col_depth <= col_depth - 1'b1;
        end
    end

    //=========================================================================
    // Patch column read
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            patch_reading     <= 1'b0;
            patch_rd_pixel_col <= {LINE_ADDR_WIDTH{1'b0}};
            patch_rd_y       <= 13'd0;
            patch_rd_row_0   <= 3'd0;
            patch_rd_row_1   <= 3'd0;
            patch_rd_row_2   <= 3'd0;
            patch_rd_row_3   <= 3'd0;
            patch_rd_row_4   <= 3'd0;
        end else if (sof) begin
            patch_reading     <= 1'b0;
            patch_rd_pixel_col <= {LINE_ADDR_WIDTH{1'b0}};
            patch_rd_y       <= 13'd0;
            patch_rd_row_0   <= 3'd0;
            patch_rd_row_1   <= 3'd0;
            patch_rd_row_2   <= 3'd0;
            patch_rd_row_3   <= 3'd0;
            patch_rd_row_4   <= 3'd0;
        end else if (enable) begin
            if (patch_col_fire) begin
                patch_reading     <= 1'b1;
                patch_rd_pixel_col <= {patch_col_addr, 1'b0};  // reconstruct pixel col
                patch_rd_y       <= row_cnt - 13'd2;
                patch_rd_row_0   <= rd_row_0;
                patch_rd_row_1   <= rd_row_1;
                patch_rd_row_2   <= rd_row_2;
                patch_rd_row_3   <= rd_row_3;
                patch_rd_row_4   <= rd_row_4;
            end else if (col_valid_r && col_ready) begin
                patch_reading <= 1'b0;
            end
        end
    end

    //=========================================================================
    // SRAM write control (per-row independent writes)
    //=========================================================================
    // Din write: writes one row per T, 2P packing into {odd, even}
    // Patch write-back: writes all 5 rows in 1T, each row independent
    //=========================================================================
    reg [DATA_WIDTH*5-1:0] patch_5x1_buf;  // latched patch data for multi-row write

    always @(*) begin
        sram_0_wr_en = 1'b0; sram_1_wr_en = 1'b0;
        sram_2_wr_en = 1'b0; sram_3_wr_en = 1'b0;
        sram_4_wr_en = 1'b0;
        sram_wr_addr = {SRAM_AW{1'b0}};
        sram_wr_data = {SRAM_DW{1'b0}};

        // Din write: 2P packing into {odd, even}, writes one row
        if (din_valid && din_ready && !din_to_bypass && din_can_write_lb) begin
            sram_wr_addr = din_sram_addr;
            sram_wr_data = din_is_even ?
                           {din_odd, din_even} :   // even col: {odd=padding, even}
                           {din_even, din_odd};    // odd col: {even, odd=padding}
            case (wr_row_ptr)
                3'd0: sram_0_wr_en = 1'b1;
                3'd1: sram_1_wr_en = 1'b1;
                3'd2: sram_2_wr_en = 1'b1;
                3'd3: sram_3_wr_en = 1'b1;
                default: sram_4_wr_en = 1'b1;
            endcase
        end

        // Patch write-back: even col → all 5 rows at same addr, 1T
        // Odd col: duplicating padding (upper half = lower half)
        if (patch_col_wr && patch_wr_col_is_even) begin
            sram_wr_addr = patch_wr_sram_addr;
            // Even col: upper half = valid data; lower half = duplicating padding
            sram_wr_data = {patch_5x1_buf[DATA_WIDTH*5-1:DATA_WIDTH*4],
                            patch_5x1_buf[DATA_WIDTH*5-1:DATA_WIDTH*4]};
            sram_0_wr_en = 1'b1; sram_1_wr_en = 1'b1;
            sram_2_wr_en = 1'b1; sram_3_wr_en = 1'b1; sram_4_wr_en = 1'b1;
        end else if (patch_col_wr && !patch_wr_col_is_even) begin
            // Odd col: duplicating padding (upper half = padding, lower half = data)
            sram_wr_addr = patch_wr_sram_addr;
            sram_wr_data = {patch_5x1_buf[DATA_WIDTH*5-1:DATA_WIDTH*4],
                            patch_5x1_buf[DATA_WIDTH*5-1:DATA_WIDTH*4]};
            sram_0_wr_en = 1'b1; sram_1_wr_en = 1'b1;
            sram_2_wr_en = 1'b1; sram_3_wr_en = 1'b1; sram_4_wr_en = 1'b1;
        end
    end

    // Latch patch 5x1 data when patch_col_wr fires (for multi-row write in 1T)
    always @(posedge clk) begin
        if (patch_col_wr)
            patch_5x1_buf <= patch_col_wr_data;
    end

    //=========================================================================
    // Bypass pipeline (4T, handshake controlled)
    //=========================================================================
    integer b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (b = 0; b <= BYPASS_STAGES; b = b + 1) begin
                bypass_even_pipe[b]  <= {DATA_WIDTH{1'b0}};
                bypass_odd_pipe[b]   <= {DATA_WIDTH{1'b0}};
                bypass_valid_pipe[b] <= 1'b0;
            end
        end else if (sof) begin
            for (b = 0; b <= BYPASS_STAGES; b = b + 1) begin
                bypass_even_pipe[b]  <= {DATA_WIDTH{1'b0}};
                bypass_odd_pipe[b]   <= {DATA_WIDTH{1'b0}};
                bypass_valid_pipe[b] <= 1'b0;
            end
        end else if (enable) begin
            if (din_shake && din_to_bypass) begin
                bypass_even_pipe[0]  <= din_even;
                bypass_odd_pipe[0]   <= din_odd;
                bypass_valid_pipe[0]  <= 1'b1;
                for (b = 1; b <= BYPASS_STAGES; b = b + 1) begin
                    bypass_even_pipe[b]  <= bypass_even_pipe[b-1];
                    bypass_odd_pipe[b]   <= bypass_odd_pipe[b-1];
                    bypass_valid_pipe[b] <= bypass_valid_pipe[b-1];
                end
            end
        end
    end

    assign bypass_even = bypass_even_pipe[BYPASS_STAGES];
    assign bypass_odd  = bypass_odd_pipe[BYPASS_STAGES];
    assign bypass_valid = bypass_valid_pipe[BYPASS_STAGES] && din_to_bypass;

    //=========================================================================
    // Column output (read 5 rows at same addr)
    //=========================================================================
    // Extract even/odd from SRAM read data based on patch_col_is_even
    wire [DATA_WIDTH-1:0] row0_pixel = patch_col_is_even ?
                                        sram_row_0_even : sram_row_0_odd;
    wire [DATA_WIDTH-1:0] row1_pixel = patch_col_is_even ?
                                        sram_row_1_even : sram_row_1_odd;
    wire [DATA_WIDTH-1:0] row2_pixel = patch_col_is_even ?
                                        sram_row_2_even : sram_row_2_odd;
    wire [DATA_WIDTH-1:0] row3_pixel = patch_col_is_even ?
                                        sram_row_3_even : sram_row_3_odd;
    wire [DATA_WIDTH-1:0] row4_pixel = patch_col_is_even ?
                                        sram_row_4_even : sram_row_4_odd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_valid_r      <= 1'b0;
            col_0_r <= {DATA_WIDTH{1'b0}};
            col_1_r <= {DATA_WIDTH{1'b0}};
            col_2_r <= {DATA_WIDTH{1'b0}};
            col_3_r <= {DATA_WIDTH{1'b0}};
            col_4_r <= {DATA_WIDTH{1'b0}};
            col_center_x_r <= {LINE_ADDR_WIDTH{1'b0}};
            col_center_y_r <= 13'd0;
        end else if (sof) begin
            col_valid_r      <= 1'b0;
            col_0_r <= {DATA_WIDTH{1'b0}};
            col_1_r <= {DATA_WIDTH{1'b0}};
            col_2_r <= {DATA_WIDTH{1'b0}};
            col_3_r <= {DATA_WIDTH{1'b0}};
            col_4_r <= {DATA_WIDTH{1'b0}};
            col_center_x_r <= {LINE_ADDR_WIDTH{1'b0}};
            col_center_y_r <= 13'd0;
        end else if (enable) begin
            if (col_valid_r && !col_ready)
                col_valid_r <= 1'b1;
            else if (!col_ready)
                col_valid_r <= 1'b0;
            else if (patch_reading) begin
                // Route each row's pixel to the correct column position
                // Even col: rows map to even slot; Odd col: rows map to odd slot
                case (patch_rd_row_0)
                    3'd0: col_0_r <= row0_pixel;
                    3'd1: col_0_r <= row1_pixel;
                    3'd2: col_0_r <= row2_pixel;
                    3'd3: col_0_r <= row3_pixel;
                    default: col_0_r <= row4_pixel;
                endcase
                case (patch_rd_row_1)
                    3'd0: col_1_r <= row0_pixel;
                    3'd1: col_1_r <= row1_pixel;
                    3'd2: col_1_r <= row2_pixel;
                    3'd3: col_1_r <= row3_pixel;
                    default: col_1_r <= row4_pixel;
                endcase
                case (patch_rd_row_2)
                    3'd0: col_2_r <= row0_pixel;
                    3'd1: col_2_r <= row1_pixel;
                    3'd2: col_2_r <= row2_pixel;
                    3'd3: col_2_r <= row3_pixel;
                    default: col_2_r <= row4_pixel;
                endcase
                case (patch_rd_row_3)
                    3'd0: col_3_r <= row0_pixel;
                    3'd1: col_3_r <= row1_pixel;
                    3'd2: col_3_r <= row2_pixel;
                    3'd3: col_3_r <= row3_pixel;
                    default: col_3_r <= row4_pixel;
                endcase
                case (patch_rd_row_4)
                    3'd0: col_4_r <= row0_pixel;
                    3'd1: col_4_r <= row1_pixel;
                    3'd2: col_4_r <= row2_pixel;
                    3'd3: col_4_r <= row3_pixel;
                    default: col_4_r <= row4_pixel;
                endcase
                col_center_x_r <= {patch_rd_pixel_col, 1'b0};
                col_center_y_r <= patch_rd_y;
                col_valid_r    <= 1'b1;
            end
        end
    end

    //=========================================================================
    // Output assignment
    //=========================================================================
    assign col_0        = col_0_r;
    assign col_1        = col_1_r;
    assign col_2        = col_2_r;
    assign col_3        = col_3_r;
    assign col_4        = col_4_r;
    assign col_valid    = col_valid_r;
    assign col_center_x = col_center_x_r;
    assign col_center_y = col_center_y_r;

    assign patch_col_ready = enable && frame_started && (row_depth >= NUM_ROWS);

    //=========================================================================
    // 5 Line SRAM Instances (2P packing: even, odd)
    //=========================================================================

    //----- Row 0 -----
    common_sram_model #(.DATA_WIDTH(SRAM_DW), .ADDR_WIDTH(SRAM_AW), .DEPTH(IMG_WIDTH/2), .OUTPUT_REG(1))
    u_sram_row_0 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_0_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr),
        .rd_data({sram_row_0_odd, sram_row_0_even}));

    //----- Row 1 -----
    common_sram_model #(.DATA_WIDTH(SRAM_DW), .ADDR_WIDTH(SRAM_AW), .DEPTH(IMG_WIDTH/2), .OUTPUT_REG(1))
    u_sram_row_1 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_1_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr),
        .rd_data({sram_row_1_odd, sram_row_1_even}));

    //----- Row 2 -----
    common_sram_model #(.DATA_WIDTH(SRAM_DW), .ADDR_WIDTH(SRAM_AW), .DEPTH(IMG_WIDTH/2), .OUTPUT_REG(1))
    u_sram_row_2 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_2_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr),
        .rd_data({sram_row_2_odd, sram_row_2_even}));

    //----- Row 3 -----
    common_sram_model #(.DATA_WIDTH(SRAM_DW), .ADDR_WIDTH(SRAM_AW), .DEPTH(IMG_WIDTH/2), .OUTPUT_REG(1))
    u_sram_row_3 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_3_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr),
        .rd_data({sram_row_3_odd, sram_row_3_even}));

    //----- Row 4 -----
    common_sram_model #(.DATA_WIDTH(SRAM_DW), .ADDR_WIDTH(SRAM_AW), .DEPTH(IMG_WIDTH/2), .OUTPUT_REG(1))
    u_sram_row_4 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_4_wr_en), .wr_addr(sram_wr_addr), .wr_data(sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr),
        .rd_data({sram_row_4_odd, sram_row_4_even}));

endmodule
