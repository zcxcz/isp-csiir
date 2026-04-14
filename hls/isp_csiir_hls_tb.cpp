//==============================================================================
// ISP-CSIIR HLS Testbench
//==============================================================================

#include "isp_csiir_hls.cpp"
#include <cstdio>
#include <cstdlib>
#include <ctime>

using namespace hls_isp_csiir;

// Image buffer for testing
static pixel_t g_image[64 * 64];
static pixel_t g_output[64 * 64];

void generate_test_image(pixel_t* img, int width, int height, int pattern) {
    for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
            int idx = j * width + i;
            int val;
            switch (pattern) {
                case 0: // Zeros
                    val = 0;
                    break;
                case 1: // Ramp
                    val = (i + j) % 1024;
                    break;
                case 2: // Random
                    val = rand() % 1024;
                    break;
                case 3: // Checkerboard
                    val = ((i / 8) + (j / 8)) % 2 ? 1023 : 0;
                    break;
                case 4: // Max
                    val = 1023;
                    break;
                case 5: // Gradient
                    val = (i * 4) % 1024;
                    break;
                default:
                    val = 0;
            }
            img[idx] = (pixel_t)val;
        }
    }
}

void print_image(const char* name, pixel_t* img, int width, int height) {
    printf("%s (%dx%d):\n", name, width, height);
    for (int j = 0; j < height && j < 16; j++) {
        printf("  Row %2d: ", j);
        for (int i = 0; i < width && i < 16; i++) {
            printf("%4d ", (int)img[j * width + i]);
        }
        printf("\n");
    }
    if (height > 16 || width > 16) {
        printf("  ... (truncated)\n");
    }
}

void extract_window_5x5(pixel_t* img, int width, int height, int center_x, int center_y, pixel_t window[25]) {
    const int taps[5] = {-4, -2, 0, 2, 4};

    for (int dy = -2; dy <= 2; dy++) {
        int row = clip(center_y + dy, 0, height - 1);
        for (int dx = -2; dx <= 2; dx++) {
            int tap_idx = dx + 2;
            int raw_x = clip(center_x + taps[dx], 0, width - 1);
            window[dy * 5 + dx + 2] = img[row * width + raw_x];
        }
    }
}

int run_standalone_test(int width, int height, int pattern, const char* pattern_name) {
    printf("\n========================================\n");
    printf("Running standalone test: %s (%dx%d)\n", pattern_name, width, height);
    printf("========================================\n");

    Config cfg;
    cfg.img_width = width;
    cfg.img_height = height;

    // Generate test image
    generate_test_image(g_image, width, height, pattern);
    printf("Input image:\n");
    print_image("Input", g_image, width, height);

    // Process image (feed-forward only, no feedback for simplicity)
    // This matches the reference model's process() behavior
    for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
            pixel_t window[25];
            extract_window_5x5(g_image, width, height, i, j, window);
            g_output[j * width + i] = process_pixel(cfg, window);
        }
    }

    printf("\nOutput image:\n");
    print_image("Output", g_output, width, height);

    // Statistics
    int min_val = 1023, max_val = 0;
    long long sum = 0;
    for (int i = 0; i < width * height; i++) {
        int v = (int)g_output[i];
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
        sum += v;
    }
    printf("\nOutput stats: min=%d, max=%d, avg=%.2f\n", min_val, max_val, (double)sum / (width * height));

    return 0;
}

int main() {
    printf("ISP-CSIIR HLS Model Testbench\n");
    printf("=============================\n");

    srand(42);  // Fixed seed for reproducibility

    // Run various tests
    run_standalone_test(16, 16, 0, "Zeros");
    run_standalone_test(16, 16, 1, "Ramp");
    run_standalone_test(16, 16, 2, "Random");
    run_standalone_test(16, 16, 3, "Checkerboard");
    run_standalone_test(16, 16, 4, "Max");
    run_standalone_test(16, 16, 5, "Gradient");

    printf("\n========================================\n");
    printf("All tests completed!\n");
    printf("========================================\n");

    return 0;
}
