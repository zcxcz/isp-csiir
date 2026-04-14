//==============================================================================
// ISP-CSIIR HLS Standalone Testbench
// Can be compiled with standard g++
//==============================================================================

#include "isp_csiir_hls_standalone.cpp"
#include <iostream>
#include <iomanip>
#include <cstdlib>

using namespace hls_isp_csiir;

static Config cfg;

// Extract 5x5 window centered at (center_x, center_y)
inline void extract_window(const pixel_t* img, int x, int y, int w, int h, pixel_t window[25]) {
    const int taps[5] = {-4, -2, 0, 2, 4};
    for (int dy = -2; dy <= 2; dy++) {
        int row = std::max(0, std::min(h - 1, y + dy));
        for (int dx = -2; dx <= 2; dx++) {
            int raw_x = std::max(0, std::min(w - 1, x + taps[dx]));
            window[dy * 5 + dx + 2] = img[row * w + raw_x];
        }
    }
}

void process_image(const pixel_t* input, pixel_t* output, int width, int height) {
    cfg.img_width = width;
    cfg.img_height = height;

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            pixel_t window[25];
            extract_window(input, x, y, width, height, window);
            output[y * width + x] = process_pixel(cfg, window);
        }
    }
}

void print_image(const char* name, const pixel_t* img, int w, int h) {
    std::cout << name << " (" << w << "x" << h << "):\n";
    for (int y = 0; y < h && y < 16; y++) {
        std::cout << "  Row " << std::setw(2) << y << ": ";
        for (int x = 0; x < w && x < 16; x++) {
            std::cout << std::setw(4) << (int)img[y * w + x] << " ";
        }
        std::cout << "\n";
    }
    if (h > 16 || w > 16) std::cout << "  ... (truncated)\n";
}

void run_test(const char* name, int width, int height, int pattern) {
    std::cout << "\n========================================\n";
    std::cout << "Test: " << name << " (" << width << "x" << height << ")\n";
    std::cout << "========================================\n";

    pixel_t* input = new pixel_t[width * height];
    pixel_t* output = new pixel_t[width * height];

    // Generate test pattern
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int val = 0;
            switch (pattern) {
                case 0: val = 0; break;
                case 1: val = (x + y) % 1024; break;
                case 2: val = (x * 17 + y * 31) % 1024; break;
                case 3: val = ((x / 8) + (y / 8)) % 2 ? 1023 : 0; break;
                case 4: val = 1023; break;
                case 5: val = (x * 4) % 1024; break;
            }
            input[y * width + x] = (pixel_t)val;
        }
    }

    print_image("Input", input, width, height);

    process_image(input, output, width, height);

    print_image("Output", output, width, height);

    // Statistics
    int min_v = 1023, max_v = 0;
    long long sum = 0;
    for (int i = 0; i < width * height; i++) {
        int v = (int)output[i];
        min_v = std::min(min_v, v);
        max_v = std::max(max_v, v);
        sum += v;
    }
    std::cout << "Stats: min=" << min_v << ", max=" << max_v
              << ", avg=" << std::fixed << std::setprecision(2) << (double)sum / (width * height) << "\n";

    delete[] input;
    delete[] output;
}

int main() {
    std::cout << "ISP-CSIIR HLS Standalone Testbench\n";
    std::cout << "==================================\n";

    // Configure
    cfg.win_size_thresh[0] = 100;
    cfg.win_size_thresh[1] = 200;
    cfg.win_size_thresh[2] = 400;
    cfg.win_size_thresh[3] = 800;
    cfg.blending_ratio[0] = 32;
    cfg.blending_ratio[1] = 32;
    cfg.blending_ratio[2] = 32;
    cfg.blending_ratio[3] = 32;
    cfg.reg_edge_protect = 32;

    // Run tests
    run_test("Zeros", 16, 16, 0);
    run_test("Ramp", 16, 16, 1);
    run_test("Random", 16, 16, 2);
    run_test("Checkerboard", 16, 16, 3);
    run_test("Max", 16, 16, 4);
    run_test("Gradient", 16, 16, 5);

    std::cout << "\n========================================\n";
    std::cout << "All tests completed!\n";
    std::cout << "========================================\n";

    return 0;
}
