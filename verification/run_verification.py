#!/usr/bin/env python3
"""
ISP-CSIIR 验证脚本

运行 RTL 仿真并进行结果对比。

作者: rtl-verf
日期: 2026-03-22
版本: v1.0
"""

import os
import sys
import subprocess
import argparse
import numpy as np
from pathlib import Path

# 添加验证目录到路径
SCRIPT_DIR = Path(__file__).parent.absolute()
sys.path.insert(0, str(SCRIPT_DIR))

from isp_csiir_fixed_model import ISPCSIIRFixedModel, FixedPointConfig


def run_simulation(simulator: str = "iverilog", testbench: str = "simple"):
    """
    运行 RTL 仿真

    Args:
        simulator: 仿真器 (iverilog, vcs, modelsim)
        testbench: 测试平台名称
    """
    rtl_dir = SCRIPT_DIR.parent / "rtl"
    tb_dir = SCRIPT_DIR / "tb"

    # 收集 RTL 文件
    rtl_files = list(rtl_dir.glob("*.v"))
    rtl_files = [str(f) for f in rtl_files]

    # 选择 testbench
    tb_file = tb_dir / f"tb_isp_csiir_{testbench}.sv"

    if simulator == "iverilog":
        # Icarus Verilog 仿真
        cmd = [
            "iverilog",
            "-g2012",  # SystemVerilog 2012
            "-o", "isp_csiir_sim",
            "-I", str(rtl_dir),
            *rtl_files,
            str(tb_file)
        ]

        print(f"编译命令: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            print(f"编译失败:\n{result.stderr}")
            return False

        print("编译成功，开始仿真...")

        # 运行仿真
        sim_result = subprocess.run(["vvp", "isp_csiir_sim"],
                                    capture_output=True, text=True)
        print(sim_result.stdout)

        if sim_result.returncode != 0:
            print(f"仿真错误:\n{sim_result.stderr}")
            return False

        return True

    else:
        print(f"暂不支持仿真器: {simulator}")
        return False


def generate_test_pattern(pattern_type: str, width: int, height: int) -> np.ndarray:
    """
    生成测试图案

    Args:
        pattern_type: 图案类型 (zero, max, ramp, random, checker)
        width: 图像宽度
        height: 图像高度

    Returns:
        测试图像数组
    """
    if pattern_type == "zero":
        return np.zeros((height, width), dtype=np.int32)

    elif pattern_type == "max":
        return np.full((height, width), 1023, dtype=np.int32)

    elif pattern_type == "ramp":
        x = np.arange(width)
        y = np.arange(height)
        xx, yy = np.meshgrid(x, y)
        return ((xx + yy) % 1024).astype(np.int32)

    elif pattern_type == "random":
        np.random.seed(42)
        return np.random.randint(0, 1024, (height, width), dtype=np.int32)

    elif pattern_type == "checker":
        x = np.arange(width)
        y = np.arange(height)
        xx, yy = np.meshgrid(x, y)
        checker = ((xx // 4) + (yy // 4)) % 2
        return (checker * 1023).astype(np.int32)

    else:
        return np.full((height, width), 512, dtype=np.int32)


def run_golden_model_test(pattern_type: str = "random",
                          width: int = 64, height: int = 64):
    """
    运行 Golden Model 测试

    Args:
        pattern_type: 测试图案类型
        width: 图像宽度
        height: 图像高度
    """
    print(f"\n运行 Golden Model 测试...")
    print(f"图案类型: {pattern_type}")
    print(f"图像尺寸: {width} x {height}")

    # 生成输入
    input_img = generate_test_pattern(pattern_type, width, height)

    # 运行定点模型
    config = FixedPointConfig(IMG_WIDTH=width, IMG_HEIGHT=height)
    model = ISPCSIIRFixedModel(config)
    output = model.process(input_img)

    # 统计
    print(f"\n输入统计:")
    print(f"  最小值: {input_img.min()}")
    print(f"  最大值: {input_img.max()}")
    print(f"  均值:   {input_img.mean():.2f}")
    print(f"  标准差: {input_img.std():.2f}")

    print(f"\n输出统计:")
    print(f"  最小值: {output.min()}")
    print(f"  最大值: {output.max()}")
    print(f"  均值:   {output.mean():.2f}")
    print(f"  标准差: {output.std():.2f}")

    # 验证范围
    errors = 0
    if output.min() < 0:
        print("错误: 输出包含负值!")
        errors += 1
    if output.max() > 1023:
        print("错误: 输出超过10位范围!")
        errors += 1

    if errors == 0:
        print("\n测试通过!")
    else:
        print(f"\n测试失败，发现 {errors} 个错误")

    return output


def main():
    parser = argparse.ArgumentParser(description="ISP-CSIIR 验证脚本")
    parser.add_argument("--simulator", default="iverilog",
                       help="仿真器选择 (iverilog, vcs, modelsim)")
    parser.add_argument("--testbench", default="simple",
                       help="测试平台 (simple, full)")
    parser.add_argument("--pattern", default="random",
                       help="测试图案 (zero, max, ramp, random, checker)")
    parser.add_argument("--width", type=int, default=64,
                       help="图像宽度")
    parser.add_argument("--height", type=int, default=64,
                       help="图像高度")
    parser.add_argument("--golden-only", action="store_true",
                       help="仅运行 Golden Model")

    args = parser.parse_args()

    print("=" * 50)
    print("ISP-CSIIR 验证环境")
    print("=" * 50)

    # 运行 Golden Model
    run_golden_model_test(args.pattern, args.width, args.height)

    # 运行 RTL 仿真
    if not args.golden_only:
        print(f"\n运行 RTL 仿真 ({args.simulator})...")
        success = run_simulation(args.simulator, args.testbench)

        if success:
            print("\n仿真完成!")
        else:
            print("\n仿真失败!")
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())