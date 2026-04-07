#!/usr/bin/env python3
"""
Complete trace from Python model perspective
"""

import numpy as np

# Config
config = {
    'width': 16,
    'height': 16,
    'thresh': [128, 256, 512, 768],
    'ratio': [32, 64, 128, 192],
    'clip': [256, 384, 512, 768]
}

# Create stimulus
def create_stimulus():
    img = np.zeros((16, 16), dtype=np.int32)
    for j in range(16):
        for i in range(16):
            img[j, i] = (j * 16 + i) * 4
    return img

stimulus = create_stimulus()

# LUT divider
def lut_divide(blend_sum, grad_sum):
    if grad_sum == 0:
        return 0

    gs = grad_sum
    if gs < 128:
        lut_index = gs
    elif gs < 256:
        lut_index = 128 + ((gs - 128) >> 1)
    elif gs < 512:
        lut_index = 160 + ((gs - 256) >> 3)
    elif gs < 1024:
        lut_index = 192 + ((gs - 512) >> 4)
    else:
        lut_index = 224 + min(((gs - 1024) >> 13), 31)

    # Calculate inverse
    inv = min((1 << 26) // max(gs, 1), 65535)

    result = (blend_sum * inv) >> 26
    return result

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

def stage1_gradient(win):
    row0_sum = win[0, :].sum()
    row4_sum = win[4, :].sum()
    col0_sum = win[:, 0].sum()
    col4_sum = win[:, 4].sum()

    grad_h = abs(row0_sum - row4_sum)
    grad_v = abs(col0_sum - col4_sum)

    grad_sum = grad_h + grad_v
    grad = (grad_sum * 205) >> 10
    round_carry = (grad_sum * 205) >> 9 & 1
    grad = grad + round_carry

    return grad_h, grad_v, min(grad, 16383)

def stage2_avg(win):
    win_s11 = win.astype(np.int32) - 512

    sum_c = win_s11.sum()
    sum_u = win_s11[:3, :].sum()
    sum_d = win_s11[2:, :].sum()
    sum_l = win_s11[:, :3].sum()
    sum_r = win_s11[:, 2:].sum()

    avg0_c = max(-512, min(511, sum_c // 25))
    avg0_u = max(-512, min(511, sum_u // 15))
    avg0_d = max(-512, min(511, sum_d // 15))
    avg0_l = max(-512, min(511, sum_l // 15))
    avg0_r = max(-512, min(511, sum_r // 15))

    return avg0_c, avg0_u, avg0_d, avg0_l, avg0_r

def stage3_fusion(avg0, grad_c, grad_u, grad_d, grad_l, grad_r):
    grads = [grad_c, grad_u, grad_d, grad_l, grad_r]
    grads_sorted = sorted(grads, reverse=True)
    grad_sum = sum(grads_sorted)

    if grad_sum == 0:
        blend0 = sum(avg0) // 5
    else:
        blend0_sum = sum(int(a) * int(g) for a, g in zip(avg0, grads_sorted))
        blend0 = lut_divide(blend0_sum, grad_sum)

    return max(-512, min(511, blend0))

def stage4_blend(blend0, blend1, avg0_u, avg1_u, win_size, center):
    # Ratio selection
    ratio_idx = (win_size // 8) - 2
    ratio_idx = max(0, min(3, ratio_idx))
    ratio = config['ratio'][ratio_idx]

    # IIR blend
    blend0_iir = (ratio * blend0 + (64 - ratio) * avg0_u) >> 6
    blend1_iir = (ratio * blend1 + (64 - ratio) * avg1_u) >> 6

    blend0_iir = max(-512, min(511, blend0_iir))
    blend1_iir = max(-512, min(511, blend1_iir))

    # Factor
    factor = max(1, min(4, win_size // 8))

    center_s11 = center - 512

    blend0_out = (blend0_iir * factor + center_s11 * (4 - factor)) >> 2
    blend1_out = (blend1_iir * factor + center_s11 * (4 - factor)) >> 2

    blend0_out = max(-512, min(511, blend0_out))
    blend1_out = max(-512, min(511, blend1_out))

    # Final
    remain = win_size % 8
    blend_final = (blend0_out * remain + blend1_out * (8 - remain)) >> 3
    blend_final = max(-512, min(511, blend_final))

    return blend_final + 512

# Simulate with delays
print("=== Simulating Python model with delays ===\n")

# Delay buffers (matching Python model)
avg0_c_delay = np.zeros(16, dtype=np.int32)
avg0_u_delay = np.zeros(16, dtype=np.int32)
avg0_d_delay = np.zeros(16, dtype=np.int32)
avg0_l_delay = np.zeros(16, dtype=np.int32)
avg0_r_delay = np.zeros(16, dtype=np.int32)
center_delay = np.zeros(16, dtype=np.int32)
win_size_delay = np.zeros(16, dtype=np.int32)

avg0_u_prev_row = np.zeros(16, dtype=np.int32)
avg1_u_prev_row = np.zeros(16, dtype=np.int32)

grad_prev_row = np.zeros(16, dtype=np.int32)
grad_curr_row = np.zeros(16, dtype=np.int32)

output = np.zeros((16, 16), dtype=np.int32)

# Process rows
for j in range(16):
    # Stage 1/2: Process current row
    curr_grad = np.zeros(16, dtype=np.int32)
    curr_avg0_c = np.zeros(16, dtype=np.int32)
    curr_avg0_u = np.zeros(16, dtype=np.int32)
    curr_avg0_d = np.zeros(16, dtype=np.int32)
    curr_avg0_l = np.zeros(16, dtype=np.int32)
    curr_avg0_r = np.zeros(16, dtype=np.int32)
    curr_center = np.zeros(16, dtype=np.int32)
    curr_win_size = np.zeros(16, dtype=np.int32)

    for i in range(16):
        win = get_window(stimulus, i, j)
        center = stimulus[j, i]

        _, _, grad = stage1_gradient(win)
        avg0_c, avg0_u, avg0_d, avg0_l, avg0_r = stage2_avg(win)

        # Win size from grad
        if grad < config['clip'][0]:
            win_size = 16
        elif grad < config['clip'][1]:
            win_size = 24
        elif grad < config['clip'][2]:
            win_size = 32
        else:
            win_size = 40

        curr_grad[i] = grad
        curr_avg0_c[i] = avg0_c
        curr_avg0_u[i] = avg0_u
        curr_avg0_d[i] = avg0_d
        curr_avg0_l[i] = avg0_l
        curr_avg0_r[i] = avg0_r
        curr_center[i] = center
        curr_win_size[i] = win_size

    # Stage 3/4: Process previous row (1-row delay)
    if j >= 1:
        for i in range(16):
            avg0_c = avg0_c_delay[i]
            avg0_u = avg0_u_delay[i]
            avg0_d = avg0_d_delay[i]
            avg0_l = avg0_l_delay[i]
            avg0_r = avg0_r_delay[i]
            center = center_delay[i]
            win_size = win_size_delay[i]

            # Gradients (with boundary handling)
            grad_u = grad_prev_row[i] if j >= 2 else grad_curr_row[i]
            grad_c = grad_curr_row[i]
            grad_d = curr_grad[i]
            grad_l = grad_c if i == 0 else grad_curr_row[i - 1]
            grad_r = grad_c

            # Stage 3 fusion
            blend0 = stage3_fusion(
                (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r),
                grad_c, grad_u, grad_d, grad_l, grad_r
            )
            blend1 = blend0  # avg1 = avg0

            # Stage 4 blend
            dout = stage4_blend(
                blend0, blend1,
                avg0_u_prev_row[i], avg1_u_prev_row[i],
                win_size, center
            )

            output[j - 1, i] = dout

            if j == 1 and i < 5:
                print(f"  Pixel ({i}, {j-1}): avg0_c={avg0_c}, avg0_u={avg0_u}, grad_c={grad_c}, grad_u={grad_u}")
                print(f"    blend0={blend0}, avg0_u_prev={avg0_u_prev_row[i]}, win_size={win_size}, center={center}")
                print(f"    dout={dout}")

    # Update delays
    avg0_c_delay = curr_avg0_c.copy()
    avg0_u_delay = curr_avg0_u.copy()
    avg0_d_delay = curr_avg0_d.copy()
    avg0_l_delay = curr_avg0_l.copy()
    avg0_r_delay = curr_avg0_r.copy()
    center_delay = curr_center.copy()
    win_size_delay = curr_win_size.copy()

    avg0_u_prev_row = avg0_u_delay.copy()
    avg1_u_prev_row = avg0_u_delay.copy()

    grad_prev_row = grad_curr_row.copy()
    grad_curr_row = curr_grad.copy()

# Last row
j = 15
for i in range(16):
    avg0_c = avg0_c_delay[i]
    avg0_u = avg0_u_delay[i]
    avg0_d = avg0_d_delay[i]
    avg0_l = avg0_l_delay[i]
    avg0_r = avg0_r_delay[i]
    center = center_delay[i]
    win_size = win_size_delay[i]

    grad_u = grad_prev_row[i]
    grad_c = grad_curr_row[i]
    grad_d = grad_c

    grad_l = grad_c if i == 0 else grad_curr_row[i - 1]
    grad_r = grad_c

    blend0 = stage3_fusion(
        (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r),
        grad_c, grad_u, grad_d, grad_l, grad_r
    )

    dout = stage4_blend(
        blend0, blend0,
        avg0_u_prev_row[i], avg1_u_prev_row[i],
        win_size, center
    )

    output[j, i] = dout

print("\n=== Output comparison ===")
print(f"First row from Python: {output[0, :5]}")
print(f"Expected from golden.hex: [123, 124, 124, 127, 130]")
print(f"RTL output: [258, 260, 262, 264, 267]")