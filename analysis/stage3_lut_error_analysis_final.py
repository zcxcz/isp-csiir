#!/usr/bin/env python3
"""
Stage 3 256-entry Compressed LUT Division Error Analysis

Based on the actual Verilog implementation from docs/stage3_division_lut_eval.md

Index compression logic:
    if (grad_sum[16])           // >= 65536
        compress_index = {3'b111, grad_sum[13:9]};
    else if (grad_sum[15])      // >= 32768
        compress_index = {3'b110, grad_sum[12:8]};
    else if (grad_sum[14])      // >= 16384
        compress_index = {3'b101, grad_sum[11:7]};
    else if (grad_sum[13])      // >= 8192
        compress_index = {3'b100, grad_sum[10:6]};
    else if (grad_sum[12])      // >= 4096
        compress_index = {3'b011, grad_sum[9:5]};
    else if (grad_sum[11])      // >= 2048
        compress_index = {3'b010, grad_sum[8:4]};
    else if (grad_sum[10:8] != 0) // 256-2047
        compress_index = {2'b01, grad_sum[9:4]};
    else                        // 0-255
        compress_index = {1'b0, grad_sum[7:0]};
"""

import numpy as np
from collections import defaultdict

def get_index_and_typical(grad_sum):
    """
    Compute LUT index based on the actual Verilog priority encoder.
    Returns: (index, typical_grad_sum, bin_min, bin_max, bin_width)
    """
    if grad_sum == 0:
        return 0, 1, 0, 0, 0

    if grad_sum >= 65536:  # bit 16 set
        # index = {3'b111, grad_sum[13:9]} = 224 + (grad_sum[13:9])
        index = (0b111 << 5) | ((grad_sum >> 9) & 0x1F)
        bin_min = (grad_sum >> 9) << 9
        bin_max = bin_min + 511
        typical = bin_min + 256  # midpoint
        return index, typical, bin_min, bin_max, 512

    elif grad_sum >= 32768:  # bit 15 set
        # index = {3'b110, grad_sum[12:8]} = 192 + (grad_sum[12:8])
        index = (0b110 << 5) | ((grad_sum >> 8) & 0x1F)
        bin_min = (grad_sum >> 8) << 8
        bin_max = bin_min + 255
        typical = bin_min + 128
        return index, typical, bin_min, bin_max, 256

    elif grad_sum >= 16384:  # bit 14 set
        # index = {3'b101, grad_sum[11:7]} = 160 + (grad_sum[11:7])
        index = (0b101 << 5) | ((grad_sum >> 7) & 0x1F)
        bin_min = (grad_sum >> 7) << 7
        bin_max = bin_min + 127
        typical = bin_min + 64
        return index, typical, bin_min, bin_max, 128

    elif grad_sum >= 8192:  # bit 13 set
        # index = {3'b100, grad_sum[10:6]} = 128 + (grad_sum[10:6])
        index = (0b100 << 5) | ((grad_sum >> 6) & 0x1F)
        bin_min = (grad_sum >> 6) << 6
        bin_max = bin_min + 63
        typical = bin_min + 32
        return index, typical, bin_min, bin_max, 64

    elif grad_sum >= 4096:  # bit 12 set
        # index = {3'b011, grad_sum[9:5]} = 96 + (grad_sum[9:5])
        index = (0b011 << 5) | ((grad_sum >> 5) & 0x1F)
        bin_min = (grad_sum >> 5) << 5
        bin_max = bin_min + 31
        typical = bin_min + 16
        return index, typical, bin_min, bin_max, 32

    elif grad_sum >= 2048:  # bit 11 set
        # index = {3'b010, grad_sum[8:4]} = 64 + (grad_sum[8:4])
        index = (0b010 << 5) | ((grad_sum >> 4) & 0x1F)
        bin_min = (grad_sum >> 4) << 4
        bin_max = bin_min + 15
        typical = bin_min + 8
        return index, typical, bin_min, bin_max, 16

    elif ((grad_sum >> 8) & 0x7) != 0:  # grad_sum[10:8] != 0, grad_sum 256-2047
        # index = {2'b01, grad_sum[9:4]} = 64 + (grad_sum[9:4])
        # Note: This gives indices 64-127
        index = (0b01 << 6) | ((grad_sum >> 4) & 0x3F)
        # For this range, each index covers multiple values
        # grad_sum[9:4] determines the index, so bin width = 16
        bin_min = (grad_sum >> 4) << 4
        bin_max = bin_min + 15
        typical = bin_min + 8
        return index, typical, bin_min, bin_max, 16

    else:  # grad_sum 0-255
        # index = {1'b0, grad_sum[7:0]} = grad_sum (for 8-bit index)
        # Actually in Verilog, {1'b0, grad_sum[7:0]} for 8-bit result = grad_sum[7:0]
        index = grad_sum & 0xFF
        bin_min = grad_sum
        bin_max = grad_sum
        typical = grad_sum
        return index, typical, bin_min, bin_max, 1


