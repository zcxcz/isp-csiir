#!/usr/bin/env python3
"""
Compare top-level stage1 input patch trace against the fixed-model delayed-feedback
stage1 input patch trace.
"""

import argparse
import sys
from pathlib import Path

import numpy as np

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


def main():
    parser = argparse.ArgumentParser(
        description="Compare top stage1 input patch trace against fixed-model delayed-feedback patch trace"
    )
    parser.add_argument("--output", "-o", default="verification_results_stage1_input_patch_trace")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--patch-center-rows", default="", help="Comma-separated center_y filters")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"stage1_input_patch_trace_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    image = stimulus.reshape(args.height, args.width).astype(np.int32)
    patch_center_rows = parse_int_list_arg(args.patch_center_rows)

    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)

    try:
        run_rtl_stage4_trace_dump(test_dir, center_rows=patch_center_rows)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    model = ISPCSIIRFixedModel(config)
    expected = model.export_stage1_input_patch_trace(image, center_rows=patch_center_rows)
    actual = parse_patch_stream(test_dir / "stage1_input_patch_trace.txt")

    total = min(len(expected), len(actual))
    first_issue = None
    for idx in range(total):
        exp = expected[idx]
        act = actual[idx]
        if exp["center_x"] != act["center_x"] or exp["center_y"] != act["center_y"]:
            first_issue = ("coord", idx, exp, act)
            break
        if not np.array_equal(exp["patch_u10"], act["patch_u10"]):
            first_issue = ("patch", idx, exp, act)
            break
    if first_issue is None and len(expected) != len(actual):
        first_issue = ("length", total, None, None)

    print("=" * 60)
    print("Stage1 Input Patch Trace Compare")
    print("=" * 60)
    print(f"Expected trace entries: {len(expected)}")
    print(f"Actual trace entries:   {len(actual)}")
    if first_issue is None:
        print("PASS: stage1 input patch trace matches fixed-model delayed-feedback trace")
        return 0

    issue_type, idx, exp, act = first_issue
    print(f"First mismatch type: {issue_type} at idx={idx}")
    if issue_type == "length":
        print("Length mismatch between expected and actual traces")
        return 1

    print(f"Expected center: ({exp['center_x']}, {exp['center_y']})")
    print(f"Actual center:   ({act['center_x']}, {act['center_y']})")
    if issue_type == "patch":
        diff = np.where(exp["patch_u10"] != act["patch_u10"])
        if len(diff[0]) > 0:
            py = int(diff[0][0])
            px = int(diff[1][0])
            print(
                f"First patch diff at row={py} col={px}: "
                f"expected={int(exp['patch_u10'][py, px])} actual={int(act['patch_u10'][py, px])}"
            )
    return 1


if __name__ == "__main__":
    sys.exit(main())
