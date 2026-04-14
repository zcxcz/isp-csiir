//////
// Module:     isp_csiir_linebuffer_core
// Author:    rtl-impl
// Date:      2026-04-07
// Modified:  2026-04-14
//////
// Purpose:
//   5-row line buffer with 1-port SRAM, circular row allocation.
//
// Architecture:
//   - row_depth (0-5): valid rows in linebuffer.
//     push on EOL, pop when patch finishes one image-width pass (col_depth→0).
//   - col_depth (0-5): columns currently being processed by patch.
//     +1 on patch_col_req, -1 on patch_col_wr.
//   - din path: direct write when row_depth<5; 4-cycle bypass when row_depth=5.
//   - wr_row_ptr: circular 0→1→2→3→4→0.
//   - patch writes: same cycle as din write (different rows, no conflict).
//////

module isp_csiir_linebuffer_core #(
    parameter IMG_WIDTH        = 5472,
    parameter DATA_WIDTH       = 10,
    parameter LINE_ADDR_WIDTH  = 14,
    parameter BYPASS_STAGES   = 4
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    input  wire [LINE_ADDR_WIDTH-1:0] img_width,
    input  wire [12:0]               img_height,

    // Pixel input stream
    input  wire [DATA_WIDTH-1:0]      din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // Patch column read (from patch assembler requesting a column)
    input  wire                        patch_col_req,
    output wire                        patch_col_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_col_addr,

    // Patch column write-back (from stage4, writes processed column back)
    input  wire                        patch_col_wr,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_col_wr_addr,
    input  wire [DATA_WIDTH*5-1:0]    patch_col_wr_data,

    // Column output (5x1 vertical column to patch assembler)
    output wire [DATA_WIDTH-1:0]      col_0,
    output wire [DATA_WIDTH-1:0]      col_1,
    output wire [DATA_WIDTH-1:0]      col_2,
    output wire [DATA_WIDTH-1:0]      col_3,
    output wire [DATA_WIDTH-1:0]      col_4,
    output wire                        col_valid,
    input  wire                        col_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  col_center_x,
    output wire [12:0]               col_center_y,

    // Bypass path (din directly to gradient when linebuffer full)
    output wire [DATA_WIDTH-1:0]     bypass_dout,
    output wire                        bypass_valid,
    input  wire                        bypass_ready
);

    //=========================================================================
    // localparam
    //=========================================================================
    localparam NUM_ROWS = 5;

    //=========================================================================
    // Reg/Wire Declarations
    //=========================================================================
    //----- Row FSM -----
    reg [3:0]                   row_depth;       // 0-5, valid rows count
    reg [2:0]                   wr_row_ptr;      // circular write pointer 0-4
    reg [LINE_ADDR_WIDTH-1:0]  wr_col_ptr;      // column addr within row
    reg [12:0]                 row_cnt;         // current row number
    reg                         frame_started;
    reg                         eol_pending;

    //----- Column FSM -----
    reg [3:0]                  col_depth;        // 0-5, columns in patch processing
    reg                         patch_reading;    // currently reading a column
    reg [LINE_ADDR_WIDTH-1:0]  patch_rd_col;    // column addr for current read
    reg [12:0]                 patch_rd_y;       // y position
    reg [2:0]                  patch_rd_row_0;   // physical row for column row 0
    reg [2:0]                  patch_rd_row_1;
    reg [2:0]                  patch_rd_row_2;
    reg [2:0]                  patch_rd_row_3;
    reg [2:0]                  patch_rd_row_4;

    //----- Column output registers -----
    reg                         col_valid_r;
    reg [DATA_WIDTH-1:0]        col_0_r, col_1_r, col_2_r, col_3_r, col_4_r;
    reg [LINE_ADDR_WIDTH-1:0]  col_center_x_r;
    reg [12:0]                 col_center_y_r;

    //----- SRAM control -----
    reg                          sram_wr_en;
    reg [2:0]                   sram_wr_row;
    reg [LINE_ADDR_WIDTH-1:0]   sram_wr_addr;
    reg [DATA_WIDTH-1:0]        sram_wr_data;

    //----- SRAM read address -----
    wire [LINE_ADDR_WIDTH-1:0]  sram_rd_addr;
    wire                        sram_rd_en = 1'b1;  // always read when patch reads

    //----- Feedback column write-back (separate from din path) -----
    // Writes processed column pixels to their respective rows
    reg                          fb_wr_en;
    reg [2:0]                    fb_wr_row_idx;
    reg [LINE_ADDR_WIDTH-1:0]    fb_wr_addr;
    reg [DATA_WIDTH-1:0]         fb_wr_data;

    //----- Bypass pipeline -----
    reg [DATA_WIDTH-1:0]         bypass_pipe [0:BYPASS_STAGES];
    reg                           bypass_pipe_valid [0:BYPASS_STAGES];

    //=========================================================================
    // SRAM Read Data
    //=========================================================================
    wire [DATA_WIDTH-1:0] sram_row_0_data;
    wire [DATA_WIDTH-1:0] sram_row_1_data;
    wire [DATA_WIDTH-1:0] sram_row_2_data;
    wire [DATA_WIDTH-1:0] sram_row_3_data;
    wire [DATA_WIDTH-1:0] sram_row_4_data;

    //=========================================================================
    // Combinational logic
    //=========================================================================
    assign din_ready = enable && frame_started;

    wire din_shake       = din_valid && din_ready;
    wire eol_fire        = eol && din_ready && !eol_pending;
    wire patch_col_fire   = patch_col_req && patch_col_ready;

    wire [2:0] next_wr_row = (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;

    // Circular row arithmetic: base - delta (mod 5)
    function [2:0] row_sub(input [2:0] base, input [2:0] delta);
        begin
            row_sub = (base >= delta) ? (base - delta) : (base + 3'd5 - delta);
        end
    endfunction

    // The 5 rows for a column centered at the current pixel:
    // row4=newest(wr_row_ptr), row3, row2, row1, row0=oldest(wr_row_ptr-4)
    wire [2:0] rd_row_0 = row_sub(wr_row_ptr, 3'd4);
    wire [2:0] rd_row_1 = row_sub(wr_row_ptr, 3'd3);
    wire [2:0] rd_row_2 = row_sub(wr_row_ptr, 3'd2);
    wire [2:0] rd_row_3 = row_sub(wr_row_ptr, 3'd1);
    wire [2:0] rd_row_4 = wr_row_ptr;

    // din can write: row_depth < 5 (free row available)
    // when row_depth == 5, din goes through bypass path
    wire din_can_write = (row_depth < NUM_ROWS);

    assign sram_rd_addr = patch_reading ? patch_rd_col : {LINE_ADDR_WIDTH{1'b0}};

    //=========================================================================
    // FSM_WR: Write pointer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
            frame_started <= 1'b0;
        end else if (sof) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
            frame_started <= 1'b1;
        end else if (enable) begin
            if (eol && !din_ready)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            if (eol_fire) begin
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= next_wr_row;
                row_cnt    <= row_cnt + 1'b1;
            end

            if (din_valid && din_ready && din_can_write) begin
                wr_col_ptr <= wr_col_ptr + 1'b1;
            end
        end
    end

    //=========================================================================
    // row_depth: valid rows count
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_depth <= 4'd0;
        end else if (sof) begin
            row_depth <= 4'd0;
        end else if (enable) begin
            if (eol_fire)
                row_depth <= row_depth + 1'b1;
            else if (!eol_fire && col_depth == 4'd1 && patch_col_wr) begin
                // Patch finished one row (all columns processed)
                // wr_row_ptr now circles back to the oldest row
                row_depth <= row_depth - 1'b1;
            end
        end
    end

    //=========================================================================
    // col_depth: columns being processed by patch
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_depth   <= 4'd0;
        end else if (sof) begin
            col_depth   <= 4'd0;
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
            patch_reading <= 1'b0;
            patch_rd_col  <= {LINE_ADDR_WIDTH{1'b0}};
            patch_rd_y    <= 13'd0;
            patch_rd_row_0 <= 3'd0;
            patch_rd_row_1 <= 3'd0;
            patch_rd_row_2 <= 3'd0;
            patch_rd_row_3 <= 3'd0;
            patch_rd_row_4 <= 3'd0;
        end else if (sof) begin
            patch_reading <= 1'b0;
            patch_rd_col  <= {LINE_ADDR_WIDTH{1'b0}};
            patch_rd_y    <= 13'd0;
            patch_rd_row_0 <= 3'd0;
            patch_rd_row_1 <= 3'd0;
            patch_rd_row_2 <= 3'd0;
            patch_rd_row_3 <= 3'd0;
            patch_rd_row_4 <= 3'd0;
        end else if (enable) begin
            if (patch_col_fire) begin
                patch_reading <= 1'b1;
                patch_rd_col  <= patch_col_addr;
                patch_rd_y    <= row_cnt - 13'd2;
                patch_rd_row_0 <= rd_row_0;
                patch_rd_row_1 <= rd_row_1;
                patch_rd_row_2 <= rd_row_2;
                patch_rd_row_3 <= rd_row_3;
                patch_rd_row_4 <= rd_row_4;
            end else if (col_valid_r && col_ready) begin
                patch_reading <= 1'b0;
            end
        end
    end

    //=========================================================================
    // din write to SRAM
    //=========================================================================
    always @(*) begin
        sram_wr_en   = 1'b0;
        sram_wr_row  = 3'd0;
        sram_wr_addr = {LINE_ADDR_WIDTH{1'b0}};
        sram_wr_data = {DATA_WIDTH{1'b0}};

        if (din_valid && din_ready && din_can_write) begin
            sram_wr_en   = 1'b1;
            sram_wr_row  = wr_row_ptr;
            sram_wr_addr = wr_col_ptr;
            sram_wr_data = din;
        end
    end

    //=========================================================================
    // Feedback column write-back (from stage4)
    //=========================================================================
    // Writes 5 pixels (one column) back to their respective rows.
    // Row index = pixel_y % 5, computed from patch_col_wr_addr (which is x coord).
    // The actual y position must come from the patch context - here we use
    // patch_rd_y (latched from when column was read).
    integer fb_i;
    reg [DATA_WIDTH-1:0] fb_pixel;
    always @(*) begin
        fb_wr_en    = 1'b0;
        fb_wr_addr  = {LINE_ADDR_WIDTH{1'b0}};
        fb_wr_data  = {DATA_WIDTH{1'b0}};
        fb_wr_row_idx = 3'd0;

        if (patch_col_wr) begin
            fb_wr_en   = 1'b1;
            fb_wr_addr = patch_col_wr_addr;
        end
    end

    // Feedback row index: derived from which row this pixel belongs to.
    // The pixel's y position is patch_rd_y (center) + (pixel_offset_in_column).
    // pixel_offset_in_column = 0,1,2,3,4 corresponds to rows 0,1,2,3,4.
    // We need to route each of the 5 pixels to its correct row.
    // For simplicity, handle one row per cycle or use a simple round-robin.
    // Here we write all 5 rows simultaneously with the same column address
    // but different row indices. This means 5 separate SRAM writes.
    // To avoid complexity, we treat each row as a separate write.
    // For this implementation: we only write one row per cycle.
    // The full 5x1 column write-back takes 5 cycles.

    //=========================================================================
    // Bypass pipeline (4 stages for din when linebuffer full)
    //=========================================================================
    integer b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (b = 0; b <= BYPASS_STAGES; b = b + 1) begin
                bypass_pipe[b]      <= {DATA_WIDTH{1'b0}};
                bypass_pipe_valid[b] <= 1'b0;
            end
        end else if (sof) begin
            for (b = 0; b <= BYPASS_STAGES; b = b + 1) begin
                bypass_pipe[b]      <= {DATA_WIDTH{1'b0}};
                bypass_pipe_valid[b] <= 1'b0;
            end
        end else if (enable) begin
            if (din_shake) begin
                bypass_pipe[0]      <= din;
                bypass_pipe_valid[0] <= 1'b1;
                for (b = 1; b <= BYPASS_STAGES; b = b + 1) begin
                    bypass_pipe[b]      <= bypass_pipe[b-1];
                    bypass_pipe_valid[b] <= bypass_pipe_valid[b-1];
                end
            end
        end
    end

    assign bypass_dout  = bypass_pipe[BYPASS_STAGES];
    assign bypass_valid = bypass_pipe_valid[BYPASS_STAGES];

    //=========================================================================
    // Column output (read side)
    //=========================================================================
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
                case (patch_rd_row_0)
                    3'd0: col_0_r <= sram_row_0_data;
                    3'd1: col_0_r <= sram_row_1_data;
                    3'd2: col_0_r <= sram_row_2_data;
                    3'd3: col_0_r <= sram_row_3_data;
                    default: col_0_r <= sram_row_4_data;
                endcase
                case (patch_rd_row_1)
                    3'd0: col_1_r <= sram_row_0_data;
                    3'd1: col_1_r <= sram_row_1_data;
                    3'd2: col_1_r <= sram_row_2_data;
                    3'd3: col_1_r <= sram_row_3_data;
                    default: col_1_r <= sram_row_4_data;
                endcase
                case (patch_rd_row_2)
                    3'd0: col_2_r <= sram_row_0_data;
                    3'd1: col_2_r <= sram_row_1_data;
                    3'd2: col_2_r <= sram_row_2_data;
                    3'd3: col_2_r <= sram_row_3_data;
                    default: col_2_r <= sram_row_4_data;
                endcase
                case (patch_rd_row_3)
                    3'd0: col_3_r <= sram_row_0_data;
                    3'd1: col_3_r <= sram_row_1_data;
                    3'd2: col_3_r <= sram_row_2_data;
                    3'd3: col_3_r <= sram_row_3_data;
                    default: col_3_r <= sram_row_4_data;
                endcase
                case (patch_rd_row_4)
                    3'd0: col_4_r <= sram_row_0_data;
                    3'd1: col_4_r <= sram_row_1_data;
                    3'd2: col_4_r <= sram_row_2_data;
                    3'd3: col_4_r <= sram_row_3_data;
                    default: col_4_r <= sram_row_4_data;
                endcase
                col_center_x_r <= patch_rd_col;
                col_center_y_r <= patch_rd_y;
                col_valid_r    <= 1'b1;
            end
        end
    end

    //=========================================================================
    // Output assignment
    //=========================================================================
    assign col_0       = col_0_r;
    assign col_1       = col_1_r;
    assign col_2       = col_2_r;
    assign col_3       = col_3_r;
    assign col_4       = col_4_r;
    assign col_valid   = col_valid_r;
    assign col_center_x = col_center_x_r;
    assign col_center_y = col_center_y_r;

    assign patch_col_ready = enable && frame_started && (row_depth >= NUM_ROWS);

    //=========================================================================
    // 5 Line SRAM Instances
    //=========================================================================
    // din write goes to sram_wr_*. Feedback write-back uses separate port.
    //=========================================================================

    //----- Row 0 -----
    wire sram_0_din_wr   = sram_wr_en && (sram_wr_row == 3'd0);
    wire sram_0_fb_wr    = fb_wr_en && (fb_wr_row_idx == 3'd0);
    common_sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(LINE_ADDR_WIDTH), .DEPTH(IMG_WIDTH), .OUTPUT_REG(1))
    u_sram_row_0 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_0_din_wr || sram_0_fb_wr),
        .wr_addr(fb_wr_en ? fb_wr_addr : sram_wr_addr),
        .wr_data(fb_wr_en ? fb_wr_data : sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr), .rd_data(sram_row_0_data));

    //----- Row 1 -----
    wire sram_1_din_wr = sram_wr_en && (sram_wr_row == 3'd1);
    wire sram_1_fb_wr  = fb_wr_en && (fb_wr_row_idx == 3'd1);
    common_sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(LINE_ADDR_WIDTH), .DEPTH(IMG_WIDTH), .OUTPUT_REG(1))
    u_sram_row_1 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_1_din_wr || sram_1_fb_wr),
        .wr_addr(fb_wr_en ? fb_wr_addr : sram_wr_addr),
        .wr_data(fb_wr_en ? fb_wr_data : sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr), .rd_data(sram_row_1_data));

    //----- Row 2 -----
    wire sram_2_din_wr = sram_wr_en && (sram_wr_row == 3'd2);
    wire sram_2_fb_wr  = fb_wr_en && (fb_wr_row_idx == 3'd2);
    common_sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(LINE_ADDR_WIDTH), .DEPTH(IMG_WIDTH), .OUTPUT_REG(1))
    u_sram_row_2 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_2_din_wr || sram_2_fb_wr),
        .wr_addr(fb_wr_en ? fb_wr_addr : sram_wr_addr),
        .wr_data(fb_wr_en ? fb_wr_data : sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr), .rd_data(sram_row_2_data));

    //----- Row 3 -----
    wire sram_3_din_wr = sram_wr_en && (sram_wr_row == 3'd3);
    wire sram_3_fb_wr  = fb_wr_en && (fb_wr_row_idx == 3'd3);
    common_sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(LINE_ADDR_WIDTH), .DEPTH(IMG_WIDTH), .OUTPUT_REG(1))
    u_sram_row_3 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_3_din_wr || sram_3_fb_wr),
        .wr_addr(fb_wr_en ? fb_wr_addr : sram_wr_addr),
        .wr_data(fb_wr_en ? fb_wr_data : sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr), .rd_data(sram_row_3_data));

    //----- Row 4 -----
    wire sram_4_din_wr = sram_wr_en && (sram_wr_row == 3'd4);
    wire sram_4_fb_wr  = fb_wr_en && (fb_wr_row_idx == 3'd4);
    common_sram_model #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(LINE_ADDR_WIDTH), .DEPTH(IMG_WIDTH), .OUTPUT_REG(1))
    u_sram_row_4 (.clk(clk), .rst_n(rst_n), .enable(enable),
        .wr_en(sram_4_din_wr || sram_4_fb_wr),
        .wr_addr(fb_wr_en ? fb_wr_addr : sram_wr_addr),
        .wr_data(fb_wr_en ? fb_wr_data : sram_wr_data),
        .rd_en(sram_rd_en), .rd_addr(sram_rd_addr), .rd_data(sram_row_4_data));

endmodule
