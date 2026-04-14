//==============================================================================
// ISP-CSIIR HLS Stream Processing Model
// This file provides the HLS-compatible C++ implementation for streaming mode
//==============================================================================

#include <iostream>
#include <fstream>
#include <vector>
#include <cstring>
#include "isp_csiir_hls.cpp"

using namespace hls_isp_csiir;

// Image dimensions
static const int MAX_WIDTH = 4096;
static const int MAX_HEIGHT = 4096;

// Line buffer for feedback simulation
static pixel_t line_buffer[5][MAX_WIDTH];
static int wr_row_ptr = 0;
static int wr_col_ptr = 0;
static int row_cnt = 0;
static bool frame_started = false;

// 5x5 patch assembler buffer
static pixel_t row_mem[5][MAX_WIDTH];

// Pending feedback columns
static pixel_t pending_cols[MAX_WIDTH][5];
static bool pending_valid[MAX_WIDTH];

// Configuration
static Config cfg;

// Helper: clip value to range
static inline int clip_int(int val, int min_val, int max_val) {
    if (val < min_val) return min_val;
    if (val > max_val) return max_val;
    return val;
}

// Extract 5x5 window centered at (center_x, center_y)
static void extract_window_5x5(int center_x, int center_y,
                               pixel_t window[25]) {
    const int taps[5] = {-4, -2, 0, 2, 4};
    int width = cfg.img_width;
    int height = cfg.img_height;

    for (int dy = -2; dy <= 2; dy++) {
        int row = clip_int(center_y + dy, 0, height - 1);
        for (int dx = -2; dx <= 2; dx++) {
            int tap_idx = dx + 2;
            int raw_x = clip_int(center_x + taps[dx], 0, width - 1);
            window[dy * 5 + dx + 2] = line_buffer[row % 5][raw_x];
        }
    }
}

// Write pixel to line buffer
static void write_to_line_buffer(int x, int y, pixel_t value) {
    int row = clip_int(y, 0, cfg.img_height - 1);
    line_buffer[row % 5][x] = value;
}

// Read pixel from line buffer
static pixel_t read_from_line_buffer(int x, int y) {
    int row = clip_int(y, 0, cfg.img_height - 1);
    return line_buffer[row % 5][x];
}

// Feedback writeback calculation
static void compute_feedback_writeback(int center_x, int center_y,
                                       int write_xs[5], int& num_writes) {
    num_writes = 0;
    for (int dx = -2; dx <= 2; dx++) {
        int raw_x = center_x + dx * 2;
        if (0 <= raw_x && raw_x < cfg.img_width) {
            write_xs[num_writes++] = raw_x;
        }
    }
}

// Check if feedback column is safe to write
static bool is_column_safe(int center_x, int raw_x) {
    for (int future_x = center_x + 1;
         future_x <= center_x + 4 && future_x < cfg.img_width;
         future_x++) {
        for (int dx = -2; dx <= 2; dx++) {
            int x = clip_int(future_x + dx * 2, 0, cfg.img_width - 1);
            if (x == raw_x) return false;
        }
    }
    return true;
}

// Apply feedback from processed patch
static void apply_feedback(int center_x, int center_y,
                          const s11_t patch_s11[25]) {
    int write_xs[5];
    int num_writes;
    compute_feedback_writeback(center_x, center_y, write_xs, num_writes);

    for (int i = 0; i < num_writes; i++) {
        int raw_x = write_xs[i];
        if (!is_column_safe(center_x, raw_x)) continue;

        for (int dy = -2; dy <= 2; dy++) {
            int write_y = clip_int(center_y + dy, 0, cfg.img_height - 1);
            int patch_row = dy + 2;
            // Find which patch column this raw_x corresponds to
            int patch_col = (raw_x - center_x) / 2 + 2;
            if (patch_col < 0 || patch_col >= 5) continue;
            pixel_t value = s11_to_u10(patch_s11[patch_row * 5 + patch_col]);
            write_to_line_buffer(raw_x, write_y, value);
        }
    }
}

// Initialize line buffer with input image
static void init_line_buffer(const pixel_t* image, int width, int height) {
    cfg.img_width = width;
    cfg.img_height = height;

    // Clear line buffer
    for (int r = 0; r < 5; r++) {
        for (int x = 0; x < width; x++) {
            line_buffer[r][x] = 0;
        }
    }

    // Load first 5 rows
    for (int y = 0; y < height && y < 5; y++) {
        for (int x = 0; x < width; x++) {
            line_buffer[y][x] = image[y * width + x];
        }
    }
    wr_row_ptr = (height >= 5) ? 4 : (height - 1);
}

