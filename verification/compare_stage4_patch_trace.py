#!/usr/bin/env python3
"""
Compare stage4 patch output against fixed-model stage4 local evaluation using
top-level stage4 input trace transactions.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from compare_patch_stream import parse_patch_stream
from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import (
    build_default_config,
    generate_test_pattern,
    parse_int_list_arg,
    save_stimulus_hex,
    write_int_filter_file,
    write_testbench_config,
)


def parse_stage4_input_trace(path: Path):
    entries = []
    current = None
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# idx="):
            if current is not None:
                current["src_patch_u10"] = np.array(current["src_patch_u10"], dtype=np.int32)
                entries.append(current)
            parts = dict(item.split("=") for item in line[2:].split())
            current = {
                "idx": int(parts["idx"]),
                "center_x": int(parts["center_x"]),
                "center_y": int(parts["center_y"]),
                "win_size": int(parts["win_size"]),
                "grad_h": int(parts["grad_h"]),
                "grad_v": int(parts["grad_v"]),
                "blend0": int(parts["blend0"]),
                "blend1": int(parts["blend1"]),
                "avg0_u": int(parts["avg0_u"]),
                "avg1_u": int(parts["avg1_u"]),
                "src_patch_u10": [],
            }
            continue
        if line.startswith("src_row"):
            _, values = line.split(":", 1)
            current["src_patch_u10"].append([int(v, 16) for v in values.strip().split()])
    if current is not None:
        current["src_patch_u10"] = np.array(current["src_patch_u10"], dtype=np.int32)
        entries.append(current)
    return entries


def run_rtl_stage4_trace_dump(test_dir: Path, center_rows=None) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "stage4_trace_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_stage4_patch_trace.sv"
    filelist = SCRIPT_DIR / "iverilog_csiir.f"
    rtl_dir = repo_root / "rtl"

    write_int_filter_file(center_rows, test_dir / "patch_center_rows.txt")

    compile_cmd = [
        "iverilog", "-g2012",
        "-o", str(sim_path),
        "-I", str(rtl_dir),
        "-f", str(filelist),
        str(tb_file),
    ]
    result = subprocess.run(compile_cmd, capture_output=True, text=True, cwd=repo_root)
    if result.returncode != 0:
        raise RuntimeError(f"compile failed:\n{result.stderr}")

    run_result = subprocess.run([str(sim_path)], capture_output=True, text=True, cwd=test_dir)
    if run_result.returncode != 0:
        raise RuntimeError(f"simulation failed:\n{run_result.stdout}\n{run_result.stderr}")

    if not (test_dir / "stage4_input_trace.txt").exists():
        raise RuntimeError("simulation did not produce stage4_input_trace.txt")
    if not (test_dir / "stage4_output_patch.txt").exists():
        raise RuntimeError("simulation did not produce stage4_output_patch.txt")


def main():
    parser = argparse.ArgumentParser(description="Compare stage4 local patch output using stage4 input traces")
    parser.add_argument("--output", "-o", default="verification_results_stage4_patch_trace")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--patch-center-rows", default="", help="Comma-separated center_y filters")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"stage4_patch_trace_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)
    patch_center_rows = parse_int_list_arg(args.patch_center_rows)

    try:
        run_rtl_stage4_trace_dump(test_dir, center_rows=patch_center_rows)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    model = ISPCSIIRFixedModel(config)
    inputs = parse_stage4_input_trace(test_dir / "stage4_input_trace.txt")
    actual = parse_patch_stream(test_dir / "stage4_output_patch.txt")

    total = min(len(inputs), len(actual))
    first_issue = None
    for idx in range(total):
        entry = inputs[idx]
        act = actual[idx]
        stage4 = model._stage4_window_blend(
            entry["src_patch_u10"],
            entry["win_size"],
            entry["blend0"],
            entry["blend1"],
            entry["avg0_u"],
            entry["avg1_u"],
            entry["grad_h"],
            entry["grad_v"],
        )
        expected_patch = np.vectorize(model._s11_to_u10)(stage4["final_patch"]).astype(np.int32)
        if entry["center_x"] != act["center_x"] or entry["center_y"] != act["center_y"]:
            first_issue = ("coord", idx, entry, act, expected_patch)
            break
        if not np.array_equal(expected_patch, act["patch_u10"]):
            first_issue = ("patch", idx, entry, act, expected_patch)
            break
    if first_issue is None and len(inputs) != len(actual):
        first_issue = ("length", total, None, None, None)

    print("=" * 60)
    print("Stage4 Patch Trace Compare")
    print("=" * 60)
    print(f"Traced stage4 inputs:  {len(inputs)}")
    print(f"Actual stage4 patches: {len(actual)}")
    if first_issue is None:
        print("PASS: stage4 patch output matches fixed-model local evaluation")
        return 0

    issue_type, idx, entry, act, expected_patch = first_issue
    print(f"First mismatch type: {issue_type} at idx={idx}")
    if entry is not None and act is not None:
        print(f"Trace center:   ({entry['center_x']}, {entry['center_y']})")
        print(f"Actual center:  ({act['center_x']}, {act['center_y']})")
        if issue_type == "patch":
            diff = np.where(expected_patch != act["patch_u10"])
            if len(diff[0]) > 0:
                py = int(diff[0][0])
                px = int(diff[1][0])
                print(
                    f"First patch diff at row={py} col={px}: "
                    f"expected={int(expected_patch[py, px])} actual={int(act['patch_u10'][py, px])}"
                )
    return 1


if __name__ == "__main__":
    sys.exit(main())
