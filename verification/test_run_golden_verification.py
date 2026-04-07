#!/usr/bin/env python3
import argparse
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import run_golden_verification as golden
from isp_csiir_fixed_model import FixedPointConfig, ISPCSIIRFixedModel


class RunGoldenVerificationTests(unittest.TestCase):
    def test_run_rtl_simulation_executes_generated_sim_binary_from_relative_test_dir(self):
        test_dir = Path("verification_results_case") / "test_case"
        rtl_dir = Path("/tmp/rtl")
        tb_dir = Path("/tmp/tb")

        compile_result = subprocess.CompletedProcess(args=["iverilog"], returncode=0, stdout="", stderr="")
        run_result = subprocess.CompletedProcess(args=["sim"], returncode=0, stdout="PASS\n", stderr="")

        def fake_subprocess_run(cmd, capture_output, text, cwd):
            if cmd[0] == "iverilog":
                return compile_result
            self.assertTrue(Path(cmd[0]).is_absolute())
            self.assertEqual(cmd, [str((test_dir / "isp_csiir_sim").resolve())])
            self.assertEqual(cwd, test_dir)
            return run_result

        with mock.patch.object(golden.subprocess, "run", side_effect=fake_subprocess_run):
            passed = golden.run_rtl_simulation(test_dir, rtl_dir, tb_dir)

        self.assertTrue(passed)

    def test_write_testbench_config_uses_fixed_point_config(self):
        config = FixedPointConfig(
            IMG_WIDTH=8,
            IMG_HEIGHT=4,
            win_size_thresh=[11, 22, 33, 44],
            win_size_clip_y=[15, 23, 31, 39],
            win_size_clip_sft=[2, 3, 4, 5],
            blending_ratio=[7, 8, 9, 10],
            reg_edge_protect=32,
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.txt"
            golden.write_testbench_config(config_path, config)
            self.assertEqual(
                config_path.read_text().splitlines(),
                [
                    "8", "4",
                    "11", "22", "33", "44",
                    "7", "8", "9", "10",
                    "15", "23", "31", "39",
                    "2", "3", "4", "5",
                    "32",
                ],
            )

    def test_main_uses_rtl_simulation_helper(self):
        args = argparse.Namespace(
            output="verification_results",
            pattern="checker",
            width=8,
            height=4,
            seed=1,
            tolerance=0,
            keep=False,
            export_linebuffer_rows=False,
        )

        expected = [1, 2, 3, 4]
        actual = [1, 2, 3, 4]

        with tempfile.TemporaryDirectory() as tmpdir:
            output_root = Path(tmpdir)

            def fake_parse_args(self):
                args.output = str(output_root)
                return args

            def fail_if_bypassed(*_args, **_kwargs):
                raise AssertionError("main bypassed run_rtl_simulation helper")

            def fake_run_rtl_simulation(test_dir, _rtl_dir, _tb_dir):
                (Path(test_dir) / "actual.hex").write_text("0008\n0004\n001\n002\n003\n004\n")
                return True

            with mock.patch.object(argparse.ArgumentParser, "parse_args", fake_parse_args), \
                 mock.patch.object(golden, "run_golden_model", return_value=expected), \
                 mock.patch.object(golden, "run_rtl_simulation", side_effect=fake_run_rtl_simulation) as run_rtl_simulation, \
                 mock.patch.object(golden, "load_hex_file", return_value=actual), \
                 mock.patch.object(golden, "compare_results", return_value={
                     "total": 4,
                     "matched": 4,
                     "mismatched": 0,
                     "max_diff": 0,
                     "mean_diff": 0.0,
                     "mismatch_indices": [],
                     "pass": True,
                 }), \
                 mock.patch("subprocess.run", side_effect=fail_if_bypassed):
                status = golden.main()

            self.assertEqual(status, 0)
            run_rtl_simulation.assert_called_once()
            generated_test_dir = next(output_root.iterdir())
            self.assertEqual(run_rtl_simulation.call_args.args[0], generated_test_dir)

    def test_run_golden_model_uses_delayed_streaming_center_output_semantics(self):
        width = 8
        height = 4
        config = golden.build_default_config(width, height)
        stimulus = np.arange(width * height, dtype=np.uint16)

        expected = ISPCSIIRFixedModel(config).process_center_stream(
            stimulus.reshape(height, width).astype(np.int32)
        )
        actual = golden.run_golden_model(stimulus, config)

        np.testing.assert_array_equal(actual, expected)

    def test_fixed_model_exports_linebuffer_snapshots_per_row(self):
        width = 4
        height = 3
        config = golden.build_default_config(width, height)
        stimulus = np.arange(width * height, dtype=np.int32).reshape(height, width)

        snapshots = ISPCSIIRFixedModel(config).export_linebuffer_row_snapshots(stimulus)

        self.assertEqual(len(snapshots), height)
        self.assertEqual(snapshots[0]["after_row"], 0)
        np.testing.assert_array_equal(snapshots[0]["row_indices"], np.array([0, 0, 0, 1, 2], dtype=np.int32))
        self.assertEqual(snapshots[0]["rows"].shape, (5, width))
        np.testing.assert_array_equal(snapshots[-1]["row_indices"], np.array([0, 1, 2, 2, 2], dtype=np.int32))

    def test_save_linebuffer_row_snapshots_writes_manifest_and_row_files(self):
        snapshots = [
            {
                "after_row": 0,
                "row_indices": np.array([0, 0, 0, 1, 2], dtype=np.int32),
                "rows": np.array([
                    [0, 1, 2, 3],
                    [0, 1, 2, 3],
                    [0, 1, 2, 3],
                    [4, 5, 6, 7],
                    [8, 9, 10, 11],
                ], dtype=np.int32),
            }
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir) / "linebuffer_rows"
            golden.save_linebuffer_row_snapshots(snapshots, out_dir)

            manifest = (out_dir / "manifest.txt").read_text()
            row_text = (out_dir / "row_0000.hex").read_text()

            self.assertIn("row_0000.hex", manifest)
            self.assertIn("# after_row=0", row_text)
            self.assertIn("# slot_to_src_y=0 0 0 1 2", row_text)


if __name__ == "__main__":
    unittest.main()
