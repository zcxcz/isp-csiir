//==============================================================================
// ISP-CSIIR Standalone C2C Testbench
// Compares C++ HLS model against Python fixed-point reference
// Compile: g++ -std=c++17 -O2 -Wall -o standalone_tb standalone_tb.cpp
//==============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include "isp_csiir_hls_standalone.cpp"

using namespace hls_isp_csiir;

// Image dimensions
static const int IMG_W = 64;
static const int IMG_H = 64;

// Test pattern types
enum PatternType { PAT_RANDOM, PAT_ZERO, PAT_RAMP, PAT_CHECKER, PAT_MAX };

void generate_stimulus(pixel_t img[IMG_H][IMG_W], PatternType pat) {
    switch (pat) {
        case PAT_ZERO:
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = 0;
            break;
        case PAT_MAX:
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = 1023;
            break;
        case PAT_RAMP:
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = (pixel_t)((i + j) % 1024);
            break;
        case PAT_CHECKER:
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = (((i / 4) + (j / 4)) % 2) ? 1023 : 0;
            break;
        case PAT_RANDOM:
        default:
            // Fixed seed for reproducibility
            srand(42);
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = (pixel_t)(rand() % 1024);
            break;
    }
}

void dump_image_hex(FILE* f, pixel_t img[IMG_H][IMG_W], int w, int h) {
    for (int j = 0; j < h; j++) {
        for (int i = 0; i < w; i++) {
            fprintf(f, "%03x\n", img[j][i] & 0x3FF);
        }
    }
}

void process_image_standalone(const Config& cfg,
                              const pixel_t input[IMG_H][IMG_W],
                              pixel_t output[IMG_H][IMG_W],
                              int img_w, int img_h) {
    // Process each pixel using the new process_pixel_at function
    for (int j = 0; j < img_h; j++) {
        for (int i = 0; i < img_w; i++) {
            output[j][i] = process_pixel_at(cfg, &input[0][0], img_w, img_h, i, j);
        }
    }
}

int main(int argc, char* argv[]) {
    PatternType pat = PAT_RANDOM;
    bool compare_with_file = false;
    const char* input_file = nullptr;
    const char* compare_file = nullptr;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "zero") == 0) pat = PAT_ZERO;
        else if (strcmp(argv[i], "max") == 0) pat = PAT_MAX;
        else if (strcmp(argv[i], "ramp") == 0) pat = PAT_RAMP;
        else if (strcmp(argv[i], "checker") == 0) pat = PAT_CHECKER;
        else if (strcmp(argv[i], "random") == 0) pat = PAT_RANDOM;
        else if (strcmp(argv[i], "-i") == 0 && i+1 < argc) {
            input_file = argv[++i];
        }
        else if (strcmp(argv[i], "-c") == 0 && i+1 < argc) {
            compare_file = argv[++i];
            compare_with_file = true;
        }
    }

    const char* pat_names[] = {"random", "zero", "max", "ramp", "checker"};
    printf("ISP-CSIIR Standalone C2C Testbench\n");
    printf("Pattern: %s, Image: %dx%d\n", pat_names[pat], IMG_W, IMG_H);

    Config cfg;
    cfg.img_width = IMG_W;
    cfg.img_height = IMG_H;

    // Load or generate input
    pixel_t input[IMG_H][IMG_W];
    if (input_file) {
        FILE* fin = fopen(input_file, "r");
        if (!fin) {
            printf("Error: Cannot open input file %s\n", input_file);
            return 1;
        }
        for (int j = 0; j < IMG_H; j++) {
            for (int i = 0; i < IMG_W; i++) {
                int val;
                if (fscanf(fin, "%x", &val) == 1) {
                    input[j][i] = (pixel_t)(val & 0x3FF);
                }
            }
        }
        fclose(fin);
        printf("Loaded input from %s\n", input_file);
    } else {
        generate_stimulus(input, pat);
    }

    // Process
    pixel_t output[IMG_H][IMG_W];
    process_image_standalone(cfg, input, output, IMG_W, IMG_H);

    // Dump output as hex
    FILE* f = fopen("cpp_output.hex", "w");
    if (f) {
        dump_image_hex(f, output, IMG_W, IMG_H);
        fclose(f);
        printf("Output written to cpp_output.hex\n");
    }

    // Print statistics
    int min_v = 1023, max_v = 0;
    long sum = 0;
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            min_v = std::min(min_v, (int)output[j][i]);
            max_v = std::max(max_v, (int)output[j][i]);
            sum += output[j][i];
        }
    }
    printf("Output stats: min=%d, max=%d, avg=%.2f\n", min_v, max_v, (double)sum / (IMG_W * IMG_H));

    // Dump first few rows for quick check
    printf("\nFirst 4x4 of output:\n");
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            printf("%4d", output[j][i]);
        }
        printf("\n");
    }

    // Compare with reference if requested
    if (compare_with_file && compare_file) {
        FILE* fref = fopen(compare_file, "r");
        if (!fref) {
            printf("Error: Cannot open compare file %s\n", compare_file);
            return 1;
        }
        pixel_t ref[IMG_H][IMG_W];
        for (int j = 0; j < IMG_H; j++) {
            for (int i = 0; i < IMG_W; i++) {
                int val;
                if (fscanf(fref, "%x", &val) == 1) {
                    ref[j][i] = (pixel_t)(val & 0x3FF);
                }
            }
        }
        fclose(fref);

        int max_diff = 0;
        int total_diff = 0;
        int diff_count = 0;
        for (int j = 0; j < IMG_H; j++) {
            for (int i = 0; i < IMG_W; i++) {
                int diff = (int)output[j][i] - (int)ref[j][i];
                if (diff != 0) {
                    diff_count++;
                    total_diff += std::abs(diff);
                    max_diff = std::max(max_diff, std::abs(diff));
                }
            }
        }
        printf("\n=== C++ vs Reference Comparison ===\n");
        printf("Total pixels: %d\n", IMG_W * IMG_H);
        printf("Pixels with diff: %d\n", diff_count);
        printf("Max abs diff: %d\n", max_diff);
        printf("Mean abs diff: %.2f\n", diff_count > 0 ? (double)total_diff / diff_count : 0.0);
        if (diff_count == 0) {
            printf("PASS: All outputs match!\n");
        } else {
            printf("FAIL: %d pixels differ\n", diff_count);
        }
    }

    return 0;
}
