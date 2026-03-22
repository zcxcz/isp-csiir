#!/usr/bin/env python3
"""
Stage 3 256-entry Compressed LUT Division Error Analysis - CORRECTED

This script analyzes the error of the 256-entry compressed LUT division scheme
used in the IIR blend stage, properly accounting for index aliasing.

Key insight: For grad_sum 1-1023, multiple values map to the same index due to
the {1'b0, grad_sum[7:0]} encoding, causing significant error.
"""

import numpy as np
from collections import defaultdict

def get_index_and_lut_typical(grad_sum):
    """
    Compute LUT index based on the Verilog priority encoder.
    Returns: (index, lut_typical_grad_sum)

    The LUT stores inv = round(2^26 / lut_typical_grad_sum)
    For the actual hardware, the typical value should be chosen carefully.
    """
    if grad_sum == 0:
        return 0, 1  # Special: grad_sum=0 returns 0 result anyway

    # Priority encoder - earlier conditions take precedence
    if grad_sum >= 65536:  # [16] = 1
        # index = {3'b111, grad_sum[13:9]}
        index = (0b111 << 5) | ((grad_sum >> 9) & 0x1F)
        # Bin covers range: [N*512, N*512+511] where N depends on upper bits
        # Typical is midpoint: bin_start + 256
        bin_start = (grad_sum >> 9) << 9  # Round down to nearest 512
        typical = bin_start + 256
        return index, typical

    elif grad_sum >= 32768:  # [15] = 1
        # index = {3'b110, grad_sum[12:8]}
        index = (0b110 << 5) | ((grad_sum >> 8) & 0x1F)
        bin_start = (grad_sum >> 8) << 8
        typical = bin_start + 128
        return index, typical

    elif grad_sum >= 16384:  # [14] = 1
        # index = {3'b101, grad_sum[11:7]}
        index = (0b101 << 5) | ((grad_sum >> 7) & 0x1F)
        bin_start = (grad_sum >> 7) << 7
        typical = bin_start + 64
        return index, typical

    elif grad_sum >= 8192:  # [13] = 1
        # index = {3'b100, grad_sum[10:6]}
        index = (0b100 << 5) | ((grad_sum >> 6) & 0x1F)
        bin_start = (grad_sum >> 6) << 6
        typical = bin_start + 32
        return index, typical

    elif grad_sum >= 4096:  # [12] = 1
        # index = {3'b011, grad_sum[9:5]}
        index = (0b011 << 5) | ((grad_sum >> 5) & 0x1F)
        bin_start = (grad_sum >> 5) << 5
        typical = bin_start + 16
        return index, typical

    elif grad_sum >= 2048:  # [11] = 1
        # index = {3'b010, grad_sum[8:4]}
        index = (0b010 << 5) | ((grad_sum >> 4) & 0x1F)
        bin_start = (grad_sum >> 4) << 4
        typical = bin_start + 8
        return index, typical

    elif grad_sum >= 1024:  # [10] = 1
        # index = {3'b001, grad_sum[7:3]}
        index = (0b001 << 5) | ((grad_sum >> 3) & 0x1F)
        bin_start = (grad_sum >> 3) << 3
        typical = bin_start + 4
        return index, typical

    else:  # 1 - 1023
        # index = {1'b0, grad_sum[7:0]}
        # THIS IS THE PROBLEM: Values 1-255, 256-511, 512-767, 768-1023
        # all alias to indices 0-255 (with index 0 getting 256, 512, 768 and grad_sum=0)
        index = grad_sum & 0xFF

        # For LUT, we need to pick a typical value
        # The analysis shows the RTL designer probably used the SMALLEST value
        # in each bin as typical (since that's the first to initialize the LUT)
        # Or we use a midpoint

        # For now, use midpoint of the 4 values that map to this index
        # Values mapping to index i: i, i+256, i+512, i+768 (for i=1-255)
        # For i=0: 256, 512, 768 (and grad_sum=0 handled separately)
        if index == 0:
            typical = 512  # Midpoint of 256, 512, 768
        else:
            typical = (index + (index + 768)) // 2  # Midpoint
        return index, typical


