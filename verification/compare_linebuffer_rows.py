#!/usr/bin/env python3
"""
Compare integrated RTL linebuffer row snapshots against fixed-model snapshots.
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
    save_linebuffer_row_snapshots,
    save_stimulus_hex,
    write_testbench_config,
)


def parse_snapshot_file(path: Path):
    snapshots = {}
    current_row = None
    current = None

    def finalize_snapshot(snapshot):
        return {
            "row_indices": snapshot["row_indices"],
            "rows": np.array(snapshot["rows"], dtype=np.int32),
        }

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# after_row="):
            if current is not None:
                snapshots[current_row] = finalize_snapshot(current)
            current_row = int(line.split("=", 1)[1])
            current = {"rows": []}
            continue
        if line.startswith("# slot_to_src_y="):
            current["row_indices"] = np.array([int(v) for v in line.split("=", 1)[1].split()], dtype=np.int32)
            continue
        if line.startswith("slot"):
            _, values = line.split(":", 1)
            current["rows"].append([int(v, 16) for v in values.strip().split()])

    if current is not None:
        snapshots[current_row] = finalize_snapshot(current)

    return snapshots


def run_rtl_snapshot_dump(test_dir: Path) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "linebuffer_rows_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_linebuffer_rows.sv"
    filelist = SCRIPT_DIR / "iverilog_csiir.f"
    rtl_dir = repo_root / "rtl"

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
    actual_path = test_dir / "actual_linebuffer_rows.txt"
    if not actual_path.exists():
        raise RuntimeError(f"simulation did not produce {actual_path.name}\n{run_result.stdout}\n{run_result.stderr}")


def main():
    parser = argparse.ArgumentParser(description="Compare RTL linebuffer row snapshots against fixed-model snapshots")
    parser.add_argument("--output", "-o", default="verification_results_linebuffer_rows")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"lb_rows_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)

    model = ISPCSIIRFixedModel(config)
    snapshots = model.export_linebuffer_row_snapshots(stimulus.reshape(args.height, args.width).astype(np.int32))
    save_linebuffer_row_snapshots(snapshots, test_dir / "expected_linebuffer_rows", data_width=config.DATA_WIDTH)

    try:
        run_rtl_snapshot_dump(test_dir)
    except Exception as exc:
        print("=" * 60)
        print("Linebuffer Row Snapshot Compare")
        print("=" * 60)
        print(f"ERROR: {exc}")
        return 2

    actual = parse_snapshot_file(test_dir / "actual_linebuffer_rows.txt")
    expected = {int(s["after_row"]): s for s in snapshots}

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
    print("Linebuffer Row Snapshot Compare")
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

    print("PASS: RTL linebuffer snapshots match fixed-model snapshots")
    return 0


if __name__ == "__main__":
    sys.exit(main())
