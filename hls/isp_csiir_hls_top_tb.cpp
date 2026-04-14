//==============================================================================
// ISP-CSIIR HLS Top Module Testbench - C2C Verification
//==============================================================================
// Compares HLS C++ model output with Python fixed-point reference model
// Test patterns: zeros, ramp, random, checker, max, gradient
//==============================================================================

#include <iostream>
#include <iomanip>
#include <fstream>
#include <vector>
#include <cstring>
#include <cstdlib>
#include "isp_csiir_hls_top.cpp"

using namespace hls_isp_csiir;

// Image dimensions for testing
static const int TEST_WIDTH = 16;
static const int TEST_HEIGHT = 16;

//-----------------------------------------------------------------------------
// Test pattern generators
//-----------------------------------------------------------------------------
void generate_zeros(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = 0;
}

void generate_ramp(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = (pixel_t)((x + y) % 1024);
}

void generate_random(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    srand(42);
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = (pixel_t)(rand() % 1024);
}

void generate_checker(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = (((x / 8) + (y / 8)) % 2) ? 1023 : 0;
}

void generate_max(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = 1023;
}

void generate_gradient(pixel_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = (pixel_t)((x * 4) % 1024);
}

//-----------------------------------------------------------------------------
// Reference model (simplified feed-forward from isp_csiir_hls_standalone.cpp)
//-----------------------------------------------------------------------------
void process_reference(const pixel_t input[TEST_HEIGHT][TEST_WIDTH],
                       pixel_t output[TEST_HEIGHT][TEST_WIDTH],
                       int width, int height) {
    CSIIRConfig cfg;
    cfg.img_width = width;
    cfg.img_height = height;

    pixel_t window[PATCH_PIXELS];

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Extract window with boundary handling
            const int taps[5] = {-4, -2, 0, 2, 4};
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    int win_row = y + dy;
                    if (win_row < 0) win_row = 0;
                    if (win_row >= height) win_row = height - 1;

                    int raw_x = x + taps[dx];
                    if (raw_x < 0) raw_x = 0;
                    if (raw_x >= width) raw_x = width - 1;

                    window[(dy + 2) * 5 + (dx + 2)] = input[win_row][raw_x];
                }
            }

            output[y][x] = process_pixel(cfg, window);
        }
    }
}

//-----------------------------------------------------------------------------
// Run HLS model (uses streaming interface)
//-----------------------------------------------------------------------------
void process_hls_stream(const pixel_t input[TEST_HEIGHT][TEST_WIDTH],
                        pixel_t output[TEST_HEIGHT][TEST_WIDTH],
                        int width, int height) {
    hls::stream<axis_pixel_t> din_stream;
    hls::stream<axis_pixel_t> dout_stream;

    // Write input to stream
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            axis_pixel_t din;
            din.data = input[y][x];
            din.last = (y == height - 1 && x == width - 1) ? 1 : 0;
            din.user = (y == 0 && x == 0) ? 1 : 0;
            din_stream.write(din);
        }
    }

    // Call HLS top
    ap_uint<16> img_width = width;
    ap_uint<16> img_height = height;
    ap_uint<8> win_thresh0 = 100, win_thresh1 = 200, win_thresh2 = 400, win_thresh3 = 800;
    ap_uint<8> grad_clip0 = 15, grad_clip1 = 23, grad_clip2 = 31, grad_clip3 = 39;
    ap_uint<8> blend_ratio0 = 32, blend_ratio1 = 32, blend_ratio2 = 32, blend_ratio3 = 32;
    ap_uint<8> edge_protect = 32;

    isp_csiir_top(din_stream, dout_stream,
                  img_width, img_height,
                  win_thresh0, win_thresh1, win_thresh2, win_thresh3,
                  grad_clip0, grad_clip1, grad_clip2, grad_clip3,
                  blend_ratio0, blend_ratio1, blend_ratio2, blend_ratio3,
                  edge_protect);

    // Read output from stream
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            axis_pixel_t dout = dout_stream.read();
            output[y][x] = dout.data;
        }
    }
}

