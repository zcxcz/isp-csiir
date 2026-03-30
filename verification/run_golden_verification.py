#!/usr/bin/env python3
"""
ISP-CSIIR Golden Model Comparison Verification

Runs RTL simulation and compares output with Python fixed-point model.

Author: rtl-verf
Date: 2026-03-26
Version: v1.0
"""

import os
import sys
import argparse
import subprocess
import numpy as np
from pathlib import Path
from datetime import datetime

# Add verification directory to path
SCRIPT_DIR = Path(__file__).parent.absolute()
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel, FixedPointConfig


def generate_test_pattern(pattern: str, width: int, height: int, seed: int) -> np.ndarray:
    """Generate test stimulus pattern"""
    rng = np.random.default_rng(seed)
    size = width * height

    if pattern == 'random':
        return rng.integers(0, 1024, size, dtype=np.uint16)
    elif pattern == 'ramp':
        return np.mod(np.arange(size, dtype=np.uint16), 1024)
    elif pattern == 'checker':
        x = np.arange(width)
        y = np.arange(height)
        xx, yy = np.meshgrid(x, y)
        checker = (xx + yy) % 2
        return (checker * 1023).flatten().astype(np.uint16)
    elif pattern == 'gradient':
        x = np.arange(width)
        y = np.arange(height)
        xx, yy = np.meshgrid(x, y)
        gradient = (xx * 1023 // width + yy * 1023 // height) // 2
        return gradient.flatten().astype(np.uint16)
    elif pattern == 'zeros':
        return np.zeros(size, dtype=np.uint16)
    elif pattern == 'max':
        return np.full(size, 1023, dtype=np.uint16)
    else:
        return rng.integers(0, 1024, size, dtype=np.uint16)


def save_stimulus_hex(values: np.ndarray, filepath: Path, width: int, height: int):
    """Save stimulus in format expected by testbench"""
    with open(filepath, 'w') as f:
        f.write(f"# Image size: {width} x {height}\n")
        f.write(f"{width:04x}\n")
        f.write(f"{height:04x}\n")
        for v in values:
            f.write(f"{int(v) & 0x3FF:03x}\n")


def save_hex_file(values: np.ndarray, filepath: Path, width: int = 10):
    """Save values to hex file (simple format, no header)"""
    mask = (1 << width) - 1
    with open(filepath, 'w') as f:
        for v in values:
            f.write(f"{int(v) & mask:03x}\n")


def load_hex_file(filepath: Path, skip_header: bool = False) -> np.ndarray:
    """Load values from hex file"""
    values = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('#'):
                continue
            if not line:
                continue
            try:
                values.append(int(line, 16))
            except ValueError:
                continue
    # Skip header (first 2 values are width and height) if needed
    if skip_header and len(values) >= 2:
        return np.array(values[2:], dtype=np.int32)
    return np.array(values, dtype=np.int32)


def run_golden_model(stimulus: np.ndarray, config: FixedPointConfig) -> np.ndarray:
    """Run Python golden model"""
    model = ISPCSIIRFixedModel(config)
    input_2d = stimulus.reshape(config.IMG_HEIGHT, config.IMG_WIDTH)
    output_2d = model.process(input_2d)
    return output_2d.flatten()


def run_rtl_simulation(test_dir: Path, rtl_dir: Path, tb_dir: Path) -> bool:
    """Run RTL simulation using Icarus Verilog"""
    # Collect RTL files
    rtl_files = list(rtl_dir.glob("*.v"))
    rtl_files.extend(rtl_dir.glob("common/*.v"))
    rtl_files = [str(f) for f in rtl_files]

    tb_file = tb_dir / "tb_isp_csiir_random.sv"

    # Compile
    cmd = [
        "iverilog", "-g2012",
        "-o", "isp_csiir_sim",
        "-I", str(rtl_dir),
        *rtl_files,
        str(tb_file)
    ]

    print("  Compiling RTL...")
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=test_dir)

    if result.returncode != 0:
        print(f"  Compilation failed:\n{result.stderr}")
        return False

    # Run simulation
    print("  Running simulation...")
    sim_result = subprocess.run(
        ["vvp", "isp_csiir_sim"],
        capture_output=True, text=True, cwd=test_dir
    )

    if sim_result.returncode != 0:
        print(f"  Simulation error:\n{sim_result.stderr}")

    print(sim_result.stdout)
    return sim_result.returncode == 0


def compare_results(expected: np.ndarray, actual: np.ndarray, tolerance: int = 0) -> dict:
    """Compare expected and actual results"""
    min_len = min(len(expected), len(actual))
    expected = expected[:min_len]
    actual = actual[:min_len]

    diff = np.abs(expected.astype(np.int32) - actual.astype(np.int32))
    mismatches = diff > tolerance

    return {
        'total': min_len,
        'matched': int(np.sum(~mismatches)),
        'mismatched': int(np.sum(mismatches)),
        'max_diff': int(np.max(diff)),
        'mean_diff': float(np.mean(diff)),
        'mismatch_indices': np.where(mismatches)[0].tolist()[:20],
        'pass': np.sum(mismatches) == 0
    }


