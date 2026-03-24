#!/usr/bin/env python3
"""
ISP-CSIIR 定点参考模型 - 匹配 RTL 架构

完全匹配 RTL 的数据处理流程：
- 5x5 窗口生成（边界复制）
- Stage 1: 梯度计算 (u10 输入)
- Stage 2: 方向平均 (s11 有符号)
- Stage 3: 梯度融合 (s11 有符号, 1-row delay)
- Stage 4: IIR 混合 (s11→u10)

作者: rtl-verf
日期: 2026-03-23
版本: v2.0 - 匹配 RTL 架构
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
    ISP-CSIIR 定点模型 - 匹配 RTL 架构

    数据格式（匹配 RTL）:
    - Stage 1 输入/输出: u10 (无符号)
    - Stage 2-4 内部: s11 (有符号, 零点 = 512)
    - 最终输出: u10 (无符号)
    """

    def __init__(self, config: FixedPointConfig = None):
        self.config = config if config else FixedPointConfig()
        self.DATA_MAX = (1 << self.config.DATA_WIDTH) - 1  # 1023

        # IIR 反馈存储
        self.src_uv = None

        # Initialize LUT for division
        self._init_div_lut()

    def _init_div_lut(self):
        """Initialize division LUT - matches RTL common_lut_divider"""
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

        # Index 192-223: grad_sum 512-1023 (16:1 compression)
        # This ensures index stays within range for all grad_sum 512-1023
        # lut_index = 192 + ((gs - 512) >> 4)
        for idx in range(192, 224):
            grad_sum = (idx - 192) * 16 + 512
            self.div_lut[idx] = min((1 << 26) // grad_sum, 65535)

        # Index 224-255: higher grad_sum values (8192:1 compression)
        for idx in range(224, 256):
            grad_sum = (idx - 224) * 8192 + 8192
            self.div_lut[idx] = min((1 << 26) // max(grad_sum, 1), 65535)

    def _clip(self, value: int, min_val: int = 0, max_val: int = None) -> int:
        """限幅函数"""
        if max_val is None:
            max_val = self.DATA_MAX
        return max(min_val, min(max_val, int(value)))

    def _u10_to_s11(self, value: int) -> int:
        """u10 -> s11 转换: s11 = u10 - 512"""
        return value - 512

    def _s11_to_u10(self, value: int) -> int:
        """s11 -> u10 转换: u10 = clip(s11 + 512, 0, 1023)"""
        result = value + 512
        return self._clip(result, 0, 1023)

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
        Stage 1: 梯度计算 (匹配 RTL)

        输入: u10 5x5 窗口
        输出: grad (u14), win_size (u6)
        """
        # Sobel 行和 (匹配 RTL stage1_gradient.v)
        row0_sum = int(win[0, :].sum())
        row4_sum = int(win[4, :].sum())

        # Sobel 列和
        col0_sum = int(win[:, 0].sum())
        col4_sum = int(win[:, 4].sum())

        # 梯度（有符号差分）
        grad_h_raw = row0_sum - row4_sum
        grad_v_raw = col0_sum - col4_sum

        # 绝对值
        grad_h = abs(grad_h_raw)
        grad_v = abs(grad_v_raw)

        # 综合梯度: grad = (grad_h + grad_v) * 205 >> 10 (approximates /5)
        # With rounding: check bit[9] for round-to-nearest
        grad_sum = grad_h + grad_v
        grad_full = grad_sum * 205
        grad_shifted = grad_full >> 10
        # Rounding: if bit[9] is set, add 1 to the result
        round_carry = (grad_full >> 9) & 1
        grad_rounded = grad_shifted + round_carry
        # Saturation to 14-bit
        grad = self._clip(grad_rounded, 0, (1 << self.config.GRAD_WIDTH) - 1)

        # 窗口大小查表 (匹配 RTL win_size_clip_y)
        win_size = self._lut_win_size(grad)

        return grad_h, grad_v, grad, win_size

    def _lut_win_size(self, grad: int) -> int:
        """窗口大小LUT (匹配 RTL)"""
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

    def _stage2_directional_avg(self, win_u10: np.ndarray) -> Tuple:
        """
        Stage 2: 方向平均 (匹配 RTL)

        输入: u10 5x5 窗口
        输出: s11 平均值 (5个方向)
        """
        # u10 -> s11 转换 (匹配 RTL line 170)
        win_s11 = win_u10.astype(np.int32) - 512

        # 计算各方向和（匹配 RTL stage2_directional_avg.v）
        # sum_c: 全部25像素
        sum_c = int(win_s11.sum())
        weight_c = 25

        # sum_u: 前3行 (rows 0,1,2)
        sum_u = int(win_s11[:3, :].sum())
        weight_u = 15

        # sum_d: 后3行 (rows 2,3,4)
        sum_d = int(win_s11[2:, :].sum())
        weight_d = 15

        # sum_l: 前3列 (cols 0,1,2)
        sum_l = int(win_s11[:, :3].sum())
        weight_l = 15

        # sum_r: 后3列 (cols 2,3,4)
        sum_r = int(win_s11[:, 2:].sum())
        weight_r = 15

        # 有符号整数除法 (匹配 RTL)
        def signed_divide(sum_val, weight):
            if weight == 0:
                return 0
            result = sum_val // weight
            # 饱和到 s11 范围
            return max(-512, min(511, result))

        avg0_c = signed_divide(sum_c, weight_c)
        avg0_u = signed_divide(sum_u, weight_u)
        avg0_d = signed_divide(sum_d, weight_d)
        avg0_l = signed_divide(sum_l, weight_l)
        avg0_r = signed_divide(sum_r, weight_r)

        # avg1 与 avg0 相同 (简化实现，匹配 RTL)
        avg1_c, avg1_u, avg1_d, avg1_l, avg1_r = avg0_c, avg0_u, avg0_d, avg0_l, avg0_r

        return (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
                avg1_c, avg1_u, avg1_d, avg1_l, avg1_r)

    def _lut_divide(self, blend_sum: int, grad_sum: int) -> int:
        """LUT-based division - matches RTL common_lut_divider"""
        if grad_sum == 0:
            return 0

        gs = grad_sum

        # Index compression (matches RTL)
        if gs < 128:
            lut_index = gs
        elif gs < 256:
            lut_index = 128 + ((gs - 128) >> 1)
        elif gs < 512:
            lut_index = 160 + ((gs - 256) >> 2)
        elif gs < 1024:
            lut_index = 192 + ((gs - 512) >> 4)  # 16:1 compression
        else:
            lut_index = 224 + min(((gs - 1024) >> 13), 31)

        lut_index = min(lut_index, 255)

        # LUT lookup
        inv = self.div_lut[lut_index]

        # Multiply and truncate (signed)
        result = (blend_sum * inv) >> 26

        return result

    def _stage3_fusion(self, avg0: Tuple, avg1: Tuple,
                       grad_c: int, grad_u: int, grad_d: int,
                       grad_l: int, grad_r: int) -> Tuple[int, int]:
        """
        Stage 3: 梯度融合 (匹配 RTL)

        输入:
          avg0, avg1: s11 平均值 (c, u, d, l, r 顺序)
          grad_c, grad_u, grad_d, grad_l, grad_r: u14 梯度

        输出: s11 混合值
        """
        # 5 个梯度 (匹配 RTL 顺序: c, u, d, l, r)
        grads = [grad_c, grad_u, grad_d, grad_l, grad_r]

        # 排序梯度（降序，匹配 RTL 排序网络）
        grads_sorted = sorted(grads, reverse=True)
        grad_sum = sum(grads_sorted)

        if grad_sum == 0:
            # 简单平均
            blend0 = sum(avg0) // 5
            blend1 = sum(avg1) // 5
        else:
            # 加权平均: avg（固定顺序 c,u,d,l,r） * sorted_grad
            # 匹配 RTL: avg 不重排，只有 grad 重排
            blend0_sum = sum(int(a) * int(g) for a, g in zip(avg0, grads_sorted))
            blend1_sum = sum(int(a) * int(g) for a, g in zip(avg1, grads_sorted))

            blend0 = self._lut_divide(blend0_sum, grad_sum)
            blend1 = self._lut_divide(blend1_sum, grad_sum)

        # 饱和到 s11 范围
        blend0 = max(-512, min(511, blend0))
        blend1 = max(-512, min(511, blend1))

        return blend0, blend1

    def _stage4_iir_blend(self, blend0: int, blend1: int,
                          avg0_u: int, avg1_u: int,
                          win_size: int, center_u10: int) -> int:
        """
        Stage 4: IIR 混合 (匹配 RTL)

        输入: s11 blend 值, s11 avg_u, u10 center
        输出: u10 最终值
        """
        # 混合比例选择 (匹配 RTL stage4_iir_blend.v line 117-119)
        ratio_idx = (win_size // 8) - 2
        ratio_idx = max(0, min(3, ratio_idx))
        ratio = self.config.blending_ratio[ratio_idx]

        # IIR 水平混合 (s11 有符号)
        # blend_iir = (ratio * blend + (64 - ratio) * avg_u) >> 6
        blend0_iir = (ratio * blend0 + (64 - ratio) * avg0_u) >> 6
        blend1_iir = (ratio * blend1 + (64 - ratio) * avg1_u) >> 6

        # 饱和到 s11 范围
        blend0_iir = max(-512, min(511, blend0_iir))
        blend1_iir = max(-512, min(511, blend1_iir))

        # 窗混合因子 (匹配 RTL line 126-128)
        factor = max(1, min(4, win_size // 8))

        # center u10 -> s11 转换 (匹配 RTL line 227)
        center_s11 = center_u10 - 512

        # 窗混合: (iir * factor + center * (4 - factor)) >> 2
        blend0_out = (blend0_iir * factor + center_s11 * (4 - factor)) >> 2
        blend1_out = (blend1_iir * factor + center_s11 * (4 - factor)) >> 2

        # 饱和到 s11 范围
        blend0_out = max(-512, min(511, blend0_out))
        blend1_out = max(-512, min(511, blend1_out))

        # 最终混合: (blend0 * remain + blend1 * (8 - remain)) >> 3
        remain = win_size % 8
        blend_final_s11 = (blend0_out * remain + blend1_out * (8 - remain)) >> 3

        # 饱和到 s11 范围
        blend_final_s11 = max(-512, min(511, blend_final_s11))

        # s11 -> u10 转换
        dout = self._s11_to_u10(blend_final_s11)

        return dout

    def process(self, input_image: np.ndarray) -> np.ndarray:
        """
        处理输入图像 (匹配 RTL 架构)

        RTL 数据流:
        1. Line buffer 需要 2 行 + 2 列延迟才能输出有效窗口
        2. Stage 3 有额外的 1 行延迟用于梯度访问
        3. 边界处理: 复制边界像素

        Args:
            input_image: 输入图像 (height x width), 值范围 [0, 1023]

        Returns:
            output_image: 输出图像 (与输入同尺寸)
        """
        h, w = input_image.shape
        output = np.zeros((h, w), dtype=np.int32)

        # IIR 反馈存储 (匹配 RTL line buffer 写回)
        self.src_uv = input_image.astype(np.int32).copy()

        # 行缓存 (用于 Stage 3/4 的 IIR 反馈)
        # Stage 3 需要上一行的 avg_u (用于 Stage 4 IIR)
        avg0_u_prev_row = np.zeros(w, dtype=np.int32)  # s11
        avg1_u_prev_row = np.zeros(w, dtype=np.int32)  # s11

        # Stage 3 的梯度行缓存 (匹配 RTL grad_line_buf)
        grad_prev_row = np.zeros(w, dtype=np.int32)  # u14, 上一行梯度
        grad_curr_row = np.zeros(w, dtype=np.int32)  # u14, 当前行梯度

        # Stage 2 输出行缓存 (用于 Stage 3 的 1-row delay)
        avg0_c_delay = np.zeros(w, dtype=np.int32)
        avg0_u_delay = np.zeros(w, dtype=np.int32)
        avg0_d_delay = np.zeros(w, dtype=np.int32)
        avg0_l_delay = np.zeros(w, dtype=np.int32)
        avg0_r_delay = np.zeros(w, dtype=np.int32)
        avg1_c_delay = np.zeros(w, dtype=np.int32)
        avg1_u_delay = np.zeros(w, dtype=np.int32)
        avg1_d_delay = np.zeros(w, dtype=np.int32)
        avg1_l_delay = np.zeros(w, dtype=np.int32)
        avg1_r_delay = np.zeros(w, dtype=np.int32)
        center_delay = np.zeros(w, dtype=np.int32)
        win_size_delay = np.zeros(w, dtype=np.int32)

        # 逐行处理
        for j in range(h):
            # 当前行数据
            curr_grad = np.zeros(w, dtype=np.int32)
            curr_avg0_c = np.zeros(w, dtype=np.int32)
            curr_avg0_u = np.zeros(w, dtype=np.int32)
            curr_avg0_d = np.zeros(w, dtype=np.int32)
            curr_avg0_l = np.zeros(w, dtype=np.int32)
            curr_avg0_r = np.zeros(w, dtype=np.int32)
            curr_avg1_c = np.zeros(w, dtype=np.int32)
            curr_avg1_u = np.zeros(w, dtype=np.int32)
            curr_avg1_d = np.zeros(w, dtype=np.int32)
            curr_avg1_l = np.zeros(w, dtype=np.int32)
            curr_avg1_r = np.zeros(w, dtype=np.int32)
            curr_center = np.zeros(w, dtype=np.int32)
            curr_win_size = np.zeros(w, dtype=np.int32)

            # Stage 1 和 Stage 2: 处理当前行
            for i in range(w):
                win = self._get_window(self.src_uv, i, j)
                center = int(self.src_uv[j, i])

                # Stage 1: 梯度计算
                _, _, grad, win_size = self._stage1_gradient(win)

                # Stage 2: 方向平均
                (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
                 avg1_c, avg1_u, avg1_d, avg1_l, avg1_r) = self._stage2_directional_avg(win)

                # 保存当前行数据
                curr_grad[i] = grad
                curr_avg0_c[i] = avg0_c
                curr_avg0_u[i] = avg0_u
                curr_avg0_d[i] = avg0_d
                curr_avg0_l[i] = avg0_l
                curr_avg0_r[i] = avg0_r
                curr_avg1_c[i] = avg1_c
                curr_avg1_u[i] = avg1_u
                curr_avg1_d[i] = avg1_d
                curr_avg1_l[i] = avg1_l
                curr_avg1_r[i] = avg1_r
                curr_center[i] = center
                curr_win_size[i] = win_size

            # Stage 3 和 Stage 4: 处理上一行 (1-row delay)
            # RTL: Stage 3 在 row >= 1 时开始输出
            if j >= 1:
                for i in range(w):
                    # 从行缓存读取上一行的 Stage 2 输出
                    avg0_c = avg0_c_delay[i]
                    avg0_u = avg0_u_delay[i]
                    avg0_d = avg0_d_delay[i]
                    avg0_l = avg0_l_delay[i]
                    avg0_r = avg0_r_delay[i]
                    avg1_c = avg1_c_delay[i]
                    avg1_u = avg1_u_delay[i]
                    avg1_d = avg1_d_delay[i]
                    avg1_l = avg1_l_delay[i]
                    avg1_r = avg1_r_delay[i]
                    center = center_delay[i]
                    win_size = win_size_delay[i]

                    # 梯度访问 (匹配 RTL Stage 3)
                    # grad_u: 上上行梯度 (row j-2)
                    # grad_c: 上一行梯度 (row j-1)
                    # grad_d: 当前行梯度 (row j) - 这是 Stage 3 的 "next row"
                    grad_u = grad_prev_row[i] if j >= 2 else grad_curr_row[i]
                    grad_c = grad_curr_row[i]
                    grad_d = curr_grad[i]

                    # grad_l: 左邻居 (匹配 RTL grad_shift_l)
                    grad_l = grad_c if i == 0 else grad_curr_row[i - 1]
                    # grad_r: 右邻居 (RTL 简化为 grad_c)
                    grad_r = grad_c

                    # Stage 3: 梯度融合
                    blend0, blend1 = self._stage3_fusion(
                        (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r),
                        (avg1_c, avg1_u, avg1_d, avg1_l, avg1_r),
                        grad_c, grad_u, grad_d, grad_l, grad_r
                    )

                    # Stage 4: IIR 混合
                    # avg0_u_prev_row[i] 是上一行的上一行的 avg_u (用于 IIR)
                    dout = self._stage4_iir_blend(
                        blend0, blend1,
                        avg0_u_prev_row[i], avg1_u_prev_row[i],
                        win_size, center
                    )

                    # 输出到上一行的位置 (因为 Stage 3 有 1-row delay)
                    output[j - 1, i] = dout

                    # IIR 反馈: 写回 line buffer
                    self._iir_feedback(i, j - 1, dout, h, w)

            # 更新行缓存
            avg0_c_delay = curr_avg0_c.copy()
            avg0_u_delay = curr_avg0_u.copy()
            avg0_d_delay = curr_avg0_d.copy()
            avg0_l_delay = curr_avg0_l.copy()
            avg0_r_delay = curr_avg0_r.copy()
            avg1_c_delay = curr_avg1_c.copy()
            avg1_u_delay = curr_avg1_u.copy()
            avg1_d_delay = curr_avg1_d.copy()
            avg1_l_delay = curr_avg1_l.copy()
            avg1_r_delay = curr_avg1_r.copy()
            center_delay = curr_center.copy()
            win_size_delay = curr_win_size.copy()

            # 更新 IIR 行缓存
            avg0_u_prev_row = avg0_u_delay.copy()
            avg1_u_prev_row = avg1_u_delay.copy()

            # 更新梯度行缓存
            grad_prev_row = grad_curr_row.copy()
            grad_curr_row = curr_grad.copy()

        # 处理最后一行 (Stage 3 的最后一个输出)
        # RTL 在 frame 结束后会输出最后一行
        j = h - 1
        for i in range(w):
            avg0_c = avg0_c_delay[i]
            avg0_u = avg0_u_delay[i]
            avg0_d = avg0_d_delay[i]
            avg0_l = avg0_l_delay[i]
            avg0_r = avg0_r_delay[i]
            avg1_c = avg1_c_delay[i]
            avg1_u = avg1_u_delay[i]
            avg1_d = avg1_d_delay[i]
            avg1_l = avg1_l_delay[i]
            avg1_r = avg1_r_delay[i]
            center = center_delay[i]
            win_size = win_size_delay[i]

            # 最后一行没有 next row, 使用当前行
            grad_u = grad_prev_row[i]
            grad_c = grad_curr_row[i]
            grad_d = grad_c  # 边界处理

            grad_l = grad_c if i == 0 else grad_curr_row[i - 1]
            grad_r = grad_c

            blend0, blend1 = self._stage3_fusion(
                (avg0_c, avg0_u, avg0_d, avg0_l, avg0_r),
                (avg1_c, avg1_u, avg1_d, avg1_l, avg1_r),
                grad_c, grad_u, grad_d, grad_l, grad_r
            )

            dout = self._stage4_iir_blend(
                blend0, blend1,
                avg0_u_prev_row[i], avg1_u_prev_row[i],
                win_size, center
            )

            output[j, i] = dout

        return output

    def _iir_feedback(self, i: int, j: int, value: int, h: int, w: int):
        """IIR 反馈写回 line buffer"""
        # 匹配 RTL: 写回当前列的上下 2 行
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