def compute_lut_entry(typical_grad_sum, scale=26):
    """Compute LUT entry: inv = round(2^scale / typical_grad_sum)"""
    if typical_grad_sum == 0:
        return 2**scale
    return int(round(2**scale / typical_grad_sum))


def lut_divide(blend_sum, inv_lut, scale=26):
    """Perform LUT-based division: result = (blend_sum * inv) >> scale"""
    result = (blend_sum * inv_lut) >> scale
    return result


def exact_divide(blend_sum, grad_sum):
    """Perform exact division with rounding"""
    if grad_sum == 0:
        return 0
    return int(round(blend_sum / grad_sum))


def analyze_index_overlap():
    """Check for index overlaps in the compression scheme"""
    print("=" * 80)
    print("Index Overlap Analysis")
    print("=" * 80)

    index_to_grad_sums = defaultdict(list)

    for gs in range(1, 131072):
        index, _, _, _, _ = get_index_and_typical(gs)
        index_to_grad_sums[index].append(gs)

    overlaps = []
    for idx, gs_list in sorted(index_to_grad_sums.items()):
        if len(gs_list) > 1:
            overlaps.append((idx, gs_list))

    if overlaps:
        print(f"\nWARNING: Found {len(overlaps)} indices with overlapping grad_sum values!")
        print("\nOverlapping indices:")
        for idx, gs_list in overlaps[:20]:  # Show first 20
            print(f"  Index {idx}: grad_sum values {min(gs_list)} - {max(gs_list)} ({len(gs_list)} values)")
        if len(overlaps) > 20:
            print(f"  ... and {len(overlaps) - 20} more")
    else:
        print("\nNo index overlaps found - each grad_sum maps to unique index!")

    return index_to_grad_sums


def build_lut(scale=26):
    """Build the complete 256-entry LUT"""
    lut = [0] * 256
    index_to_typical = {}

    for gs in range(1, 131072):
        index, typical, _, _, _ = get_index_and_typical(gs)
        if index not in index_to_typical:
            index_to_typical[index] = typical

    # Handle index 0 specially (grad_sum = 0)
    index_to_typical[0] = 1  # Will output 0 for grad_sum = 0 anyway

    for idx in range(256):
        if idx in index_to_typical:
            lut[idx] = compute_lut_entry(index_to_typical[idx], scale)
        else:
            lut[idx] = compute_lut_entry(1, scale)  # Default

    return lut, index_to_typical


def print_lut_table(lut, index_to_typical):
    """Print LUT values organized by region"""
    print("\n" + "=" * 80)
    print("LUT Values by Region")
    print("=" * 80)

    regions = [
        ("grad_sum 0-255 (indices 0-255)", 0, 255),
        ("grad_sum 256-2047 (indices 64-127)", 64, 127),
        ("grad_sum 2048-4095 (indices 64-95)", 64, 95),
        ("grad_sum 4096-8191 (indices 96-127)", 96, 127),
        ("grad_sum 8192-16383 (indices 128-159)", 128, 159),
        ("grad_sum 16384-32767 (indices 160-191)", 160, 191),
        ("grad_sum 32768-65535 (indices 192-223)", 192, 223),
        ("grad_sum 65536-131071 (indices 224-255)", 224, 255),
    ]

    for name, start, end in regions:
        print(f"\n{name}:")
        print("Index  Typical_GS  LUT_Value     Approx_1/GS")
        print("-" * 55)
        for i in range(start, min(end + 1, 256)):
            if i in index_to_typical:
                typical = index_to_typical[i]
                lut_val = lut[i]
                approx_inv = lut_val / 2**26
                print(f"{i:3d}    {typical:7d}    {lut_val:10d}    {approx_inv:.8f}")


