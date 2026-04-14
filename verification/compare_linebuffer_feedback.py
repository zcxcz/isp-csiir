#!/usr/bin/env python3
"""
Compare linebuffer_core feedback row snapshots against fixed-model delayed-
feedback snapshots using fixed-model patch stream as the feedback stimulus.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from compare_linebuffer_rows import parse_snapshot_file
from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import (
    build_default_config,
    derive_sim_timeout_seconds,
    generate_test_pattern,
    parse_int_list_arg,
    run_command_with_timeout,
    save_linebuffer_row_snapshots,
    save_patch_stream,
    save_stimulus_hex,
    write_int_filter_file,
    write_testbench_config,
)


def run_rtl_linebuffer_feedback_dump(test_dir: Path, after_rows=None, timeout_sec: int = 30) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "linebuffer_feedback_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_linebuffer_feedback.sv"
    rtl_dir = repo_root / "rtl"

    write_int_filter_file(after_rows, test_dir / "linebuffer_after_rows.txt")

    compile_cmd = [
        "iverilog", "-g2012",
        "-o", str(sim_path),
        "-I", str(rtl_dir),
        str(rtl_dir / "isp_csiir_linebuffer_core.v"),
        str(tb_file),
    ]
    result = subprocess.run(compile_cmd, capture_output=True, text=True, cwd=repo_root)
    if result.returncode != 0:
        raise RuntimeError(f"compile failed:\n{result.stderr}")

    run_result = run_command_with_timeout(
        [str(sim_path)],
        cwd=test_dir,
        timeout_sec=timeout_sec,
        description="linebuffer feedback simulation",
    )
    if run_result.returncode != 0:
        raise RuntimeError(f"simulation failed:\n{run_result.stdout}\n{run_result.stderr}")

    actual_path = test_dir / "actual_linebuffer_feedback_rows.txt"
    if not actual_path.exists():
        raise RuntimeError(f"simulation did not produce {actual_path.name}\n{run_result.stdout}\n{run_result.stderr}")


def main():
    parser = argparse.ArgumentParser(
        description="Compare linebuffer_core feedback behavior against fixed-model row snapshots"
    )
    parser.add_argument("--output", "-o", default="verification_results_linebuffer_feedback")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument(
        "--linebuffer-after-rows",
        default="",
        help="Comma-separated after_row filters for both expected and actual snapshot dumps",
    )
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"linebuffer_feedback_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    image = stimulus.reshape(args.height, args.width).astype(np.int32)
    after_rows = parse_int_list_arg(args.linebuffer_after_rows)

    model = ISPCSIIRFixedModel(config)
    input_patches = model.export_patch_stream(image)
    expected_snapshots = model.export_linebuffer_row_snapshots(image, after_rows=after_rows)

    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)
    save_patch_stream(input_patches, test_dir / "input_patch_stream.txt", data_width=config.DATA_WIDTH)
    save_linebuffer_row_snapshots(expected_snapshots, test_dir / "expected_linebuffer_feedback_rows", data_width=config.DATA_WIDTH)

    try:
        run_rtl_linebuffer_feedback_dump(
            test_dir,
            after_rows=after_rows,
            timeout_sec=max(30, derive_sim_timeout_seconds(args.width, args.height)),
        )
    except Exception as exc:
        print("=" * 60)
        print("Linebuffer Feedback Compare")
        print("=" * 60)
        print(f"ERROR: {exc}")
        return 2

    actual = parse_snapshot_file(test_dir / "actual_linebuffer_feedback_rows.txt")
    expected = {int(snapshot["after_row"]): snapshot for snapshot in expected_snapshots}

    mismatch_rows = []
    for after_row, expected_snapshot in expected.items():
        if after_row not in actual:
            mismatch_rows.append((after_row, "missing_actual"))
            continue
        actual_snapshot = actual[after_row]
        if not np.array_equal(expected_snapshot["row_indices"], actual_snapshot["row_indices"]):
            mismatch_rows.append((after_row, "row_indices"))
            continue
        if not np.array_equal(expected_snapshot["rows"], actual_snapshot["rows"]):
            mismatch_rows.append((after_row, "rows"))

    print("=" * 60)
    print("Linebuffer Feedback Compare")
    print("=" * 60)
    print(f"Pattern: {args.pattern}")
    print(f"Image size: {args.width} x {args.height}")
    print(f"Rows compared: {len(expected)}")
    print(f"Mismatch rows: {len(mismatch_rows)}")
    if mismatch_rows:
        print("First mismatches:")
        for after_row, reason in mismatch_rows[:10]:
            print(f"  after_row={after_row}: {reason}")
        first_row = mismatch_rows[0][0]
        exp = expected[first_row]
        act = actual.get(first_row)
        print(f"Expected row_indices[{first_row}]: {exp['row_indices'].tolist()}")
        if act is not None:
            print(f"Actual row_indices[{first_row}]:   {act['row_indices'].tolist()}")
            diff = np.where(exp["rows"] != act["rows"])
            if len(diff[0]) > 0:
                slot_idx = int(diff[0][0])
                col_idx = int(diff[1][0])
                print(
                    f"First value diff at row={first_row} slot={slot_idx} col={col_idx}: "
                    f"expected={int(exp['rows'][slot_idx, col_idx])} actual={int(act['rows'][slot_idx, col_idx])}"
                )
        return 1

    print("PASS: linebuffer_core feedback snapshots match fixed-model snapshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
