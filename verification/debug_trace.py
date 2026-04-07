#!/usr/bin/env python3
"""
Detailed stage-by-stage trace for first pixel
"""

import numpy as np

# Config from test_config.txt
config = {
    'width': 16,
    'height': 16,
    'thresh': [128, 256, 512, 768],
    'ratio': [32, 64, 128, 192],
    'clip': [256, 384, 512, 768]
}

# Stimulus from sim_debug/stimulus.hex - first few rows
# 16x16 image with values 0, 4, 8, 12, ... (incrementing by 4)
def create_stimulus():
    img = np.zeros((16, 16), dtype=np.int32)
    for j in range(16):
        for i in range(16):
            img[j, i] = (j * 16 + i) * 4
    return img

stimulus = create_stimulus()

print("=== First pixel (0, 0) analysis ===")
print(f"Center pixel: {stimulus[0, 0]}")

# Get 5x5 window (with boundary replication)
def get_window(img, i, j):
    h, w = img.shape
    window = np.zeros((5, 5), dtype=np.int32)
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            # RTL style: for j < 2, all window rows replicate current row
            if j < 2:
                y = j
            else:
                y = max(0, min(h - 1, j + dy))
            x = max(0, min(w - 1, i + dx))
            window[dy + 2, dx + 2] = int(img[y, x])
    return window

win = get_window(stimulus, 0, 0)
print(f"\n5x5 window (row 0):")
print(win[0])
print(win[1])
print(win[2])
print(win[3])
print(win[4])

# Stage 1: Gradient calculation
row0_sum = win[0, :].sum()
row4_sum = win[4, :].sum()
col0_sum = win[:, 0].sum()
col4_sum = win[:, 4].sum()

print(f"\nStage 1:")
print(f"  row0_sum = {row0_sum}, row4_sum = {row4_sum}")
print(f"  col0_sum = {col0_sum}, col4_sum = {col4_sum}")

grad_h_raw = row0_sum - row4_sum
grad_v_raw = col0_sum - col4_sum
grad_h = abs(grad_h_raw)
grad_v = abs(grad_v_raw)

print(f"  grad_h_raw = {grad_h_raw}, grad_h = {grad_h}")
print(f"  grad_v_raw = {grad_v_raw}, grad_v = {grad_v}")

grad_sum = grad_h + grad_v
grad_full = grad_sum * 205
grad_shifted = grad_full >> 10
round_carry = (grad_full >> 9) & 1
grad = grad_shifted + round_carry

print(f"  grad_sum = {grad_sum}")
print(f"  grad_full = {grad_full}, shifted = {grad_shifted}, round = {round_carry}")
print(f"  final grad = {grad}")

# Window size from grad
if grad < config['clip'][0]:
    win_size = 16
elif grad < config['clip'][1]:
    win_size = 24
elif grad < config['clip'][2]:
    win_size = 32
else:
    win_size = 40
print(f"  win_size = {win_size} (grad={grad} < clip[0]={config['clip'][0]})")

# Stage 2: Directional average
# u10 -> s11 conversion
win_s11 = win.astype(np.int32) - 512
print(f"\nStage 2:")
print(f"  win_s11[0,0] = {win[0,0]} - 512 = {win_s11[0,0]}")

sum_c = win_s11.sum()
sum_u = win_s11[:3, :].sum()  # Top 3 rows
sum_d = win_s11[2:, :].sum()  # Bottom 3 rows
sum_l = win_s11[:, :3].sum()  # Left 3 columns
sum_r = win_s11[:, 2:].sum()  # Right 3 columns

print(f"  sum_c = {sum_c} (25 pixels)")
print(f"  sum_u = {sum_u} (top 3 rows = 15 pixels)")
print(f"  sum_d = {sum_d} (bottom 3 rows = 15 pixels)")
print(f"  sum_l = {sum_l} (left 3 cols = 15 pixels)")
print(f"  sum_r = {sum_r} (right 3 cols = 15 pixels)")

# Division
avg0_c = sum_c // 25
avg0_u = sum_u // 15
avg0_d = sum_d // 15
avg0_l = sum_l // 15
avg0_r = sum_r // 15

print(f"  avg0_c = {sum_c} // 25 = {avg0_c}")
print(f"  avg0_u = {sum_u} // 15 = {avg0_u}")
print(f"  avg0_d = {sum_d} // 15 = {avg0_d}")
print(f"  avg0_l = {sum_l} // 15 = {avg0_l}")
print(f"  avg0_r = {sum_r} // 15 = {avg0_r}")

