//==============================================================================
// ISP-CSIIR HLS Top Module Testbench
//==============================================================================
// Tests HLS top module with simple patterns
// Optional: reads input from hex file, writes output to hex file
// Usage: ./hls_top_tb [input.hex] [output.hex] [config.json]
//==============================================================================

#include <iostream>
#include <iomanip>
#include <fstream>
#include <sstream>
#include <string>
#include <cstdlib>
#include <cstdint>
#include <cstring>
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
// Configurable parameters (can be overridden by JSON config)
//-----------------------------------------------------------------------------
struct TestConfig {
    int width = TEST_WIDTH;
    int height = TEST_HEIGHT;
    uint8_t win_thresh[4] = {100, 200, static_cast<uint8_t>(400), static_cast<uint8_t>(800)};
    uint8_t grad_clip[4] = {15, 23, 31, 39};
    uint8_t blend_ratio[4] = {32, 32, 32, 32};
    uint8_t edge_protect = 32;
};

//-----------------------------------------------------------------------------
// Load config from JSON file
//-----------------------------------------------------------------------------
bool load_config(const string& filename, TestConfig& cfg) {
    ifstream f(filename.c_str());
    if (!f.is_open()) {
        cerr << "Error: Cannot open config file: " << filename << endl;
        return false;
    }

    // Simple JSON parser for our config format
    string content((istreambuf_iterator<char>(f)), istreambuf_iterator<char>());
    f.close();

    // Parse width
    size_t pos = content.find("\"width\"");
    if (pos != string::npos) {
        pos = content.find(":", pos);
        cfg.width = atoi(content.c_str() + pos + 1);
    }
    // Parse height
    pos = content.find("\"height\"");
    if (pos != string::npos) {
        pos = content.find(":", pos);
        cfg.height = atoi(content.c_str() + pos + 1);
    }
    // Parse win_thresh array
    pos = content.find("\"win_thresh\"");
    if (pos != string::npos) {
        pos = content.find("[", pos);
        size_t end = content.find("]", pos);
        string arr = content.substr(pos + 1, end - pos - 1);
        int idx = 0;
        size_t p = 0;
        while (p < arr.size() && idx < 4) {
            while (p < arr.size() && !isdigit(arr[p])) p++;
            if (p < arr.size()) {
                cfg.win_thresh[idx++] = atoi(arr.c_str() + p);
                while (p < arr.size() && isdigit(arr[p])) p++;
            }
        }
    }
    // Parse grad_clip array
    pos = content.find("\"grad_clip\"");
    if (pos != string::npos) {
        pos = content.find("[", pos);
        size_t end = content.find("]", pos);
        string arr = content.substr(pos + 1, end - pos - 1);
        int idx = 0;
        size_t p = 0;
        while (p < arr.size() && idx < 4) {
            while (p < arr.size() && !isdigit(arr[p])) p++;
            if (p < arr.size()) {
                cfg.grad_clip[idx++] = atoi(arr.c_str() + p);
                while (p < arr.size() && isdigit(arr[p])) p++;
            }
        }
    }
    // Parse blend_ratio array
    pos = content.find("\"blend_ratio\"");
    if (pos != string::npos) {
        pos = content.find("[", pos);
        size_t end = content.find("]", pos);
        string arr = content.substr(pos + 1, end - pos - 1);
        int idx = 0;
        size_t p = 0;
        while (p < arr.size() && idx < 4) {
            while (p < arr.size() && !isdigit(arr[p])) p++;
            if (p < arr.size()) {
                cfg.blend_ratio[idx++] = atoi(arr.c_str() + p);
                while (p < arr.size() && isdigit(arr[p])) p++;
            }
        }
    }
    // Parse edge_protect
    pos = content.find("\"edge_protect\"");
    if (pos != string::npos) {
        pos = content.find(":", pos);
        cfg.edge_protect = atoi(content.c_str() + pos + 1);
    }

    return true;
}

//-----------------------------------------------------------------------------
// Process with HLS top
//-----------------------------------------------------------------------------
void process_top(const uint16_t input[TEST_HEIGHT][TEST_WIDTH],
                 uint16_t output[TEST_HEIGHT][TEST_WIDTH],
                 const TestConfig& cfg) {
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

    // Call HLS top with config parameters
    ap_uint<16> img_width = cfg.width;
    ap_uint<16> img_height = cfg.height;
    ap_uint<8> win_thresh0 = cfg.win_thresh[0], win_thresh1 = cfg.win_thresh[1];
    ap_uint<8> win_thresh2 = cfg.win_thresh[2], win_thresh3 = cfg.win_thresh[3];
    ap_uint<8> grad_clip0 = cfg.grad_clip[0], grad_clip1 = cfg.grad_clip[1];
    ap_uint<8> grad_clip2 = cfg.grad_clip[2], grad_clip3 = cfg.grad_clip[3];
    ap_uint<8> blend_ratio0 = cfg.blend_ratio[0], blend_ratio1 = cfg.blend_ratio[1];
    ap_uint<8> blend_ratio2 = cfg.blend_ratio[2], blend_ratio3 = cfg.blend_ratio[3];
    ap_uint<8> edge_protect = cfg.edge_protect;

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
    string config_file;

    // Parse arguments: [input.hex] [output.hex] [config.json]
    if (argc >= 2) {
        input_file = argv[1];
    }
    if (argc >= 3) {
        output_file = argv[2];
    }
    if (argc >= 4) {
        config_file = argv[3];
    }

    // Load config or use defaults
    TestConfig cfg;
    if (!config_file.empty()) {
        cout << "\n--- Loading config from " << config_file << " ---" << endl;
        if (!load_config(config_file, cfg)) {
            return 1;
        }
    }

    cout << "ISP-CSIIR HLS Top Test" << endl;
    cout << "======================" << endl;
    cout << "Image size: " << cfg.width << " x " << cfg.height << endl;

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
    process_top(input, output, cfg);

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
