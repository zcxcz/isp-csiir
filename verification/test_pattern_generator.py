#!/usr/bin/env python3
"""
ISP-CSIIR Test Pattern Generator

Generates test patterns for RTL verification:
- Input pixel data (random, gradient, edge patterns)
- Golden reference output from Python model

Output files (CSV format):
- input_pixels.csv: Input pixel data per frame
- golden_output.csv: Expected output from Python reference model
"""

import numpy as np
import os
import sys

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from isp_csiir_ref_model import ISPCSIIRRefModel, ISPConfig


def generate_random_pattern(height: int, width: int, seed: int = 42) -> np.ndarray:
    """Generate random pixel pattern"""
    np.random.seed(seed)
    return np.random.randint(0, 1024, (height, width), dtype=np.int32)


def generate_gradient_pattern(height: int, width: int) -> np.ndarray:
    """Generate horizontal gradient pattern"""
    img = np.zeros((height, width), dtype=np.int32)
    for i in range(width):
        img[:, i] = int(1023 * i / (width - 1))
    return img


def generate_vertical_gradient_pattern(height: int, width: int) -> np.ndarray:
    """Generate vertical gradient pattern"""
    img = np.zeros((height, width), dtype=np.int32)
    for j in range(height):
        img[j, :] = int(1023 * j / (height - 1))
    return img


def generate_edge_pattern(height: int, width: int) -> np.ndarray:
    """Generate edge pattern for testing edge detection"""
    img = np.zeros((height, width), dtype=np.int32)
    # Horizontal edges
    mid_h = height // 2
    img[:mid_h, :] = 200
    img[mid_h:, :] = 800
    return img


def generate_checkerboard_pattern(height: int, width: int, block_size: int = 8) -> np.ndarray:
    """Generate checkerboard pattern"""
    img = np.zeros((height, width), dtype=np.int32)
    for j in range(height):
        for i in range(width):
            if ((j // block_size) + (i // block_size)) % 2 == 0:
                img[j, i] = 800
            else:
                img[j, i] = 200
    return img


def generate_corner_pattern(height: int, width: int) -> np.ndarray:
    """Generate corner pattern for testing"""
    img = np.zeros((height, width), dtype=np.int32)
    img[:height//2, :width//2] = 900
    img[:height//2, width//2:] = 100
    img[height//2:, :width//2] = 100
    img[height//2:, width//2:] = 900
    return img


def write_csv(filename: str, data: np.ndarray, header: str = None):
    """Write 2D array to CSV file"""
    with open(filename, 'w') as f:
        if header:
            f.write(f"# {header}\n")
        for row in data:
            f.write(','.join(str(x) for x in row) + '\n')


def read_csv(filename: str) -> np.ndarray:
    """Read 2D array from CSV file"""
    data = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                data.append([int(x) for x in line.split(',')])
    return np.array(data, dtype=np.int32)


def generate_test_patterns(output_dir: str, height: int, width: int, num_frames: int = 2):
    """
    Generate test patterns and golden reference outputs.

    Args:
        output_dir: Directory to save pattern files
        height: Image height
        width: Image width
        num_frames: Number of test frames
    """
    os.makedirs(output_dir, exist_ok=True)

    # Configuration
    config = ISPConfig(width=width, height=height)
    model = ISPCSIIRRefModel(config)

    # Pattern generators
    patterns = [
        ("random", generate_random_pattern(height, width, seed=42)),
        ("gradient", generate_gradient_pattern(height, width)),
        ("edge", generate_edge_pattern(height, width)),
        ("checkerboard", generate_checkerboard_pattern(height, width)),
    ]

    # Generate combined input file with multiple frames
    all_inputs = []
    all_golden = []
    all_expected = []

    print(f"Generating test patterns for {height}x{width} images...")

    for frame_idx in range(num_frames):
        # Select pattern based on frame index
        pattern_name, img = patterns[frame_idx % len(patterns)]

        print(f"  Frame {frame_idx + 1}: {pattern_name} pattern")

        # Process with Python model
        result = model.process(img.astype(np.float64))

        # Store for combined output
        all_inputs.append(img)
        all_golden.append(result)

        # Flatten for testbench (raster scan order)
        flat_input = img.flatten()
        flat_golden = result.flatten()

        for pixel in flat_input:
            all_expected.append(pixel)

    # Write input pixels (one per line, for testbench $readmemh)
    input_file = os.path.join(output_dir, "input_pixels.txt")
    with open(input_file, 'w') as f:
        # No comments - $readmemh doesn't support them
        # Use 3 hex digits for 10-bit values (max 0x3FF = 1023)
        for frame_idx, img in enumerate(all_inputs):
            for row in img:
                for pixel in row:
                    f.write(f"{pixel:03x}\n")

    # Write golden output
    golden_file = os.path.join(output_dir, "golden_output.txt")
    with open(golden_file, 'w') as f:
        # No comments - $readmemh doesn't support them
        # Use 3 hex digits for 10-bit values (max 0x3FF = 1023)
        for frame_idx, result in enumerate(all_golden):
            for row in result:
                for pixel in row:
                    f.write(f"{pixel:03x}\n")

    # Write combined CSV for visualization
    combined_file = os.path.join(output_dir, "test_data.csv")
    with open(combined_file, 'w') as f:
        f.write("frame,row,col,input,golden\n")
        for frame_idx, (inp, gold) in enumerate(zip(all_inputs, all_golden)):
            for j in range(height):
                for i in range(width):
                    f.write(f"{frame_idx},{j},{i},{inp[j,i]},{gold[j,i]}\n")

    # Write metadata
    meta_file = os.path.join(output_dir, "metadata.txt")
    with open(meta_file, 'w') as f:
        f.write(f"HEIGHT={height}\n")
        f.write(f"WIDTH={width}\n")
        f.write(f"NUM_FRAMES={num_frames}\n")
        f.write(f"DATA_WIDTH=10\n")
        f.write(f"TOTAL_PIXELS={height * width * num_frames}\n")

    print(f"Files generated in {output_dir}:")
    print(f"  - input_pixels.txt: Input pixel data (hex)")
    print(f"  - golden_output.txt: Expected output (hex)")
    print(f"  - test_data.csv: Combined CSV for analysis")
    print(f"  - metadata.txt: Test configuration")

    return all_inputs, all_golden


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description='Generate ISP-CSIIR test patterns')
    parser.add_argument('--height', type=int, default=64, help='Image height')
    parser.add_argument('--width', type=int, default=64, help='Image width')
    parser.add_argument('--frames', type=int, default=2, help='Number of frames')
    parser.add_argument('--output', type=str, default='test_vectors', help='Output directory')

    args = parser.parse_args()

    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), args.output)

    generate_test_patterns(output_dir, args.height, args.width, args.frames)