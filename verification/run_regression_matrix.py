#!/usr/bin/env python3
"""
Compact regression runner for ISP-CSIIR top-level golden verification.

Runs a curated size/pattern/seed matrix with low console noise, emits a
practical functional-coverage summary, and keeps only light artifacts for
passing cases by default.
"""

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import run_golden_verification as golden


DEFAULT_CASES = [
    {"width": 8, "height": 4, "pattern": "ramp"},
    {"width": 8, "height": 4, "pattern": "checker"},
    {"width": 31, "height": 17, "pattern": "gradient"},
    {"width": 32, "height": 32, "pattern": "zeros"},
    {"width": 32, "height": 32, "pattern": "max"},
    {"width": 32, "height": 32, "pattern": "ramp"},
    {"width": 63, "height": 17, "pattern": "checker"},
    {"width": 64, "height": 32, "pattern": "gradient"},
    {"width": 256, "height": 4, "pattern": "ramp"},
    {"width": 256, "height": 4, "pattern": "max"},
    {"width": 32, "height": 32, "pattern": "random", "seed": 1},
    {"width": 32, "height": 32, "pattern": "random", "seed": 7},
    {"width": 32, "height": 32, "pattern": "random", "seed": 42},
    {"width": 32, "height": 32, "pattern": "random", "seed": 99},
    {"width": 63, "height": 17, "pattern": "random", "seed": 7},
    {"width": 63, "height": 17, "pattern": "random", "seed": 42},
    {"width": 256, "height": 4, "pattern": "random", "seed": 1},
    {"width": 256, "height": 4, "pattern": "random", "seed": 42},
]


def width_bin(width: int) -> str:
    if width <= 8:
        return "w_le8"
    if width <= 32:
        return "w_9_32"
    if width <= 127:
        return "w_33_127"
    return "w_ge128"


def height_bin(height: int) -> str:
    if height <= 4:
        return "h_le4"
    if height <= 32:
        return "h_5_32"
    return "h_ge33"


def scenario_bins(width: int, height: int) -> list[str]:
    bins = []
    if width == 256:
        bins.append("max_width")
    if width % 2 == 1 or height % 2 == 1:
        bins.append("odd_dimension")
    if width == height:
        bins.append("square")
    if width > height:
        bins.append("wide")
    if height <= 4:
        bins.append("short_height")
    return bins


def case_name(case: dict) -> str:
    seed = case.get("seed")
    seed_tag = f"_seed{seed}" if seed is not None else ""
    return f"{case['pattern']}_{case['width']}x{case['height']}{seed_tag}"


def compile_shared_sim(sim_path: Path) -> None:
    rtl_dir = SCRIPT_DIR.parent / "rtl"
    tb_file = SCRIPT_DIR / "tb" / "tb_isp_csiir_random.sv"
    filelist = SCRIPT_DIR / "iverilog_csiir.f"
    cmd = [
        "iverilog",
        "-g2012",
        "-o",
        str(sim_path),
        "-I",
        str(rtl_dir),
        "-f",
        str(filelist),
        str(tb_file),
    ]
    result = subprocess.run(
        cmd,
        cwd=SCRIPT_DIR.parent,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"iverilog compile failed\n{result.stderr}")


def run_sim_case(sim_path: Path, test_dir: Path, width: int, height: int) -> tuple[bool, str]:
    timeout_cycles = golden.derive_sim_timeout_cycles(width, height)
    stall_timeout_cycles = golden.derive_stall_timeout_cycles(width)
    sim_timeout_sec = golden.derive_sim_timeout_seconds(width, height)
    cmd = [
        str(sim_path),
        f"+timeout_cycles={timeout_cycles}",
        f"+stall_timeout_cycles={stall_timeout_cycles}",
    ]
    try:
        result = golden.run_command_with_timeout(
            cmd,
            cwd=test_dir,
            timeout_sec=sim_timeout_sec,
            description=f"simulation {test_dir.name}",
        )
    except RuntimeError as exc:
        return False, str(exc)

    stdout = result.stdout or ""
    stderr = result.stderr or ""
    text = stdout
    if stderr:
        text = f"{stdout}\n[stderr]\n{stderr}"

    if result.returncode != 0:
        return False, text
    if "TEST TIMEOUT" in stdout:
        return False, text
    return True, text


