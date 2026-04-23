#!/usr/bin/env python3
"""Generate test patterns for ISP-CSIIR verification"""

import argparse
import numpy as np
from pathlib import Path

PATTERNS = {
    'zeros': lambda h, w: np.zeros((h, w), dtype=np.int32),
    'ramp': lambda h, w: np.fromfunction(lambda j, i: (i + j) % 1024, (h, w), dtype=np.int32),
    'random': lambda h, w: (np.random.seed(42) or np.random.randint(0, 1024, (h, w), dtype=np.int32)),
    'checkerboard': lambda h, w: np.fromfunction(lambda j, i: ((i // 8) + (j // 8)) % 2 * 1023, (h, w), dtype=np.int32),
    'max': lambda h, w: np.full((h, w), 1023, dtype=np.int32),
    'gradient': lambda h, w: np.fromfunction(lambda j, i: (i * 4) % 1024, (h, w), dtype=np.int32),
}

def main():
    parser = argparse.ArgumentParser(description='Generate ISP-CSIIR test patterns')
    parser.add_argument('--pattern', default='random', choices=list(PATTERNS.keys()))
    parser.add_argument('--width', type=int, default=16)
    parser.add_argument('--height', type=int, default=16)
    parser.add_argument('--output', type=str, required=True)
    args = parser.parse_args()

    img = PATTERNS[args.pattern](args.height, args.width)

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, 'w') as f:
        for row in img:
            for v in row:
                f.write(f'{v:03x}\n')

    print(f"Pattern: {args.pattern} ({args.width}x{args.height})")
    print(f"Input range: [{img.min()}, {img.max()}]")
    print(f"Output: {args.output}")

if __name__ == '__main__':
    main()
