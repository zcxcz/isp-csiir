//==============================================================================
// ISP-CSIIR Standalone Testbench
// Uses isp_csiir_hls_standalone.cpp for HLS verification
//
// Usage:
//   ./standalone_tb --width 64 --height 64 --config cfg.txt -i input.hex
//
// Options:
//   --width W          Image width (default: 64)
//   --height H         Image height (default: 64)
//   --config <file>    Configuration file
//   --seed N           Random seed for pattern generation
//   -i <file>          Load input from file
//   -o <file>          Save output to file
//   -c <file>          Compare with reference
//   --feedback         Enable linebuffer feedback (default: on)
//
// Configuration file format (one param per line):
//   win_size_thresh=16,24,32,40
//   win_size_clip_y=15,23,31,39
//   win_size_clip_sft=2,2,2,2
//   blending_ratio=32,32,32,32
//   edge_protect=32
//==============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include "isp_csiir_hls_standalone.cpp"

using namespace hls_isp_csiir;

//==============================================================================
// Configuration File Parsing
//==============================================================================

void parse_config_file(const char* filename, Config& cfg) {
    FILE* f = fopen(filename, "r");
    if (!f) {
        fprintf(stderr, "Error: Cannot open config file %s\n", filename);
        exit(1);
    }

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char* token = strtok(line, "=\n");
        if (!token) continue;

        if (strcmp(token, "win_size_thresh") == 0) {
            int values[4];
            for (int i = 0; i < 4; i++) {
                char* num = strtok(NULL, ",\n");
                if (num) values[i] = atoi(num);
            }
            for (int i = 0; i < 4; i++) cfg.win_size_thresh[i] = values[i];
        }
        else if (strcmp(token, "win_size_clip_y") == 0) {
            int values[4];
            for (int i = 0; i < 4; i++) {
                char* num = strtok(NULL, ",\n");
                if (num) values[i] = atoi(num);
            }
            for (int i = 0; i < 4; i++) cfg.win_size_clip_y[i] = values[i];
        }
        else if (strcmp(token, "win_size_clip_sft") == 0) {
            int values[4];
            for (int i = 0; i < 4; i++) {
                char* num = strtok(NULL, ",\n");
                if (num) values[i] = atoi(num);
            }
            for (int i = 0; i < 4; i++) cfg.win_size_clip_sft[i] = values[i];
        }
        else if (strcmp(token, "blending_ratio") == 0) {
            int values[4];
            for (int i = 0; i < 4; i++) {
                char* num = strtok(NULL, ",\n");
                if (num) values[i] = atoi(num);
            }
            for (int i = 0; i < 4; i++) cfg.blending_ratio[i] = values[i];
        }
        else if (strcmp(token, "edge_protect") == 0) {
            char* num = strtok(NULL, "\n");
            if (num) cfg.reg_edge_protect = atoi(num);
        }
    }
    fclose(f);
}

//==============================================================================
// Main
//==============================================================================