def prepare_case(test_dir: Path, case: dict) -> np.ndarray:
    width = int(case["width"])
    height = int(case["height"])
    pattern = str(case["pattern"])
    seed = int(case.get("seed", 42))

    stimulus = golden.generate_test_pattern(pattern, width, height, seed)
    config = golden.build_default_config(width, height)
    expected = golden.run_golden_model(
        stimulus,
        config,
        timeout_sec=golden.derive_model_timeout_seconds(width, height),
    )

    golden.save_stimulus_hex(stimulus, test_dir / "stimulus.hex", width, height)
    golden.save_hex_file(expected, test_dir / "expected.hex")
    golden.write_testbench_config(test_dir / "config.txt", config)
    return expected


def cleanup_passing_case(test_dir: Path) -> None:
    for name in [
        "stimulus.hex",
        "expected.hex",
        "actual.hex",
        "config.txt",
        "sim_stdout.log",
        "tb_isp_csiir_random.vcd",
    ]:
        path = test_dir / name
        if path.exists():
            path.unlink()


def collect_functional_coverage(results: list[dict]) -> dict:
    coverage = {
        "patterns": sorted({case["pattern"] for case in results}),
        "width_bins": sorted({width_bin(case["width"]) for case in results}),
        "height_bins": sorted({height_bin(case["height"]) for case in results}),
        "width_parity": sorted({("width_even" if case["width"] % 2 == 0 else "width_odd") for case in results}),
        "height_parity": sorted({("height_even" if case["height"] % 2 == 0 else "height_odd") for case in results}),
        "scenario_bins": sorted({name for case in results for name in scenario_bins(case["width"], case["height"])}),
        "random_seeds": sorted({case["seed"] for case in results if case["pattern"] == "random"}),
        "max_width_hit": any(case["width"] == 256 for case in results),
        "odd_dimension_hit": any((case["width"] % 2 == 1 or case["height"] % 2 == 1) for case in results),
        "total_cases": len(results),
        "passing_cases": sum(1 for case in results if case["pass"]),
        "failing_cases": sum(1 for case in results if not case["pass"]),
        "total_expected_pixels": int(sum(case["expected_len"] for case in results)),
    }
    return coverage