def main():
    parser = argparse.ArgumentParser(description='ISP-CSIIR Golden Model Verification')
    parser.add_argument('--output', '-o', default='verification_results',
                        help='Output directory')
    parser.add_argument('--pattern', '-p',
                        choices=['random', 'ramp', 'checker', 'gradient', 'zeros', 'max'],
                        default='random', help='Test pattern')
    parser.add_argument('--width', '-W', type=int, default=32,
                        help='Image width')
    parser.add_argument('--height', '-H', type=int, default=32,
                        help='Image height')
    parser.add_argument('--seed', '-s', type=int, default=42,
                        help='Random seed')
    parser.add_argument('--tolerance', '-t', type=int, default=0,
                        help='Tolerance for comparison')
    parser.add_argument('--keep', '-k', action='store_true',
                        help='Keep test directory')
    args = parser.parse_args()

    print("=" * 60)
    print("ISP-CSIIR Golden Model Verification")
    print("=" * 60)

    # Setup directories
    test_id = f"test_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    output_dir = Path(args.output)
    test_dir = output_dir / test_id
    test_dir.mkdir(parents=True, exist_ok=True)

    rtl_dir = SCRIPT_DIR.parent / "rtl"
    tb_dir = SCRIPT_DIR / "tb"

    print(f"\nTest ID: {test_id}")
    print(f"Image size: {args.width} x {args.height}")
    print(f"Pattern: {args.pattern}")
    print(f"Seed: {args.seed}")

    # Step 1: Generate stimulus
    print("\n[Step 1] Generating stimulus...")
    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    print(f"  Generated {len(stimulus)} pixels")

    # Step 2: Run Golden Model
    print("\n[Step 2] Running Python Golden Model...")
    config = FixedPointConfig(
        IMG_WIDTH=args.width,
        IMG_HEIGHT=args.height,
        win_size_thresh=[16, 24, 32, 40],
        win_size_clip_y=[400, 650, 900, 1023],
        blending_ratio=[32, 32, 32, 32]
    )

    expected = run_golden_model(stimulus, config)
    save_hex_file(expected, test_dir / "expected.hex")
    print(f"  Generated {len(expected)} expected outputs")

    # Step 3: Generate config file for testbench
    print("\n[Step 3] Generating config file...")
    with open(test_dir / "config.txt", 'w') as f:
        f.write(f"{args.width}\n")
        f.write(f"{args.height}\n")
        f.write("16\n24\n32\n40\n")  # thresh
        f.write("32\n32\n32\n32\n")  # ratio
        f.write("400\n650\n900\n1023\n")  # clip_y
    print("  Config written to config.txt")

    # Copy files to current directory for testbench
    import shutil
    shutil.copy(test_dir / "config.txt", SCRIPT_DIR / "config.txt")
    shutil.copy(test_dir / "stimulus.hex", SCRIPT_DIR / "stimulus.hex")

    # Step 4: Run RTL simulation
    print("\n[Step 4] Running RTL simulation...")

    # Compile and run with tb_isp_csiir_random.sv
    rtl_files = list(rtl_dir.glob("*.v"))
    rtl_files.extend(rtl_dir.glob("common/*.v"))
    rtl_file_strs = [str(f) for f in rtl_files]
    tb_file = tb_dir / "tb_isp_csiir_random.sv"

    # Compile
    sim_path = SCRIPT_DIR / "isp_csiir_golden_sim"
    cmd = [
        "iverilog", "-g2012",
        "-o", str(sim_path),
        "-I", str(rtl_dir),
        *rtl_file_strs,
        str(tb_file)
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, cwd=SCRIPT_DIR)
    if result.returncode != 0:
        print(f"  Compilation failed:\n{result.stderr}")
        return 1

    # Run
    sim_result = subprocess.run(
        [str(sim_path)],
        capture_output=True, text=True, cwd=SCRIPT_DIR
    )
    print(sim_result.stdout)

    if sim_result.returncode != 0:
        print(f"  Simulation failed")
        return 1

    # Step 5: Compare results
    print("\n[Step 5] Comparing results...")

    actual_path = SCRIPT_DIR / "actual.hex"
    if not actual_path.exists():
        print("  ERROR: actual.hex not found - RTL did not produce output")
        return 1

    actual = load_hex_file(actual_path, skip_header=True)
    print(f"  RTL output: {len(actual)} pixels")

    result = compare_results(expected, actual, args.tolerance)

    print("\n" + "=" * 60)
    print("Comparison Results")
    print("=" * 60)
    print(f"Total pixels:   {result['total']}")
    print(f"Matched:        {result['matched']}")
    print(f"Mismatched:     {result['mismatched']}")
    print(f"Match rate:     {100 * result['matched'] / result['total']:.2f}%")
    print(f"Max diff:       {result['max_diff']}")
    print(f"Mean diff:      {result['mean_diff']:.4f}")

    if result['mismatched'] > 0:
        print(f"\nFirst 10 mismatched indices: {result['mismatch_indices'][:10]}")

    print("=" * 60)

    if result['pass']:
        print("PASS: All outputs match golden model!")
        status = 0
    else:
        print(f"FAIL: {result['mismatched']} pixels mismatch")
        status = 1

    # Copy results to test directory
    shutil.copy(SCRIPT_DIR / "actual.hex", test_dir / "actual.hex")
    if args.keep:
        print(f"\nResults saved to: {test_dir}")
    else:
        # Clean up
        if sim_path.exists():
            sim_path.unlink()
        for f in [SCRIPT_DIR / "config.txt", SCRIPT_DIR / "stimulus.hex",
                  SCRIPT_DIR / "actual.hex", SCRIPT_DIR / "tb_isp_csiir_random.vcd"]:
            if f.exists():
                f.unlink()

    return status


if __name__ == '__main__':
    sys.exit(main())