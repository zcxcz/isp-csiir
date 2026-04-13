//////
// Module:     isp_csiir_linebuffer_core
// Author:    rtl-impl
// Date:      2026-04-07
// Modified:  2026-04-13
//////
// Purpose:
//   5-row line buffer storage. Manages:
//   - Pixel stream input (din) -> write to line SRAM by row
//   - Column capture (read 5 rows at same column) -> output 5x1 column
//   - Patch write-back (patch_valid) -> write pixels at specific positions
//   - Tail flush after last row (vertical padding)
//////
// Parameters:
//   IMG_WIDTH       - Image width (pixels per row)
//   DATA_WIDTH      - Bits per pixel
//   LINE_ADDR_WIDTH - Address width for line SRAM
//////

module isp_csiir_linebuffer_core #(
    parameter IMG_WIDTH        = 5472,
    parameter DATA_WIDTH       = 10,
    parameter LINE_ADDR_WIDTH   = 14
)(
    // Clock & reset
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Image geometry
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,
    input  wire [12:0]                img_height,
    input  wire [12:0]                max_center_y_allow,

    // Pixel input stream
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // Legacy write-back (tied off in current design)
    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset,

    // Patch write-back from stage4 feedback
    input  wire                        patch_valid,
    output wire                        patch_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_center_x,
    input  wire [12:0]                patch_center_y,
    input  wire [DATA_WIDTH*25-1:0]  patch_5x5,

    // Column output (5x1 vertical pixel column)
    output wire [DATA_WIDTH-1:0]      col_0,
    output wire [DATA_WIDTH-1:0]      col_1,
    output wire [DATA_WIDTH-1:0]      col_2,
    output wire [DATA_WIDTH-1:0]      col_3,
    output wire [DATA_WIDTH-1:0]      col_4,
    output reg                         column_valid,
    input  wire                        column_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                center_y
);

    //=========================================================================
    // localparam
    //=========================================================================
    localparam NUM_ROWS = 5;

    //=========================================================================
    // Declaration
    //=========================================================================
    //----- Write pointer -----
    reg [2:0]                    wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]    wr_col_ptr;
    reg [12:0]                   row_cnt;
    reg                          frame_started;
    reg                          eol_pending;

    //----- Patch write FSM -----
    localparam PATCH_IDLE = 2'd0;
    localparam PATCH_BUSY = 2'd1;
    reg [1:0]                    patch_state;
    reg [LINE_ADDR_WIDTH-1:0]    patch_base_x;
    reg [12:0]                   patch_base_y;
    reg [DATA_WIDTH*25-1:0]      patch_5x5_buf;
    integer                      patch_dx;
    integer                      patch_dy;
    reg                          patch_pixel_wr;

    //----- Column capture FSM -----
    reg                          capture_req;
    reg [LINE_ADDR_WIDTH-1:0]   capture_col;
    reg [12:0]                  capture_y;
    reg [2:0]                    capture_row_0;
    reg [2:0]                    capture_row_1;
    reg [2:0]                    capture_row_2;
    reg [2:0]                    capture_row_3;
    reg [2:0]                    capture_row_4;

    //----- Tail flush FSM -----
    reg                          tail_req;
    reg                          tail_active;
    reg [2:0]                    tail_base;
    reg [LINE_ADDR_WIDTH-1:0]    tail_col;
    reg [12:0]                  tail_y;

    //----- Column output -----
    reg [DATA_WIDTH-1:0]         col_0_r;
    reg [DATA_WIDTH-1:0]         col_1_r;
    reg [DATA_WIDTH-1:0]         col_2_r;
    reg [DATA_WIDTH-1:0]         col_3_r;
    reg [DATA_WIDTH-1:0]         col_4_r;
    reg [LINE_ADDR_WIDTH-1:0]    center_x_r;
    reg [12:0]                  center_y_r;

    //----- SRAM write control (driven by FSM, used by instance) -----
    reg                          sram_wr_en;
    reg [2:0]                    sram_wr_row;
    reg [LINE_ADDR_WIDTH-1:0]    sram_wr_addr;
    reg [DATA_WIDTH-1:0]         sram_wr_data;

    //----- SRAM read address -----
    reg [LINE_ADDR_WIDTH-1:0]    sram_rd_addr;

    //----- Temp variables for SRAM write mux (avoid SV inline decl) -----
    integer                      sram_mux_px;
    integer                      sram_mux_py;
    integer                      sram_mux_row_idx;

    //=========================================================================
    // SRAM read data wires
    //=========================================================================
    wire [DATA_WIDTH-1:0] sram_row_0_data;
    wire [DATA_WIDTH-1:0] sram_row_1_data;
    wire [DATA_WIDTH-1:0] sram_row_2_data;
    wire [DATA_WIDTH-1:0] sram_row_3_data;
    wire [DATA_WIDTH-1:0] sram_row_4_data;

    //=========================================================================
    // Combinational logic
    //=========================================================================
    // din_ready: frame must be active and downstream must be ready
    assign din_ready    = enable && frame_started && column_ready;
    assign patch_ready   = 1'b1;

    // EOL fire: EOL seen and downstream not stalled
    wire column_stalled = ~column_ready;
    wire eol_fire       = (eol || eol_pending) && ~column_stalled;

    // Next write row pointer (circular 0-4)
    wire [2:0] next_wr_row = (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;

    //----- Row address helpers (wr_row_ptr - N, with wrap) -----
    function [2:0] row_wrap_sub;
        input [2:0] base;
        input [2:0] delta;
        begin
            row_wrap_sub = (base >= delta) ? (base - delta) : (base + 3'd5 - delta);
        end
    endfunction

    wire [2:0] wr_row_m1 = row_wrap_sub(wr_row_ptr, 3'd1);  // previous row
    wire [2:0] wr_row_m2 = row_wrap_sub(wr_row_ptr, 3'd2);  // 2 rows back
    wire [2:0] wr_row_m3 = row_wrap_sub(wr_row_ptr, 3'd3);  // 3 rows back
    wire [2:0] wr_row_m4 = row_wrap_sub(wr_row_ptr, 3'd4);  // 4 rows back

    //----- Stream rows: rows visible in the 5x5 window centered at current pixel -----
    // For row_cnt == 0,1: no valid capture yet (rows 0,1 are in padding)
    // For row_cnt >= 2: center is row_cnt - 2, window rows:
    //   row0 of window = wr_row - 4
    //   row1 of window = wr_row - 3
    //   row2 of window = wr_row - 2  (center row)
    //   row3 of window = wr_row - 1
    //   row4 of window = wr_row      (current row)
    wire [2:0] stream_row_0 = (row_cnt <= 13'd3) ? wr_row_m4 : wr_row_m4;
    wire [2:0] stream_row_1 = (row_cnt <= 13'd3) ? wr_row_m3 : wr_row_m3;
    wire [2:0] stream_row_2 = wr_row_m2;
    wire [2:0] stream_row_3 = wr_row_m1;
    wire [2:0] stream_row_4 = wr_row_ptr;

    //----- Tail rows: flush rows after last row is received -----
    wire [2:0] tail_row_0 = (tail_y == img_height - 1'b1) ? row_wrap_sub(tail_base, 3'd3) : row_wrap_sub(tail_base, 3'd4);
    wire [2:0] tail_row_1 = (tail_y == img_height - 1'b1) ? row_wrap_sub(tail_base, 3'd2) : row_wrap_sub(tail_base, 3'd3);
    wire [2:0] tail_row_2 = (tail_y == img_height - 1'b1) ? row_wrap_sub(tail_base, 3'd1) : row_wrap_sub(tail_base, 3'd2);
    wire [2:0] tail_row_3 = row_wrap_sub(tail_base, 3'd1);
    wire [2:0] tail_row_4 = row_wrap_sub(tail_base, 3'd1);

    // Capture fire: valid input pixel that has 2 rows behind it
    wire normal_capture_fire = din_valid && din_ready && (row_cnt >= 13'd2) && (row_cnt < img_height);
    wire last_row_eol        = eol_fire && (row_cnt == img_height - 1'b1);

    // Tail capture allow: tail flush always allowed (no row dependency)
    wire tail_capture_allow = 1'b1;

    //=========================================================================
    // FSM_WR: Write pointer and row counter
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
        end else if (sof) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
        end else if (enable) begin
            // EOL pending: remember EOL arrived while stalled
            if (eol && column_stalled)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            // Advance on EOL
            if (eol_fire) begin
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= next_wr_row;
                row_cnt    <= row_cnt + 1'b1;
            end
        end
    end

    //=========================================================================
    // FSM_PATCH: Patch write-back state machine (25 cycles per patch)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            patch_state   <= PATCH_IDLE;
            patch_base_x  <= {LINE_ADDR_WIDTH{1'b0}};
            patch_base_y  <= 13'd0;
            patch_5x5_buf <= {DATA_WIDTH*25{1'b0}};
            patch_dx      <= -2;
            patch_dy      <= -2;
            patch_pixel_wr <= 1'b0;
        end else if (sof) begin
            patch_state   <= PATCH_IDLE;
            patch_base_x  <= {LINE_ADDR_WIDTH{1'b0}};
            patch_base_y  <= 13'd0;
            patch_5x5_buf <= {DATA_WIDTH*25{1'b0}};
            patch_dx      <= -2;
            patch_dy      <= -2;
            patch_pixel_wr <= 1'b0;
        end else if (enable) begin
            case (patch_state)
                PATCH_IDLE: begin
                    patch_pixel_wr <= 1'b0;
                    if (patch_valid && patch_ready) begin
                        patch_state   <= PATCH_BUSY;
                        patch_base_x  <= patch_center_x;
                        patch_base_y  <= patch_center_y;
                        patch_5x5_buf <= patch_5x5;
                        patch_dx      <= -2;
                        patch_dy      <= -2;
                    end
                end

                PATCH_BUSY: begin
                    // Write one pixel per cycle
                    patch_pixel_wr <= 1'b1;

                    // Advance grid position: left-to-right, top-to-bottom
                    if (patch_dx < 2)
                        patch_dx <= patch_dx + 1;
                    else begin
                        patch_dx <= -2;
                        patch_dy <= patch_dy + 1;
                    end

                    // Done after bottom-right pixel (dy==2 && dx==2)
                    if (patch_dy == 2 && patch_dx == 2) begin
                        patch_state    <= PATCH_IDLE;
                        patch_pixel_wr <= 1'b0;
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // FSM_CAPTURE: Column capture request generator
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_req  <= 1'b0;
            capture_col  <= {LINE_ADDR_WIDTH{1'b0}};
            capture_y    <= 13'd0;
            capture_row_0 <= 3'd0;
            capture_row_1 <= 3'd0;
            capture_row_2 <= 3'd0;
            capture_row_3 <= 3'd0;
            capture_row_4 <= 3'd0;
        end else if (sof) begin
            capture_req  <= 1'b0;
            capture_col  <= {LINE_ADDR_WIDTH{1'b0}};
            capture_y    <= 13'd0;
            capture_row_0 <= 3'd0;
            capture_row_1 <= 3'd0;
            capture_row_2 <= 3'd0;
            capture_row_3 <= 3'd0;
            capture_row_4 <= 3'd0;
        end else if (enable) begin
            // Clear capture request once column_valid is asserted
            if (capture_req && column_valid && column_ready)
                capture_req <= 1'b0;

            // Normal capture from pixel stream
            if (normal_capture_fire && !capture_req) begin
                capture_req  <= 1'b1;
                capture_col  <= wr_col_ptr;
                capture_y    <= row_cnt - 13'd2;
                capture_row_0 <= stream_row_0;
                capture_row_1 <= stream_row_1;
                capture_row_2 <= stream_row_2;
                capture_row_3 <= stream_row_3;
                capture_row_4 <= stream_row_4;
            end
        end
    end

    //=========================================================================
    // FSM_TAIL: Tail flush after last row
    //=========================================================================
    reg tail_turnaround;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tail_req       <= 1'b0;
            tail_active    <= 1'b0;
            tail_base      <= 3'd0;
            tail_col       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_y         <= 13'd0;
            tail_turnaround <= 1'b0;
        end else if (sof) begin
            tail_req       <= 1'b0;
            tail_active    <= 1'b0;
            tail_base      <= 3'd0;
            tail_col       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_y         <= 13'd0;
            tail_turnaround <= 1'b0;
        end else if (enable) begin
            // Clear tail_req when capture starts
            if (tail_req && capture_req)
                tail_req <= 1'b0;

            // Arm tail flush when last row EOL fires
            if (last_row_eol && !tail_req) begin
                tail_req   <= 1'b1;
                tail_base  <= next_wr_row;
                tail_col   <= {LINE_ADDR_WIDTH{1'b0}};
                tail_y     <= (img_height > 1) ? (img_height - 2'd2) : 13'd0;
                tail_turnaround <= 1'b0;
            end

            // Tail flush active: walk through remaining rows column by column
            if (tail_req && !capture_req && tail_active && tail_capture_allow) begin
                if (tail_turnaround) begin
                    tail_turnaround <= 1'b0;
                end else begin
                    // Advance column
                    if (tail_col >= img_width - 1'b1) begin
                        tail_col <= {LINE_ADDR_WIDTH{1'b0}};
                        // Advance row
                        if (tail_y >= img_height - 1'b1) begin
                            tail_active <= 1'b0;
                            tail_y      <= img_height;
                        end else begin
                            tail_y         <= tail_y + 1'b1;
                            tail_turnaround <= 1'b1;
                        end
                    end else begin
                        tail_col <= tail_col + 1'b1;
                    end
                end
            end

            // Start tail flush when stream capture is done
            if (tail_req && !capture_req && !tail_active && !normal_capture_fire && !capture_req) begin
                tail_active    <= 1'b1;
                tail_col       <= {LINE_ADDR_WIDTH{1'b0}};
                tail_y         <= (img_height > 1) ? (img_height - 2'd2) : 13'd0;
                tail_turnaround <= 1'b0;
            end
        end
    end

    //=========================================================================
    // SRAM write control: multiplex din and patch writes onto shared SRAM ports
    //=========================================================================
    // din and patch are mutually exclusive: din_valid when streaming pixels,
    // patch_valid when stage4 feedback fires. din has priority.
    always @(*) begin
        sram_wr_en   = 1'b0;
        sram_wr_row  = 3'd0;
        sram_wr_addr = {LINE_ADDR_WIDTH{1'b0}};
        sram_wr_data = {DATA_WIDTH{1'b0}};

        if (patch_pixel_wr && patch_state == PATCH_BUSY) begin
            // Patch write: calculate (x, y) -> row index
            sram_mux_px = patch_base_x + (patch_dx * 2);
            sram_mux_py = patch_base_y + patch_dy;

            if (sram_mux_px < 0)          sram_mux_px = 0;
            else if (sram_mux_px >= img_width) sram_mux_px = img_width - 1;

            if (sram_mux_py < 0)          sram_mux_py = 0;
            else if (sram_mux_py >= img_height) sram_mux_py = img_height - 1;

            sram_mux_row_idx = sram_mux_py % 5;

            sram_wr_en   = 1'b1;
            sram_wr_row  = sram_mux_row_idx[2:0];
            sram_wr_addr = sram_mux_px[LINE_ADDR_WIDTH-1:0];
            sram_wr_data = patch_5x5_buf[((patch_dy+2)*5 + (patch_dx+2))*DATA_WIDTH +: DATA_WIDTH];
        end else if (din_valid && din_ready) begin
            // Normal pixel write
            sram_wr_en   = 1'b1;
            sram_wr_row  = wr_row_ptr;
            sram_wr_addr = wr_col_ptr;
            sram_wr_data = din;
        end
    end

    //=========================================================================
    // Column output (read side): capture SRAM read into output registers
    //=========================================================================
    // Drive SRAM read address from capture request
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_rd_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            sram_rd_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (enable) begin
            if (capture_req && !column_valid)
                sram_rd_addr <= capture_col;
            else if (tail_req && tail_active && !column_valid)
                sram_rd_addr <= tail_col;
        end
    end

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_0_r      <= {DATA_WIDTH{1'b0}};
            col_1_r      <= {DATA_WIDTH{1'b0}};
            col_2_r      <= {DATA_WIDTH{1'b0}};
            col_3_r      <= {DATA_WIDTH{1'b0}};
            col_4_r      <= {DATA_WIDTH{1'b0}};
            center_x_r   <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_r   <= 13'd0;
            column_valid <= 1'b0;
        end else if (sof) begin
            col_0_r      <= {DATA_WIDTH{1'b0}};
            col_1_r      <= {DATA_WIDTH{1'b0}};
            col_2_r      <= {DATA_WIDTH{1'b0}};
            col_3_r      <= {DATA_WIDTH{1'b0}};
            col_4_r      <= {DATA_WIDTH{1'b0}};
            center_x_r   <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_r   <= 13'd0;
            column_valid <= 1'b0;
        end else if (enable) begin
            // Backpressure: hold column_valid when downstream not ready
            if (column_valid && !column_ready)
                column_valid <= 1'b1;
            else if (!column_ready)
                column_valid <= 1'b0;
            else if (capture_req || (tail_req && tail_active)) begin
                // Read 5 rows at captured column address
                case (capture_req ? capture_row_0 : tail_row_0)
                    3'd0: col_0_r <= sram_row_0_data;
                    3'd1: col_0_r <= sram_row_1_data;
                    3'd2: col_0_r <= sram_row_2_data;
                    3'd3: col_0_r <= sram_row_3_data;
                    default: col_0_r <= sram_row_4_data;
                endcase
                case (capture_req ? capture_row_1 : tail_row_1)
                    3'd0: col_1_r <= sram_row_0_data;
                    3'd1: col_1_r <= sram_row_1_data;
                    3'd2: col_1_r <= sram_row_2_data;
                    3'd3: col_1_r <= sram_row_3_data;
                    default: col_1_r <= sram_row_4_data;
                endcase
                case (capture_req ? capture_row_2 : tail_row_2)
                    3'd0: col_2_r <= sram_row_0_data;
                    3'd1: col_2_r <= sram_row_1_data;
                    3'd2: col_2_r <= sram_row_2_data;
                    3'd3: col_2_r <= sram_row_3_data;
                    default: col_2_r <= sram_row_4_data;
                endcase
                case (capture_req ? capture_row_3 : tail_row_3)
                    3'd0: col_3_r <= sram_row_0_data;
                    3'd1: col_3_r <= sram_row_1_data;
                    3'd2: col_3_r <= sram_row_2_data;
                    3'd3: col_3_r <= sram_row_3_data;
                    default: col_3_r <= sram_row_4_data;
                endcase
                case (capture_req ? capture_row_4 : tail_row_4)
                    3'd0: col_4_r <= sram_row_0_data;
                    3'd1: col_4_r <= sram_row_1_data;
                    3'd2: col_4_r <= sram_row_2_data;
                    3'd3: col_4_r <= sram_row_3_data;
                    default: col_4_r <= sram_row_4_data;
                endcase
                center_x_r   <= capture_req ? capture_col : tail_col;
                center_y_r   <= capture_req ? capture_y   : tail_y;
                column_valid <= 1'b1;
            end
        end
    end

    //=========================================================================
    // Output assignment
    //=========================================================================
    assign col_0     = col_0_r;
    assign col_1     = col_1_r;
    assign col_2     = col_2_r;
    assign col_3     = col_3_r;
    assign col_4     = col_4_r;
    assign center_x  = center_x_r;
    assign center_y  = center_y_r;

    //=========================================================================
    // 5 Line SRAM Instances
    //=========================================================================
    // One SRAM per row. Write port is shared: din or patch writes.
    // Read port is used for column capture (all SRAMs read same addr).
    //=========================================================================

    //----- Row 0 -----
    wire sram_0_wr = sram_wr_en && (sram_wr_row == 3'd0);
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_row_0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_0_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_row_0_data)
    );

    //----- Row 1 -----
    wire sram_1_wr = sram_wr_en && (sram_wr_row == 3'd1);
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_row_1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_1_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_row_1_data)
    );

    //----- Row 2 -----
    wire sram_2_wr = sram_wr_en && (sram_wr_row == 3'd2);
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_row_2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_2_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_row_2_data)
    );

    //----- Row 3 -----
    wire sram_3_wr = sram_wr_en && (sram_wr_row == 3'd3);
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_row_3 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_3_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_row_3_data)
    );

    //----- Row 4 -----
    wire sram_4_wr = sram_wr_en && (sram_wr_row == 3'd4);
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_row_4 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_4_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_row_4_data)
    );

endmodule
