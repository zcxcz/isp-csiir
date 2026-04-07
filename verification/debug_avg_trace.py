#!/usr/bin/env python3
"""
Trace avg values through the pipeline
"""
import numpy as np

# Constants matching RTL
DATA_WIDTH = 10
SIGNED_WIDTH = 11
GRAD_WIDTH = 14

# Create stimulus
stimulus = np.zeros((16, 16), dtype=np.int32)
for j in range(16):
    for i in range(16):
        stimulus[j, i] = (j * 16 + i) * 4

print("=== First pixel (0, 0) ===")
print(f"Center: {stimulus[0, 0]}")

# Window for first pixel (with boundary replication)
def get_window(img, i, j):
    h, w = img.shape
    window = np.zeros((5, 5), dtype=np.int32)
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            if j < 2:
                y = j
            else:
                y = max(0, min(h - 1, j + dy))
            x = max(0, min(w - 1, i + dx))
            window[dy + 2, dx + 2] = int(img[y, x])
    return window

win = get_window(stimulus, 0, 0)
print(f"Window:\n{win}")

# Stage 2: Directional average
win_s11 = win.astype(np.int32) - 512
print(f"\nWindow in s11 format (first 5 pixels): {win_s11[0, :5]}")

sum_c = win_s11.sum()
sum_u = win_s11[:3, :].sum()
sum_d = win_s11[2:, :].sum()
sum_l = win_s11[:, :3].sum()
sum_r = win_s11[:, 2:].sum()

print(f"\nDirectional sums:")
print(f"  sum_c (25 pixels): {sum_c}")
print(f"  sum_u (15 pixels, top 3 rows): {sum_u}")
print(f"  sum_d (15 pixels, bottom 3 rows): {sum_d}")

avg0_c = max(-512, min(511, sum_c // 25))
avg0_u = max(-512, min(511, sum_u // 15))

print(f"\nDirectional averages:")
print(f"  avg0_c = {sum_c} // 25 = {avg0_c}")
print(f"  avg0_u = {sum_u} // 15 = {avg0_u}")

print("\n=== Expected RTL Stage 2 output ===")
print(f"  avg0_c = {avg0_c} (s11)")
print(f"  avg0_u = {avg0_u} (s11)")
print(f"  These should be passed to Stage 3")

# For Stage 3, the row delay buffer should contain:
# - When processing row 1, Stage 3 reads from buffer which has row 0's values
# - avg0_u_prev for Stage 4 should be row 0's avg0_u

print("\n=== Expected Stage 3 inputs (for row 0 output) ===")
print("  When Stage 3 outputs for row 0 (during row 1 processing):")
print(f"    avg0_c_rd = {avg0_c} (from buffer, row 0's avg0_c)")
print(f"    avg0_u_rd = {avg0_u} (from buffer, row 0's avg0_u)")
print("  This avg0_u_rd is passed to Stage 4 for IIR blend")