def write_summary(output_root: Path, results: list[dict], coverage: dict) -> None:
    summary = {
        "results": results,
        "functional_coverage": coverage,
    }
    with open(output_root / "regression_summary.json", "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)

    lines = []
    lines.append("ISP-CSIIR Regression Summary")
    lines.append("")
    lines.append(
        f"Cases: {coverage['total_cases']}  Pass: {coverage['passing_cases']}  Fail: {coverage['failing_cases']}"
    )
    lines.append(f"Patterns: {', '.join(coverage['patterns'])}")
    lines.append(f"Width bins: {', '.join(coverage['width_bins'])}")
    lines.append(f"Height bins: {', '.join(coverage['height_bins'])}")
    lines.append(f"Scenario bins: {', '.join(coverage['scenario_bins'])}")
    lines.append(
        "Random seeds: "
        + (", ".join(str(seed) for seed in coverage["random_seeds"]) if coverage["random_seeds"] else "none")
    )
    lines.append("")
    lines.append("Per-case:")
    for case in results:
        seed_text = f" seed={case['seed']}" if case["seed"] is not None else ""
        lines.append(
            f"{'PASS' if case['pass'] else 'FAIL'} {case['pattern']} {case['width']}x{case['height']}{seed_text} "
            f"matched={case['matched']}/{case['total']} time={case['elapsed_sec']:.2f}s"
        )
        if not case["pass"]:
            lines.append(
                f"  reason={case['failure_reason']} compared={case['compared_len']} mismatch_idx={case['mismatch_indices'][:5]}"
            )

    with open(output_root / "regression_summary.txt", "w") as f:
        f.write("\n".join(lines) + "\n")


def run_case(sim_path: Path, output_root: Path, case: dict, keep_passing_artifacts: bool) -> dict:
    width = int(case["width"])
    height = int(case["height"])
    pattern = str(case["pattern"])
    seed = case.get("seed")
    seed_value = int(seed) if seed is not None else None
    test_dir = output_root / case_name(case)
    if test_dir.exists():
        shutil.rmtree(test_dir)
    test_dir.mkdir(parents=True, exist_ok=True)

    start = time.monotonic()
    expected = prepare_case(test_dir, case)
    sim_ok, sim_text = run_sim_case(sim_path, test_dir, width, height)
    (test_dir / "sim_stdout.log").write_text(sim_text)

    result = {
        "name": case_name(case),
        "pattern": pattern,
        "width": width,
        "height": height,
        "seed": seed_value,
        "pass": False,
        "total": int(len(expected)),
        "expected_len": int(len(expected)),
        "actual_len": 0,
        "compared_len": 0,
        "matched": 0,
        "mismatched": int(len(expected)),
        "max_diff": 0,
        "mean_diff": 0.0,
        "mismatch_indices": [],
        "failure_reason": "",
        "elapsed_sec": 0.0,
        "test_dir": str(test_dir),
    }

    if not sim_ok:
        result["failure_reason"] = "simulation_failed"
    else:
        actual_path = test_dir / "actual.hex"
        if not actual_path.exists():
            result["failure_reason"] = "missing_actual"
        else:
            actual = golden.load_hex_file(actual_path, skip_header=True)
            compare = golden.compare_results(expected, actual, tolerance=0)
            result.update(compare)
            result["failure_reason"] = "" if result["pass"] else "compare_failed"

    result["elapsed_sec"] = time.monotonic() - start

    with open(test_dir / "case_result.json", "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)

    if result["pass"] and not keep_passing_artifacts:
        cleanup_passing_case(test_dir)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Run compact ISP-CSIIR regression matrix")
    parser.add_argument(
        "--output",
        default="verification_results_regression_matrix",
        help="Output directory for regression artifacts",
    )
    parser.add_argument(
        "--keep-passing-artifacts",
        action="store_true",
        help="Keep full artifacts for passing cases",
    )
    parser.add_argument(
        "--case-limit",
        type=int,
        default=0,
        help="Run only the first N cases from the default matrix",
    )
    args = parser.parse_args()

    output_root = Path(args.output)
    output_root.mkdir(parents=True, exist_ok=True)
    sim_path = (output_root / "isp_csiir_regression_sim").resolve()

    print(f"[build] compiling shared simulator -> {sim_path}")
    compile_shared_sim(sim_path)

    cases = DEFAULT_CASES[:args.case_limit] if args.case_limit > 0 else DEFAULT_CASES

    results = []
    for idx, case in enumerate(cases, start=1):
        result = run_case(sim_path, output_root, case, args.keep_passing_artifacts)
        results.append(result)
        seed_text = f" seed={result['seed']}" if result["seed"] is not None else ""
        status = "PASS" if result["pass"] else "FAIL"
        print(
            f"[{idx:02d}/{len(cases):02d}] {status} "
            f"{result['pattern']} {result['width']}x{result['height']}{seed_text} "
            f"matched={result['matched']}/{result['total']} time={result['elapsed_sec']:.2f}s"
        )

    coverage = collect_functional_coverage(results)
    write_summary(output_root, results, coverage)

    print(
        f"[done] cases={coverage['total_cases']} pass={coverage['passing_cases']} "
        f"fail={coverage['failing_cases']} summary={output_root / 'regression_summary.txt'}"
    )
    return 0 if coverage["failing_cases"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
