#!/usr/bin/env python3
"""
Compare top-level stage3 input trace against fixed-model local evaluation using
the traced stage1 input patches as the compare object.
"""

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from compare_patch_stream import parse_patch_stream
from compare_stage4_patch_trace import run_rtl_stage4_trace_dump
from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import (
    build_default_config,
    generate_test_pattern,
    parse_int_list_arg,
    save_stimulus_hex,
    write_testbench_config,
)


def parse_stage3_input_trace(path: Path):
    entries = []
    current = None
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# idx="):
            if current is not None:
                entries.append(current)
            parts = dict(item.split("=") for item in line[2:].split())
            current = {
                "idx": int(parts["idx"]),
                "center_x": int(parts["center_x"]),
                "center_y": int(parts["center_y"]),
                "win_size": int(parts["win_size"]),
            }
            continue
        key, values = line.split(":", 1)
        numbers = [int(v) for v in values.strip().split()]
        if key == "g":
            current["grad_inv"] = {
                "c": numbers[0],
                "u": numbers[1],
                "d": numbers[2],
                "l": numbers[3],
                "r": numbers[4],
            }
        elif key == "avg0":
            current["avg0"] = {
                "c": numbers[0],
                "u": numbers[1],
                "d": numbers[2],
                "l": numbers[3],
                "r": numbers[4],
            }
        elif key == "avg1":
            current["avg1"] = {
                "c": numbers[0],
                "u": numbers[1],
                "d": numbers[2],
                "l": numbers[3],
                "r": numbers[4],
            }
    if current is not None:
        entries.append(current)
    return entries


def clip_center(center_x: int, center_y: int, width: int, height: int):
    return max(0, min(width - 1, int(center_x))), max(0, min(height - 1, int(center_y)))


def main():
    parser = argparse.ArgumentParser(
        description="Compare top stage3 input trace against fixed-model local evaluation from traced stage1 patches"
    )
    parser.add_argument("--output", "-o", default="verification_results_stage3_input_trace")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--patch-center-rows", default="", help="Comma-separated center_y filters")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"stage3_input_trace_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    patch_center_rows = parse_int_list_arg(args.patch_center_rows)

    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)

    try:
        run_rtl_stage4_trace_dump(test_dir, center_rows=patch_center_rows)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    model = ISPCSIIRFixedModel(config)
    stage1_patches = parse_patch_stream(test_dir / "stage1_input_patch_trace.txt")
    patch_map = {(int(entry["center_x"]), int(entry["center_y"])): entry["patch_u10"] for entry in stage1_patches}
    actual = parse_stage3_input_trace(test_dir / "stage3_input_trace.txt")

    first_issue = None
    for idx, act in enumerate(actual):
        cx = int(act["center_x"])
        cy = int(act["center_y"])
        lx, ly = clip_center(cx - 2, cy, args.width, args.height)
        rx, ry = clip_center(cx + 2, cy, args.width, args.height)
        ux, uy = clip_center(cx, cy - 1, args.width, args.height)
        dx, dy = clip_center(cx, cy + 1, args.width, args.height)

        center_patch = patch_map[(cx, cy)]
        left_patch = patch_map[(lx, ly)]
        right_patch = patch_map[(rx, ry)]
        up_patch = patch_map[(ux, uy)]
        down_patch = patch_map[(dx, dy)]

        _, _, grad_c = model._stage1_gradient(center_patch)
        _, _, grad_l = model._stage1_gradient(left_patch)
        _, _, grad_r = model._stage1_gradient(right_patch)
        _, _, grad_u = model._stage1_gradient(up_patch)
        _, _, grad_d = model._stage1_gradient(down_patch)
        win_size = model._lut_win_size(max(grad_l, grad_c, grad_r))
        stage2 = model._stage2_directional_avg(center_patch, win_size)
        stage3_state = model._stage3_blend_state(
            stage2["avg0"],
            stage2["avg1"],
            {
                "c": int(grad_c),
                "u": int(grad_u),
                "d": int(grad_d),
                "l": int(grad_l),
                "r": int(grad_r),
            },
        )
        exp = {
            "center_x": cx,
            "center_y": cy,
            "win_size": int(win_size),
            "grad_inv": {
                key: int(stage3_state["grad_inv"][key]) for key in ("c", "u", "d", "l", "r")
            },
            "avg0": {key: int(stage2["avg0"][key]) for key in ("c", "u", "d", "l", "r")},
            "avg1": {key: int(stage2["avg1"][key]) for key in ("c", "u", "d", "l", "r")},
        }
        act = actual[idx]
        for key in ("center_x", "center_y", "win_size"):
            if int(exp[key]) != int(act[key]):
                first_issue = ("meta", idx, key, exp, act)
                break
        if first_issue is not None:
            break
        for scope in ("grad_inv", "avg0", "avg1"):
            for key in ("c", "u", "d", "l", "r"):
                if int(exp[scope][key]) != int(act[scope][key]):
                    first_issue = (scope, idx, key, exp, act)
                    break
            if first_issue is not None:
                break
    print("=" * 60)
    print("Stage3 Input Trace Compare")
    print("=" * 60)
    print(f"Expected trace entries: {len(actual)}")
    print(f"Actual trace entries:   {len(actual)}")
    if first_issue is None:
        print("PASS: stage3 input trace matches fixed-model local evaluation from traced stage1 patches")
        return 0

    issue_type, idx, key, exp, act = first_issue
    print(f"First mismatch type: {issue_type} at idx={idx}")
    if issue_type == "length":
        print("Length mismatch between expected and actual traces")
        return 1

    print(f"Expected center: ({exp['center_x']}, {exp['center_y']})")
    print(f"Actual center:   ({act['center_x']}, {act['center_y']})")
    if issue_type == "meta":
        print(f"Mismatched field: {key} expected={int(exp[key])} actual={int(act[key])}")
    else:
        print(
            f"Mismatched field: {issue_type}.{key} "
            f"expected={int(exp[issue_type][key])} actual={int(act[issue_type][key])}"
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
