#!/usr/bin/env python3
"""
Compare integrated RTL patch metadata stream against fixed-model metadata stream.
This is the lightweight watch-mode companion to compare_patch_stream.py.
"""

import argparse
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import (
    build_default_config,
    generate_test_pattern,
    parse_int_list_arg,
    save_patch_metadata_stream,
    save_stimulus_hex,
    write_int_filter_file,
    write_testbench_config,
)


def parse_patch_metadata_stream(path: Path):
    entries = []
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or not line.startswith("# idx="):
            continue
        parts = dict(item.split("=") for item in line[2:].split())
        entries.append(
            {
                "idx": int(parts["idx"]),
                "center_x": int(parts["center_x"]),
                "center_y": int(parts["center_y"]),
            }
        )
    return entries


def run_rtl_patch_watch(test_dir: Path, center_rows=None) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "patch_watch_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_patch_stream_watch.sv"
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

    if not (test_dir / "actual_patch_watch.txt").exists():
        raise RuntimeError("simulation did not produce actual_patch_watch.txt")


def main():
    parser = argparse.ArgumentParser(description="Compare RTL patch metadata stream against fixed-model metadata stream")
    parser.add_argument("--output", "-o", default="verification_results_patch_watch")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    parser.add_argument("--patch-center-rows", default="",
                        help="Comma-separated center_y filters for both expected and actual metadata dump")
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"patch_watch_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)
    patch_center_rows = parse_int_list_arg(args.patch_center_rows)

    expected_patches = ISPCSIIRFixedModel(config).export_patch_stream(
        stimulus.reshape(args.height, args.width).astype(int),
        center_rows=patch_center_rows,
    )
    expected = [
        {
            "idx": int(entry["idx"]),
            "center_x": int(entry["center_x"]),
            "center_y": int(entry["center_y"]),
        }
        for entry in expected_patches
    ]
    save_patch_metadata_stream(expected, test_dir / "expected_patch_watch.txt")

    try:
        run_rtl_patch_watch(test_dir, center_rows=patch_center_rows)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    actual = parse_patch_metadata_stream(test_dir / "actual_patch_watch.txt")
    total = min(len(expected), len(actual))
    first_issue = None
    for idx in range(total):
        exp = expected[idx]
        act = actual[idx]
        if exp != act:
            first_issue = (idx, exp, act)
            break
    if first_issue is None and len(expected) != len(actual):
        first_issue = (total, None, None)

    print("=" * 60)
    print("Patch Watch Compare")
    print("=" * 60)
    print(f"Expected metadata entries: {len(expected)}")
    print(f"Actual metadata entries:   {len(actual)}")
    if first_issue is None:
        print("PASS: patch metadata stream matches fixed model")
        return 0

    idx, exp, act = first_issue
    print(f"First mismatch at idx={idx}")
    if exp is None or act is None:
        print("Length mismatch between expected and actual metadata streams")
    else:
        print(f"Expected: idx={exp['idx']} center=({exp['center_x']}, {exp['center_y']})")
        print(f"Actual:   idx={act['idx']} center=({act['center_x']}, {act['center_y']})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
