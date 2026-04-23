#!/usr/bin/env python3
"""Compare Python and HLS outputs for ISP-CSIIR"""

import argparse
import numpy as np

def load_hex(filepath):
    values = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # Handle both space-separated and line-separated formats
            for val in line.split():
                try:
                    values.append(int(val, 16))
                except ValueError:
                    continue
    return np.array(values)

def main():
    parser = argparse.ArgumentParser(description='Compare Python vs HLS output')
    parser.add_argument('--python', required=True, help='Python output hex file')
    parser.add_argument('--hls', required=True, help='HLS output hex file')
    args = parser.parse_args()

    py_out = load_hex(args.python)
    hl_out = load_hex(args.hls)

    if len(py_out) != len(hl_out):
        print(f"Length mismatch: Python={len(py_out)}, HLS={len(hl_out)}")
        return 1

    diff = np.abs(py_out.astype(int) - hl_out.astype(int))
    max_diff = int(np.max(diff))
    mean_diff = float(np.mean(diff))
    match_count = int(np.sum(diff == 0))
    total = len(diff)

    print(f"Python output: min={py_out.min()}, max={py_out.max()}")
    print(f"HLS output:    min={hl_out.min()}, max={hl_out.max()}")
    print(f"Max diff: {max_diff}, Mean diff: {mean_diff:.4f}")
    print(f"Match: {match_count}/{total} pixels ({100*match_count/total:.1f}%)")

    if max_diff == 0:
        print("[PASS] Outputs match exactly!")
        return 0
    else:
        print(f"[INFO] {total - match_count} pixels differ")
        return 1

if __name__ == '__main__':
    exit(main())