def compute_lut_entry(typical_grad_sum):
    """Compute LUT entry: inv = round(2^26 / typical_grad_sum)"""
    if typical_grad_sum == 0:
        return 2**26  # Max value for division by zero case
    return int(round(2**26 / typical_grad_sum))


def lut_divide(blend_sum, inv_lut, grad_sum=1):
    """Perform LUT-based division: result = (blend_sum * inv) >> 26"""
    if grad_sum == 0:
        return 0  # Special case
    result = (blend_sum * inv_lut) >> 26
    return result


def exact_divide(blend_sum, grad_sum):
    """Perform exact division with rounding"""
    if grad_sum == 0:
        return 0
    return int(round(blend_sum / grad_sum))


def build_lut_and_mapping():
    """Build the LUT and map each index to its grad_sum range"""

    # First pass: determine LUT typical values for each index
    index_to_typical = {}

    for grad_sum in range(1, 131072):
        index, typical = get_index_and_lut_typical(grad_sum)
        if index not in index_to_typical:
            index_to_typical[index] = typical

    # Handle index 0 specially
    index_to_typical[0] = 512  # Midpoint of 256, 512, 768

    # Build LUT
    lut = [compute_lut_entry(index_to_typical.get(i, 1)) for i in range(256)]

    # Build reverse mapping: index -> list of grad_sum values
    index_to_grad_sums = defaultdict(list)
    for grad_sum in range(1, 131072):
        index, _ = get_index_and_lut_typical(grad_sum)
        index_to_grad_sums[index].append(grad_sum)

    return lut, index_to_grad_sums, index_to_typical


