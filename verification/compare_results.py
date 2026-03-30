#!/usr/bin/env python3
"""
ISP-CSIIR 结果比对工具

比较 RTL 仿真输出与 Golden Model 输出

作者: rtl-verf
日期: 2026-03-26
版本: v1.0
"""

import os
import sys
import argparse
import numpy as np
from pathlib import Path
from dataclasses import dataclass
from typing import List, Tuple, Optional


@dataclass
class ComparisonResult:
    """比对结果"""
    match: bool
    total_pixels: int
    matched_pixels: int
    mismatched_pixels: int
    max_diff: int
    mean_diff: float
    mismatched_indices: List[int]
    mismatched_expected: List[int]
    mismatched_actual: List[int]


class CoverageCollector:
    """覆盖率收集器"""

    def __init__(self):
        self.input_values = set()
        self.output_values = set()
        self.diff_values = []

    def add_sample(self, expected: int, actual: int, diff: int):
        """添加样本"""
        self.input_values.add(expected)
        self.output_values.add(actual)
        self.diff_values.append(diff)

    def get_coverage_report(self) -> str:
        """获取覆盖率报告"""
        report = []
        report.append("=" * 50)
        report.append("覆盖率报告")
        report.append("=" * 50)
        report.append(f"输入值覆盖: {len(self.input_values)} 个不同值")
        report.append(f"输出值覆盖: {len(self.output_values)} 个不同值")
        report.append(f"差值范围: {min(self.diff_values)} ~ {max(self.diff_values)}")
        report.append(f"平均绝对差值: {np.mean(np.abs(self.diff_values)):.2f}")
        report.append("=" * 50)
        return "\n".join(report)


class ResultComparator:
    """结果比对器"""

    def __init__(self, tolerance: int = 0):
        """
        初始化比对器

        Args:
            tolerance: 误差容差 (允许的最大差值)
        """
        self.tolerance = tolerance
        self.coverage = CoverageCollector()

    def load_hex_file(self, filepath: Path) -> np.ndarray:
        """加载十六进制文件"""
        values = []
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    try:
                        values.append(int(line, 16))
                    except ValueError:
                        continue
        return np.array(values, dtype=np.int32)

    def save_hex_file(self, values: np.ndarray, filepath: Path):
        """保存十六进制文件"""
        with open(filepath, 'w') as f:
            for v in values:
                f.write(f"{int(v) & 0x3FF:03x}\n")

    def compare(self, expected: np.ndarray, actual: np.ndarray) -> ComparisonResult:
        """
        比较期望输出与实际输出

        Args:
            expected: 期望输出 (golden model)
            actual: 实际输出 (RTL)

        Returns:
            比对结果
        """
        # 确保长度匹配
        min_len = min(len(expected), len(actual))
        expected = expected[:min_len]
        actual = actual[:min_len]

        # 计算差异
        diff = np.abs(expected.astype(np.int32) - actual.astype(np.int32))

        # 找出不匹配的像素
        if self.tolerance > 0:
            mismatches = diff > self.tolerance
        else:
            mismatches = diff != 0

        matched = np.sum(~mismatches)
        mismatched = np.sum(mismatches)

        # 收集覆盖率
        for i in range(min_len):
            self.coverage.add_sample(expected[i], actual[i], diff[i])

        # 记录不匹配的索引
        mismatched_indices = np.where(mismatches)[0].tolist()
        mismatched_expected = expected[mismatches].tolist()
        mismatched_actual = actual[mismatches].tolist()

        return ComparisonResult(
            match=(mismatched == 0),
            total_pixels=min_len,
            matched_pixels=int(matched),
            mismatched_pixels=int(mismatched),
            max_diff=int(np.max(diff)),
            mean_diff=float(np.mean(diff)),
            mismatched_indices=mismatched_indices[:100],  # 只记录前100个
            mismatched_expected=mismatched_expected[:100],
            mismatched_actual=mismatched_actual[:100]
        )

    def print_result(self, result: ComparisonResult, verbose: bool = True):
        """打印比对结果"""
        print("\n" + "=" * 60)
        print("RTL vs Golden Model 比对结果")
        print("=" * 60)
        print(f"总像素数:     {result.total_pixels}")
        print(f"匹配像素数:   {result.matched_pixels}")
        print(f"不匹配像素数: {result.mismatched_pixels}")
        print(f"匹配率:       {100 * result.matched_pixels / result.total_pixels:.2f}%")
        print(f"最大差值:     {result.max_diff}")
        print(f"平均差值:     {result.mean_diff:.4f}")
        print("=" * 60)

        if result.mismatched_pixels > 0 and verbose:
            print("\n前10个不匹配的像素:")
            print(f"{'索引':<10} {'期望':<10} {'实际':<10} {'差值':<10}")
            print("-" * 40)
            for i in range(min(10, len(result.mismatched_indices))):
                idx = result.mismatched_indices[i]
                exp = result.mismatched_expected[i]
                act = result.mismatched_actual[i]
                print(f"{idx:<10} {exp:<10} {act:<10} {abs(exp - act):<10}")

        if result.match:
            print("\n✓ 结果匹配！")
        else:
            print(f"\n✗ 发现 {result.mismatched_pixels} 个不匹配像素")


def main():
    parser = argparse.ArgumentParser(description='比对 RTL 与 Golden Model 结果')
    parser.add_argument('--expected', type=str, required=True,
                        help='期望输出文件 (Golden Model)')
    parser.add_argument('--actual', type=str, required=True,
                        help='实际输出文件 (RTL)')
    parser.add_argument('--tolerance', type=int, default=0,
                        help='误差容差')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='详细输出')
    args = parser.parse_args()

    comparator = ResultComparator(tolerance=args.tolerance)

    # 加载结果
    expected = comparator.load_hex_file(args.expected)
    actual = comparator.load_hex_file(args.actual)

    print(f"期望输出: {len(expected)} 个像素")
    print(f"实际输出: {len(actual)} 个像素")

    # 比较
    result = comparator.compare(expected, actual)
    comparator.print_result(result, verbose=args.verbose)

    # 打印覆盖率报告
    print(comparator.coverage.get_coverage_report())

    # 返回状态
    sys.exit(0 if result.match else 1)


if __name__ == '__main__':
    main()