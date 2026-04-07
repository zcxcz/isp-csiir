#!/usr/bin/env python3
"""
Compare RTL output with Python golden model for debugging
"""

import numpy as np
from isp_csiir_fixed_model import FixedPointConfig, ISPCSIIRFixedModel

def read_stimulus(filename):
    """Read stimulus hex file"""
    with open(filename, 'r') as f:
        lines = f.readlines()

    # Skip header
    data = []
    for line in lines:
        line = line.strip()
        if line.startswith('#'):
            continue
        if line:
            data.append(int(line, 16))

    # First two values are width and height
    width = data[0]
    height = data[1]
    pixels = data[2:]

    return width, height, np.array(pixels, dtype=np.int32).reshape(height, width)

def read_config(filename):
    """Read config file"""
    with open(filename, 'r') as f:
        values = [int(line.strip()) for line in f if line.strip()]

    return {
        'width': values[0],
        'height': values[1],
        'thresh': values[2:6],
        'ratio': values[6:10],
        'clip': values[10:14]
    }

def read_actual(filename):
    """Read RTL actual output"""
    with open(filename, 'r') as f:
        lines = f.readlines()

    data = []
    for line in lines:
        line = line.strip()
        if line.startswith('#'):
            continue
        if line:
            # Handle xxx values
            if 'x' in line.lower():
                data.append(-1)  # Mark as invalid
            else:
                data.append(int(line, 16))

    if len(data) >= 2:
        width = data[0]
        height = data[1]
        pixels = data[2:]
        return width, height, np.array(pixels, dtype=np.int32).reshape(height, width)
    return 0, 0, np.array([])

def main():
    # Read config
    config = read_config('test_config.txt')
    print(f"Config: {config['width']}x{config['height']}")
    print(f"  Thresh: {config['thresh']}")
    print(f"  Ratio: {config['ratio']}")
    print(f"  Clip: {config['clip']}")

    # Read stimulus
    width, height, stimulus = read_stimulus('test_stimulus.hex')
    print(f"\nStimulus: {width}x{height}")
    print(f"  Range: [{stimulus.min()}, {stimulus.max()}]")
    print(f"  First row: {stimulus[0, :5]}...")

    # Create model with matching config
    fp_config = FixedPointConfig(
        DATA_WIDTH=10,
        GRAD_WIDTH=14,
        IMG_WIDTH=width,
        IMG_HEIGHT=height,
        win_size_thresh=config['thresh'],
        win_size_clip_y=config['clip'],
        blending_ratio=config['ratio']
    )

    model = ISPCSIIRFixedModel(fp_config)

    # Process
    golden_output = model.process(stimulus)
    print(f"\nGolden output range: [{golden_output.min()}, {golden_output.max()}]")
    print(f"  First row: {golden_output[0, :5]}...")

    # Read RTL output
    rtl_width, rtl_height, rtl_output = read_actual('test_actual.hex')
    if rtl_width > 0:
        print(f"\nRTL output: {rtl_width}x{rtl_height}")
        # Check for invalid values
        invalid_count = np.sum(rtl_output < 0)
        if invalid_count > 0:
            print(f"  WARNING: {invalid_count} invalid (X) values!")
        valid_mask = rtl_output >= 0
        if np.any(valid_mask):
            print(f"  Valid range: [{rtl_output[valid_mask].min()}, {rtl_output[valid_mask].max()}]")
        print(f"  First row: {rtl_output[0, :5]}...")

        # Compare
        if rtl_output.shape == golden_output.shape:
            diff = np.abs(rtl_output.astype(np.int32) - golden_output.astype(np.int32))
            match_count = np.sum(diff == 0)
            total_count = diff.size
            print(f"\nComparison:")
            print(f"  Exact matches: {match_count}/{total_count} ({100*match_count/total_count:.1f}%)")
            print(f"  Max diff: {diff.max()}")
            print(f"  Mean diff: {diff.mean():.2f}")

            # Show first few differences
            print("\nFirst 10 pixel comparison:")
            for i in range(min(10, width)):
                print(f"  Pixel [{i}]: Golden={golden_output[0, i]}, RTL={rtl_output[0, i]}, Diff={diff[0, i]}")
    else:
        print("\nNo RTL output found")

if __name__ == "__main__":
    main()