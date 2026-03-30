#!/usr/bin/env python3
"""
ISP-CSIIR 测试配置生成器

生成测试激励、配置参数和预期输出

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
from typing import List, Optional, Tuple


@dataclass
class TestConfig:
    """测试配置"""
    img_width: int = 64
    img_height: int = 64
    win_size_thresh: List[int] = None
    win_size_clip_y: List[int] = None
    blending_ratio: List[int] = None

    def __post_init__(self):
        if self.win_size_thresh is None:
            self.win_size_thresh = [16, 24, 32, 40]
        if self.win_size_clip_y is None:
            self.win_size_clip_y = [400, 650, 900, 1023]
        if self.blending_ratio is None:
            self.blending_ratio = [32, 32, 32, 32]


class ConfigGenerator:
    """配置生成器"""

    def __init__(self, seed: int = 0):
        """初始化生成器"""
        self.rng = np.random.default_rng(seed)

    def generate_random_config(self) -> TestConfig:
        """生成随机配置"""
        return TestConfig(
            img_width=self.rng.integers(16, 128),
            img_height=self.rng.integers(16, 128),
            win_size_thresh=[
                self.rng.integers(8, 32),
                self.rng.integers(16, 48),
                self.rng.integers(24, 64),
                self.rng.integers(32, 80)
            ],
            win_size_clip_y=[
                self.rng.integers(200, 500),
                self.rng.integers(400, 700),
                self.rng.integers(600, 900),
                self.rng.integers(800, 1023)
            ],
            blending_ratio=[
                self.rng.integers(16, 64),
                self.rng.integers(16, 64),
                self.rng.integers(16, 64),
                self.rng.integers(16, 64)
            ]
        )

    def generate_stimulus(self, config: TestConfig, pattern: str = "random") -> np.ndarray:
        """
        生成测试激励

        Args:
            config: 测试配置
            pattern: 激励模式 (random/ramp/checker/corner/gradient)

        Returns:
            输入像素数组
        """
        size = config.img_width * config.img_height

        if pattern == "random":
            return self.rng.integers(0, 1024, size, dtype=np.uint16)
        elif pattern == "ramp":
            return np.mod(np.arange(size, dtype=np.uint16), 1024)
        elif pattern == "checker":
            x = np.arange(config.img_width)
            y = np.arange(config.img_height)
            xx, yy = np.meshgrid(x, y)
            checker = (xx + yy) % 2
            return (checker * 1023).flatten().astype(np.uint16)
        elif pattern == "corner":
            arr = np.zeros(size, dtype=np.uint16)
            arr[0] = 1023
            arr[-1] = 1023
            arr[config.img_width - 1] = 511
            arr[config.img_width] = 511
            return arr
        elif pattern == "gradient":
            x = np.arange(config.img_width)
            y = np.arange(config.img_height)
            xx, yy = np.meshgrid(x, y)
            gradient = (xx * 1023 // config.img_width + yy * 1023 // config.img_height) // 2
            return gradient.flatten().astype(np.uint16)
        else:
            return self.rng.integers(0, 1024, size, dtype=np.uint16)

    def save_stimulus(self, stimulus: np.ndarray, output_path: Path):
        """保存激励到文件"""
        with open(output_path, 'w') as f:
            for val in stimulus:
                f.write(f"{val:03x}\n")

    def save_config(self, config: TestConfig, output_path: Path):
        """保存配置到文件"""
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


def main():
    parser = argparse.ArgumentParser(description='生成测试配置和激励')
    parser.add_argument('--output', type=str, default='test_data',
                        help='输出目录')
    parser.add_argument('--seed', type=int, default=0,
                        help='随机种子')
    parser.add_argument('--pattern', type=str, default='random',
                        choices=['random', 'ramp', 'checker', 'corner', 'gradient'],
                        help='激励模式')
    parser.add_argument('--width', type=int, default=64,
                        help='图像宽度')
    parser.add_argument('--height', type=int, default=64,
                        help='图像高度')
    args = parser.parse_args()

    # 创建输出目录
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # 生成配置
    generator = ConfigGenerator(seed=args.seed)

    if args.pattern == 'random':
        config = generator.generate_random_config()
    else:
        config = TestConfig(img_width=args.width, img_height=args.height)

    # 生成激励
    stimulus = generator.generate_stimulus(config, args.pattern)

    # 保存
    generator.save_config(config, output_dir / 'config.txt')
    generator.save_stimulus(stimulus, output_dir / 'stimulus.hex')

    print(f"生成了 {len(stimulus)} 个像素")
    print(f"图像尺寸: {config.img_width} x {config.img_height}")
    print(f"配置已保存到: {output_dir / 'config.txt'}")
    print(f"激励已保存到: {output_dir / 'stimulus.hex'}")


if __name__ == '__main__':
    main()