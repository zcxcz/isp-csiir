//-----------------------------------------------------------------------------
// Module: stage2_directional_avg
// Purpose: Multi-scale directional averaging
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.1 - Implemented dual-path directional kernels
//-----------------------------------------------------------------------------

module stage2_directional_avg #(
    parameter DATA_WIDTH      = 10,
    parameter SIGNED_WIDTH    = 11,
    parameter GRAD_WIDTH      = 14,
    parameter WIN_SIZE_WIDTH  = 6,
    parameter ACC_WIDTH       = 20,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             enable,

    input  wire [DATA_WIDTH-1:0]            window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    input  wire [DATA_WIDTH-1:0]            window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    input  wire [DATA_WIDTH-1:0]            window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    input  wire [DATA_WIDTH-1:0]            window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    input  wire [DATA_WIDTH-1:0]            window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,

    input  wire [GRAD_WIDTH-1:0]            grad_h,
    input  wire [GRAD_WIDTH-1:0]            grad_v,
    input  wire [GRAD_WIDTH-1:0]            grad,
    input  wire [WIN_SIZE_WIDTH-1:0]        win_size_clip,
    input  wire                             stage1_valid,
    input  wire [DATA_WIDTH-1:0]            center_pixel,
    output wire                             stage1_ready,

    input  wire [15:0]                      win_size_thresh0,
    input  wire [15:0]                      win_size_thresh1,
    input  wire [15:0]                      win_size_thresh2,
    input  wire [15:0]                      win_size_thresh3,

    output wire signed [SIGNED_WIDTH-1:0]  avg0_c,
    output wire signed [SIGNED_WIDTH-1:0]  avg0_u,
    output wire signed [SIGNED_WIDTH-1:0]  avg0_d,
    output wire signed [SIGNED_WIDTH-1:0]  avg0_l,
    output wire signed [SIGNED_WIDTH-1:0]  avg0_r,
    output wire signed [SIGNED_WIDTH-1:0]  avg1_c,
    output wire signed [SIGNED_WIDTH-1:0]  avg1_u,
    output wire signed [SIGNED_WIDTH-1:0]  avg1_d,
    output wire signed [SIGNED_WIDTH-1:0]  avg1_l,
    output wire signed [SIGNED_WIDTH-1:0]  avg1_r,
    output wire                             stage2_valid,
    input  wire                             stage2_ready,

    input  wire [LINE_ADDR_WIDTH-1:0]       pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]         pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]       pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]         pixel_y_out,
    output wire [GRAD_WIDTH-1:0]            grad_out,
    output wire [WIN_SIZE_WIDTH-1:0]        win_size_clip_out,
    output wire [DATA_WIDTH-1:0]            center_pixel_out
);

    localparam [2:0] KERNEL_ZERO = 3'd0;
    localparam [2:0] KERNEL_2X2  = 3'd1;
    localparam [2:0] KERNEL_3X3  = 3'd2;
    localparam [2:0] KERNEL_4X4  = 3'd3;
    localparam [2:0] KERNEL_5X5  = 3'd4;

    localparam [2:0] DIR_C = 3'd0;
    localparam [2:0] DIR_U = 3'd1;
    localparam [2:0] DIR_D = 3'd2;
    localparam [2:0] DIR_L = 3'd3;
    localparam [2:0] DIR_R = 3'd4;

    assign stage1_ready = stage2_ready;

    wire [2:0] avg0_kernel_select_comb;
    wire [2:0] avg1_kernel_select_comb;

    assign avg0_kernel_select_comb = (win_size_clip < win_size_thresh0[WIN_SIZE_WIDTH-1:0]) ? KERNEL_ZERO :
                                     (win_size_clip < win_size_thresh1[WIN_SIZE_WIDTH-1:0]) ? KERNEL_3X3  :
                                     (win_size_clip < win_size_thresh2[WIN_SIZE_WIDTH-1:0]) ? KERNEL_4X4  :
                                     (win_size_clip < win_size_thresh3[WIN_SIZE_WIDTH-1:0]) ? KERNEL_5X5  :
                                                                                              KERNEL_5X5;

    assign avg1_kernel_select_comb = (win_size_clip < win_size_thresh0[WIN_SIZE_WIDTH-1:0]) ? KERNEL_2X2  :
                                     (win_size_clip < win_size_thresh1[WIN_SIZE_WIDTH-1:0]) ? KERNEL_2X2  :
                                     (win_size_clip < win_size_thresh2[WIN_SIZE_WIDTH-1:0]) ? KERNEL_3X3  :
                                     (win_size_clip < win_size_thresh3[WIN_SIZE_WIDTH-1:0]) ? KERNEL_4X4  :
                                                                                               KERNEL_ZERO;

    wire signed [SIGNED_WIDTH-1:0] window_s11 [0:4][0:4];

    assign window_s11[0][0] = $signed({1'b0, window_0_0}) - $signed(11'sd512);
    assign window_s11[0][1] = $signed({1'b0, window_0_1}) - $signed(11'sd512);
    assign window_s11[0][2] = $signed({1'b0, window_0_2}) - $signed(11'sd512);
    assign window_s11[0][3] = $signed({1'b0, window_0_3}) - $signed(11'sd512);
    assign window_s11[0][4] = $signed({1'b0, window_0_4}) - $signed(11'sd512);
    assign window_s11[1][0] = $signed({1'b0, window_1_0}) - $signed(11'sd512);
    assign window_s11[1][1] = $signed({1'b0, window_1_1}) - $signed(11'sd512);
    assign window_s11[1][2] = $signed({1'b0, window_1_2}) - $signed(11'sd512);
    assign window_s11[1][3] = $signed({1'b0, window_1_3}) - $signed(11'sd512);
    assign window_s11[1][4] = $signed({1'b0, window_1_4}) - $signed(11'sd512);
    assign window_s11[2][0] = $signed({1'b0, window_2_0}) - $signed(11'sd512);
    assign window_s11[2][1] = $signed({1'b0, window_2_1}) - $signed(11'sd512);
    assign window_s11[2][2] = $signed({1'b0, window_2_2}) - $signed(11'sd512);
    assign window_s11[2][3] = $signed({1'b0, window_2_3}) - $signed(11'sd512);
    assign window_s11[2][4] = $signed({1'b0, window_2_4}) - $signed(11'sd512);
    assign window_s11[3][0] = $signed({1'b0, window_3_0}) - $signed(11'sd512);
    assign window_s11[3][1] = $signed({1'b0, window_3_1}) - $signed(11'sd512);
    assign window_s11[3][2] = $signed({1'b0, window_3_2}) - $signed(11'sd512);
    assign window_s11[3][3] = $signed({1'b0, window_3_3}) - $signed(11'sd512);
    assign window_s11[3][4] = $signed({1'b0, window_3_4}) - $signed(11'sd512);
    assign window_s11[4][0] = $signed({1'b0, window_4_0}) - $signed(11'sd512);
    assign window_s11[4][1] = $signed({1'b0, window_4_1}) - $signed(11'sd512);
    assign window_s11[4][2] = $signed({1'b0, window_4_2}) - $signed(11'sd512);
    assign window_s11[4][3] = $signed({1'b0, window_4_3}) - $signed(11'sd512);
    assign window_s11[4][4] = $signed({1'b0, window_4_4}) - $signed(11'sd512);

    reg [2:0]                      avg0_kernel_s4;
    reg [2:0]                      avg1_kernel_s4;
    reg signed [SIGNED_WIDTH-1:0]  win_s4 [0:4][0:4];
    reg [WIN_SIZE_WIDTH-1:0]       win_size_s4;
    reg [LINE_ADDR_WIDTH-1:0]      pixel_x_s4;
    reg [ROW_CNT_WIDTH-1:0]        pixel_y_s4;
    reg [DATA_WIDTH-1:0]           center_s4;
    reg [GRAD_WIDTH-1:0]           grad_s4;
    reg                            valid_s4;

    reg signed [ACC_WIDTH-1:0]     avg0_sum_c_s5;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_u_s5;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_d_s5;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_l_s5;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_r_s5;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_c_s5;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_u_s5;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_d_s5;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_l_s5;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_r_s5;
    reg [7:0]                      avg0_w_c_s5;
    reg [7:0]                      avg0_w_u_s5;
    reg [7:0]                      avg0_w_d_s5;
    reg [7:0]                      avg0_w_l_s5;
    reg [7:0]                      avg0_w_r_s5;
    reg [7:0]                      avg1_w_c_s5;
    reg [7:0]                      avg1_w_u_s5;
    reg [7:0]                      avg1_w_d_s5;
    reg [7:0]                      avg1_w_l_s5;
    reg [7:0]                      avg1_w_r_s5;
    reg [WIN_SIZE_WIDTH-1:0]       win_size_s5;
    reg [LINE_ADDR_WIDTH-1:0]      pixel_x_s5;
    reg [ROW_CNT_WIDTH-1:0]        pixel_y_s5;
    reg [DATA_WIDTH-1:0]           center_s5;
    reg [GRAD_WIDTH-1:0]           grad_s5;
    reg                            valid_s5;

    reg signed [ACC_WIDTH-1:0]     avg0_sum_c_s6;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_u_s6;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_d_s6;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_l_s6;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_r_s6;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_c_s6;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_u_s6;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_d_s6;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_l_s6;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_r_s6;
    reg [7:0]                      avg0_w_c_s6;
    reg [7:0]                      avg0_w_u_s6;
    reg [7:0]                      avg0_w_d_s6;
    reg [7:0]                      avg0_w_l_s6;
    reg [7:0]                      avg0_w_r_s6;
    reg [7:0]                      avg1_w_c_s6;
    reg [7:0]                      avg1_w_u_s6;
    reg [7:0]                      avg1_w_d_s6;
    reg [7:0]                      avg1_w_l_s6;
    reg [7:0]                      avg1_w_r_s6;
    reg [WIN_SIZE_WIDTH-1:0]       win_size_s6;
    reg [LINE_ADDR_WIDTH-1:0]      pixel_x_s6;
    reg [ROW_CNT_WIDTH-1:0]        pixel_y_s6;
    reg [DATA_WIDTH-1:0]           center_s6;
    reg [GRAD_WIDTH-1:0]           grad_s6;
    reg                            valid_s6;

    reg signed [SIGNED_WIDTH-1:0]  avg0_c_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg0_u_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg0_d_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg0_l_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg0_r_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg1_c_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg1_u_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg1_d_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg1_l_reg;
    reg signed [SIGNED_WIDTH-1:0]  avg1_r_reg;
    reg [WIN_SIZE_WIDTH-1:0]       win_size_out_reg;
    reg [LINE_ADDR_WIDTH-1:0]      pixel_x_out_reg;
    reg [ROW_CNT_WIDTH-1:0]        pixel_y_out_reg;
    reg [DATA_WIDTH-1:0]           center_out_reg;
    reg [GRAD_WIDTH-1:0]           grad_out_reg;
    reg                            stage2_valid_reg;

    reg signed [ACC_WIDTH-1:0]     avg0_sum_c_comb;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_u_comb;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_d_comb;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_l_comb;
    reg signed [ACC_WIDTH-1:0]     avg0_sum_r_comb;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_c_comb;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_u_comb;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_d_comb;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_l_comb;
    reg signed [ACC_WIDTH-1:0]     avg1_sum_r_comb;
    reg [7:0]                      avg0_w_c_comb;
    reg [7:0]                      avg0_w_u_comb;
    reg [7:0]                      avg0_w_d_comb;
    reg [7:0]                      avg0_w_l_comb;
    reg [7:0]                      avg0_w_r_comb;
    reg [7:0]                      avg1_w_c_comb;
    reg [7:0]                      avg1_w_u_comb;
    reg [7:0]                      avg1_w_d_comb;
    reg [7:0]                      avg1_w_l_comb;
    reg [7:0]                      avg1_w_r_comb;

    function [3:0] kernel_coeff;
        input [2:0] kernel_sel;
        input integer row;
        input integer col;
        begin
            kernel_coeff = 4'd0;
            case (kernel_sel)
                KERNEL_2X2: begin
                    case (row)
                        1: begin
                            case (col)
                                1, 3: kernel_coeff = 4'd1;
                                2:    kernel_coeff = 4'd2;
                                default: kernel_coeff = 4'd0;
                            endcase
                        end
                        2: begin
                            case (col)
                                1, 3: kernel_coeff = 4'd2;
                                2:    kernel_coeff = 4'd4;
                                default: kernel_coeff = 4'd0;
                            endcase
                        end
                        3: begin
                            case (col)
                                1, 3: kernel_coeff = 4'd1;
                                2:    kernel_coeff = 4'd2;
                                default: kernel_coeff = 4'd0;
                            endcase
                        end
                        default: kernel_coeff = 4'd0;
                    endcase
                end
                KERNEL_3X3: begin
                    if ((row >= 1) && (row <= 3) && (col >= 1) && (col <= 3))
                        kernel_coeff = 4'd1;
                end
                KERNEL_4X4: begin
                    case (row)
                        0, 4: begin
                            case (col)
                                0, 1, 3, 4: kernel_coeff = 4'd1;
                                2:          kernel_coeff = 4'd2;
                                default:    kernel_coeff = 4'd0;
                            endcase
                        end
                        1, 3: begin
                            case (col)
                                0, 4:       kernel_coeff = 4'd1;
                                1, 3:       kernel_coeff = 4'd2;
                                2:          kernel_coeff = 4'd4;
                                default:    kernel_coeff = 4'd0;
                            endcase
                        end
                        2: begin
                            case (col)
                                0, 4:       kernel_coeff = 4'd2;
                                1, 3:       kernel_coeff = 4'd4;
                                2:          kernel_coeff = 4'd8;
                                default:    kernel_coeff = 4'd0;
                            endcase
                        end
                        default: kernel_coeff = 4'd0;
                    endcase
                end
                KERNEL_5X5: begin
                    kernel_coeff = 4'd1;
                end
                default: begin
                    kernel_coeff = 4'd0;
                end
            endcase
        end
    endfunction

    function dir_match;
        input [2:0] dir_sel;
        input integer row;
        input integer col;
        begin
            case (dir_sel)
                DIR_C: dir_match = 1'b1;
                DIR_U: dir_match = (row <= 2);
                DIR_D: dir_match = (row >= 2);
                DIR_L: dir_match = (col <= 2);
                DIR_R: dir_match = (col >= 2);
                default: dir_match = 1'b0;
            endcase
        end
    endfunction

    function [3:0] factor_coeff;
        input [2:0] kernel_sel;
        input [2:0] dir_sel;
        input integer row;
        input integer col;
        begin
            if (dir_match(dir_sel, row, col))
                factor_coeff = kernel_coeff(kernel_sel, row, col);
            else
                factor_coeff = 4'd0;
        end
    endfunction

    function signed [SIGNED_WIDTH-1:0] saturate_s11;
        input signed [ACC_WIDTH-1:0] value;
        begin
            if (value > 511)
                saturate_s11 = 11'sd511;
            else if (value < -512)
                saturate_s11 = -11'sd512;
            else
                saturate_s11 = value[SIGNED_WIDTH-1:0];
        end
    endfunction

    function signed [ACC_WIDTH-1:0] round_div_signed;
        input signed [ACC_WIDTH-1:0] numerator;
        input [7:0]                  denominator;
        reg signed [ACC_WIDTH-1:0] abs_numerator;
        reg [7:0]                   bias;
        begin
            if (denominator == 0) begin
                round_div_signed = $signed({ACC_WIDTH{1'b0}});
            end else begin
                bias = denominator >> 1;
                if (numerator >= 0)
                    round_div_signed = (numerator + $signed({{(ACC_WIDTH-8){1'b0}}, bias})) / $signed({1'b0, denominator});
                else begin
                    abs_numerator = -numerator;
                    round_div_signed = -((abs_numerator + $signed({{(ACC_WIDTH-8){1'b0}}, bias})) / $signed({1'b0, denominator}));
                end
            end
        end
    endfunction

    wire signed [ACC_WIDTH-1:0] avg0_c_div_comb = round_div_signed(avg0_sum_c_s6, avg0_w_c_s6);
    wire signed [ACC_WIDTH-1:0] avg0_u_div_comb = round_div_signed(avg0_sum_u_s6, avg0_w_u_s6);
    wire signed [ACC_WIDTH-1:0] avg0_d_div_comb = round_div_signed(avg0_sum_d_s6, avg0_w_d_s6);
    wire signed [ACC_WIDTH-1:0] avg0_l_div_comb = round_div_signed(avg0_sum_l_s6, avg0_w_l_s6);
    wire signed [ACC_WIDTH-1:0] avg0_r_div_comb = round_div_signed(avg0_sum_r_s6, avg0_w_r_s6);
    wire signed [ACC_WIDTH-1:0] avg1_c_div_comb = round_div_signed(avg1_sum_c_s6, avg1_w_c_s6);
    wire signed [ACC_WIDTH-1:0] avg1_u_div_comb = round_div_signed(avg1_sum_u_s6, avg1_w_u_s6);
    wire signed [ACC_WIDTH-1:0] avg1_d_div_comb = round_div_signed(avg1_sum_d_s6, avg1_w_d_s6);
    wire signed [ACC_WIDTH-1:0] avg1_l_div_comb = round_div_signed(avg1_sum_l_s6, avg1_w_l_s6);
    wire signed [ACC_WIDTH-1:0] avg1_r_div_comb = round_div_signed(avg1_sum_r_s6, avg1_w_r_s6);

    wire signed [SIGNED_WIDTH-1:0] avg0_c_next = saturate_s11(avg0_c_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg0_u_next = saturate_s11(avg0_u_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg0_d_next = saturate_s11(avg0_d_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg0_l_next = saturate_s11(avg0_l_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg0_r_next = saturate_s11(avg0_r_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg1_c_next = saturate_s11(avg1_c_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg1_u_next = saturate_s11(avg1_u_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg1_d_next = saturate_s11(avg1_d_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg1_l_next = saturate_s11(avg1_l_div_comb);
    wire signed [SIGNED_WIDTH-1:0] avg1_r_next = saturate_s11(avg1_r_div_comb);

    integer s4_row;
    integer s4_col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_kernel_s4 <= KERNEL_ZERO;
            avg1_kernel_s4 <= KERNEL_ZERO;
            win_size_s4    <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s4     <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s4     <= {ROW_CNT_WIDTH{1'b0}};
            center_s4      <= {DATA_WIDTH{1'b0}};
            grad_s4        <= {GRAD_WIDTH{1'b0}};
            valid_s4       <= 1'b0;
            for (s4_row = 0; s4_row < 5; s4_row = s4_row + 1) begin
                for (s4_col = 0; s4_col < 5; s4_col = s4_col + 1) begin
                    win_s4[s4_row][s4_col] <= {SIGNED_WIDTH{1'b0}};
                end
            end
        end else if (stage2_ready) begin
            avg0_kernel_s4 <= avg0_kernel_select_comb;
            avg1_kernel_s4 <= avg1_kernel_select_comb;
            win_size_s4    <= win_size_clip;
            pixel_x_s4     <= pixel_x;
            pixel_y_s4     <= pixel_y;
            center_s4      <= center_pixel;
            grad_s4        <= grad;
            valid_s4       <= stage1_valid && enable;
            for (s4_row = 0; s4_row < 5; s4_row = s4_row + 1) begin
                for (s4_col = 0; s4_col < 5; s4_col = s4_col + 1) begin
                    win_s4[s4_row][s4_col] <= window_s11[s4_row][s4_col];
                end
            end
        end
    end

    integer calc_row;
    integer calc_col;
    integer coeff;
    always @(*) begin
        avg0_sum_c_comb = $signed({ACC_WIDTH{1'b0}});
        avg0_sum_u_comb = $signed({ACC_WIDTH{1'b0}});
        avg0_sum_d_comb = $signed({ACC_WIDTH{1'b0}});
        avg0_sum_l_comb = $signed({ACC_WIDTH{1'b0}});
        avg0_sum_r_comb = $signed({ACC_WIDTH{1'b0}});
        avg1_sum_c_comb = $signed({ACC_WIDTH{1'b0}});
        avg1_sum_u_comb = $signed({ACC_WIDTH{1'b0}});
        avg1_sum_d_comb = $signed({ACC_WIDTH{1'b0}});
        avg1_sum_l_comb = $signed({ACC_WIDTH{1'b0}});
        avg1_sum_r_comb = $signed({ACC_WIDTH{1'b0}});

        avg0_w_c_comb = 8'd0;
        avg0_w_u_comb = 8'd0;
        avg0_w_d_comb = 8'd0;
        avg0_w_l_comb = 8'd0;
        avg0_w_r_comb = 8'd0;
        avg1_w_c_comb = 8'd0;
        avg1_w_u_comb = 8'd0;
        avg1_w_d_comb = 8'd0;
        avg1_w_l_comb = 8'd0;
        avg1_w_r_comb = 8'd0;

        for (calc_row = 0; calc_row < 5; calc_row = calc_row + 1) begin
            for (calc_col = 0; calc_col < 5; calc_col = calc_col + 1) begin
                coeff = factor_coeff(avg0_kernel_s4, DIR_C, calc_row, calc_col);
                avg0_sum_c_comb = avg0_sum_c_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg0_w_c_comb   = avg0_w_c_comb + coeff;

                coeff = factor_coeff(avg0_kernel_s4, DIR_U, calc_row, calc_col);
                avg0_sum_u_comb = avg0_sum_u_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg0_w_u_comb   = avg0_w_u_comb + coeff;

                coeff = factor_coeff(avg0_kernel_s4, DIR_D, calc_row, calc_col);
                avg0_sum_d_comb = avg0_sum_d_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg0_w_d_comb   = avg0_w_d_comb + coeff;

                coeff = factor_coeff(avg0_kernel_s4, DIR_L, calc_row, calc_col);
                avg0_sum_l_comb = avg0_sum_l_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg0_w_l_comb   = avg0_w_l_comb + coeff;

                coeff = factor_coeff(avg0_kernel_s4, DIR_R, calc_row, calc_col);
                avg0_sum_r_comb = avg0_sum_r_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg0_w_r_comb   = avg0_w_r_comb + coeff;

                coeff = factor_coeff(avg1_kernel_s4, DIR_C, calc_row, calc_col);
                avg1_sum_c_comb = avg1_sum_c_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg1_w_c_comb   = avg1_w_c_comb + coeff;

                coeff = factor_coeff(avg1_kernel_s4, DIR_U, calc_row, calc_col);
                avg1_sum_u_comb = avg1_sum_u_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg1_w_u_comb   = avg1_w_u_comb + coeff;

                coeff = factor_coeff(avg1_kernel_s4, DIR_D, calc_row, calc_col);
                avg1_sum_d_comb = avg1_sum_d_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg1_w_d_comb   = avg1_w_d_comb + coeff;

                coeff = factor_coeff(avg1_kernel_s4, DIR_L, calc_row, calc_col);
                avg1_sum_l_comb = avg1_sum_l_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg1_w_l_comb   = avg1_w_l_comb + coeff;

                coeff = factor_coeff(avg1_kernel_s4, DIR_R, calc_row, calc_col);
                avg1_sum_r_comb = avg1_sum_r_comb + ($signed(win_s4[calc_row][calc_col]) * coeff);
                avg1_w_r_comb   = avg1_w_r_comb + coeff;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_sum_c_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_u_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_d_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_l_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_r_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_c_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_u_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_d_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_l_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_r_s5 <= $signed({ACC_WIDTH{1'b0}});
            avg0_w_c_s5   <= 8'd0;
            avg0_w_u_s5   <= 8'd0;
            avg0_w_d_s5   <= 8'd0;
            avg0_w_l_s5   <= 8'd0;
            avg0_w_r_s5   <= 8'd0;
            avg1_w_c_s5   <= 8'd0;
            avg1_w_u_s5   <= 8'd0;
            avg1_w_d_s5   <= 8'd0;
            avg1_w_l_s5   <= 8'd0;
            avg1_w_r_s5   <= 8'd0;
            win_size_s5   <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s5    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s5    <= {ROW_CNT_WIDTH{1'b0}};
            center_s5     <= {DATA_WIDTH{1'b0}};
            grad_s5       <= {GRAD_WIDTH{1'b0}};
            valid_s5      <= 1'b0;
        end else if (stage2_ready) begin
            avg0_sum_c_s5 <= avg0_sum_c_comb;
            avg0_sum_u_s5 <= avg0_sum_u_comb;
            avg0_sum_d_s5 <= avg0_sum_d_comb;
            avg0_sum_l_s5 <= avg0_sum_l_comb;
            avg0_sum_r_s5 <= avg0_sum_r_comb;
            avg1_sum_c_s5 <= avg1_sum_c_comb;
            avg1_sum_u_s5 <= avg1_sum_u_comb;
            avg1_sum_d_s5 <= avg1_sum_d_comb;
            avg1_sum_l_s5 <= avg1_sum_l_comb;
            avg1_sum_r_s5 <= avg1_sum_r_comb;
            avg0_w_c_s5   <= avg0_w_c_comb;
            avg0_w_u_s5   <= avg0_w_u_comb;
            avg0_w_d_s5   <= avg0_w_d_comb;
            avg0_w_l_s5   <= avg0_w_l_comb;
            avg0_w_r_s5   <= avg0_w_r_comb;
            avg1_w_c_s5   <= avg1_w_c_comb;
            avg1_w_u_s5   <= avg1_w_u_comb;
            avg1_w_d_s5   <= avg1_w_d_comb;
            avg1_w_l_s5   <= avg1_w_l_comb;
            avg1_w_r_s5   <= avg1_w_r_comb;
            win_size_s5   <= win_size_s4;
            pixel_x_s5    <= pixel_x_s4;
            pixel_y_s5    <= pixel_y_s4;
            center_s5     <= center_s4;
            grad_s5       <= grad_s4;
            valid_s5      <= valid_s4;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_sum_c_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_u_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_d_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_l_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg0_sum_r_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_c_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_u_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_d_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_l_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg1_sum_r_s6 <= $signed({ACC_WIDTH{1'b0}});
            avg0_w_c_s6   <= 8'd0;
            avg0_w_u_s6   <= 8'd0;
            avg0_w_d_s6   <= 8'd0;
            avg0_w_l_s6   <= 8'd0;
            avg0_w_r_s6   <= 8'd0;
            avg1_w_c_s6   <= 8'd0;
            avg1_w_u_s6   <= 8'd0;
            avg1_w_d_s6   <= 8'd0;
            avg1_w_l_s6   <= 8'd0;
            avg1_w_r_s6   <= 8'd0;
            win_size_s6   <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s6    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s6    <= {ROW_CNT_WIDTH{1'b0}};
            center_s6     <= {DATA_WIDTH{1'b0}};
            grad_s6       <= {GRAD_WIDTH{1'b0}};
            valid_s6      <= 1'b0;
        end else if (stage2_ready) begin
            avg0_sum_c_s6 <= avg0_sum_c_s5;
            avg0_sum_u_s6 <= avg0_sum_u_s5;
            avg0_sum_d_s6 <= avg0_sum_d_s5;
            avg0_sum_l_s6 <= avg0_sum_l_s5;
            avg0_sum_r_s6 <= avg0_sum_r_s5;
            avg1_sum_c_s6 <= avg1_sum_c_s5;
            avg1_sum_u_s6 <= avg1_sum_u_s5;
            avg1_sum_d_s6 <= avg1_sum_d_s5;
            avg1_sum_l_s6 <= avg1_sum_l_s5;
            avg1_sum_r_s6 <= avg1_sum_r_s5;
            avg0_w_c_s6   <= avg0_w_c_s5;
            avg0_w_u_s6   <= avg0_w_u_s5;
            avg0_w_d_s6   <= avg0_w_d_s5;
            avg0_w_l_s6   <= avg0_w_l_s5;
            avg0_w_r_s6   <= avg0_w_r_s5;
            avg1_w_c_s6   <= avg1_w_c_s5;
            avg1_w_u_s6   <= avg1_w_u_s5;
            avg1_w_d_s6   <= avg1_w_d_s5;
            avg1_w_l_s6   <= avg1_w_l_s5;
            avg1_w_r_s6   <= avg1_w_r_s5;
            win_size_s6   <= win_size_s5;
            pixel_x_s6    <= pixel_x_s5;
            pixel_y_s6    <= pixel_y_s5;
            center_s6     <= center_s5;
            grad_s6       <= grad_s5;
            valid_s6      <= valid_s5;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_c_reg      <= {SIGNED_WIDTH{1'b0}};
            avg0_u_reg      <= {SIGNED_WIDTH{1'b0}};
            avg0_d_reg      <= {SIGNED_WIDTH{1'b0}};
            avg0_l_reg      <= {SIGNED_WIDTH{1'b0}};
            avg0_r_reg      <= {SIGNED_WIDTH{1'b0}};
            avg1_c_reg      <= {SIGNED_WIDTH{1'b0}};
            avg1_u_reg      <= {SIGNED_WIDTH{1'b0}};
            avg1_d_reg      <= {SIGNED_WIDTH{1'b0}};
            avg1_l_reg      <= {SIGNED_WIDTH{1'b0}};
            avg1_r_reg      <= {SIGNED_WIDTH{1'b0}};
            win_size_out_reg <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_out_reg <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out_reg <= {ROW_CNT_WIDTH{1'b0}};
            center_out_reg  <= {DATA_WIDTH{1'b0}};
            grad_out_reg    <= {GRAD_WIDTH{1'b0}};
            stage2_valid_reg <= 1'b0;
        end else if (stage2_ready) begin
            avg0_c_reg      <= avg0_c_next;
            avg0_u_reg      <= avg0_u_next;
            avg0_d_reg      <= avg0_d_next;
            avg0_l_reg      <= avg0_l_next;
            avg0_r_reg      <= avg0_r_next;
            avg1_c_reg      <= avg1_c_next;
            avg1_u_reg      <= avg1_u_next;
            avg1_d_reg      <= avg1_d_next;
            avg1_l_reg      <= avg1_l_next;
            avg1_r_reg      <= avg1_r_next;
            win_size_out_reg <= win_size_s6;
            pixel_x_out_reg <= pixel_x_s6;
            pixel_y_out_reg <= pixel_y_s6;
            center_out_reg  <= center_s6;
            grad_out_reg    <= grad_s6;
            stage2_valid_reg <= valid_s6;
        end
    end

    assign avg0_c           = avg0_c_reg;
    assign avg0_u           = avg0_u_reg;
    assign avg0_d           = avg0_d_reg;
    assign avg0_l           = avg0_l_reg;
    assign avg0_r           = avg0_r_reg;
    assign avg1_c           = avg1_c_reg;
    assign avg1_u           = avg1_u_reg;
    assign avg1_d           = avg1_d_reg;
    assign avg1_l           = avg1_l_reg;
    assign avg1_r           = avg1_r_reg;
    assign stage2_valid     = stage2_valid_reg;
    assign pixel_x_out      = pixel_x_out_reg;
    assign pixel_y_out      = pixel_y_out_reg;
    assign grad_out         = grad_out_reg;
    assign win_size_clip_out = win_size_out_reg;
    assign center_pixel_out = center_out_reg;

endmodule
