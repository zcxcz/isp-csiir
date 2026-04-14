#!/usr/bin/env python3
"""
Compare forward-path linebuffer_core output column stream against the fixed-model
forward column stream.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import (
    build_default_config,
    generate_test_pattern,
    parse_int_list_arg,
    save_column_stream,
    save_stimulus_hex,
    write_int_filter_file,
    write_testbench_config,
)


def parse_column_stream(path: Path):
    columns = []
    current = None
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# idx="):
            if current is not None:
                current["column_u10"] = np.array(current["column_u10"], dtype=np.int32)
                columns.append(current)
            parts = dict(item.split("=") for item in line[2:].split())
            current = {
                "idx": int(parts["idx"]),
                "center_x": int(parts["center_x"]),
                "center_y": int(parts["center_y"]),
                "column_u10": [],
            }
            continue
        if line.startswith("col:"):
            current["column_u10"] = [int(v, 16) for v in line.split(":", 1)[1].strip().split()]
    if current is not None:
        current["column_u10"] = np.array(current["column_u10"], dtype=np.int32)
        columns.append(current)
    return columns


def run_rtl_linebuffer_core_dump(test_dir: Path, center_rows=None) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "linebuffer_core_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_linebuffer_core.sv"
    rtl_dir = repo_root / "rtl"

    write_int_filter_file(center_rows, test_dir / "column_center_rows.txt")

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

    run_result = subprocess.run([str(sim_path)], capture_output=True, text=True, cwd=test_dir)
    if run_result.returncode != 0:
        raise RuntimeError(f"simulation failed:\n{run_result.stdout}\n{run_result.stderr}")

    if not (test_dir / "actual_column_stream.txt").exists():
        raise RuntimeError("simulation did not produce actual_column_stream.txt")


def main():
    parser = argparse.ArgumentParser(description="Compare linebuffer_core against fixed-model forward column stream")
    parser.add_argument("--output", "-o", default="verification_results_linebuffer_core")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--column-center-rows", default="", help="Comma-separated center_y filters")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"linebuffer_core_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    image = stimulus.reshape(args.height, args.width).astype(np.int32)
    center_rows = parse_int_list_arg(args.column_center_rows)

    model = ISPCSIIRFixedModel(config)
    expected_columns = model.export_forward_column_stream(image, center_rows=center_rows)

    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)
    save_column_stream(expected_columns, test_dir / "expected_column_stream.txt", data_width=config.DATA_WIDTH)

    try:
        run_rtl_linebuffer_core_dump(test_dir, center_rows=center_rows)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    actual = parse_column_stream(test_dir / "actual_column_stream.txt")
    total = min(len(expected_columns), len(actual))
    first_issue = None
    for idx in range(total):
        exp = expected_columns[idx]
        act = actual[idx]
        if exp["center_x"] != act["center_x"] or exp["center_y"] != act["center_y"]:
            first_issue = ("coord", idx, exp, act)
            break
        if not np.array_equal(exp["column_u10"], act["column_u10"]):
            first_issue = ("column", idx, exp, act)
            break
    if first_issue is None and len(expected_columns) != len(actual):
        first_issue = ("length", total, None, None)

    print("=" * 60)
    print("Linebuffer Core Compare")
    print("=" * 60)
    print(f"Expected columns: {len(expected_columns)}")
    print(f"Actual columns:   {len(actual)}")
    if first_issue is None:
        print("PASS: linebuffer_core matches fixed model forward column stream")
        return 0

    issue_type, idx, exp, act = first_issue
    print(f"First mismatch type: {issue_type} at idx={idx}")
    if exp is not None and act is not None:
        print(f"Expected center: ({exp['center_x']}, {exp['center_y']})")
        print(f"Actual center:   ({act['center_x']}, {act['center_y']})")
        if issue_type == "column":
            diff = np.where(exp["column_u10"] != act["column_u10"])
            if len(diff[0]) > 0:
                row = int(diff[0][0])
                print(
                    f"First column diff at row={row}: "
                    f"expected={int(exp['column_u10'][row])} actual={int(act['column_u10'][row])}"
                )
    return 1


if __name__ == "__main__":
    sys.exit(main())