int main(int argc, char* argv[]) {
    const char* input_file = nullptr;
    const char* output_file = nullptr;
    const char* compare_file = nullptr;
    const char* config_file = nullptr;
    int img_width = 64;
    int img_height = 64;
    int seed = 42;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            img_width = atoi(argv[++i]);
        }
        else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            img_height = atoi(argv[++i]);
        }
        else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_file = argv[++i];
        }
        else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            seed = atoi(argv[++i]);
        }
        else if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
            input_file = argv[++i];
        }
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            output_file = argv[++i];
        }
        else if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            compare_file = argv[++i];
        }
    }

    // Validate dimensions
    if (img_width < 8 || img_width > 4096 || img_height < 8 || img_height > 4096) {
        fprintf(stderr, "Error: Image dimensions must be between 8 and 4096\n");
        return 1;
    }

    printf("ISP-CSIIR Standalone Testbench\n");
    printf("Image: %dx%d\n", img_width, img_height);

    // Setup configuration
    Config cfg;
    cfg.img_width = img_width;
    cfg.img_height = img_height;

    if (config_file) {
        parse_config_file(config_file, cfg);
        printf("Loaded config from %s\n", config_file);
    }

    printf("Config: thresh=[%d,%d,%d,%d], clip_y=[%d,%d,%d,%d], "
           "blend=[%d,%d,%d,%d], edge=%d\n",
           cfg.win_size_thresh[0], cfg.win_size_thresh[1],
           cfg.win_size_thresh[2], cfg.win_size_thresh[3],
           cfg.win_size_clip_y[0], cfg.win_size_clip_y[1],
           cfg.win_size_clip_y[2], cfg.win_size_clip_y[3],
           cfg.blending_ratio[0], cfg.blending_ratio[1],
           cfg.blending_ratio[2], cfg.blending_ratio[3],
           cfg.reg_edge_protect);

    // Allocate arrays dynamically
    pixel_t* input = new pixel_t[img_height * img_width];
    pixel_t* output = new pixel_t[img_height * img_width];

    // Load or generate input
    if (input_file) {
        FILE* fin = fopen(input_file, "r");
        if (!fin) {
            fprintf(stderr, "Error: Cannot open input file %s\n", input_file);
            delete[] input;
            delete[] output;
            return 1;
        }
        for (int j = 0; j < img_height; j++) {
            for (int i = 0; i < img_width; i++) {
                int val;
                if (fscanf(fin, "%x", &val) == 1) {
                    input[j * img_width + i] = (pixel_t)(val & 0x3FF);
                }
            }
        }
        fclose(fin);
        printf("Loaded input from %s\n", input_file);
    } else {
        // Generate random pattern with given seed
        srand(seed);
        for (int j = 0; j < img_height; j++) {
            for (int i = 0; i < img_width; i++) {
                input[j * img_width + i] = (pixel_t)(rand() % 1024);
            }
        }
        printf("Generated random input (seed=%d)\n", seed);
        // Save generated input for verification
        FILE* fin_save = fopen("/tmp/cpp_gen_input.hex", "w");
        if (fin_save) {
            for (int j = 0; j < img_height; j++) {
                for (int i = 0; i < img_width; i++) {
                    fprintf(fin_save, "%03x\n", input[j * img_width + i] & 0x3FF);
                }
            }
            fclose(fin_save);
        }
    }

    //==========================================================================
    // Linebuffer feedback simulation (matches RTL architecture)
    //
    // Data path equivalent to RTL:
    //   - Original LB (4 rows): gradient/stage2 read ORIGINAL data
    //   - Filtered LB (5 rows): stage4 IIR blend reads FILTERED neighbors
    //                            current row uses ORIGINAL data (no self-feedback)
    //
    // Implementation:
    //   - src[] buffer: original image (never modified)
    //   - filt[] buffer: starts as copy of input, updated with filtered values
    //
    // For each pixel (i, j):
    //   - Gradient window: from src[] (original)
    //   - Stage2 window: from src[] (original)
    //   - Stage4 IIR window:
    //       rows 0-3: from filt[] (filtered neighbors)
    //       row 4: from src[] (original current row)
    //   - Write filtered value back to filt[]
    //==========================================================================
    printf("Running ISP-CSIIR with linebuffer feedback...\n");

    // Allocate working buffers
    pixel_t* src = new pixel_t[img_height * img_width];
    pixel_t* filt = new pixel_t[img_height * img_width];
    memcpy(src, input, img_height * img_width * sizeof(pixel_t));
    memcpy(filt, input, img_height * img_width * sizeof(pixel_t));

    // Gradient row buffers (2 rows, for stage3 neighbor gradient computation)
    pixel_t* grad_row_buf[2];
    for (int r = 0; r < 2; r++) {
        grad_row_buf[r] = new pixel_t[img_width];
        memset(grad_row_buf[r], 0, img_width * sizeof(pixel_t));
    }
    grad_t grad_shift[3] = {0, 0, 0};

    // Helper: build 5x5 window from a buffer
    auto build_window = [&](pixel_t* buf, int i, int j, pixel_t win[PATCH_SIZE]) -> void {
        for (int dy = -2; dy <= 2; dy++) {
            for (int dx = -2; dx <= 2; dx++) {
                int row = std::max(0, std::min(img_height - 1, j + dy));
                int col = std::max(0, std::min(img_width - 1, i + dx * 2));
                win[(dy + 2) * 5 + (dx + 2)] = buf[row * img_width + col];
            }
        }
    };

    // Process each pixel
    for (int j = 0; j < img_height; j++) {
        for (int i = 0; i < img_width; i++) {
            //------ Gradient window: from ORIGINAL (src[]) ------
            pixel_t src_win[PATCH_SIZE];
            build_window(src, i, j, src_win);

            //------ Stage 1: Sobel Gradient ------
            grad_t grad_h, grad_v, grad_c;
            sobel_gradient_5x5(src_win, grad_h, grad_v, grad_c);

            // Left/right gradients for LUT
            pixel_t lwin[PATCH_SIZE], rwin[PATCH_SIZE];
            build_window(src, i - 2, j, lwin);
            build_window(src, i + 2, j, rwin);
            grad_t grad_l, grad_r;
            grad_t tmp1, tmp2;
            sobel_gradient_5x5(lwin, tmp1, tmp2, grad_l);
            sobel_gradient_5x5(rwin, tmp1, tmp2, grad_r);

            // Neighbor gradients for fusion (from gradient row buffer)
            grad_t grad_u = (grad_t)grad_shift[1];
            grad_t grad_d = grad_row_buf[0][i];
            grad_shift[0] = grad_shift[1];
            grad_shift[1] = grad_shift[2];
            grad_shift[2] = grad_c;
            grad_row_buf[0][i] = grad_c;
            grad_row_buf[1][i] = grad_row_buf[0][i];

            //------ Stage 2: Directional Average (reads ORIGINAL) ------
            s11_t src_s11[PATCH_SIZE];
            for (int k = 0; k < PATCH_SIZE; k++) {
                src_s11[k] = u10_to_s11(src_win[k]);
            }
            int win_size = lut_win_size(cfg, (int)std::max(grad_l, std::max(grad_c, grad_r)));
            DirAvgResult dir_avg = compute_directional_avg(cfg, src_s11, win_size);

            //------ Stage 3: Gradient Fusion ------
            FusionResult fusion = compute_gradient_fusion(dir_avg,
                (int)grad_u, (int)grad_d, (int)grad_l, (int)grad_r, (int)grad_c);

            //------ Stage 4: IIR Blend ------
            // Build 5x5 window: rows 0-3 from filtered, row 4 from original
            s11_t filt_win[PATCH_SIZE];
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    int patch_idx = (dy + 2) * 5 + (dx + 2);
                    int row = std::max(0, std::min(img_height - 1, j + dy));
                    int col = std::max(0, std::min(img_width - 1, i + dx * 2));
                    if (dy < 0) {
                        // Rows 0-3: filtered neighbors
                        filt_win[patch_idx] = u10_to_s11(filt[row * img_width + col]);
                    } else {
                        // Row 4 (dy=0): original (current row, no self-feedback)
                        filt_win[patch_idx] = u10_to_s11(src[row * img_width + col]);
                    }
                }
            }

            s11_t final_patch[PATCH_SIZE];
            compute_iir_blend(cfg, filt_win, win_size, fusion.blend0, fusion.blend1,
                              dir_avg.avg0_u, dir_avg.avg1_u,
                              (int)grad_h, (int)grad_v, final_patch);

            pixel_t dout_pixel = s11_to_u10(final_patch[12]);

            //------ Write back filtered value to filt[] ------
            filt[j * img_width + i] = dout_pixel;

            //------ Output ------
            // Output when j >= 2 (window valid from original line buffer)
            if (j >= 2) {
                output[j * img_width + i] = dout_pixel;
            }
        }
    }

    // Fill first two rows from input (boundary)
    for (int j = 0; j < 2 && j < img_height; j++) {
        for (int i = 0; i < img_width; i++) {
            output[j * img_width + i] = input[j * img_width + i];
        }
    }

    // Save output to cpp_output.hex
    FILE* fout = fopen("cpp_output.hex", "w");
    if (!fout) {
        fprintf(stderr, "Error: Cannot open cpp_output.hex for writing\n");
        delete[] input;
        delete[] output;
        return 1;
    }
    for (int j = 0; j < img_height; j++) {
        for (int i = 0; i < img_width; i++) {
            fprintf(fout, "%03x\n", output[j * img_width + i] & 0x3FF);
        }
    }
    fclose(fout);
    printf("Output written to cpp_output.hex\n");

    // Save to custom file if requested
    if (output_file) {
        FILE* fcustom = fopen(output_file, "w");
        if (fcustom) {
            for (int j = 0; j < img_height; j++) {
                for (int i = 0; i < img_width; i++) {
                    fprintf(fcustom, "%03x\n", output[j * img_width + i] & 0x3FF);
                }
            }
            fclose(fcustom);
            printf("Output written to %s\n", output_file);
        }
    }

    // Print statistics
    int min_v = 1023, max_v = 0;
    long sum = 0;
    for (int j = 0; j < img_height; j++) {
        for (int i = 0; i < img_width; i++) {
            min_v = std::min(min_v, (int)output[j * img_width + i]);
            max_v = std::max(max_v, (int)output[j * img_width + i]);
            sum += output[j * img_width + i];
        }
    }
    printf("Output stats: min=%d, max=%d, avg=%.2f\n", min_v, max_v, (double)sum / (img_width * img_height));

    // Print first 4x4 for quick check
    printf("\nFirst 4x4 of output:\n");
    for (int j = 0; j < std::min(4, img_height); j++) {
        for (int i = 0; i < std::min(4, img_width); i++) {
            printf("%4d", output[j * img_width + i]);
        }
        printf("\n");
    }

    // Compare with reference if requested
    if (compare_file) {
        FILE* fref = fopen(compare_file, "r");
        if (!fref) {
            fprintf(stderr, "Error: Cannot open reference file %s\n", compare_file);
            delete[] input;
            delete[] output;
            delete[] src;
            delete[] filt;
            for (int r = 0; r < 2; r++)
                delete[] grad_row_buf[r];
            return 1;
        }

        int max_diff = 0;
        int total_diff = 0;
        int diff_count = 0;

        for (int j = 0; j < img_height; j++) {
            for (int i = 0; i < img_width; i++) {
                int val;
                if (fscanf(fref, "%x", &val) == 1) {
                    int ref_val = val & 0x3FF;
                    int diff = (int)output[j * img_width + i] - ref_val;
                    if (diff != 0) {
                        diff_count++;
                        total_diff += std::abs(diff);
                        max_diff = std::max(max_diff, std::abs(diff));
                    }
                }
            }
        }
        fclose(fref);

        printf("\n=== C++ vs Reference Comparison ===\n");
        printf("Total pixels: %d\n", img_width * img_height);
        printf("Pixels with diff: %d\n", diff_count);
        printf("Max abs diff: %d\n", max_diff);
        printf("Mean abs diff: %.2f\n", diff_count > 0 ? (double)total_diff / diff_count : 0.0);
        if (diff_count == 0) {
            printf("PASS: All outputs match!\n");
        } else {
            printf("FAIL: %d pixels differ\n", diff_count);
        }
    }

    delete[] input;
    delete[] output;
    delete[] src;
    delete[] filt;
    for (int r = 0; r < 2; r++)
        delete[] grad_row_buf[r];

    return 0;
}
