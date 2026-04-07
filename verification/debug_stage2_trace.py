#!/usr/bin/env python3
"""
Export Stage 2 intermediate values for comparison with RTL
"""

import numpy as np
from isp_csiir_fixed_model import FixedPointConfig, ISPCSIIRFixedModel

def read_config(filename):
    """Read config file"""
    with open(filename, 'r') as f:
        content = f.read().strip()
        # Handle both single-line and multi-line formats
        values = [int(x) for x in content.split()]
    return {
        'width': values[0],
        'height': values[1],
        'thresh': values[2:6],
        'ratio': values[6:10],
        'clip': values[10:14]
    }

def read_stimulus(filename):
    """Read stimulus hex file"""
    with open(filename, 'r') as f:
        lines = f.readlines()

    data = []
    for line in lines:
        line = line.strip()
        if line.startswith('#'):
            continue
        if line:
            data.append(int(line, 16))

    width = data[0]
    height = data[1]
    pixels = data[2:]
    return width, height, np.array(pixels, dtype=np.int32).reshape(height, width)

class Stage2Tracer(ISPCSIIRFixedModel):
    """Extended model that traces Stage 2 intermediate values"""

    def __init__(self, config):
        super().__init__(config)
        self.stage2_traces = []

    def _stage2_directional_avg(self, win_u10: np.ndarray, win_size: int):
        """Override to trace intermediate values"""
        # u10 -> s11 conversion
        win_s11 = win_u10.astype(np.int32) - 512

        # Calculate sums
        sum_c = int(win_s11.sum())
        sum_u = int(win_s11[:3, :].sum())
        sum_d = int(win_s11[2:, :].sum())
        sum_l = int(win_s11[:, :3].sum())
        sum_r = int(win_s11[:, 2:].sum())

        # Calculate averages
        def signed_divide(sum_val, weight):
            if weight == 0:
                return 0
            result = sum_val // weight
            return max(-512, min(511, result))

        avg0_c = signed_divide(sum_c, 25)
        avg0_u = signed_divide(sum_u, 15)
        avg0_d = signed_divide(sum_d, 15)
        avg0_l = signed_divide(sum_l, 15)
        avg0_r = signed_divide(sum_r, 15)

        # Store trace
        self.stage2_traces.append({
            'center': int(win_u10[2, 2]),
            'sum_c': sum_c,
            'sum_u': sum_u,
            'sum_d': sum_d,
            'sum_l': sum_l,
            'sum_r': sum_r,
            'avg0_c': avg0_c,
            'avg0_u': avg0_u,
            'avg0_d': avg0_d,
            'avg0_l': avg0_l,
            'avg0_r': avg0_r,
        })

        # Call parent
        return super()._stage2_directional_avg(win_u10, win_size)

def main():
    # Read config
    config = read_config('config.txt')
    print(f"Config: {config['width']}x{config['height']}")

    # Read stimulus
    width, height, stimulus = read_stimulus('stimulus.hex')
    print(f"Stimulus: {width}x{height}")

    # Create tracer model
    fp_config = FixedPointConfig(
        DATA_WIDTH=10,
        GRAD_WIDTH=14,
        IMG_WIDTH=width,
        IMG_HEIGHT=height,
        win_size_thresh=config['thresh'],
        win_size_clip_y=config['clip'],
        blending_ratio=config['ratio']
    )

    model = Stage2Tracer(fp_config)
    output = model.process(stimulus)

    # Export Stage 2 traces
    print(f"\nTotal Stage 2 outputs: {len(model.stage2_traces)}")

    # Write to file
    with open('stage2_python.txt', 'w') as f:
        f.write("# Pixel_X Pixel_Y Center Sum_C Sum_U Sum_D Sum_L Sum_R Avg0_C Avg0_U Avg0_D Avg0_L Avg0_R\n")
        for i, trace in enumerate(model.stage2_traces):
            px = i % width
            py = i // width
            f.write(f"{px} {py} {trace['center']} {trace['sum_c']} {trace['sum_u']} {trace['sum_d']} {trace['sum_l']} {trace['sum_r']} {trace['avg0_c']} {trace['avg0_u']} {trace['avg0_d']} {trace['avg0_l']} {trace['avg0_r']}\n")

    print("Stage 2 traces written to stage2_python.txt")

    # Print first 20 traces
    print("\nFirst 20 Stage 2 traces:")
    print("  PX PY Ctr  Sum_C   Sum_U   Sum_D   Sum_L   Sum_R  Avg0_C Avg0_U Avg0_D Avg0_L Avg0_R")
    for i in range(min(20, len(model.stage2_traces))):
        t = model.stage2_traces[i]
        px = i % width
        py = i // width
        print(f"  {px:2d} {py:2d} {t['center']:3d} {t['sum_c']:7d} {t['sum_u']:7d} {t['sum_d']:7d} {t['sum_l']:7d} {t['sum_r']:7d}  {t['avg0_c']:6d} {t['avg0_u']:6d} {t['avg0_d']:6d} {t['avg0_l']:6d} {t['avg0_r']:6d}")

if __name__ == '__main__':
    main()