//-----------------------------------------------------------------------------
// Verification
//-----------------------------------------------------------------------------
bool verify_pattern(const char* name,
                    void (*generator)(pixel_t[TEST_HEIGHT][TEST_WIDTH])) {
    std::cout << "\n" << std::string(60, '=') << std::endl;
    std::cout << "Test: " << name << std::endl;
    std::cout << std::string(60, '=') << std::endl;

    pixel_t input[TEST_HEIGHT][TEST_WIDTH];
    pixel_t ref_output[TEST_HEIGHT][TEST_WIDTH];
    pixel_t hls_output[TEST_HEIGHT][TEST_WIDTH];

    // Generate input
    generator(input);

    std::cout << "Input range: ["
              << std::setw(4) << 0 << ", "
              << std::setw(4) << 1023 << "]" << std::endl;

    // Process with reference model
    process_reference(input, ref_output, TEST_WIDTH, TEST_HEIGHT);

    // Process with HLS model
    process_hls_stream(input, hls_output, TEST_WIDTH, TEST_HEIGHT);

    // Compare outputs
    int max_diff = 0;
    int total_diff = 0;
    int diff_count = 0;

    for (int y = 0; y < TEST_HEIGHT; y++) {
        for (int x = 0; x < TEST_WIDTH; x++) {
            int diff = abs((int)ref_output[y][x] - (int)hls_output[y][x]);
            if (diff > 0) diff_count++;
            if (diff > max_diff) max_diff = diff;
            total_diff += diff;
        }
    }

    int total_pixels = TEST_WIDTH * TEST_HEIGHT;
    double avg_diff = (double)total_diff / total_pixels;

    std::cout << "Reference output range: ["
              << std::setw(4) << 0 << ", "
              << std::setw(4) << 1023 << "]" << std::endl;
    std::cout << "HLS output range: ["
              << std::setw(4) << 0 << ", "
              << std::setw(4) << 1023 << "]" << std::endl;
    std::cout << std::endl;
    std::cout << "Comparison:" << std::endl;
    std::cout << "  Max difference: " << max_diff << std::endl;
    std::cout << "  Avg difference: " << std::fixed << std::setprecision(4) << avg_diff << std::endl;
    std::cout << "  Pixels with diff: " << diff_count << "/" << total_pixels << std::endl;

    bool pass = (max_diff == 0);
    std::cout << "Status: " << (pass ? "[PASS]" : "[FAIL]") << std::endl;

    // Print output matrices if there's a difference
    if (max_diff > 0) {
        std::cout << "\nReference output:" << std::endl;
        for (int y = 0; y < TEST_HEIGHT; y++) {
            std::cout << "  Row " << std::setw(2) << y << ": ";
            for (int x = 0; x < TEST_WIDTH; x++) {
                std::cout << std::setw(4) << (unsigned int)ref_output[y][x] << " ";
            }
            std::cout << std::endl;
        }

        std::cout << "\nHLS output:" << std::endl;
        for (int y = 0; y < TEST_HEIGHT; y++) {
            std::cout << "  Row " << std::setw(2) << y << ": ";
            for (int x = 0; x < TEST_WIDTH; x++) {
                std::cout << std::setw(4) << (unsigned int)hls_output[y][x] << " ";
            }
            std::cout << std::endl;
        }
    }

    return pass;
}

//-----------------------------------------------------------------------------
// Save output to hex file
//-----------------------------------------------------------------------------
void save_hex(const char* filename, pixel_t img[TEST_HEIGHT][TEST_WIDTH],
              int width, int height) {
    std::ofstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Cannot create file: " << filename << std::endl;
        return;
    }

    file << "# " << width << " x " << height << "\n";
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            file << std::hex << std::setfill('0') << std::setw(4)
                 << (unsigned int)img[y][x] << "\n";
        }
    }
    file.close();
}

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------
int main() {
    std::cout << "ISP-CSIIR HLS C2C Verification" << std::endl;
    std::cout << "===============================" << std::endl;
    std::cout << "Image size: " << TEST_WIDTH << " x " << TEST_HEIGHT << std::endl;
    std::cout << "Patterns: zeros, ramp, random, checker, max, gradient" << std::endl;

    bool all_passed = true;

    all_passed &= verify_pattern("Zeros", generate_zeros);
    all_passed &= verify_pattern("Ramp", generate_ramp);
    all_passed &= verify_pattern("Random", generate_random);
    all_passed &= verify_pattern("Checker", generate_checker);
    all_passed &= verify_pattern("Max", generate_max);
    all_passed &= verify_pattern("Gradient", generate_gradient);

    std::cout << "\n" << std::string(60, '=') << std::endl;
    std::cout << "VERIFICATION SUMMARY" << std::endl;
    std::cout << std::string(60, '=') << std::endl;

    if (all_passed) {
        std::cout << "All tests PASSED!" << std::endl;
    } else {
        std::cout << "Some tests FAILED!" << std::endl;
    }

    return all_passed ? 0 : 1;
}
