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
    }

    // Process
    printf("Running ISP-CSIIR...\n");
    for (int j = 0; j < img_height; j++) {
        for (int i = 0; i < img_width; i++) {
            output[j * img_width + i] = process_pixel_at(cfg, input, img_width, img_height, i, j);
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

    return 0;
}
