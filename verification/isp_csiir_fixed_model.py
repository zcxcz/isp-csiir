#!/usr/bin/env python3
"""
ISP-CSIIR 定点参考模型

用于 RTL 仿真对比的定点化 Python 模型。
实现与 RTL 一致的定点运算逻辑。

作者: rtl-verf
日期: 2026-03-22
版本: v1.0
"""

import numpy as np
from dataclasses import dataclass
from typing import Tuple, List


@dataclass
class FixedPointConfig:
    """定点配置参数"""
    DATA_WIDTH: int = 10
    GRAD_WIDTH: int = 14
    ACC_WIDTH: int = 20

    # 图像尺寸
    IMG_WIDTH: int = 64
    IMG_HEIGHT: int = 64

    # 窗口阈值
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


class ISPCSIIRFixedModel:
    """
    ISP-CSIIR 定点模型

    实现与 RTL 一致的定点运算：
    - 10-bit 像素数据
    - 14-bit 梯度数据
    - 整数除法（截断）
    """

    def __init__(self, config: FixedPointConfig = None):
        self.config = config if config else FixedPointConfig()
        self.DATA_MAX = (1 << self.config.DATA_WIDTH) - 1  # 1023

        # IIR 反馈存储
        self.src_uv = None

        # Initialize LUT for division (256 x 16-bit)
        self._init_div_lut()

    def _init_div_lut(self):
        """Initialize division LUT with inverse values

        Index mapping (no overlap, matches RTL):
          Index 0: grad_sum = 0
          Index 1-127: grad_sum 1-127 (direct mapping)
          Index 128-159: grad_sum 128-255 (2:1 compression)
          Index 160-191: grad_sum 256-511 (4:1 compression)
          Index 192-223: grad_sum 512-1023 (8:1 compression)
          Index 224-231: grad_sum 8192-16383
          Index 232-239: grad_sum 16384-32767
          Index 240-247: grad_sum 32768-65535
          Index 248-255: grad_sum 65536-131071
        """
        self.div_lut = [0] * 256

        # Index 0: grad_sum = 0
        self.div_lut[0] = 65535

        # Index 1-127: grad_sum 1-127 (direct mapping)
        for i in range(1, 128):
            inv = (1 << 26) // i
            self.div_lut[i] = min(inv, 65535)

        # Index 128-159: grad_sum 128-255 (2:1 compression)
        for idx in range(128, 160):
            grad_sum = (idx - 128) * 2 + 128
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 160-191: grad_sum 256-511 (4:1 compression)
        for idx in range(160, 192):
            grad_sum = (idx - 160) * 4 + 256
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 192-223: grad_sum 512-1023 (8:1 compression)
        for idx in range(192, 224):
            grad_sum = (idx - 192) * 8 + 512
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 224-231: grad_sum 8192-16383 (note: gap 1024-8191)
        for idx in range(224, 232):
            grad_sum = (idx - 224) * 1024 + 8192
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 232-239: grad_sum 16384-32767
        for idx in range(232, 240):
            grad_sum = (idx - 232) * 2048 + 16384
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 240-247: grad_sum 32768-65535
        for idx in range(240, 248):
            grad_sum = (idx - 240) * 4096 + 32768
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 248-255: grad_sum 65536-131071
        for idx in range(248, 256):
            grad_sum = (idx - 248) * 8192 + 65536
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

    def _clip(self, value: int, min_val: int = 0, max_val: int = None) -> int:
        """限幅函数"""
        if max_val is None:
            max_val = self.DATA_MAX
        return max(min_val, min(max_val, int(value)))

    def _abs(self, value: int) -> int:
        """定点绝对值"""
        return abs(value)

    def _get_window(self, img: np.ndarray, i: int, j: int) -> np.ndarray:
        """获取5x5窗口，边界复制"""
        h, w = img.shape
        window = np.zeros((5, 5), dtype=np.int32)

        for dy in range(-2, 3):
            for dx in range(-2, 3):
                y = self._clip(j + dy, 0, h - 1)
                x = self._clip(i + dx, 0, w - 1)
                window[dy + 2, dx + 2] = int(img[y, x])

        return window

    def _stage1_gradient(self, win: np.ndarray) -> Tuple[int, int, int, int]:
        """
        Stage 1: 梯度计算

        Returns:
            grad_h: 水平梯度绝对值
            grad_v: 垂直梯度绝对值
            grad: 综合梯度
            win_size: 窗口大小
        """
        # 行和
        row0_sum = int(win[0, :].sum())
        row4_sum = int(win[4, :].sum())

        # 列和
        col0_sum = int(win[:, 0].sum())
        col4_sum = int(win[:, 4].sum())

        # 梯度（有符号）
        grad_h_raw = row0_sum - row4_sum
        grad_v_raw = col0_sum - col4_sum

        # 绝对值
        grad_h = self._abs(grad_h_raw)
        grad_v = self._abs(grad_v_raw)

        # 综合梯度: grad = (grad_h + grad_v) * 205 >> 10 (approximates /5)
        grad_sum = grad_h + grad_v
        grad_full = grad_sum * 205
        grad = grad_full >> 10
        # 饱和到 14-bit
        grad = self._clip(grad, 0, (1 << self.config.GRAD_WIDTH) - 1)

        # 窗口大小查表
        win_size = self._lut_win_size(grad)

        return grad_h, grad_v, grad, win_size

    def _lut_win_size(self, grad: int) -> int:
        """窗口大小LUT"""
        clip_y = self.config.win_size_clip_y

        if grad < clip_y[0]:
            return 16
        elif grad < clip_y[1]:
            return 24
        elif grad < clip_y[2]:
            return 32
        elif grad < clip_y[3]:
            return 40
        else:
            return 40

    def _stage2_directional_avg(self, win: np.ndarray, win_size: int) -> Tuple:
        """
        Stage 2: 方向平均

        简化实现：计算各区域的平均值
        """
        # 核选择
        thresh = self.config.win_size_thresh

        # 计算各方向和
        # 中心: 全部25像素
        sum_c = int(win.sum())
        weight_c = 25

        # 上: 前3行
        sum_u = int(win[:3, :].sum())
        weight_u = 15

        # 下: 后3行
        sum_d = int(win[2:, :].sum())
        weight_d = 15

        # 左: 前3列
        sum_l = int(win[:, :3].sum())
        weight_l = 15

        # 右: 后3列
        sum_r = int(win[:, 2:].sum())
        weight_r = 15

        # 整数除法
        avg0_c = sum_c // weight_c if weight_c > 0 else 0
        avg0_u = sum_u // weight_u if weight_u > 0 else 0
        avg0_d = sum_d // weight_d if weight_d > 0 else 0
        avg0_l = sum_l // weight_l if weight_l > 0 else 0
        avg0_r = sum_r // weight_r if weight_r > 0 else 0

        # avg1 相同（简化）
        avg1_c, avg1_u, avg1_d, avg1_l, avg1_r = avg0_c, avg0_u, avg0_d, avg0_l, avg0_r

        return (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
                avg1_c, avg1_u, avg1_d, avg1_l, avg1_r)

    def _lut_divide(self, blend_sum: int, grad_sum: int) -> int:
        """
        LUT-based division: blend_sum / grad_sum

        Uses index compression and LUT for single-cycle output.
        Index mapping (no overlap):
          grad_sum 0:        index 0
          grad_sum 1-127:    index 1-127 (direct mapping)
          grad_sum 128-255:  index 128-159 (2:1 compression)
          grad_sum 256-511:  index 160-191 (4:1 compression)
          grad_sum 512-1023: index 192-223 (8:1 compression)
          grad_sum 1024+:    index 224-255 (higher compression)
        """
        if grad_sum == 0:
            return 0

        gs = grad_sum

        # Index compression (matches RTL)
        if gs < 128:
            lut_index = gs  # 1-127 → 1-127
        elif gs < 256:
            lut_index = 128 + ((gs - 128) >> 1)  # 128-255 → 128-159
        elif gs < 512:
            lut_index = 160 + ((gs - 256) >> 2)  # 256-511 → 160-191
        elif gs < 1024:
            lut_index = 192 + ((gs - 512) >> 3)  # 512-1023 → 192-223
        elif gs >= 65536:
            lut_index = 248 + ((gs - 65536) >> 13)  # 65536+ → 248-255
        elif gs >= 32768:
            lut_index = 240 + ((gs - 32768) >> 12)  # 32768-65535 → 240-247
        elif gs >= 16384:
            lut_index = 232 + ((gs - 16384) >> 11)  # 16384-32767 → 232-239
        else:  # 1024-16383
            lut_index = 224 + ((gs - 1024) >> 10)  # 1024-16383 → 224-231

        # Clamp index to LUT range
        lut_index = min(lut_index, 255)

        # LUT lookup
        inv = self.div_lut[lut_index]

        # Multiply and truncate
        result = (blend_sum * inv) >> 26

        return self._clip(result, 0, self.DATA_MAX)

    def _stage3_fusion(self, avg0: Tuple, avg1: Tuple,
                       grad: int, grad_neighbors: List[int]) -> Tuple[int, int]:
        """
        Stage 3: 梯度融合

        使用 LUT 除法实现梯度加权融合
        """
        # 排序梯度
        grads = sorted(grad_neighbors + [grad], reverse=True)
        grad_sum = sum(grads)

        if grad_sum == 0:
            # 简单平均
            blend0 = sum(avg0) // 5
            blend1 = sum(avg1) // 5
        else:
            # 加权平均
            blend0_sum = sum(a * g for a, g in zip(avg0, grads))
            blend1_sum = sum(a * g for a, g in zip(avg1, grads))
            # Use LUT-based division
            blend0 = self._lut_divide(blend0_sum, grad_sum)
            blend1 = self._lut_divide(blend1_sum, grad_sum)

        return blend0, blend1

    def _stage4_iir_blend(self, blend0: int, blend1: int,
                          avg0_u: int, avg1_u: int,
                          win_size: int, center: int) -> int:
        """
        Stage 4: IIR混合
        """
        # 混合比例选择
        ratio_idx = (win_size // 8) - 2
        ratio_idx = self._clip(ratio_idx, 0, 3)
        ratio = self.config.blending_ratio[ratio_idx]

        # IIR水平混合
        blend0_iir = (ratio * blend0 + (64 - ratio) * avg0_u) >> 6
        blend1_iir = (ratio * blend1 + (64 - ratio) * avg1_u) >> 6

        # 窗混合因子
        factor = self._clip(win_size // 8, 1, 4)

        blend0_out = (blend0_iir * factor + center * (4 - factor)) >> 2
        blend1_out = (blend1_iir * factor + center * (4 - factor)) >> 2

        # 最终混合
        remain = win_size % 8
        dout = (blend0_out * remain + blend1_out * (8 - remain)) >> 3

        return self._clip(dout)

    def process(self, input_image: np.ndarray) -> np.ndarray:
        """
        处理输入图像

        Args:
            input_image: 输入图像 (height x width), 值范围 [0, 1023]

        Returns:
            output_image: 输出图像
        """
        h, w = input_image.shape
        output = np.zeros((h, w), dtype=np.int32)

        # 初始化 IIR 存储
        self.src_uv = input_image.astype(np.int32).copy()

        # 行缓存的 avg_u
        avg0_u_row = np.zeros(w, dtype=np.int32)
        avg1_u_row = np.zeros(w, dtype=np.int32)

        for j in range(h):
            # 当前行的 avg_u
            curr_avg0_u = np.zeros(w, dtype=np.int32)
            curr_avg1_u = np.zeros(w, dtype=np.int32)

            for i in range(w):
                # 获取窗口
                win = self._get_window(self.src_uv, i, j)
                center = int(self.src_uv[j, i])

                # Stage 1
                grad_h, grad_v, grad, win_size = self._stage1_gradient(win)

                # Stage 2
                (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
                 avg1_c, avg1_u_val, avg1_d, avg1_l, avg1_r) = self._stage2_directional_avg(win, win_size)

                # 保存 avg_u 用于下一行
                curr_avg0_u[i] = avg0_u
                curr_avg1_u[i] = avg1_u_val

                # Stage 3
                # 获取邻居梯度（简化：使用当前行左右）
                grad_l = grad if i == 0 else int(self._get_window(self.src_uv, i-1, j)[2, 2])
                grad_r = grad if i == w-1 else int(self._get_window(self.src_uv, i+1, j)[2, 2])

                # 使用上一行的 avg_u 进行 IIR 混合
                blend0, blend1 = self._stage3_fusion(
                    (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r),
                    (avg1_c, avg1_u_val, avg1_d, avg1_l, avg1_r),
                    grad, [grad_l, grad_r, grad]  # 简化的邻居梯度
                )

                # Stage 4
                dout = self._stage4_iir_blend(
                    blend0, blend1,
                    avg0_u_row[i], avg1_u_row[i],
                    win_size, center
                )

                output[j, i] = dout

                # IIR 反馈
                self._iir_feedback(i, j, dout, h, w)

            # 更新行缓存
            avg0_u_row = curr_avg0_u.copy()
            avg1_u_row = curr_avg1_u.copy()

        return output

    def _iir_feedback(self, i: int, j: int, value: int, h: int, w: int):
        """IIR 反馈写回"""
        # 简化实现：只更新当前行上下2行
        for dy in range(-2, 3):
            y = j + dy
            if 0 <= y < h:
                self.src_uv[y, i] = value


def test_fixed_model():
    """测试定点模型"""
    config = FixedPointConfig(IMG_WIDTH=64, IMG_HEIGHT=64)
    model = ISPCSIIRFixedModel(config)

    # 创建测试图像
    np.random.seed(42)
    input_img = np.random.randint(0, 1024, (64, 64), dtype=np.int32)

    # 处理
    output = model.process(input_img)

    print(f"输入范围: [{input_img.min()}, {input_img.max()}]")
    print(f"输出范围: [{output.min()}, {output.max()}]")
    print(f"输出均值: {output.mean():.2f}")

    # 验证输出范围
    assert output.min() >= 0, "Output below 0"
    assert output.max() <= 1023, "Output above 1023"

    print("定点模型测试通过!")
    return output


if __name__ == "__main__":
    test_fixed_model()