#!/usr/bin/env python3
"""
ISP-CSIIR 配置驱动随机验证主脚本

集成配置生成、Golden Model 运行、RTL 仿真和结果比对。

作者: rtl-verf
日期: 2026-03-23
版本: v1.0
"""

import os
import sys
import json
import argparse
import subprocess
import numpy as np
from pathlib import Path
from typing import Optional, List, Tuple
from datetime import datetime

# 添加验证目录到路径
SCRIPT_DIR = Path(__file__).parent.absolute()
sys.path.insert(0, str(SCRIPT_DIR))

from generate_test_config import ConfigGenerator, TestConfig
from isp_csiir_fixed_model import ISPCSIIRFixedModel, FixedPointConfig
from compare_results import ResultComparator, ComparisonResult, CoverageCollector


class RandomVerificationRunner:
    """随机验证运行器"""

    def __init__(self, output_dir: Path, simulator: str = "iverilog"):
        """
        初始化验证运行器

        Args:
            output_dir: 输出目录
            simulator: 仿真器类型
        """
        self.output_dir = Path(output_dir)
        self.simulator = simulator
        self.rtl_dir = SCRIPT_DIR.parent / "rtl"
        self.tb_dir = SCRIPT_DIR / "tb"
        self.coverage = CoverageCollector()

    def setup_directories(self, test_id: str) -> Path:
        """创建测试目录"""
        test_dir = self.output_dir / test_id
        test_dir.mkdir(parents=True, exist_ok=True)
        return test_dir

    def generate_config_text(self, config: TestConfig, output_path: Path):
        """
        生成 testbench 可读的配置文件格式

        Args:
            config: 测试配置
            output_path: 输出路径
        """
        with open(output_path, 'w') as f:
            f.write(f"{config.img_width}\n")
            f.write(f"{config.img_height}\n")
            f.write(f"{config.win_size_thresh[0]}\n")
            f.write(f"{config.win_size_thresh[1]}\n")
            f.write(f"{config.win_size_thresh[2]}\n")
            f.write(f"{config.win_size_thresh[3]}\n")
            f.write(f"{config.blending_ratio[0]}\n")
            f.write(f"{config.blending_ratio[1]}\n")
            f.write(f"{config.blending_ratio[2]}\n")
            f.write(f"{config.blending_ratio[3]}\n")
            f.write(f"{config.win_size_clip_y[0]}\n")
            f.write(f"{config.win_size_clip_y[1]}\n")
            f.write(f"{config.win_size_clip_y[2]}\n")
            f.write(f"{config.win_size_clip_y[3]}\n")

    def run_golden_model(self, config: TestConfig, stimulus: np.ndarray) -> np.ndarray:
        """
        运行 Python Golden Model

        Args:
            config: 测试配置
            stimulus: 输入激励

        Returns:
            期望输出
        """
        # 创建 Golden Model 配置
        gm_config = FixedPointConfig(
            IMG_WIDTH=config.img_width,
            IMG_HEIGHT=config.img_height,
            win_size_thresh=config.win_size_thresh,
            win_size_clip_y=config.win_size_clip_y,
            blending_ratio=config.blending_ratio
        )

        # 运行模型
        model = ISPCSIIRFixedModel(gm_config)
        output = model.process(stimulus)

        return output

    def run_rtl_simulation(self, test_dir: Path) -> bool:
        """
        运行 RTL 仿真

        Args:
            test_dir: 测试目录

        Returns:
            是否成功
        """
        # 收集 RTL 文件
        rtl_files = list(self.rtl_dir.glob("*.v"))
        rtl_files.extend(self.rtl_dir.glob("common/*.v"))
        rtl_files = [str(f) for f in rtl_files]

        tb_file = self.tb_dir / "tb_isp_csiir_random.sv"

        if self.simulator == "iverilog":
            # 编译 - use simple output name since we run from test_dir
            cmd = [
                "iverilog",
                "-g2012",
                "-o", "isp_csiir_sim",
                "-I", str(self.rtl_dir),
                *rtl_files,
                str(tb_file)
            ]

            print(f"  Compiling RTL...")
            result = subprocess.run(cmd, capture_output=True, text=True, cwd=test_dir)

            if result.returncode != 0:
                print(f"  Compilation failed:\n{result.stderr}")
                return False

            # 运行仿真
            print(f"  Running simulation...")
            sim_result = subprocess.run(
                ["vvp", "isp_csiir_sim"],
                capture_output=True,
                text=True,
                cwd=test_dir
            )

            print(sim_result.stdout)

            if sim_result.returncode != 0:
                print(f"  Simulation error:\n{sim_result.stderr}")
                return False

            return True

        else:
            print(f"  Simulator not supported: {self.simulator}")
            return False

    def run_single_test(self, seed: int, pattern: str = 'random',
                        img_width: Optional[int] = None,
                        img_height: Optional[int] = None,
                        tolerance: int = 0) -> Tuple[bool, ComparisonResult]:
        """
        运行单次测试

        Args:
            seed: 随机种子
            pattern: 激励图案
            img_width: 图像宽度
            img_height: 图像高度
            tolerance: 容差阈值

        Returns:
            (是否通过, 比对结果)
        """
        print(f"\n{'='*60}")
        print(f"Running test with seed={seed}")
        print(f"{'='*60}")

        # 生成配置
        generator = ConfigGenerator(seed)

        if img_width and img_height:
            config = generator.generate_random_config(
                img_width_range=(img_width, img_width),
                img_height_range=(img_height, img_height)
            )
        else:
            config = generator.generate_random_config()

        test_dir = self.setup_directories(config.test_id)

        print(f"  Test ID: {config.test_id}")
        print(f"  Image size: {config.img_width} x {config.img_height}")
        print(f"  Win clip Y: {config.win_size_clip_y}")
        print(f"  Blend ratio: {config.blending_ratio}")

        # Step 1: 生成激励
        print(f"\n  Step 1: Generating stimulus...")
        stimulus = generator.generate_stimulus(config, pattern)
        generator.save_stimulus(stimulus, test_dir)

        # Step 2: 运行 Golden Model
        print(f"  Step 2: Running Golden Model...")
        expected = self.run_golden_model(config, stimulus)
        generator.save_expected(expected, test_dir)

        # Step 3: 生成配置文件
        print(f"  Step 3: Writing config files...")
        generator.save_config(config, test_dir)
        self.generate_config_text(config, test_dir / "config.txt")

        # Step 4: 运行 RTL 仿真
        print(f"  Step 4: Running RTL simulation...")
        sim_success = self.run_rtl_simulation(test_dir)

        if not sim_success:
            print(f"  RTL simulation FAILED")
            return False, None

        # Step 5: 比对结果
        print(f"  Step 5: Comparing results...")
        comparator = ResultComparator(tolerance=tolerance)

        expected_path = test_dir / "expected.hex"
        actual_path = test_dir / "actual.hex"

        if not actual_path.exists():
            print(f"  Actual output file not found!")
            return False, None

        result = comparator.compare_files(expected_path, actual_path)

        # 生成报告
        report = comparator.generate_report(result, config.to_dict())
        print(report)

        # 保存报告
        comparator.save_report(result, test_dir / "comparison_report.txt", config.to_dict())

        # 记录覆盖率
        self.coverage.add_result(config.to_dict(), result)

        return result.is_pass, result

    def run_multiple_tests(self, num_tests: int, pattern: str = 'random',
                          img_width: Optional[int] = None,
                          img_height: Optional[int] = None,
                          tolerance: int = 0,
                          seed_start: int = 0) -> dict:
        """
        运行多次测试

        Args:
            num_tests: 测试次数
            pattern: 激励图案
            img_width: 图像宽度
            img_height: 图像高度
            tolerance: 容差阈值
            seed_start: 起始种子

        Returns:
            统计结果
        """
        print(f"\n{'#'*60}")
        print(f"Running {num_tests} random tests")
        print(f"{'#'*60}")

        stats = {
            'total': num_tests,
            'passed': 0,
            'failed': 0,
            'results': []
        }

        for i in range(num_tests):
            seed = seed_start + i
            passed, result = self.run_single_test(
                seed=seed,
                pattern=pattern,
                img_width=img_width,
                img_height=img_height,
                tolerance=tolerance
            )

            if passed:
                stats['passed'] += 1
            else:
                stats['failed'] += 1

            stats['results'].append({
                'seed': seed,
                'passed': passed
            })

        return stats

    def generate_final_report(self, stats: dict) -> str:
        """生成最终报告"""
        lines = []
        lines.append("\n" + "=" * 60)
        lines.append("FINAL VERIFICATION REPORT")
        lines.append("=" * 60)
        lines.append(f"\nTest Summary:")
        lines.append(f"  Total Tests:  {stats['total']}")
        lines.append(f"  Passed:       {stats['passed']}")
        lines.append(f"  Failed:       {stats['failed']}")
        lines.append(f"  Pass Rate:    {stats['passed']/stats['total']*100:.2f}%")

        # 添加覆盖率报告
        lines.append("\n" + self.coverage.generate_coverage_report())

        lines.append("\n" + "=" * 60)

        if stats['failed'] == 0:
            lines.append("ALL TESTS PASSED")
        else:
            lines.append("SOME TESTS FAILED")
        lines.append("=" * 60)

        return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="ISP-CSIIR 配置驱动随机验证")
    parser.add_argument("--output", "-o", default="verification_results",
                       help="输出目录")
    parser.add_argument("--num-tests", "-n", type=int, default=1,
                       help="测试次数")
    parser.add_argument("--seed", "-s", type=int, default=None,
                       help="随机种子 (单次测试)")
    parser.add_argument("--seed-start", type=int, default=0,
                       help="起始种子 (多次测试)")
    parser.add_argument("--pattern", "-p",
                       choices=['random', 'ramp', 'checker', 'corner', 'gradient'],
                       default='random',
                       help="激励图案类型")
    parser.add_argument("--width", "-W", type=int, default=None,
                       help="固定图像宽度")
    parser.add_argument("--height", "-H", type=int, default=None,
                       help="固定图像高度")
    parser.add_argument("--tolerance", "-t", type=int, default=0,
                       help="误差容差阈值")
    parser.add_argument("--simulator", default="iverilog",
                       help="仿真器 (iverilog)")
    parser.add_argument("--golden-only", action="store_true",
                       help="仅运行 Golden Model")

    args = parser.parse_args()

    # 创建运行器
    runner = RandomVerificationRunner(
        output_dir=args.output,
        simulator=args.simulator
    )

    print("=" * 60)
    print("ISP-CSIIR Configuration-Driven Verification")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    if args.num_tests == 1:
        # 单次测试
        seed = args.seed if args.seed is not None else 0
        passed, result = runner.run_single_test(
            seed=seed,
            pattern=args.pattern,
            img_width=args.width,
            img_height=args.height,
            tolerance=args.tolerance
        )

        if passed:
            print("\nTEST PASSED")
            sys.exit(0)
        else:
            print("\nTEST FAILED")
            sys.exit(1)
    else:
        # 多次测试
        stats = runner.run_multiple_tests(
            num_tests=args.num_tests,
            pattern=args.pattern,
            img_width=args.width,
            img_height=args.height,
            tolerance=args.tolerance,
            seed_start=args.seed_start
        )

        report = runner.generate_final_report(stats)
        print(report)

        # 保存最终报告
        report_path = Path(args.output) / "final_report.txt"
        with open(report_path, 'w') as f:
            f.write(report)

        print(f"\nFinal report saved to: {report_path}")

        sys.exit(0 if stats['failed'] == 0 else 1)


if __name__ == "__main__":
    main()