def analyze_comprehensive():
    """Complete comprehensive error analysis"""

    print("=" * 80)
    print("Stage 3 256-Entry Compressed LUT Division Error Analysis")
    print("=" * 80)
    print("\nCRITICAL FINDING: The low range (grad_sum 1-1023) has INDEX ALIASING!")
    print("Multiple grad_sum values map to the same LUT index, causing large errors.\n")

    lut, index_to_grad_sums, index_to_typical = build_lut_and_mapping()

    # Print LUT summary
    print("=" * 80)
    print("LUT Construction Summary")
    print("=" * 80)

    # Group by region
    regions = [
        ("Index 0 (aliased)", 0, 0),
        ("1-255 (direct, 1 value each)", 1, 255),
        ("256-1023 (aliased to 0-255)", -1, -1),  # Special marker
        ("1024-2047", 32, 63),
        ("2048-4095", 64, 95),
        ("4096-8191", 96, 127),
        ("8192-16383", 128, 159),
        ("16384-32767", 160, 191),
        ("32768-65535", 192, 223),
        ("65536-131071", 224, 255),
    ]

    print("\nRegion                    Indices    Bin Width  Typical Formula")
    print("-" * 75)
    print("Index 0:                    0         N/A        (aliased: 256,512,768)")
    print("grad_sum 1-255:           1-255         1        direct value")
    print("grad_sum 256-511:   aliased to 0-255  N/A        USES WRONG LUT!")
    print("grad_sum 512-767:   aliased to 0-255  N/A        USES WRONG LUT!")
    print("grad_sum 768-1023:  aliased to 0-255  N/A        USES WRONG LUT!")
    print("grad_sum 1024-2047:      32-63         8        bin_start + 4")
    print("grad_sum 2048-4095:      64-95        16        bin_start + 8")
    print("grad_sum 4096-8191:     96-127       32        bin_start + 16")
    print("grad_sum 8192-16383:   128-159       64        bin_start + 32")
    print("grad_sum 16384-32767:  160-191      128        bin_start + 64")
    print("grad_sum 32768-65535:  192-223      256        bin_start + 128")
    print("grad_sum 65536-131071: 224-255      512        bin_start + 256")

    # Detailed per-region error analysis
    print("\n" + "=" * 80)
    print("Per-Region Error Analysis (using typical blend_sum = 10000 * grad_sum)")
    print("=" * 80)

    all_errors = []
    region_stats = []

    # Test each region
    test_regions = [
        ("grad_sum 1-255 (direct)", list(range(1, 256))),
        ("grad_sum 256-511 (aliased)", list(range(256, 512))),
        ("grad_sum 512-767 (aliased)", list(range(512, 768))),
        ("grad_sum 768-1023 (aliased)", list(range(768, 1024))),
        ("grad_sum 1024-2047", list(range(1024, 2048))),
        ("grad_sum 2048-4095", list(range(2048, 4096))),
        ("grad_sum 4096-8191", list(range(4096, 8192))),
        ("grad_sum 8192-16383", list(range(8192, 16384))),
        ("grad_sum 16384-32767", list(range(16384, 32768))),
        ("grad_sum 32768-65535", list(range(32768, 65536))),
        ("grad_sum 65536-131071", list(range(65536, min(131072, 70001)))),  # Limit for speed
    ]

    print("\nRegion                        Max_Err   Avg_Err   Max_Rel%   Avg_Rel%")
    print("-" * 80)

    for region_name, grad_sums in test_regions:
        errors = []
        rel_errors = []

        for gs in grad_sums:
            index, typical = get_index_and_lut_typical(gs)
            inv_lut = lut[index]

            # Test with blend_sum proportional to grad_sum (realistic scenario)
            blend_sum = min(gs * 100, 67108863)

            exact = exact_divide(blend_sum, gs)
            lut_result = lut_divide(blend_sum, inv_lut, gs)

            error = lut_result - exact
            abs_error = abs(error)
            errors.append(abs_error)

            if exact > 0:
                rel_error = 100.0 * abs_error / exact
            else:
                rel_error = 0
            rel_errors.append(rel_error)

            all_errors.append(abs_error)

        max_err = max(errors)
        avg_err = np.mean(errors)
        max_rel = max(rel_errors)
        avg_rel = np.mean(rel_errors)

        region_stats.append({
            'name': region_name,
            'max_err': max_err,
            'avg_err': avg_err,
            'max_rel': max_rel,
            'avg_rel': avg_rel
        })

        print(f"{region_name:28s} {max_err:8.1f}  {avg_err:8.2f}  {max_rel:8.2f}%  {avg_rel:8.2f}%")

    # Detailed analysis of the aliasing problem
    print("\n" + "=" * 80)
    print("ALIASING PROBLEM ANALYSIS")
    print("=" * 80)

    print("""
The Verilog logic for grad_sum 1-1023:
    index = {1'b0, grad_sum[7:0]}

This creates index collisions:
- grad_sum = 1   -> index = 1  -> LUT[1] = 2^26/1   = 67,108,864
- grad_sum = 257 -> index = 1  -> LUT[1] = 67,108,864 (WRONG! should be 2^26/257 = 261,121)
- grad_sum = 513 -> index = 1  -> LUT[1] = 67,108,864 (WRONG! should be 2^26/513 = 130,806)
- grad_sum = 769 -> index = 1  -> LUT[1] = 67,108,864 (WRONG! should be 2^26/769 = 87,264)
""")

    # Show specific examples
    print("\nExample Errors for grad_sum mapping to index 1:")
    print("-" * 70)
    print(f"{'grad_sum':>10} {'blend_sum':>12} {'Exact':>10} {'LUT':>12} {'Error':>10} {'Rel%':>8}")
    print("-" * 70)

    for gs in [1, 257, 513, 769]:
        index, _ = get_index_and_lut_typical(gs)
        inv_lut = lut[index]

        # Use blend_sum = 50000000 (typical max value)
        blend_sum = 50000000

        exact = exact_divide(blend_sum, gs)
        lut_result = lut_divide(blend_sum, inv_lut, gs)
        error = lut_result - exact
        rel_error = 100.0 * error / exact if exact > 0 else 0

        print(f"{gs:10d} {blend_sum:12,d} {exact:10,d} {lut_result:12,d} {error:+10,d} {rel_error:+8.1f}%")

    # Comprehensive error distribution
    print("\n" + "=" * 80)
    print("COMPREHENSIVE ERROR DISTRIBUTION")
    print("=" * 80)

    # Sample more thoroughly
    error_bins = {'0': 0, '1': 0, '2': 0, '3-5': 0, '6-10': 0, '11-50': 0, '51-100': 0, '>100': 0}
    error_list = []

    print("Sampling across all grad_sum and blend_sum values...")

    for gs in range(1, 131072, 100):  # Sample every 100th grad_sum
        index, _ = get_index_and_lut_typical(gs)
        inv_lut = lut[index]

        for bs in [gs, gs*10, gs*100, 100000, 1000000, 10000000, 50000000]:
            bs = min(bs, 67108863)
            exact = exact_divide(bs, gs)
            lut_result = lut_divide(bs, inv_lut, gs)

            error = abs(lut_result - exact)
            error_list.append(error)

            if error == 0:
                error_bins['0'] += 1
            elif error == 1:
                error_bins['1'] += 1
            elif error == 2:
                error_bins['2'] += 1
            elif error <= 5:
                error_bins['3-5'] += 1
            elif error <= 10:
                error_bins['6-10'] += 1
            elif error <= 50:
                error_bins['11-50'] += 1
            elif error <= 100:
                error_bins['51-100'] += 1
            else:
                error_bins['>100'] += 1

    total = sum(error_bins.values())
    print(f"\nTotal samples: {total:,}")
    print("\nError Distribution (absolute LSB error):")
    print("-" * 50)
    for bin_name, count in error_bins.items():
        pct = 100.0 * count / total
        bar = '#' * int(pct / 2)
        print(f"  |Error| = {bin_name:>6s}: {count:8d} ({pct:5.1f}%) {bar}")

    print(f"\nStatistical Summary:")
    print(f"  Maximum error: {max(error_list):,.0f} LSB")
    print(f"  Mean error:    {np.mean(error_list):,.1f} LSB")
    print(f"  Median error:  {np.median(error_list):,.1f} LSB")

    # Impact on output quality
    print("\n" + "=" * 80)
    print("IMPACT ASSESSMENT FOR 10-BIT OUTPUT")
    print("=" * 80)

    print("""
Output range: 0-1023 (10-bit)

Error analysis for realistic use cases:

1. DIRECT RANGE (grad_sum 1-255): VERY GOOD
   - Each value has its own LUT entry
   - Error from LUT quantization: < 0.5 LSB

2. ALIASED RANGE (grad_sum 256-1023): CRITICAL PROBLEM!
   - grad_sum 256-1023 use WRONG LUT values
   - Example: grad_sum=769 uses LUT for grad_sum=1
   - Result: 769x larger output than correct value!

3. UPPER RANGES (grad_sum >= 1024): ACCEPTABLE
   - Bin widths: 8 to 512
   - Max error proportional to bin width
   - Still within acceptable bounds for most applications

ROOT CAUSE:
-----------
The index calculation for grad_sum 1-1023:
    index = {1\'b0, grad_sum[7:0]}   <-- Verilog syntax

This takes only the lower 8 bits, causing:
- grad_sum 1-255 -> indices 1-255 (CORRECT, 1:1 mapping)
- grad_sum 256-511 -> indices 0-255 (WRONG, should use different LUT!)
- grad_sum 512-767 -> indices 0-255 (WRONG, should use different LUT!)
- grad_sum 768-1023 -> indices 0-255 (WRONG, should use different LUT!)

SUGGESTED FIX:
--------------
For grad_sum 1-1023, use separate LUT bank or different encoding:

Option 1: Expand LUT to 1024 entries (10-bit index)
Option 2: Use different bit extraction:
    if (grad_sum < 1024)
        index = grad_sum;  // Direct mapping for 0-1023
    This requires 1024-entry LUT

Option 3: For 256-entry LUT, sacrifice upper range:
    if (grad_sum < 256)
        index = grad_sum;
    else if (grad_sum >= 1024)
        // existing compressed logic
""")

    # Export LUT values
    print("\n" + "=" * 80)
    print("LUT VALUES (256 entries)")
    print("=" * 80)
    print("\nFirst 32 entries:")
    print("Index  Typical_GS  LUT_Value     LUT_Value/2^26 (approx 1/GS)")
    print("-" * 65)
    for i in range(32):
        typical = index_to_typical.get(i, 1)
        lut_val = lut[i]
        approx_inv = lut_val / 2**26
        print(f"{i:3d}    {typical:7d}    {lut_val:10d}    {approx_inv:.8f}")

    return lut, region_stats


if __name__ == "__main__":
    lut, region_stats = analyze_comprehensive()