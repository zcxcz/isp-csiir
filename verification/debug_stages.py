#!/usr/bin/env python3
"""
Stage-by-stage comparison between RTL and Python model
"""

import numpy as np
from isp_csiir_fixed_model import FixedPointConfig, ISPCSIIRFixedModel

def read_stimulus(filename):
    """Read stimulus hex file"""
    with open(filename, 'r') as f:
        lines = f.readlines()

    data = []
    for line in lines:
        line = line.strip()
        if line.startswith('#'):
            continue
        if line:
            data.append(int(line, 16))

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

def get_window(img, i, j):
    """Get 5x5 window with boundary replication (matching RTL)"""
    h, w = img.shape
    window = np.zeros((5, 5), dtype=np.int32)

    for dy in range(-2, 3):
        for dx in range(-2, 3):
            # Standard x boundary replication
            x = max(0, min(w - 1, i + dx))

            # RTL style y boundary handling
            if j < 2:
                # First 2 rows: all window rows replicate current row
                y = j
            else:
                # Standard boundary handling
                y = max(0, min(h - 1, j + dy))

            window[dy + 2, dx + 2] = int(img[y, x])

    return window

def stage1_gradient(win):
    """Stage 1: Gradient calculation (matching RTL)"""
    # Sobel row sums
    row0_sum = int(win[0, :].sum())
    row4_sum = int(win[4, :].sum())

    # Sobel column sums
    col0_sum = int(win[:, 0].sum())
    col4_sum = int(win[:, 4].sum())

    # Gradient (signed difference)
    grad_h_raw = row0_sum - row4_sum
    grad_v_raw = col0_sum - col4_sum

    # Absolute value
    grad_h = abs(grad_h_raw)
    grad_v = abs(grad_v_raw)

    # Combined gradient: grad = (grad_h + grad_v) * 205 >> 10 (approximates /5)
    grad_sum = grad_h + grad_v
    grad_full = grad_sum * 205
    grad_shifted = grad_full >> 10
    round_carry = (grad_full >> 9) & 1
    grad_rounded = grad_shifted + round_carry
    grad = min(grad_rounded, 16383)  # 14-bit saturation

    return grad_h, grad_v, grad

def stage2_directional_avg(win_u10):
    """Stage 2: Directional average (matching RTL)"""
    # u10 -> s11 conversion
    win_s11 = win_u10.astype(np.int32) - 512

    # Calculate directional sums
    sum_c = int(win_s11.sum())
    sum_u = int(win_s11[:3, :].sum())
    sum_d = int(win_s11[2:, :].sum())
    sum_l = int(win_s11[:, :3].sum())
    sum_r = int(win_s11[:, 2:].sum())

    # Signed division
    def signed_divide(sum_val, weight):
        if weight == 0:
            return 0
        result = sum_val // weight
        return max(-512, min(511, result))

    avg0_c = signed_divide(sum_c, 25)
    avg0_u = signed_divide(sum_u, 15)
    avg0_d = signed_divide(sum_d, 15)
    avg0_l = signed_divide(sum_l, 15)
    avg0_r = signed_divide(sum_r, 15)

    return avg0_c, avg0_u, avg0_d, avg0_l, avg0_r, sum_c, sum_u, sum_d, sum_l, sum_r

def main():
    # Read config
    config = read_config('test_config.txt')

    # Read stimulus
    width, height, stimulus = read_stimulus('test_stimulus.hex')

    print(f"=== Stage-by-stage analysis ===")
    print(f"Image: {width}x{height}")
    print(f"Stimulus range: [{stimulus.min()}, {stimulus.max()}]")

    # Process first few pixels and show intermediate values
    for j in range(min(3, height)):
        for i in range(min(5, width)):
            print(f"\n--- Pixel ({i}, {j}) ---")

            # Get window
            win = get_window(stimulus, i, j)
            center = stimulus[j, i]
            print(f"Center pixel: {center}")

            # Stage 1
            grad_h, grad_v, grad = stage1_gradient(win)
            print(f"Stage 1: grad_h={grad_h}, grad_v={grad_v}, grad={grad}")

            # Stage 2
            avg0_c, avg0_u, avg0_d, avg0_l, avg0_r, sum_c, sum_u, sum_d, sum_l, sum_r = stage2_directional_avg(win)
            print(f"Stage 2: sum_c={sum_c}, avg0_c={avg0_c}")
            print(f"         sum_u={sum_u}, avg0_u={avg0_u}")

            # Window size from gradient
            if grad < config['clip'][0]:
                win_size = 16
            elif grad < config['clip'][1]:
                win_size = 24
            elif grad < config['clip'][2]:
                win_size = 32
            else:
                win_size = 40
            print(f"Win_size: {win_size} (grad={grad}, clip={config['clip']})")

if __name__ == "__main__":
    main()