#!/usr/bin/env python3
"""
ISP-CSIIR 定点参考模型 - 对齐 isp-csiir-ref.md 语义
"""

import numpy as np
from dataclasses import dataclass
from typing import Dict, List, Tuple


AVG_FACTOR_C_2X2 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
AVG_FACTOR_C_3X3 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
AVG_FACTOR_C_4X4 = np.array([
    [1, 1, 2, 1, 1],
    [1, 2, 4, 2, 1],
    [2, 4, 8, 4, 2],
    [1, 2, 4, 2, 1],
    [1, 1, 2, 1, 1],
], dtype=np.int32)
AVG_FACTOR_C_5X5 = np.ones((5, 5), dtype=np.int32)

AVG_MASK_U = np.array([
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
AVG_MASK_D = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
], dtype=np.int32)
AVG_MASK_L = np.array([
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
], dtype=np.int32)
AVG_MASK_R = np.array([
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
], dtype=np.int32)

HORIZONTAL_TAP_STEP = 2

BLEND_FACTOR_2X2_H = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
BLEND_FACTOR_2X2_V = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
BLEND_FACTOR_2X2 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
BLEND_FACTOR_3X3 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0],
], dtype=np.int32)
BLEND_FACTOR_4X4 = np.array([
    [1, 1, 2, 1, 1],
    [1, 2, 4, 2, 1],
    [2, 4, 8, 4, 2],
    [1, 2, 4, 2, 1],
    [1, 1, 2, 1, 1],
], dtype=np.int32)
BLEND_FACTOR_5X5 = np.ones((5, 5), dtype=np.int32)

SOBEL_X = np.array([
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [-1, -1, -1, -1, -1],
], dtype=np.int32)
SOBEL_Y = np.array([
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
], dtype=np.int32)


@dataclass
class FixedPointConfig:
    DATA_WIDTH: int = 10
    GRAD_WIDTH: int = 14
    ACC_WIDTH: int = 20
    IMG_WIDTH: int = 64
    IMG_HEIGHT: int = 64
    win_size_thresh: List[int] = None
    win_size_clip_y: List[int] = None
    win_size_clip_sft: List[int] = None
    blending_ratio: List[int] = None
    reg_edge_protect: int = 32

    def __post_init__(self):
        if self.win_size_thresh is None:
            self.win_size_thresh = [16, 24, 32, 40]
        if self.win_size_clip_y is None:
            self.win_size_clip_y = [15, 23, 31, 39]
        if self.win_size_clip_sft is None:
            self.win_size_clip_sft = [2, 2, 2, 2]
        if self.blending_ratio is None:
            self.blending_ratio = [32, 32, 32, 32]


