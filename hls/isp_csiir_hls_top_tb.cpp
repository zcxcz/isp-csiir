//==============================================================================
// ISP-CSIIR HLS Top Module Testbench
//==============================================================================
// Tests HLS top module with simple patterns
// Optional: reads input from hex file, writes output to hex file
// Usage: ./hls_top_tb [input.hex] [output.hex]
//==============================================================================

#include <iostream>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <string>
#include <cstdlib>
#include <cstdint>
#include "isp_csiir_hls_top.cpp"

using namespace std;
using namespace hls;

// Image dimensions (can be overridden)
#ifndef TEST_WIDTH
#define TEST_WIDTH 16
#endif
#ifndef TEST_HEIGHT
#define TEST_HEIGHT 16
#endif

//-----------------------------------------------------------------------------
// Pattern generators (used when no input file provided)
//-----------------------------------------------------------------------------
void generate_zeros(uint16_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = 0;
}

void generate_ramp(uint16_t img[TEST_HEIGHT][TEST_WIDTH]) {
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = (x + y) % 1024;
}

void generate_random(uint16_t img[TEST_HEIGHT][TEST_WIDTH]) {
    srand(42);
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++)
            img[y][x] = rand() % 1024;
}

//-----------------------------------------------------------------------------
// Load input from hex file
//-----------------------------------------------------------------------------
bool load_input(const string& filename, uint16_t img[TEST_HEIGHT][TEST_WIDTH]) {
    ifstream f(filename.c_str());
    if (!f.is_open()) {
        cerr << "Error: Cannot open input file: " << filename << endl;
        return false;
    }

    string line;
    int idx = 0;
    while (getline(f, line) && idx < TEST_WIDTH * TEST_HEIGHT) {
        // Skip empty lines and comments
        if (line.empty() || line[0] == '#' || line[0] == '/')
            continue;
        // Parse hex value
        istringstream iss(line);
        int val;
        if (iss >> hex >> val) {
            int y = idx / TEST_WIDTH;
            int x = idx % TEST_WIDTH;
            if (y < TEST_HEIGHT && x < TEST_WIDTH)
                img[y][x] = val;
            idx++;
        }
    }
    f.close();
    return true;
}

//-----------------------------------------------------------------------------
// Save output to hex file
//-----------------------------------------------------------------------------
bool save_output(const string& filename, uint16_t output[TEST_HEIGHT][TEST_WIDTH]) {
    ofstream f(filename.c_str());
    if (!f.is_open()) {
        cerr << "Error: Cannot open output file: " << filename << endl;
        return false;
    }

    for (int y = 0; y < TEST_HEIGHT; y++) {
        for (int x = 0; x < TEST_WIDTH; x++) {
            f << hex << output[y][x] << "\n";
        }
    }
    f.close();
    return true;
}

//-----------------------------------------------------------------------------
// Process with HLS top
//-----------------------------------------------------------------------------
void process_top(const uint16_t input[TEST_HEIGHT][TEST_WIDTH],
                 uint16_t output[TEST_HEIGHT][TEST_WIDTH]) {
    stream<axis_pixel_t> din_stream;
    stream<axis_pixel_t> dout_stream;

    // Write input
    for (int y = 0; y < TEST_HEIGHT; y++) {
        for (int x = 0; x < TEST_WIDTH; x++) {
            axis_pixel_t din;
            din.data = input[y][x];
            din.last = (y == TEST_HEIGHT-1 && x == TEST_WIDTH-1) ? 1 : 0;
            din.user = (y == 0 && x == 0) ? 1 : 0;
            din_stream.write(din);
        }
    }

    // Call HLS top
    ap_uint<16> img_width = TEST_WIDTH;
    ap_uint<16> img_height = TEST_HEIGHT;
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

    // Read output
    for (int y = 0; y < TEST_HEIGHT; y++) {
        for (int x = 0; x < TEST_WIDTH; x++) {
            axis_pixel_t dout = dout_stream.read();
            output[y][x] = dout.data;
        }
    }
}

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------
int main(int argc, char* argv[]) {
    string input_file;
    string output_file;

    // Parse arguments
    if (argc >= 2) {
        input_file = argv[1];
    }
    if (argc >= 3) {
        output_file = argv[2];
    }

    cout << "ISP-CSIIR HLS Top Test" << endl;
    cout << "======================" << endl;
    cout << "Image size: " << TEST_WIDTH << " x " << TEST_HEIGHT << endl;

    uint16_t input[TEST_HEIGHT][TEST_WIDTH];
    uint16_t output[TEST_HEIGHT][TEST_WIDTH];

    // Load input or generate
    if (!input_file.empty()) {
        cout << "\n--- Loading from " << input_file << " ---" << endl;
        if (!load_input(input_file, input)) {
            return 1;
        }
    } else {
        cout << "\n--- Random Pattern (built-in) ---" << endl;
        generate_random(input);
    }

    // Compute input range
    int min_in = 1024, max_in = 0;
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++) {
            min_in = min(min_in, (int)input[y][x]);
            max_in = max(max_in, (int)input[y][x]);
        }
    cout << "Input range: [" << min_in << ", " << max_in << "]" << endl;

    // Process
    process_top(input, output);

    // Compute output range
    int min_out = 1024, max_out = 0;
    for (int y = 0; y < TEST_HEIGHT; y++)
        for (int x = 0; x < TEST_WIDTH; x++) {
            min_out = min(min_out, (int)output[y][x]);
            max_out = max(max_out, (int)output[y][x]);
        }
    cout << "Output range: [" << min_out << ", " << max_out << "]" << endl;

    cout << "\nFirst 4x4 of output:" << endl;
    for (int y = 0; y < 4; y++) {
        cout << "  Row " << y << ": ";
        for (int x = 0; x < 4; x++) {
            cout << setw(4) << output[y][x] << " ";
        }
        cout << endl;
    }

    // Save output if filename provided
    if (!output_file.empty()) {
        if (save_output(output_file, output)) {
            cout << "\nOutput written to: " << output_file << endl;
        }
    }

    cout << "\nTest completed!" << endl;
    return 0;
}
