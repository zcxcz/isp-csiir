//==============================================================================
// ISP-CSIIR Standalone Testbench
// Uses isp_csiir_hls_standalone.cpp for HLS verification
//
// Usage:
//   ./standalone_tb                        # Random pattern, 64x64
//   ./standalone_tb zero                  # Zero input
//   ./standalone_tb ramp                  # Ramp pattern
//   ./standalone_tb -i input.hex           # Load input from file
//   ./standalone_tb -o output.hex         # Save output to file
//   ./standalone_tb -c ref.hex            # Compare with reference
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

//==============================================================================
// Stimulus Generation
//==============================================================================

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
            srand(42);
            for (int j = 0; j < IMG_H; j++)
                for (int i = 0; i < IMG_W; i++)
                    img[j][i] = (pixel_t)(rand() % 1024);
            break;
    }
}

//==============================================================================
// File I/O
//==============================================================================

void load_input(const char* filename, pixel_t img[IMG_H][IMG_W]) {
    FILE* fin = fopen(filename, "r");
    if (!fin) {
        fprintf(stderr, "Error: Cannot open input file %s\n", filename);
        exit(1);
    }
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            int val;
            if (fscanf(fin, "%x", &val) == 1) {
                img[j][i] = (pixel_t)(val & 0x3FF);
            }
        }
    }
    fclose(fin);
}

void save_output(const char* filename, pixel_t img[IMG_H][IMG_W]) {
    FILE* f = fopen(filename, "w");
    if (!f) {
        fprintf(stderr, "Error: Cannot open output file %s\n", filename);
        exit(1);
    }
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            fprintf(f, "%03x\n", img[j][i] & 0x3FF);
        }
    }
    fclose(f);
}

void compare_with_reference(const char* ref_file, pixel_t img[IMG_H][IMG_W]) {
    FILE* fref = fopen(ref_file, "r");
    if (!fref) {
        fprintf(stderr, "Error: Cannot open reference file %s\n", ref_file);
        exit(1);
    }

    int max_diff = 0;
    int total_diff = 0;
    int diff_count = 0;

    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            int val;
            if (fscanf(fref, "%x", &val) == 1) {
                int ref_val = val & 0x3FF;
                int diff = (int)img[j][i] - ref_val;
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

//==============================================================================
// Main
//==============================================================================

int main(int argc, char* argv[]) {
    PatternType pat = PAT_RANDOM;
    const char* input_file = nullptr;
    const char* output_file = nullptr;
    const char* compare_file = nullptr;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "zero") == 0) pat = PAT_ZERO;
        else if (strcmp(argv[i], "max") == 0) pat = PAT_MAX;
        else if (strcmp(argv[i], "ramp") == 0) pat = PAT_RAMP;
        else if (strcmp(argv[i], "checker") == 0) pat = PAT_CHECKER;
        else if (strcmp(argv[i], "random") == 0) pat = PAT_RANDOM;
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

    const char* pat_names[] = {"random", "zero", "max", "ramp", "checker"};
    printf("ISP-CSIIR Standalone Testbench\n");
    printf("Pattern: %s, Image: %dx%d\n", pat_names[pat], IMG_W, IMG_H);

    // Setup configuration
    Config cfg;
    cfg.img_width = IMG_W;
    cfg.img_height = IMG_H;

    // Generate or load input
    pixel_t input[IMG_H][IMG_W];
    if (input_file) {
        load_input(input_file, input);
        printf("Loaded input from %s\n", input_file);
    } else {
        generate_stimulus(input, pat);
    }

    // Flatten input for process function
    pixel_t input_flat[IMG_H * IMG_W];
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            input_flat[j * IMG_W + i] = input[j][i];
        }
    }

    // Process using namespace function
    printf("Running ISP-CSIIR...\n");
    pixel_t output_flat[IMG_H * IMG_W];
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            output_flat[j * IMG_W + i] = process_pixel_at(cfg, input_flat, IMG_W, IMG_H, i, j);
        }
    }

    // Reshape output
    pixel_t output[IMG_H][IMG_W];
    for (int j = 0; j < IMG_H; j++) {
        for (int i = 0; i < IMG_W; i++) {
            output[j][i] = output_flat[j * IMG_W + i];
        }
    }

    // Save output to cpp_output.hex (always, for verification script compatibility)
    save_output("cpp_output.hex", output);
    printf("Output written to cpp_output.hex\n");

    // Also save to custom file if requested
    if (output_file) {
        save_output(output_file, output);
        printf("Output written to %s\n", output_file);
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

    // Print first 4x4 for quick check
    printf("\nFirst 4x4 of output:\n");
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            printf("%4d", output[j][i]);
        }
        printf("\n");
    }

    // Compare with reference if requested
    if (compare_file) {
        compare_with_reference(compare_file, output);
    }

    return 0;
}