class ISPCSIIRFixedModel:
    def __init__(self, config: FixedPointConfig = None):
        self.config = config if config else FixedPointConfig()
        self.DATA_MAX = (1 << self.config.DATA_WIDTH) - 1
        self.src_uv = None

    def _clip(self, value: int, min_val: int = 0, max_val: int = None) -> int:
        if max_val is None:
            max_val = self.DATA_MAX
        return max(min_val, min(max_val, int(value)))

    def _round_div(self, num: int, den: int) -> int:
        if den == 0:
            raise ZeroDivisionError("division by zero")
        if num >= 0:
            return (num + den // 2) // den
        return -(((-num) + den // 2) // den)

    def _u10_to_s11(self, value: int) -> int:
        return int(value) - 512

    def _s11_to_u10(self, value: int) -> int:
        return self._clip(int(value) + 512, 0, 1023)

    def _saturate_s11(self, value: int) -> int:
        return self._clip(value, -512, 511)

    def _get_window(self, img: np.ndarray, i: int, j: int) -> np.ndarray:
        h, w = img.shape
        window = np.zeros((5, 5), dtype=np.int32)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                x = self._clip(i + dx * HORIZONTAL_TAP_STEP, 0, w - 1)
                y = self._clip(j + dy, 0, h - 1)
                window[dy + 2, dx + 2] = int(img[y, x])
        return window

    def _lut_x_nodes(self) -> List[int]:
        nodes = []
        acc = 0
        for shift in self.config.win_size_clip_sft:
            acc += 1 << int(shift)
            nodes.append(acc)
        return nodes

    def _lut_win_size(self, grad_triplet_max: int) -> int:
        x_nodes = self._lut_x_nodes()
        y_nodes = self.config.win_size_clip_y
        x = int(grad_triplet_max)
        if x <= x_nodes[0]:
            win_size_grad = y_nodes[0]
        elif x >= x_nodes[-1]:
            win_size_grad = y_nodes[-1]
        else:
            win_size_grad = y_nodes[-1]
            for idx in range(len(x_nodes) - 1):
                x0, x1 = x_nodes[idx], x_nodes[idx + 1]
                if x0 <= x <= x1:
                    y0, y1 = y_nodes[idx], y_nodes[idx + 1]
                    win_size_grad = y0 + self._round_div((x - x0) * (y1 - y0), x1 - x0)
                    break
        return self._clip(win_size_grad, 16, 40)

    def _stage1_gradient(self, win: np.ndarray) -> Tuple[int, int, int]:
        grad_h = int(np.sum(win * SOBEL_X))
        grad_v = int(np.sum(win * SOBEL_Y))
        grad_h = abs(grad_h)  # Match C++ sobel_gradient_5x5 behavior
        grad_v = abs(grad_v)
        grad = self._round_div(grad_h, 5) + self._round_div(grad_v, 5)
        return grad_h, grad_v, grad

    def _grad_triplet_win_size(self, img: np.ndarray, i: int, j: int) -> Tuple[int, int, int, int, np.ndarray]:
        h, w = img.shape
        # Use unclipped center positions for window building - _get_window handles clipping internally
        # This ensures dx offsets are applied correctly before clipping, matching C++ behavior
        left_win = self._get_window(img, i - HORIZONTAL_TAP_STEP, j)
        center_win = self._get_window(img, i, j)
        right_win = self._get_window(img, i + HORIZONTAL_TAP_STEP, j)
        grad_h, grad_v, grad_c = self._stage1_gradient(center_win)
        _, _, grad_l = self._stage1_gradient(left_win)
        _, _, grad_r = self._stage1_gradient(right_win)
        win_size = self._lut_win_size(max(grad_l, grad_c, grad_r))
        return grad_h, grad_v, grad_c, win_size, center_win

    def _select_stage2_kernels(self, win_size: int) -> Tuple[np.ndarray, np.ndarray]:
        t0, t1, t2, t3 = self.config.win_size_thresh
        if win_size < t0:
            return np.zeros((5, 5), dtype=np.int32), AVG_FACTOR_C_2X2.copy()
        if win_size < t1:
            return AVG_FACTOR_C_3X3.copy(), AVG_FACTOR_C_2X2.copy()
        if win_size < t2:
            return AVG_FACTOR_C_4X4.copy(), AVG_FACTOR_C_3X3.copy()
        if win_size < t3:
            return AVG_FACTOR_C_5X5.copy(), AVG_FACTOR_C_4X4.copy()
        return AVG_FACTOR_C_5X5.copy(), np.zeros((5, 5), dtype=np.int32)

    def _weighted_avg_from_factor(self, win_s11: np.ndarray, factor: np.ndarray) -> int:
        weight = int(np.sum(factor))
        if weight == 0:
            return 0
        total = int(np.sum(win_s11 * factor))
        return self._saturate_s11(self._round_div(total, weight))

    def _build_stage2_path(self, win_s11: np.ndarray, kernel: np.ndarray) -> Dict:
        factors = {
            "c": kernel,
            "u": kernel * AVG_MASK_U,
            "d": kernel * AVG_MASK_D,
            "l": kernel * AVG_MASK_L,
            "r": kernel * AVG_MASK_R,
        }
        enable = int(np.sum(kernel)) != 0
        values = {name: self._weighted_avg_from_factor(win_s11, factor) for name, factor in factors.items()}
        return {
            "enable": enable,
            "kernel": kernel.copy(),
            "factors": {k: v.copy() for k, v in factors.items()},
            "values": values,
        }

    def _stage2_directional_avg(self, win_u10: np.ndarray, win_size: int) -> Dict:
        win_s11 = win_u10.astype(np.int32) - 512
        avg0_kernel, avg1_kernel = self._select_stage2_kernels(win_size)
        avg0_path = self._build_stage2_path(win_s11, avg0_kernel)
        avg1_path = self._build_stage2_path(win_s11, avg1_kernel)
        return {
            "avg0_enable": avg0_path["enable"],
            "avg1_enable": avg1_path["enable"],
            "avg0": avg0_path["values"],
            "avg1": avg1_path["values"],
            "avg0_kernel": avg0_path["kernel"],
            "avg1_kernel": avg1_path["kernel"],
            "avg0_factors": avg0_path["factors"],
            "avg1_factors": avg1_path["factors"],
        }

    def _stage3_neighbors(self, img: np.ndarray, i: int, j: int) -> Dict[str, int]:
        h, w = img.shape
        grad_c = self._stage1_gradient(self._get_window(img, i, j))[2]
        grad_u = self._stage1_gradient(self._get_window(img, i, self._clip(j - 1, 0, h - 1)))[2]
        grad_d = self._stage1_gradient(self._get_window(img, i, self._clip(j + 1, 0, h - 1)))[2]
        grad_l = self._stage1_gradient(self._get_window(img, self._clip(i - HORIZONTAL_TAP_STEP, 0, w - 1), j))[2]
        grad_r = self._stage1_gradient(self._get_window(img, self._clip(i + HORIZONTAL_TAP_STEP, 0, w - 1), j))[2]
        return {"c": grad_c, "u": grad_u, "d": grad_d, "l": grad_l, "r": grad_r}

    def _stage3_fusion(self, avg0: Dict[str, int], avg1: Dict[str, int], grads: Dict[str, int]) -> Tuple[int, int]:
        # g array like C++: order is u(0), d(1), l(2), r(3), c(4)
        g = [grads["u"], grads["d"], grads["l"], grads["r"], grads["c"]]

        # Bubble sort tracking original indices (same as C++ grad_inverse_remap)
        idx = list(range(5))  # [0, 1, 2, 3, 4]
        for i in range(4):
            for j in range(4 - i):
                if g[idx[j]] < g[idx[j+1]]:
                    idx[j], idx[j+1] = idx[j+1], idx[j]

        # Build inverse mapping: inv[original_idx_of_value_at_sorted_pos_i] = g_sorted[4-i]
        # Like C++: for i in 0..4: inv[idx[4-i]] = g[idx[i]]
        inv = [0, 0, 0, 0, 0]
        for i in range(5):
            inv[idx[4 - i]] = g[idx[i]]

        grad_sum = sum(inv)

        # v array order: c(0), u(1), d(2), l(3), r(4) - matches C++
        v0 = [avg0["c"], avg0["u"], avg0["d"], avg0["l"], avg0["r"]]
        v1 = [avg1["c"], avg1["u"], avg1["d"], avg1["l"], avg1["r"]]

        def blend(v: List[int]) -> int:
            if grad_sum == 0:
                return self._saturate_s11(self._round_div(sum(v), 5))
            total = sum(v[i] * inv[i] for i in range(5))
            return self._saturate_s11(self._round_div(total, grad_sum))

        return blend(v0), blend(v1)

    def _mix_scalar_with_patch(self, scalar: int, src_uv_s11_5x5: np.ndarray, factor: np.ndarray) -> np.ndarray:
        out = np.zeros((5, 5), dtype=np.int32)
        for y in range(5):
            for x in range(5):
                out[y, x] = self._saturate_s11(
                    self._round_div(int(scalar) * int(factor[y, x]) + int(src_uv_s11_5x5[y, x]) * (4 - int(factor[y, x])), 4)
                )
        return out

    def _stage4_window_blend(self, win_u10: np.ndarray, win_size: int,
                             blend0_grad: int, blend1_grad: int,
                             avg0_u: int, avg1_u: int,
                             grad_h: int, grad_v: int) -> Dict:
        src_uv_s11_5x5 = win_u10.astype(np.int32) - 512
        ratio_idx = self._clip((win_size // 8) - 2, 0, 3)
        ratio = int(self.config.blending_ratio[ratio_idx])

        blend0_hor = self._saturate_s11(self._round_div(ratio * blend0_grad + (64 - ratio) * avg0_u, 64))
        blend1_hor = self._saturate_s11(self._round_div(ratio * blend1_grad + (64 - ratio) * avg1_u, 64))

        orient_factor = BLEND_FACTOR_2X2_H if abs(grad_h) > abs(grad_v) else BLEND_FACTOR_2X2_V
        orientation = "h" if abs(grad_h) > abs(grad_v) else "v"

        t0, t1, t2, t3 = self.config.win_size_thresh
        blend0_win = None
        blend1_win = None

        if win_size < t0:
            blend10 = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, orient_factor)
            blend11 = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, BLEND_FACTOR_2X2)
            blend1_win = np.zeros((5, 5), dtype=np.int32)
            for y in range(5):
                for x in range(5):
                    blend1_win[y, x] = self._saturate_s11(
                        self._round_div(int(blend10[y, x]) * self.config.reg_edge_protect + int(blend11[y, x]) * (64 - self.config.reg_edge_protect), 64)
                    )
        elif win_size < t1:
            blend10 = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, orient_factor)
            blend11 = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, BLEND_FACTOR_2X2)
            blend1_win = np.zeros((5, 5), dtype=np.int32)
            for y in range(5):
                for x in range(5):
                    blend1_win[y, x] = self._saturate_s11(
                        self._round_div(int(blend10[y, x]) * self.config.reg_edge_protect + int(blend11[y, x]) * (64 - self.config.reg_edge_protect), 64)
                    )
            blend0_win = self._mix_scalar_with_patch(blend0_hor, src_uv_s11_5x5, BLEND_FACTOR_3X3)
        elif win_size < t2:
            blend1_win = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, BLEND_FACTOR_3X3)
            blend0_win = self._mix_scalar_with_patch(blend0_hor, src_uv_s11_5x5, BLEND_FACTOR_4X4)
        elif win_size < t3:
            blend1_win = self._mix_scalar_with_patch(blend1_hor, src_uv_s11_5x5, BLEND_FACTOR_4X4)
            blend0_win = self._mix_scalar_with_patch(blend0_hor, src_uv_s11_5x5, BLEND_FACTOR_5X5)
        else:
            blend0_win = self._mix_scalar_with_patch(blend0_hor, src_uv_s11_5x5, BLEND_FACTOR_5X5)

        remain = win_size % 8
        if win_size < t0:
            final_patch = blend1_win
        elif win_size >= t3:
            final_patch = blend0_win
        else:
            final_patch = np.zeros((5, 5), dtype=np.int32)
            for y in range(5):
                for x in range(5):
                    final_patch[y, x] = self._saturate_s11(
                        self._round_div(int(blend0_win[y, x]) * remain + int(blend1_win[y, x]) * (8 - remain), 8)
                    )

        return {
            "ratio": ratio,
            "blend0_hor": blend0_hor,
            "blend1_hor": blend1_hor,
            "orientation": orientation,
            "final_patch": final_patch,
        }

    def _process_feedback_raster(self, input_image: np.ndarray,
                                 emit_center_stream: bool = False,
                                 emit_linebuffer_rows: bool = False,
                                 emit_patch_stream: bool = False):
        src = input_image.astype(np.int32).copy()
        filt = input_image.astype(np.int32).copy()
        self.src_uv = src
        h, w = src.shape
        center_stream = [] if emit_center_stream else None
        linebuffer_rows = [] if emit_linebuffer_rows else None
        patch_stream = [] if emit_patch_stream else None

        # Gradient row buffer (matches C++ grad_row_buf[2][width])
        grad_row_buf = np.zeros((2, w), dtype=np.int32)
        grad_shift = [0, 0, 0]  # grad_shift[3] register

        for j in range(h):
            for i in range(w):
                # C++ processes ALL rows through Stage4 pipeline, but only outputs from row 2+
                # For rows 0,1: gradients are computed (for grad_row_buf to have valid data for row 2),
                # but output is not written (output[0,1] stay as original per C++ semantics)

                # Gradient/stage2/stage3: from ORIGINAL (src)
                grad_h, grad_v, grad_c, win_size, center_win = self._grad_triplet_win_size(src, i, j)
                stage2 = self._stage2_directional_avg(center_win, win_size)

                # Neighbor gradients - use grad_row_buf like C++
                # grad_u from grad_shift[1], grad_d from grad_row_buf[0][i]
                grad_u = grad_shift[1]
                grad_d = grad_row_buf[0, i]
                grad_l = self._stage1_gradient(self._get_window(src, i - HORIZONTAL_TAP_STEP, j))[2]
                grad_r = self._stage1_gradient(self._get_window(src, i + HORIZONTAL_TAP_STEP, j))[2]
                grads = {"u": grad_u, "d": grad_d, "l": grad_l, "r": grad_r, "c": grad_c}

                # Update gradient row buffer (matches C++ shift logic)
                grad_shift[0] = grad_shift[1]
                grad_shift[1] = grad_shift[2]
                grad_shift[2] = grad_c
                grad_row_buf[0, i] = grad_c
                grad_row_buf[1, i] = grad_row_buf[0, i]

                blend0_grad, blend1_grad = self._stage3_fusion(stage2["avg0"], stage2["avg1"], grads)

                # Stage4 IIR blend: rows 0-3 from filt, row 4 from src
                stage4_win = np.zeros((5, 5), dtype=np.int32)
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        x = self._clip(i + dx * HORIZONTAL_TAP_STEP, 0, w - 1)
                        y = self._clip(j + dy, 0, h - 1)
                        if dy < 0:
                            stage4_win[dy + 2, dx + 2] = filt[y, x]
                        else:
                            stage4_win[dy + 2, dx + 2] = src[y, x]

                stage4 = self._stage4_window_blend(
                    stage4_win,
                    win_size,
                    blend0_grad,
                    blend1_grad,
                    stage2["avg0"]["u"],
                    stage2["avg1"]["u"],
                    grad_h,
                    grad_v,
                )
                patch = stage4["final_patch"]

                # Write filtered center pixel back to filt (ALL rows, matches C++ behavior)
                filt[j, i] = self._s11_to_u10(int(patch[2, 2]))

                # Output only from row 2+ (matches C++ behavior: if j >= 2, output[j,i] = dout_pixel)
                if j >= 2:
                    if center_stream is not None:
                        center_stream.append(self._s11_to_u10(int(patch[2, 2])))
                    if patch_stream is not None:
                        patch_stream.append({
                            "center_x": i,
                            "center_y": j,
                            "patch_u10": np.vectorize(self._s11_to_u10)(patch).astype(np.int32),
                        })

            if linebuffer_rows is not None:
                row_indices = np.array([self._clip(j + dy, 0, h - 1) for dy in range(-2, 5)], dtype=np.int32)
                linebuffer_rows.append({
                    "after_row": j,
                    "row_indices": row_indices,
                    "rows": filt[row_indices, :].copy(),
                })

        # Output: rows 0-1 from input (boundary), rows 2+ from filt
        final_image = np.empty((h, w), dtype=np.int32)
        for j in range(min(2, h)):
            for i in range(w):
                final_image[j, i] = input_image[j, i]
        for j in range(2, h):
            for i in range(w):
                final_image[j, i] = filt[j, i]
        if center_stream is None and linebuffer_rows is None and patch_stream is None:
            return final_image
        if center_stream is not None and linebuffer_rows is None and patch_stream is None:
            return final_image, np.array(center_stream, dtype=np.int32)
        if center_stream is None and linebuffer_rows is not None and patch_stream is None:
            return final_image, linebuffer_rows
        if center_stream is None and linebuffer_rows is None and patch_stream is not None:
            return final_image, patch_stream
        if center_stream is not None and linebuffer_rows is None and patch_stream is not None:
            return final_image, np.array(center_stream, dtype=np.int32), patch_stream
        if center_stream is None and linebuffer_rows is not None and patch_stream is not None:
            return final_image, linebuffer_rows, patch_stream
        return final_image, np.array(center_stream, dtype=np.int32), linebuffer_rows, patch_stream

    def process(self, input_image: np.ndarray) -> np.ndarray:
        return self._process_feedback_raster(input_image, emit_center_stream=False)

    def process_center_stream(self, input_image: np.ndarray) -> np.ndarray:
        _, center_stream = self._process_feedback_raster(input_image, emit_center_stream=True)
        return center_stream

    def export_linebuffer_row_snapshots(self, input_image: np.ndarray):
        _, linebuffer_rows = self._process_feedback_raster(
            input_image,
            emit_center_stream=False,
            emit_linebuffer_rows=True,
        )
        return linebuffer_rows

    def export_patch_stream(self, input_image: np.ndarray):
        _, patch_stream = self._process_feedback_raster(
            input_image,
            emit_center_stream=False,
            emit_patch_stream=True,
        )
        return patch_stream


