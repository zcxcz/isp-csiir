#!/usr/bin/env python3
"""
ISP-CSIIR Verification Test Script

Compares Python reference model output with RTL simulation output.
"""

import numpy as np
import subprocess
import os
import sys
import argparse
from pathlib import Path

# Add verification directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from isp_csiir_ref_model import ISPCSIIRRefModel, ISPConfig


def generate_test_image(width: int, height: int, seed: int = 42) -> np.ndarray:
    """Generate random test image"""
    np.random.seed(seed)
    return np.random.randint(0, 1024, (height, width), dtype=np.int32)


def write_test_vector(filename: str, img: np.ndarray):
    """Write test image to file for RTL simulation"""
    height, width = img.shape
    with open(filename, 'w') as f:
        f.write(f"// Test vector: {width}x{height}\n")
        f.write(f"// Format: one pixel per line (decimal)\n")
        for j in range(height):
            for i in range(width):
                f.write(f"{img[j, i]}\n")


def read_rtl_output(filename: str, width: int, height: int) -> np.ndarray:
    """Read RTL simulation output"""
    result = np.zeros((height, width), dtype=np.int32)
    with open(filename, 'r') as f:
        lines = f.readlines()
        # Skip header comments
        data_lines = [l.strip() for l in lines if not l.startswith('//')]
        idx = 0
        for j in range(height):
            for i in range(width):
                if idx < len(data_lines):
                    result[j, i] = int(data_lines[idx])
                    idx += 1
    return result


def run_python_model(img: np.ndarray, config: ISPConfig) -> np.ndarray:
    """Run Python reference model"""
    model = ISPCSIIRRefModel(config)
    return model.process(img)


def compare_results(py_output: np.ndarray, rtl_output: np.ndarray, tolerance: int = 2) -> dict:
    """Compare Python and RTL outputs"""
    diff = np.abs(py_output.astype(np.int32) - rtl_output.astype(np.int32))

    result = {
        'total_pixels': py_output.size,
        'match_count': np.sum(diff <= tolerance),
        'mismatch_count': np.sum(diff > tolerance),
        'max_diff': int(np.max(diff)),
        'mean_diff': float(np.mean(diff)),
        'pass_rate': 0.0
    }

    result['pass_rate'] = result['match_count'] / result['total_pixels'] * 100

    return result


def main():
    parser = argparse.ArgumentParser(description='ISP-CSIIR Verification')
    parser.add_argument('--width', type=int, default=64, help='Image width')
    parser.add_argument('--height', type=int, default=64, help='Image height')
    parser.add_argument('--seed', type=int, default=42, help='Random seed')
    parser.add_argument('--tolerance', type=int, default=2, help='Pixel tolerance')
    parser.add_argument('--verbose', action='store_true', help='Verbose output')
    args = parser.parse_args()

    print("=" * 60)
    print("ISP-CSIIR Python Model vs RTL Verification")
    print("=" * 60)
    print(f"Image size: {args.width}x{args.height}")
    print(f"Random seed: {args.seed}")
    print(f"Tolerance: {args.tolerance}")
    print()

    # Create config
    config = ISPConfig(width=args.width, height=args.height)

    # Generate test image
    print("Generating test image...")
    img = generate_test_image(args.width, args.height, args.seed)

    # Run Python model
    print("Running Python reference model...")
    py_output = run_python_model(img, config)

    # Print statistics
    print(f"Python output range: [{py_output.min()}, {py_output.max()}]")
    print()

    # For RTL comparison, we need to run actual simulation
    # This is a simplified version - full verification would need
    # a proper testbench that reads input and produces output

    # Save test vectors
    test_dir = Path(__file__).parent / 'test_vectors'
    test_dir.mkdir(exist_ok=True)

    input_file = test_dir / f'input_{args.width}x{args.height}.txt'
    py_output_file = test_dir / f'python_output_{args.width}x{args.height}.txt'

    write_test_vector(str(input_file), img)
    write_test_vector(str(py_output_file), py_output)

    print(f"Test vectors saved to: {test_dir}")
    print()

    # Print sample comparison (center region)
    if args.verbose:
        print("Sample comparison (5x5 center region):")
        cy, cx = args.height // 2, args.width // 2
        for j in range(cy-2, cy+3):
            for i in range(cx-2, cx+3):
                print(f"  ({i},{j}): in={img[j,i]:4d}, py_out={py_output[j,i]:4d}")
            print()

    print("=" * 60)
    print("Python model validation complete")
    print("=" * 60)
    print()
    print("To run full RTL verification:")
    print("  1. Create a testbench that reads input from test_vectors/")
    print("  2. Run iverilog simulation")
    print("  3. Compare RTL output with python_output_*.txt")

    return 0


if __name__ == "__main__":
    sys.exit(main())