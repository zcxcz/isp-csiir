#!/usr/bin/env python3
"""Generate test patterns for ISP-CSIIR verification"""

import argparse
import json
import numpy as np
from pathlib import Path

PATTERNS = {
    'zeros': lambda h, w: np.zeros((h, w), dtype=np.int32),
    'ramp': lambda h, w: np.fromfunction(lambda j, i: (i + j) % 1024, (h, w), dtype=np.int32),
    'random': lambda h, w, seed=None: np.random.RandomState(seed).randint(0, 1024, (h, w), dtype=np.int32),
    'checkerboard': lambda h, w: np.fromfunction(lambda j, i: ((i // 8) + (j // 8)) % 2 * 1023, (h, w), dtype=np.int32),
    'max': lambda h, w: np.full((h, w), 1023, dtype=np.int32),
    'gradient': lambda h, w: np.fromfunction(lambda j, i: (i * 4) % 1024, (h, w), dtype=np.int32),
}


def main():
    parser = argparse.ArgumentParser(description='Generate ISP-CSIIR test patterns')
    parser.add_argument('--config', type=str, help='配置文件 (JSON)')
    parser.add_argument('--pattern', default='random', choices=list(PATTERNS.keys()))
    parser.add_argument('--width', type=int, default=16)
    parser.add_argument('--height', type=int, default=16)
    parser.add_argument('--seed', type=int, default=None, help='随机种子')
    parser.add_argument('--output', type=str, required=True, help='输出 hex 文件')
    args = parser.parse_args()

    # 从配置文件加载
    if args.config:
        with open(args.config, 'r') as f:
            config = json.load(f)
        width = config.get('width', args.width)
        height = config.get('height', args.height)
        pattern = config.get('pattern', args.pattern)
        seed = config.get('seed', args.seed)
    else:
        width = args.width
        height = args.height
        pattern = args.pattern
        seed = args.seed

    # 生成图像
    if pattern == 'random':
        img = PATTERNS[pattern](height, width, seed=seed)
    else:
        img = PATTERNS[pattern](height, width)

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, 'w') as f:
        for row in img:
            for v in row:
                f.write(f'{v:03x}\n')

    print(f"Pattern: {pattern} ({width}x{height})")
    if seed is not None:
        print(f"Seed: {seed}")
    print(f"Input range: [{img.min()}, {img.max()}]")
    print(f"Output: {args.output}")

if __name__ == '__main__':
    main()