def test_fixed_model():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--width', type=int, default=64)
    parser.add_argument('--height', type=int, default=64)
    parser.add_argument('--input', type=str, default=None)
    parser.add_argument('--output', type=str, default=None)
    parser.add_argument('--compare', type=str, default=None)
    args = parser.parse_args()

    config = FixedPointConfig(IMG_WIDTH=args.width, IMG_HEIGHT=args.height)
    model = ISPCSIIRFixedModel(config)

    if args.input:
        with open(args.input) as f:
            input_vals = [int(line.strip(), 16) for line in f if line.strip()]
        input_img = np.array(input_vals, dtype=np.int32).reshape(args.height, args.width)
    else:
        np.random.seed(42)
        input_img = np.random.randint(0, 1024, (args.height, args.width), dtype=np.int32)

    output = model.process(input_img)
    print(f"输入范围: [{input_img.min()}, {input_img.max()}]")
    print(f"输出范围: [{output.min()}, {output.max()}]")
    assert output.min() >= 0
    assert output.max() <= 1023

    if args.output:
        np.savetxt(args.output, output.astype(np.int32), fmt='%03x')
        print(f"Python output written to {args.output}")

    if args.compare:
        with open(args.compare) as f:
            ref_vals = [int(line.strip(), 16) for line in f if line.strip()]
        ref = np.array(ref_vals, dtype=np.int32).reshape(args.height, args.width)
        diff = np.abs(output.astype(np.int32) - ref.astype(np.int32))
        diff_count = np.sum(diff != 0)
        max_diff = int(np.max(diff))
        mean_diff = float(np.mean(diff[diff != 0])) if diff_count > 0 else 0.0
        print(f"\n=== Python vs Reference Comparison ===")
        print(f"Total pixels: {args.width * args.height}")
        print(f"Pixels with diff: {diff_count}")
        print(f"Max abs diff: {max_diff}")
        print(f"Mean abs diff: {mean_diff:.2f}")
        if diff_count == 0:
            print("PASS: All outputs match!")
        else:
            print(f"FAIL: {diff_count} pixels differ")

    print("定点模型测试通过!")
    return output


if __name__ == "__main__":
    test_fixed_model()