// Process image with full feedback
static void process_image_with_feedback(const pixel_t* input,
                                       pixel_t* output,
                                       int width, int height) {
    // Initialize with input
    init_line_buffer(input, width, height);

    // Clear pending columns
    for (int x = 0; x < width; x++) {
        pending_valid[x] = false;
    }

    // Process each pixel with feedback
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Extract window
            pixel_t window[25];
            extract_window_5x5(x, y, window);

            // Convert to s11
            s11_t patch_s11[25];
            for (int i = 0; i < 25; i++) {
                patch_s11[i] = u10_to_s11(window[i]);
            }

            // Stage 1: Gradient
            grad_t grad_h, grad_v, grad;
            sobel_gradient_5x5(window, grad_h, grad_v, grad);

            // Window size from LUT
            int win_size = lut_win_size(cfg, (int)grad);

            // Stage 2: Directional Average
            DirAvgResult dir_avg = compute_directional_avg(cfg, patch_s11, win_size);

            // For fusion, need neighbor gradients - simplified (use center)
            grad_t grad_u = grad, grad_d = grad, grad_l = grad, grad_c = grad;

            // Stage 3: Gradient Fusion
            FusionResult fusion = compute_gradient_fusion(dir_avg, win_size,
                                                         (int)grad_u, (int)grad_d,
                                                         (int)grad_l, (int)grad_c,
                                                         (int)grad);

            // Stage 4: IIR Blend
            BlendResult blend = compute_iir_blend(cfg, patch_s11, win_size,
                                                 fusion.blend0, fusion.blend1,
                                                 dir_avg.avg0_u, dir_avg.avg1_u,
                                                 (int)grad_h, (int)grad_v);

            // Output center pixel
            output[y * width + x] = s11_to_u10(blend.final_patch[12]);

            // Apply feedback (update line buffer for next pixel)
            apply_feedback(x, y, blend.final_patch);

            // Update line buffer with input pixel
            if (y >= 2 && y < height - 2) {
                write_to_line_buffer(x, y, input[y * width + x]);
            }
        }
    }
}

// Simplified feed-forward only processing
static void process_image_feedforward(const pixel_t* input,
                                     pixel_t* output,
                                     int width, int height) {
    cfg.img_width = width;
    cfg.img_height = height;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Extract window
            pixel_t window[25];
            const int taps[5] = {-4, -2, 0, 2, 4};

            for (int dy = -2; dy <= 2; dy++) {
                int row = clip_int(y + dy, 0, height - 1);
                for (int dx = -2; dx <= 2; dx++) {
                    int raw_x = clip_int(x + taps[dx], 0, width - 1);
                    window[dy * 5 + dx + 2] = input[row * width + raw_x];
                }
            }

            // Process
            output[y * width + x] = process_pixel(cfg, window);
        }
    }
}

// Load image from hex file
static bool load_image(const char* filename, std::vector<pixel_t>& image,
                       int& width, int& height) {
    std::ifstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Cannot open file: " << filename << std::endl;
        return false;
    }

    // Read dimensions from first line (comment format: # W x H)
    std::string line;
    if (!std::getline(file, line)) return false;

    // Try to parse dimensions
    if (line[0] == '#') {
        char w_str[16], h_str[16];
        if (sscanf(line.c_str(), "# %15[^x] x %15s", w_str, h_str) == 2) {
            width = std::atoi(w_str);
            height = std::atoi(h_str);
        }
    }

    if (width <= 0 || height <= 0) {
        std::cerr << "Invalid dimensions" << std::endl;
        return false;
    }

    // Read pixel values
    image.clear();
    int count = 0;
    while (std::getline(file, line) && count < width * height) {
        if (line.empty() || line[0] == '#') continue;
        unsigned int val;
        if (sscanf(line.c_str(), "%x", &val) == 1) {
            image.push_back((pixel_t)val);
            count++;
        }
    }

    if ((int)image.size() != width * height) {
        std::cerr << "Expected " << width * height << " pixels, got " << image.size() << std::endl;
        return false;
    }

    return true;
}

// Save image to hex file
static bool save_image(const char* filename, const pixel_t* image,
                       int width, int height) {
    std::ofstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Cannot create file: " << filename << std::endl;
        return false;
    }

    file << "# HLS output: " << width << " x " << height << "\n";
    for (int i = 0; i < width * height; i++) {
        file << std::hex << std::setfill('0') << std::setw(4)
             << (unsigned int)image[i] << "\n";
    }

    return true;
}