# Stage 3: Gradient fusion
# For first pixel, gradients:
# grad_c = grad from current row = grad = 8
# grad_u = grad from previous row (boundary) = grad_c = 8
# grad_d = grad from next row (need to calculate)
# grad_l = grad from left neighbor (boundary) = grad_c
# grad_r = grad from right neighbor (simplified) = grad_c

print(f"\nStage 3 (1-row delay):")
print(f"  For pixel (0, 0), Stage 3 processes the DELAYED data from row -1")
print(f"  Since row -1 doesn't exist, Stage 3 outputs row 0's data on row 1")
print(f"  When processing pixel (0, 1), Stage 3 outputs the blend for (0, 0)")

# The key insight: Stage 3 has a 1-row delay
# So when RTL outputs for pixel (0, 0), it's using avg0_u from the PREVIOUS row's buffer
# For the first row, avg0_u buffer was filled with zeros (initial state)

# Let's trace what happens for pixel (0, 1) which outputs for (0, 0):
print(f"\n  When Stage 2 processes pixel (0, 1):")
win_1 = get_window(stimulus, 0, 1)
win_s11_1 = win_1.astype(np.int32) - 512
sum_c_1 = win_s11_1.sum()
sum_u_1 = win_s11_1[:3, :].sum()
avg0_c_1 = sum_c_1 // 25
avg0_u_1 = sum_u_1 // 15

print(f"    avg0_c(0,1) = {avg0_c_1}, avg0_u(0,1) = {avg0_u_1}")
print(f"    These are written to row delay buffer for next cycle")

# Stage 3 reads from previous buffer position
# For pixel (0, 0): avg0_c_rd, avg0_u_rd come from the buffer
# But buffer was initialized to 0!

print(f"\n  For Stage 3 processing pixel (0, 0):")
print(f"    avg0_c_rd comes from buffer position 0")
print(f"    avg0_u_rd comes from buffer position 0")
print(f"    Buffer was initialized to 0, so avg0_u_rd = 0")

# Stage 4: IIR blend
print(f"\nStage 4 (IIR blend):")
print(f"  blend0 = blend1 = 0 (from Stage 3 for first row)")
print(f"  avg0_u = 0 (from buffer)")
print(f"  win_size = {win_size}")
print(f"  ratio = {config['ratio'][0]} (win_size < 24)")
print(f"  center = {stimulus[0, 0]}")

# IIR blend formula
ratio = config['ratio'][0]
blend0 = 0  # From Stage 3
blend1 = 0
avg0_u_prev = 0  # From buffer

# IIR mixing
blend0_iir = (ratio * blend0 + (64 - ratio) * avg0_u_prev) >> 6
blend1_iir = (ratio * blend1 + (64 - ratio) * avg0_u_prev) >> 6
print(f"  blend0_iir = ({ratio} * {blend0} + {64-ratio} * {avg0_u_prev}) >> 6 = {blend0_iir}")

# Window mixing
factor = max(1, min(4, win_size // 8))
center_s11 = stimulus[0, 0] - 512
blend0_out = (blend0_iir * factor + center_s11 * (4 - factor)) >> 2
blend1_out = (blend1_iir * factor + center_s11 * (4 - factor)) >> 2
print(f"  factor = {factor}")
print(f"  center_s11 = {center_s11}")
print(f"  blend0_out = ({blend0_iir} * {factor} + {center_s11} * {4-factor}) >> 2 = {blend0_out}")

# Final mixing
remain = win_size % 8
blend_final_s11 = (blend0_out * remain + blend1_out * (8 - remain)) >> 3
print(f"  remain = {remain}")
print(f"  blend_final_s11 = ({blend0_out} * {remain} + {blend1_out} * {8-remain}) >> 3 = {blend_final_s11}")

# s11 -> u10
dout = blend_final_s11 + 512
dout = max(0, min(1023, dout))
print(f"  dout = {blend_final_s11} + 512 = {dout}")

print(f"\n  Expected from Python model: 123")
print(f"  RTL output from actual.hex: 258")
print(f"\n  DIFFERENCE: RTL is {258 - 123} higher!")

print("\n=== Analysis ===")
print("The RTL output is much higher than expected.")
print("This suggests either:")
print("1. The avg0_u buffer is not being initialized/used correctly")
print("2. The blend calculation is wrong")
print("3. There's a mismatch in the pipeline delay logic")