def analyze_errors(lut, index_to_grad_sums, scale=26):
    """Comprehensive error analysis"""
    print("\n" + "=" * 80)
    print("Error Analysis")
    print("=" * 80)

    # Per-region error analysis
    regions = [
        ("grad_sum 1-255", list(range(1, 256))),
        ("grad_sum 256-1023", list(range(256, 1024))),
        ("grad_sum 1024-2047", list(range(1024, 2048))),
        ("grad_sum 2048-4095", list(range(2048, 4096))),
        ("grad_sum 4096-8191", list(range(4096, 8192))),
        ("grad_sum 8192-16383", list(range(8192, 16384))),
        ("grad_sum 16384-32767", list(range(16384, 32768))),
        ("grad_sum 32768-65535", list(range(32768, 65536))),
        ("grad_sum 65536-70000 (typical max)", list(range(65536, min(70001, 131072)))),
    ]

    print("\nRegion-wise Error Analysis (blend_sum = grad_sum * 1000, clipped to 26-bit max):")
    print("-" * 85)
    print(f"{'Region':<25} {'Bin_Width':<10} {'Max_Err':<10} {'Avg_Err':<10} {'Max_Rel%':<10} {'Avg_Rel%':<10}")
    print("-" * 85)

    all_errors = []

    for region_name, grad_sums in regions:
        errors = []
        rel_errors = []
        bin_widths = []

        for gs in grad_sums:
            index, typical, bin_min, bin_max, bin_width = get_index_and_typical(gs)
            bin_widths.append(bin_width)

            inv_lut = lut[index]

            # Test with realistic blend_sum
            blend_sum = min(gs * 1000, 2**26 - 1)

            exact = exact_divide(blend_sum, gs)
            lut_result = lut_divide(blend_sum, inv_lut, scale)

            error = lut_result - exact
            abs_error = abs(error)
            errors.append(abs_error)

            if exact > 0:
                rel_error = 100.0 * abs_error / exact
            else:
                rel_error = 0
            rel_errors.append(rel_error)

            all_errors.append(abs_error)

        if errors:
            max_err = max(errors)
            avg_err = np.mean(errors)
            max_rel = max(rel_errors)
            avg_rel = np.mean(rel_errors)
            avg_bin_width = np.mean(bin_widths)

            print(f"{region_name:<25} {avg_bin_width:<10.0f} {max_err:<10.2f} {avg_err:<10.2f} {max_rel:<10.2f}% {avg_rel:<10.2f}%")

    # Global statistics
    print("\n" + "-" * 85)
    print(f"Global Statistics:")
    print(f"  Maximum absolute error: {max(all_errors):.2f} LSB")
    print(f"  Mean absolute error: {np.mean(all_errors):.2f} LSB")
    print(f"  Median absolute error: {np.median(all_errors):.2f} LSB")

    return all_errors


def detailed_bin_analysis(lut, index_to_grad_sums):
    """Analyze error within each bin"""
    print("\n" + "=" * 80)
    print("Detailed Bin Error Analysis")
    print("=" * 80)

    # Find bins with large widths
    print("\nBins with width > 1 (showing worst-case error per bin):")
    print("-" * 100)
    print(f"{'Index':<6} {'Bin_Range':<20} {'Width':<8} {'Typical':<10} {'Max_Err':<10} {'Max_Rel%':<10}")
    print("-" * 100)

    worst_bins = []

    for idx in sorted(index_to_grad_sums.keys()):
        gs_list = index_to_grad_sums[idx]
        if len(gs_list) <= 1:
            continue

        bin_min = min(gs_list)
        bin_max = max(gs_list)
        bin_width = bin_max - bin_min + 1
        typical = (bin_min + bin_max) // 2

        # Find max error in this bin
        max_err = 0
        max_rel = 0

        for gs in gs_list:
            inv_lut = lut[idx]
            blend_sum = min(gs * 1000, 2**26 - 1)

            exact = exact_divide(blend_sum, gs)
            lut_result = lut_divide(blend_sum, inv_lut)

            error = abs(lut_result - exact)
            if error > max_err:
                max_err = error
                max_rel = 100.0 * error / exact if exact > 0 else 0

        worst_bins.append((idx, bin_min, bin_max, bin_width, typical, max_err, max_rel))

    # Sort by max error
    worst_bins.sort(key=lambda x: x[5], reverse=True)

    for idx, bin_min, bin_max, bin_width, typical, max_err, max_rel in worst_bins[:30]:
        print(f"{idx:<6} {bin_min:>7}-{bin_max:<12} {bin_width:<8} {typical:<10} {max_err:<10.2f} {max_rel:<10.2f}%")


