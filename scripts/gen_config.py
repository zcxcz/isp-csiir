#!/usr/bin/env python3
"""
ISP-CSIIR 配置生成器 - 生成随机算法配置

用法:
    python3 gen_config.py --seed 42 --width 16 --height 16 --output config.json
"""

import argparse
import json
import random


def generate_random_config(seed=None, width=16, height=16):
    """生成随机算法配置"""
    if seed is not None:
        random.seed(seed)

    # 窗口阈值 [t0, t1, t2, t3] - 控制窗口大小选择
    win_thresh = sorted([
        random.randint(50, 200),
        random.randint(150, 350),
        random.randint(300, 500),
        random.randint(450, 700)
    ])

    # 梯度裁剪阈值 [g0, g1, g2, g3]
    grad_clip = sorted([
        random.randint(10, 25),
        random.randint(20, 35),
        random.randint(28, 42),
        random.randint(35, 50)
    ])

    # 混合比例 [b0, b1, b2, b3] - 0-64范围
    blend_ratio = [
        random.randint(0, 64),
        random.randint(0, 64),
        random.randint(0, 64),
        random.randint(0, 64)
    ]

    # 边缘保护等级 0-64
    edge_protect = random.randint(0, 64)

    config = {
        "width": width,
        "height": height,
        "pattern": "random",
        "seed": seed if seed is not None else random.randint(0, 999999),
        "win_thresh": win_thresh,
        "grad_clip": grad_clip,
        "blend_ratio": blend_ratio,
        "edge_protect": edge_protect
    }

    return config


def main():
    parser = argparse.ArgumentParser(description='ISP-CSIIR 配置生成器')
    parser.add_argument('--seed', type=int, default=None, help='随机种子')
    parser.add_argument('--width', type=int, default=16, help='图像宽度')
    parser.add_argument('--height', type=int, default=16, help='图像高度')
    parser.add_argument('--output', type=str, required=True, help='输出配置文件')
    parser.add_argument('--min-config', action='store_true', help='生成最小配置（仅必需参数）')

    args = parser.parse_args()

    config = generate_random_config(seed=args.seed, width=args.width, height=args.height)

    if args.min_config:
        # 最小配置：只包含与默认不同的参数
        defaults = {
            "win_thresh": [100, 200, 400, 800],
            "grad_clip": [15, 23, 31, 39],
            "blend_ratio": [32, 32, 32, 32],
            "edge_protect": 32
        }
        minimal = {k: v for k, v in config.items() if k in ['width', 'height', 'pattern', 'seed']}
        for k, v in config.items():
            if k in defaults and v != defaults[k]:
                minimal[k] = v
        config = minimal

    with open(args.output, 'w') as f:
        json.dump(config, f, indent=2)

    print(f"配置已生成: {args.output}")
    print(f"  图像尺寸: {config['width']}x{config['height']}")
    print(f"  随机种子: {config['seed']}")
    if 'win_thresh' in config:
        print(f"  窗口阈值: {config['win_thresh']}")
    if 'grad_clip' in config:
        print(f"  梯度裁剪: {config['grad_clip']}")
    if 'blend_ratio' in config:
        print(f"  混合比例: {config['blend_ratio']}")
    if 'edge_protect' in config:
        print(f"  边缘保护: {config['edge_protect']}")


if __name__ == '__main__':
    main()