// Main test
int main(int argc, char* argv[]) {
    std::cout << "ISP-CSIIR HLS Model" << std::endl;
    std::cout << "===================" << std::endl;

    // Default configuration
    cfg.win_size_thresh[0] = 100;
    cfg.win_size_thresh[1] = 200;
    cfg.win_size_thresh[2] = 400;
    cfg.win_size_thresh[3] = 800;
    cfg.blending_ratio[0] = 32;
    cfg.blending_ratio[1] = 32;
    cfg.blending_ratio[2] = 32;
    cfg.blending_ratio[3] = 32;
    cfg.reg_edge_protect = 32;

    // Test patterns
    if (argc < 2) {
        std::cout << "\nUsage: " << argv[0] << " <mode> [options]" << std::endl;
        std::cout << "Modes:" << std::endl;
        std::cout << "  test <pattern> - Run built-in test pattern" << std::endl;
        std::cout << "  file <input.hex> - Process input file" << std::endl;
        std::cout << "  compare <input.hex> <golden.hex> - Compare outputs" << std::endl;
        std::cout << "\nTest patterns: zeros, ramp, random, checker, max, gradient" << std::endl;
        return 1;
    }

    std::string mode = argv[1];

    if (mode == "test") {
        if (argc < 3) {
            std::cout << "Specify pattern: zeros, ramp, random, checker, max, gradient" << std::endl;
            return 1;
        }
        std::string pattern = argv[2];

        int width = 16;
        int height = 16;
        std::vector<pixel_t> input(width * height);
        std::vector<pixel_t> output(width * height);

        // Generate test pattern
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int idx = y * width + x;
                int val = 0;
                if (pattern == "zeros") {
                    val = 0;
                } else if (pattern == "ramp") {
                    val = (x + y) % 1024;
                } else if (pattern == "random") {
                    val = (x * 17 + y * 31) % 1024;
                } else if (pattern == "checker") {
                    val = ((x / 8) + (y / 8)) % 2 ? 1023 : 0;
                } else if (pattern == "max") {
                    val = 1023;
                } else if (pattern == "gradient") {
                    val = (x * 4) % 1024;
                }
                input[idx] = (pixel_t)val;
            }
        }

        std::cout << "Running " << pattern << " test (" << width << "x" << height << ")" << std::endl;

        // Process
        process_image_feedforward(input.data(), output.data(), width, height);

        // Print output
        std::cout << "\nOutput:" << std::endl;
        for (int y = 0; y < height; y++) {
            std::cout << "Row " << std::setw(2) << y << ": ";
            for (int x = 0; x < width; x++) {
                std::cout << std::setw(4) << (unsigned int)output[y * width + x] << " ";
            }
            std::cout << std::endl;
        }

    } else if (mode == "file") {
        if (argc < 3) {
            std::cout << "Specify input file" << std::endl;
            return 1;
        }

        std::vector<pixel_t> input;
        std::vector<pixel_t> output;
        int width, height;

        if (!load_image(argv[2], input, width, height)) {
            return 1;
        }

        output.resize(width * height);

        std::cout << "Processing " << width << "x" << height << " image" << std::endl;
        process_image_feedforward(input.data(), output.data(), width, height);

        // Save output
        std::string outfile = std::string(argv[2]) + ".hls_out";
        if (save_image(outfile.c_str(), output.data(), width, height)) {
            std::cout << "Saved to " << outfile << std::endl;
        }

    } else if (mode == "compare") {
        if (argc < 4) {
            std::cout << "Specify input and golden files" << std::endl;
            return 1;
        }

        std::vector<pixel_t> input, golden;
        int width, height;

        if (!load_image(argv[2], input, width, height)) {
            return 1;
        }

        // Load golden
        if (!load_image(argv[3], golden, width, height)) {
            return 1;
        }

        std::vector<pixel_t> output(width * height);
        process_image_feedforward(input.data(), output.data(), width, height);

        // Compare
        int max_diff = 0;
        int total_diff = 0;
        for (int i = 0; i < width * height; i++) {
            int diff = abs((int)output[i] - (int)golden[i]);
            if (diff > max_diff) max_diff = diff;
            total_diff += diff;
        }

        std::cout << "Comparison results:" << std::endl;
        std::cout << "  Max difference: " << max_diff << std::endl;
        std::cout << "  Avg difference: " << (double)total_diff / (width * height) << std::endl;
        std::cout << "  Status: " << (max_diff == 0 ? "PASS" : "FAIL") << std::endl;

    } else {
        std::cout << "Unknown mode: " << mode << std::endl;
        return 1;
    }

    return 0;
}