def comprehensive_error_distribution(lut, scale=26):
    """Compute comprehensive error distribution"""
    print("\n" + "=" * 80)
    print("Comprehensive Error Distribution")
    print("=" * 80)

    error_distribution = {
        '0': 0, '1': 0, '2': 0, '3-5': 0, '6-10': 0,
        '11-50': 0, '51-100': 0, '101-500': 0, '>500': 0
    }
    all_errors = []

    # Sample across all combinations
    test_blend_sums = [100, 1000, 10000, 100000, 1000000, 10000000, 50000000]

    for gs in range(1, 131072, 50):  # Sample every 50th grad_sum
        index, _, _, _, _ = get_index_and_typical(gs)
        inv_lut = lut[index]

        for bs in test_blend_sums:
            if bs > gs:  # Only test meaningful cases
                exact = exact_divide(bs, gs)
                lut_result = lut_divide(bs, inv_lut, scale)

                error = abs(lut_result - exact)
                all_errors.append(error)

                if error == 0:
                    error_distribution['0'] += 1
                elif error == 1:
                    error_distribution['1'] += 1
                elif error == 2:
                    error_distribution['2'] += 1
                elif error <= 5:
                    error_distribution['3-5'] += 1
                elif error <= 10:
                    error_distribution['6-10'] += 1
                elif error <= 50:
                    error_distribution['11-50'] += 1
                elif error <= 100:
                    error_distribution['51-100'] += 1
                elif error <= 500:
                    error_distribution['101-500'] += 1
                else:
                    error_distribution['>500'] += 1

    total = sum(error_distribution.values())
    print(f"\nTotal test points: {total:,}")
    print("\nError Distribution (absolute LSB error):")
    print("-" * 60)
    for bin_name, count in error_distribution.items():
        pct = 100.0 * count / total if total > 0 else 0
        bar = '#' * int(pct / 2)
        print(f"  |Error| = {bin_name:>8s}: {count:8d} ({pct:5.1f}%) {bar}")

    print(f"\nStatistical Summary:")
    print(f"  Maximum error: {max(all_errors):,.0f} LSB")
    print(f"  Mean error:    {np.mean(all_errors):,.1f} LSB")
    print(f"  Median error:  {np.median(all_errors):,.1f} LSB")
    print(f"  Std deviation: {np.std(all_errors):,.1f} LSB")


def generate_lut_summary(lut, index_to_typical):
    """Generate a summary of all 256 LUT entries"""
    print("\n" + "=" * 80)
    print("Complete LUT (256 entries)")
    print("=" * 80)

    print("\n// LUT for division: inv = round(2^26 / typical_grad_sum)")
    print("// result = (blend_sum * inv) >> 26")
    print("\nlocalparam [26:0] DIV_LUT [0:255] = '{")

    for i in range(256):
        typical = index_to_typical.get(i, 1)
        lut_val = lut[i]
        if i < 255:
            print(f"    27'd{lut_val},  // [{i:3d}] typical={typical}")
        else:
            print(f"    27'd{lut_val}   // [{i:3d}] typical={typical}")

    print("};")


def main():
    print("=" * 80)
    print("Stage 3 256-Entry Compressed LUT Division Error Analysis")
    print("=" * 80)

    # Check index overlap first
    index_to_grad_sums = analyze_index_overlap()

    # Build LUT
    lut, index_to_typical = build_lut(scale=26)

    # Print LUT table
    print_lut_table(lut, index_to_typical)

    # Error analysis
    all_errors = analyze_errors(lut, index_to_grad_sums)

    # Detailed bin analysis
    detailed_bin_analysis(lut, index_to_grad_sums)

    # Comprehensive error distribution
    comprehensive_error_distribution(lut)

    # Generate LUT for Verilog
    generate_lut_summary(lut, index_to_typical)

    # Final assessment
    print("\n" + "=" * 80)
    print("FINAL ASSESSMENT")
    print("=" * 80)

    print("""
1. INDEX ALLOCATION SUMMARY:
   - Indices 0-255: grad_sum 0-255 (direct 1:1 mapping, bin_width=1)
   - Indices 64-127: grad_sum 256-2047 (bin_width=16)
   - Indices 64-95: grad_sum 2048-4095 (bin_width=16) [OVERLAP with above!]
   - Indices 96-127: grad_sum 4096-8191 (bin_width=32)
   - Indices 128-159: grad_sum 8192-16383 (bin_width=64)
   - Indices 160-191: grad_sum 16384-32767 (bin_width=128)
   - Indices 192-223: grad_sum 32768-65535 (bin_width=256)
   - Indices 224-255: grad_sum 65536-131071 (bin_width=512)

2. CRITICAL ISSUE DETECTED:
   Indices 64-95 are used TWICE:
   - grad_sum 1024-1791 map to indices 64-79 (via case 7)
   - grad_sum 2048-4095 map to indices 64-95 (via case 6)

   This causes ALIASING - the LUT cannot distinguish between these ranges!

3. ROOT CAUSE:
   The Verilog logic has overlapping index ranges:
   - Case 6 (grad_sum >= 2048): index = {3'b010, grad_sum[8:4]} = 64-95
   - Case 7 (grad_sum 256-2047): index = {2'b01, grad_sum[9:4]} = 64-127

   Since case 6 comes BEFORE case 7 in priority, grad_sum >= 2048 takes
   precedence, but the index range overlaps.

4. RECOMMENDATION:
   The current implementation has a fundamental design flaw that will cause
   incorrect results for grad_sum in the overlapping ranges.

   Suggested fixes:
   a) Modify case 7 to use different index prefix: {2'b00, grad_sum[9:4]}
      This gives indices 0-63, avoiding overlap with cases 6-8.

   b) Or restructure the compression to eliminate overlap entirely.
""")


if __name__ == "__main__":
    main()