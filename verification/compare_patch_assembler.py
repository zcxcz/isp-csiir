#!/usr/bin/env python3
"""
Compare forward-path patch assembler output against fixed-model forward patch stream
using fixed-model forward column stream input.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel
from compare_patch_stream import parse_patch_stream
from run_golden_verification import (
    build_default_config,
    generate_test_pattern,
    parse_int_list_arg,
    save_column_stream,
    save_patch_stream,
    write_testbench_config,
)


def run_rtl_assembler_dump(test_dir: Path) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "patch_assembler_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_patch_assembler_5x5.sv"
    rtl_dir = repo_root / "rtl"

    compile_cmd = [
        "iverilog", "-g2012",
        "-o", str(sim_path),
        "-I", str(rtl_dir),
        str(rtl_dir / "isp_csiir_patch_assembler_5x5.v"),
        str(tb_file),
    ]
    result = subprocess.run(compile_cmd, capture_output=True, text=True, cwd=repo_root)
    if result.returncode != 0:
        raise RuntimeError(f"compile failed:\n{result.stderr}")

    run_result = subprocess.run([str(sim_path)], capture_output=True, text=True, cwd=test_dir)
    if run_result.returncode != 0:
        raise RuntimeError(f"simulation failed:\n{run_result.stdout}\n{run_result.stderr}")

    if not (test_dir / "actual_patch_stream.txt").exists():
        raise RuntimeError("simulation did not produce actual_patch_stream.txt")


def main():
    parser = argparse.ArgumentParser(description="Compare patch assembler against fixed-model patch stream")
    parser.add_argument("--output", "-o", default="verification_results_patch_assembler")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--patch-center-rows", default="", help="Comma-separated center_y filters")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"patch_assembler_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    image = stimulus.reshape(args.height, args.width).astype(np.int32)
    center_rows = parse_int_list_arg(args.patch_center_rows)

    model = ISPCSIIRFixedModel(config)
    expected_patches = model.export_forward_patch_stream(image, center_rows=center_rows)
    input_columns = model.export_forward_column_stream(image, center_rows=center_rows)

    write_testbench_config(test_dir / "config.txt", config)
    save_patch_stream(expected_patches, test_dir / "expected_patch_stream.txt", data_width=config.DATA_WIDTH)
    save_column_stream(input_columns, test_dir / "input_column_stream.txt", data_width=config.DATA_WIDTH)

    try:
        run_rtl_assembler_dump(test_dir)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    actual = parse_patch_stream(test_dir / "actual_patch_stream.txt")
    total = min(len(expected_patches), len(actual))
    first_issue = None
    for idx in range(total):
        exp = expected_patches[idx]
        act = actual[idx]
        if exp["center_x"] != act["center_x"] or exp["center_y"] != act["center_y"]:
            first_issue = ("coord", idx, exp, act)
            break
        if not np.array_equal(exp["patch_u10"], act["patch_u10"]):
            first_issue = ("patch", idx, exp, act)
            break
    if first_issue is None and len(expected_patches) != len(actual):
        first_issue = ("length", total, None, None)

    print("=" * 60)
    print("Patch Assembler Compare")
    print("=" * 60)
    print(f"Expected patches: {len(expected_patches)}")
    print(f"Actual patches:   {len(actual)}")
    if first_issue is None:
        print("PASS: patch assembler matches fixed model")
        return 0

    issue_type, idx, exp, act = first_issue
    print(f"First mismatch type: {issue_type} at idx={idx}")
    if exp is not None and act is not None:
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
