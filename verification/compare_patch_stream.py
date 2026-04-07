#!/usr/bin/env python3
"""
Compare integrated RTL Stage4 patch stream against fixed-model patch stream.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel
from run_golden_verification import build_default_config, generate_test_pattern, save_stimulus_hex, write_testbench_config


def parse_patch_stream(path: Path):
    patches = []
    current = None
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# idx="):
            if current is not None:
                current["patch_u10"] = np.array(current["patch_u10"], dtype=np.int32)
                patches.append(current)
            parts = dict(item.split("=") for item in line[2:].split())
            current = {
                "idx": int(parts["idx"]),
                "center_x": int(parts["center_x"]),
                "center_y": int(parts["center_y"]),
                "patch_u10": [],
            }
            continue
        if line.startswith("row"):
            _, values = line.split(":", 1)
            current["patch_u10"].append([int(v, 16) for v in values.strip().split()])
    if current is not None:
        current["patch_u10"] = np.array(current["patch_u10"], dtype=np.int32)
        patches.append(current)
    return patches


def run_rtl_patch_dump(test_dir: Path) -> None:
    repo_root = SCRIPT_DIR.parent
    sim_path = (test_dir / "patch_stream_sim").resolve()
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_patch_stream.sv"
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

    if not (test_dir / "actual_patch_stream.txt").exists():
        raise RuntimeError("simulation did not produce actual_patch_stream.txt")


def main():
    parser = argparse.ArgumentParser(description="Compare RTL patch stream against fixed-model patch stream")
    parser.add_argument("--output", "-o", default="verification_results_patch_stream")
    parser.add_argument("--pattern", "-p", choices=["random", "ramp", "checker", "gradient", "zeros", "max"], default="ramp")
    parser.add_argument("--width", "-W", type=int, default=32)
    parser.add_argument("--height", "-H", type=int, default=32)
    parser.add_argument("--seed", "-s", type=int, default=42)
    args = parser.parse_args()

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    test_dir = output_dir / f"patch_stream_{args.pattern}_{args.width}x{args.height}_seed{args.seed}"
    test_dir.mkdir(parents=True, exist_ok=True)

    stimulus = generate_test_pattern(args.pattern, args.width, args.height, args.seed)
    config = build_default_config(args.width, args.height)
    save_stimulus_hex(stimulus, test_dir / "stimulus.hex", args.width, args.height)
    write_testbench_config(test_dir / "config.txt", config)

    expected = ISPCSIIRFixedModel(config).export_patch_stream(stimulus.reshape(args.height, args.width).astype(np.int32))

    try:
        run_rtl_patch_dump(test_dir)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 2

    actual = parse_patch_stream(test_dir / "actual_patch_stream.txt")
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
    print("Patch Stream Compare")
    print("=" * 60)
    print(f"Expected patches: {len(expected)}")
    print(f"Actual patches:   {len(actual)}")
    if first_issue is None:
        print("PASS: patch stream matches fixed model")
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
