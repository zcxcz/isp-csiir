#!/usr/bin/env python3
import argparse
import inspect
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import FixedPointConfig, ISPCSIIRFixedModel
from run_golden_verification import generate_test_pattern

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
AVG_FACTOR_C_5X5 = np.array([
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
], dtype=np.int32)
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
    [1, 2, 2, 2, 1],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [1, 2, 2, 2, 1],
], dtype=np.int32)
BLEND_FACTOR_5X5 = np.full((5, 5), 4, dtype=np.int32)
HORIZONTAL_TAP_STEP = 2
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


def _round_div(num: int, den: int) -> int:
    if den == 0:
        raise ZeroDivisionError("division by zero")
    if num >= 0:
        return (num + den // 2) // den
    return -(((-num) + den // 2) // den)


def _clip(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, int(value)))


def _window(img: np.ndarray, x: int, y: int) -> np.ndarray:
    h, w = img.shape
    out = np.zeros((5, 5), dtype=np.int32)
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            xx = _clip(x + dx * HORIZONTAL_TAP_STEP, 0, w - 1)
            yy = _clip(y + dy, 0, h - 1)
            out[dy + 2, dx + 2] = int(img[yy, xx])
    return out


def _stage1_gradients(img: np.ndarray, x: int, y: int) -> dict:
    win = _window(img, x, y)
    grad_h = int(np.sum(win * SOBEL_X))
    grad_v = int(np.sum(win * SOBEL_Y))
    grad = _round_div(abs(grad_h), 5) + _round_div(abs(grad_v), 5)
    return {"grad_h": grad_h, "grad_v": grad_v, "grad": grad, "win": win}


def _lut_x_nodes(cfg: FixedPointConfig):
    x_nodes = []
    acc = 0
    for shift in cfg.win_size_clip_sft:
        acc += 1 << int(shift)
        x_nodes.append(acc)
    return x_nodes


def _win_size_from_grad_triplet(g_left: int, g_center: int, g_right: int, cfg: FixedPointConfig) -> int:
    x = max(g_left, g_center, g_right)
    x_nodes = _lut_x_nodes(cfg)
    y_nodes = cfg.win_size_clip_y
    if x <= x_nodes[0]:
        raw = y_nodes[0]
    elif x >= x_nodes[-1]:
        raw = y_nodes[-1]
    else:
        raw = y_nodes[-1]
        for idx in range(len(x_nodes) - 1):
            x0, x1 = x_nodes[idx], x_nodes[idx + 1]
            if x0 <= x <= x1:
                y0, y1 = y_nodes[idx], y_nodes[idx + 1]
                raw = y0 + _round_div((x - x0) * (y1 - y0), x1 - x0)
                break
    return _clip(raw, 16, 40)


def _select_kernels(win_size: int, cfg: FixedPointConfig):
    t0, t1, t2, t3 = cfg.win_size_thresh
    if win_size < t0:
        avg0_c = np.zeros((5, 5), dtype=np.int32)
        avg1_c = AVG_FACTOR_C_2X2.copy()
    elif win_size < t1:
        avg0_c = AVG_FACTOR_C_3X3.copy()
        avg1_c = AVG_FACTOR_C_2X2.copy()
    elif win_size < t2:
        avg0_c = AVG_FACTOR_C_4X4.copy()
        avg1_c = AVG_FACTOR_C_3X3.copy()
    elif win_size < t3:
        avg0_c = AVG_FACTOR_C_5X5.copy()
        avg1_c = AVG_FACTOR_C_4X4.copy()
    else:
        avg0_c = AVG_FACTOR_C_5X5.copy()
        avg1_c = np.zeros((5, 5), dtype=np.int32)
    return avg0_c, avg1_c


def _weighted_signed_avg(win_s11: np.ndarray, factor: np.ndarray):
    weight = int(np.sum(factor))
    enabled = weight != 0
    if not enabled:
        return 0
    total = int(np.sum(win_s11 * factor))
    return _clip(_round_div(total, weight), -512, 511)


def ref_stage2(window_u10: np.ndarray, win_size: int, cfg: FixedPointConfig):
    win_s11 = window_u10.astype(np.int32) - 512
    avg0_c, avg1_c = _select_kernels(win_size, cfg)
    paths = {}
    for name, kernel in (("avg0", avg0_c), ("avg1", avg1_c)):
        factors = {
            "c": kernel,
            "u": kernel * AVG_MASK_U,
            "d": kernel * AVG_MASK_D,
            "l": kernel * AVG_MASK_L,
            "r": kernel * AVG_MASK_R,
        }
        enable = int(np.sum(kernel)) != 0
        values = {dir_name: _weighted_signed_avg(win_s11, factor) for dir_name, factor in factors.items()}
        paths[name] = {"enable": enable, "values": values, "kernel": kernel, "factors": factors}
    return paths


def ref_stage3(avg0_values, avg1_values, grads):
    pairs = [("u", grads["u"]), ("d", grads["d"]), ("l", grads["l"]), ("r", grads["r"]), ("c", grads["c"])]
    sorted_pairs = sorted(pairs, key=lambda item: item[1], reverse=True)
    grad_inv = {}
    for idx, (dir_name, _) in enumerate(sorted_pairs):
        grad_inv[dir_name] = sorted_pairs[4 - idx][1]
    grad_sum = sum(grad_inv.values())

    def fuse(values):
        if grad_sum == 0:
            return _clip(_round_div(sum(values.values()), 5), -512, 511)
        total = sum(int(values[key]) * int(grad_inv[key]) for key in ("c", "u", "d", "l", "r"))
        return _clip(_round_div(total, grad_sum), -512, 511)

    return fuse(avg0_values), fuse(avg1_values), grad_inv, grad_sum


def ref_stage4(window_u10, win_size, blend0_grad, blend1_grad, avg0_u, avg1_u, grad_h, grad_v, cfg: FixedPointConfig):
    window_s11 = window_u10.astype(np.int32) - 512
    ratio_idx = _clip((win_size // 8) - 2, 0, 3)
    ratio = int(cfg.blending_ratio[ratio_idx])
    blend0_hor = _clip(_round_div(ratio * blend0_grad + (64 - ratio) * avg0_u, 64), -512, 511)
    blend1_hor = _clip(_round_div(ratio * blend1_grad + (64 - ratio) * avg1_u, 64), -512, 511)

    orient = BLEND_FACTOR_2X2_H if abs(grad_v) > abs(grad_h) else BLEND_FACTOR_2X2_V

    def mix_scalar_with_patch(value, factor):
        return np.vectorize(lambda src, f: _clip(_round_div(value * int(f) + int(src) * (4 - int(f)), 4), -512, 511))(window_s11, factor).astype(np.int32)

    blend0_win = None
    blend1_win = None
    t0, t1, t2, t3 = cfg.win_size_thresh
    if win_size < t0:
        blend10 = mix_scalar_with_patch(blend1_hor, orient)
        blend11 = mix_scalar_with_patch(blend1_hor, BLEND_FACTOR_2X2)
        blend1_win = np.vectorize(lambda a, b: _clip(_round_div(int(a) * cfg.reg_edge_protect + int(b) * (64 - cfg.reg_edge_protect), 64), -512, 511))(blend10, blend11).astype(np.int32)
    elif win_size < t1:
        blend10 = mix_scalar_with_patch(blend1_hor, orient)
        blend11 = mix_scalar_with_patch(blend1_hor, BLEND_FACTOR_2X2)
        blend1_win = np.vectorize(lambda a, b: _clip(_round_div(int(a) * cfg.reg_edge_protect + int(b) * (64 - cfg.reg_edge_protect), 64), -512, 511))(blend10, blend11).astype(np.int32)
        blend0_win = mix_scalar_with_patch(blend0_hor, BLEND_FACTOR_3X3)
    elif win_size < t2:
        blend1_win = mix_scalar_with_patch(blend1_hor, BLEND_FACTOR_3X3)
        blend0_win = mix_scalar_with_patch(blend0_hor, BLEND_FACTOR_4X4)
    elif win_size < t3:
        blend1_win = mix_scalar_with_patch(blend1_hor, BLEND_FACTOR_4X4)
        blend0_win = mix_scalar_with_patch(blend0_hor, BLEND_FACTOR_5X5)
    else:
        blend0_win = mix_scalar_with_patch(blend0_hor, BLEND_FACTOR_5X5)

    remain = win_size % 8
    if win_size < t0:
        final_patch = blend1_win
    elif win_size >= t3:
        final_patch = blend0_win
    else:
        final_patch = np.vectorize(lambda a, b: _clip(_round_div(int(a) * remain + int(b) * (8 - remain), 8), -512, 511))(blend0_win, blend1_win).astype(np.int32)

    return {
        "ratio": ratio,
        "blend0_hor": blend0_hor,
        "blend1_hor": blend1_hor,
        "orientation": "h" if abs(grad_v) > abs(grad_h) else "v",
        "final_patch": final_patch,
    }


def reference_process(image: np.ndarray, cfg: FixedPointConfig) -> np.ndarray:
    src = image.astype(np.int32).copy()
    h, w = src.shape
    for y in range(h):
        for x in range(w):
            g_l = _stage1_gradients(src, _clip(x - HORIZONTAL_TAP_STEP, 0, w - 1), y)["grad"]
            g_c_info = _stage1_gradients(src, x, y)
            g_r = _stage1_gradients(src, _clip(x + HORIZONTAL_TAP_STEP, 0, w - 1), y)["grad"]
            win_size = _win_size_from_grad_triplet(g_l, g_c_info["grad"], g_r, cfg)
            stage2 = ref_stage2(g_c_info["win"], win_size, cfg)

            grads = {
                "c": g_c_info["grad"],
                "u": _stage1_gradients(src, x, _clip(y - 1, 0, h - 1))["grad"],
                "d": _stage1_gradients(src, x, _clip(y + 1, 0, h - 1))["grad"],
                "l": g_l,
                "r": g_r,
            }
            blend0_grad, blend1_grad, _, _ = ref_stage3(stage2["avg0"]["values"], stage2["avg1"]["values"], grads)
            stage4 = ref_stage4(
                g_c_info["win"],
                win_size,
                blend0_grad,
                blend1_grad,
                stage2["avg0"]["values"]["u"],
                stage2["avg1"]["values"]["u"],
                g_c_info["grad_h"],
                g_c_info["grad_v"],
                cfg,
            )
            patch = stage4["final_patch"]
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    xx = _clip(x + dx, 0, w - 1)
                    yy = _clip(y + dy, 0, h - 1)
                    src[yy, xx] = _clip(int(patch[dy + 2, dx + 2]) + 512, 0, 1023)
    return src.astype(np.int32)


def normalize_stage2_result(result):
    if isinstance(result, dict):
        return result
    raise TypeError(f"Unexpected stage2 result type: {type(result).__name__}")


def fixture_stage2_split(model, cfg):
    window = np.array([
        [512, 520, 560, 620, 700],
        [512, 516, 548, 612, 676],
        [500, 508, 540, 604, 668],
        [488, 496, 528, 592, 656],
        [476, 484, 516, 580, 644],
    ], dtype=np.int32)
    win_size = 20
    expected = ref_stage2(window, win_size, cfg)
    actual = normalize_stage2_result(model._stage2_directional_avg(window, win_size))
    assert actual["avg0_enable"] is True
    assert actual["avg1_enable"] is True
    assert actual["avg0"]["c"] == expected["avg0"]["values"]["c"]
    assert actual["avg1"]["c"] == expected["avg1"]["values"]["c"]
    assert actual["avg0"]["c"] != actual["avg1"]["c"]


def fixture_stage3_direction_map(model, cfg):
    avg0 = {"c": 100, "u": 200, "d": -100, "l": 50, "r": -50}
    avg1 = {"c": -120, "u": 60, "d": 180, "l": -30, "r": 90}
    grads = {"c": 20, "u": 100, "d": 80, "l": 60, "r": 40}
    exp0, exp1, inv_map, _ = ref_stage3(avg0, avg1, grads)
    act0, act1 = model._stage3_fusion(avg0, avg1, grads)
    assert inv_map["u"] == grads["c"]
    assert inv_map["c"] == grads["u"]
    assert act0 == exp0
    assert act1 == exp1


def fixture_stage4_orientation(model, cfg):
    window = np.array([
        [400, 410, 420, 430, 440],
        [450, 460, 470, 480, 490],
        [500, 510, 520, 530, 540],
        [550, 560, 570, 580, 590],
        [600, 610, 620, 630, 640],
    ], dtype=np.int32)
    expected_h = ref_stage4(window, 18, 64, -32, 40, -20, grad_h=15, grad_v=90, cfg=cfg)
    actual_h = model._stage4_window_blend(window, 18, 64, -32, 40, -20, grad_h=15, grad_v=90)
    assert actual_h["orientation"] == "h"
    np.testing.assert_array_equal(actual_h["final_patch"], expected_h["final_patch"])
    assert actual_h["final_patch"][2, 1] != actual_h["final_patch"][1, 2]

    expected_v = ref_stage4(window, 18, 64, -32, 40, -20, grad_h=90, grad_v=15, cfg=cfg)
    actual_v = model._stage4_window_blend(window, 18, 64, -32, 40, -20, grad_h=90, grad_v=15)
    assert actual_v["orientation"] == "v"
    np.testing.assert_array_equal(actual_v["final_patch"], expected_v["final_patch"])
    assert not np.array_equal(actual_h["final_patch"], actual_v["final_patch"])


def fixture_feedback_raster(model, cfg):
    image = np.array([
        [512, 512, 512, 512, 512, 512],
        [512, 520, 520, 520, 520, 512],
        [512, 520, 900, 520, 520, 512],
        [512, 520, 520, 520, 520, 512],
        [512, 512, 512, 512, 512, 512],
        [512, 512, 512, 512, 512, 512],
    ], dtype=np.int32)
    updated = image.copy()
    x0, y0 = 2, 2
    x1, y1 = 3, 2
    original_next_window = _window(updated, x1, y1)

    g_l = _stage1_gradients(updated, _clip(x0 - 1, 0, updated.shape[1] - 1), y0)["grad"]
    g_c_info = _stage1_gradients(updated, x0, y0)
    g_r = _stage1_gradients(updated, _clip(x0 + 1, 0, updated.shape[1] - 1), y0)["grad"]
    win_size = _win_size_from_grad_triplet(g_l, g_c_info["grad"], g_r, cfg)
    stage2 = ref_stage2(g_c_info["win"], win_size, cfg)
    grads = {
        "c": g_c_info["grad"],
        "u": _stage1_gradients(updated, x0, _clip(y0 - 1, 0, updated.shape[0] - 1))["grad"],
        "d": _stage1_gradients(updated, x0, _clip(y0 + 1, 0, updated.shape[0] - 1))["grad"],
        "l": g_l,
        "r": g_r,
    }
    blend0_grad, blend1_grad, _, _ = ref_stage3(stage2["avg0"]["values"], stage2["avg1"]["values"], grads)
    stage4 = ref_stage4(
        g_c_info["win"],
        win_size,
        blend0_grad,
        blend1_grad,
        stage2["avg0"]["values"]["u"],
        stage2["avg1"]["values"]["u"],
        g_c_info["grad_h"],
        g_c_info["grad_v"],
        cfg,
    )
    patch = stage4["final_patch"]
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            xx = _clip(x0 + dx, 0, updated.shape[1] - 1)
            yy = _clip(y0 + dy, 0, updated.shape[0] - 1)
            updated[yy, xx] = _clip(int(patch[dy + 2, dx + 2]) + 512, 0, 1023)

    feedback_next_window = _window(updated, x1, y1)
    assert not np.array_equal(feedback_next_window, original_next_window)

    expected = reference_process(image, cfg)
    actual = model.process(image)
    np.testing.assert_array_equal(actual, expected)


def run_smoke(model, cfg, pattern: str, width: int, height: int):
    stimulus = generate_test_pattern(pattern, width, height, seed=123).reshape(height, width).astype(np.int32)
    expected = reference_process(stimulus, cfg)
    actual = model.process(stimulus)
    if actual.min() < 0 or actual.max() > 1023:
        raise AssertionError(f"output out of range: [{actual.min()}, {actual.max()}]")
    np.testing.assert_array_equal(actual, expected)


def main():
    parser = argparse.ArgumentParser(description="Check golden-model semantics against isp-csiir-ref.md")
    parser.add_argument("--smoke", action="store_true", help="Run end-to-end smoke comparison")
    parser.add_argument("--pattern", default="checker", choices=["random", "ramp", "checker", "gradient", "zeros", "max"])
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--height", type=int, default=32)
    args = parser.parse_args()

    cfg = FixedPointConfig(IMG_WIDTH=args.width, IMG_HEIGHT=args.height)
    model = ISPCSIIRFixedModel(cfg)

    fixtures = [
        ("fixture_stage2_split", fixture_stage2_split),
        ("fixture_stage3_direction_map", fixture_stage3_direction_map),
        ("fixture_stage4_orientation", fixture_stage4_orientation),
        ("fixture_feedback_raster", fixture_feedback_raster),
    ]

    failures = []
    for name, func in fixtures:
        try:
            func(model, cfg)
            print(f"PASS {name}")
        except Exception as exc:
            failures.append((name, exc))
            print(f"FAIL {name}: {exc}")

    if args.smoke:
        try:
            run_smoke(model, cfg, args.pattern, args.width, args.height)
            print(f"PASS smoke pattern={args.pattern} size={args.width}x{args.height}")
        except Exception as exc:
            failures.append(("smoke", exc))
            print(f"FAIL smoke: {exc}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
