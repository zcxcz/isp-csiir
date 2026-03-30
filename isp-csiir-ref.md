# ISP-CSIIR 算法参考文档

## 1. 记号与约定

### 1.1 命名约定

- 变量名后缀 `u10` 表示 10-bit 无符号数，例如 `src_uv_u10`。
- 变量名后缀 `s11` 表示 11-bit 有符号数，最高位为符号位，例如 `src_uv_s11`。
- 形如 `a_5x5(i, j)` 的名称中，`5x5` 表示二维窗口；`(i, j)` 表示当前窗口中心像素坐标。
- 形如 `b(i, j)` 的名称中，`(i, j)` 表示当前像素坐标。

### 1.2 运算约定

- `clip(a, b, c)` 为限幅函数：当 `a` 落在区间 `[b, c]` 内时输出 `a`；当 `a < b` 时输出 `b`；当 `a > c` 时输出 `c`。
- 当访问 `src_uv_s11(i, j)` 或其他二维数组时，若索引越界，则对越界位置采用临近值复制（duplicating）。
- 若无特别说明，本文中的缩放除法、插值和定点截位均默认采用四舍五入。
- 若运算结果超出目标数值范围，则采用饱和截位。

---

## 2. 梯度计算与窗口大小确定

### 2.1 Sobel 滤波器

```python
sobel_x = [
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [-1, -1, -1, -1, -1]
]

sobel_y = [
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1]
]
```

```text
src_uv_s11 = src_uv_u10 - 512
```

### 2.2 滤波窗数据更新

```text
for (j = 0; j <= reg_pic_height_m1; j++)
    for (i = 0; i <= reg_pic_width_m1; i++)
        for (h = -2; h <= 2; h++)
            for (w = -4; w <= 4; w = w + 2)
                src_uv_u10_5x5(w, h) = src_uv_u10(clip(i + w, 0, reg_pic_width_m1), clip(j + h, 0, reg_pic_height_m1))
                src_uv_s11_5x5(w, h) = src_uv_s11(clip(i + w, 0, reg_pic_width_m1), clip(j + h, 0, reg_pic_height_m1))
```

其中：
- 当前中心像素坐标为 `(i, j)`。
- 窗口内偏移坐标为 `(w, h)`。
- 横向偏移集合为 `{ -4, -2, 0, 2, 4 }`。
- 纵向偏移集合为 `{ -2, -1, 0, 1, 2 }`。

### 2.3 梯度计算

```text
grad_h(i, j) = (src_uv_u10_5x5 * sobel_x)
grad_v(i, j) = (src_uv_u10_5x5 * sobel_y)
grad(i, j)   = |grad_h(i, j)| / 5 + |grad_v(i, j)| / 5
```

说明：`grad_h` 和 `grad_v` 均基于原始无符号窗口 `src_uv_u10_5x5` 做卷积计算。

### 2.4 窗口大小 LUT

```text
win_size_clip_y   = [15, 23, 31, 39]
win_size_clip_sft = [2, 2, 2, 2]

# LUT 定义：
#   x0 = 2^(win_size_clip_sft[0])
#   x1 = x0 + 2^(win_size_clip_sft[1])
#   x2 = x1 + 2^(win_size_clip_sft[2])
#   x3 = x2 + 2^(win_size_clip_sft[3])
#
# 对当前输入 x = Max(grad(i-1, j), grad(i, j), grad(i+1, j))：
#   1. 当 x 位于相邻两个坐标点之间时，按对应 y 值做线性插值；
#   2. 线性插值的截位规则默认采用四舍五入；
#   3. 当 x 小于最小节点 x0 时，输出钳位为 y0；
#   4. 当 x 大于最大节点 x3 时，输出钳位为 y3。
#
# 当前参数默认对应：
#   x 节点 = [4, 8, 12, 16]
#   y 节点 = [15, 23, 31, 39]

win_size_grad(i, j) = LUT(Max(grad(i-1, j), grad(i, j), grad(i+1, j)), win_size_clip_y, win_size_clip_sft)
win_size_clip(i, j) = clip(win_size_grad(i, j), 16, 40)
```

---

## 3. 多尺度方向性平均

### 3.1 平均因子核

```python
# 2x2 核
avg_factor_c_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
]

# 3x3 核
avg_factor_c_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
]

# 4x4 核
avg_factor_c_4x4 = [
    [1, 1, 2, 1, 1],
    [1, 2, 4, 2, 1],
    [2, 4, 8, 4, 2],
    [1, 2, 4, 2, 1],
    [1, 1, 2, 1, 1]
]

# 5x5 核
avg_factor_c_5x5 = [
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]
```

### 3.2 方向掩码

```python
avg_factor_u_mask = [  # 上
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]

avg_factor_d_mask = [  # 下
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]

avg_factor_l_mask = [  # 左
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0]
]

avg_factor_r_mask = [  # 右
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1]
]
```

### 3.3 核选择逻辑

```text
# 命名约定：
#   avg1 / blend1 表示较小窗口路径；
#   avg0 / blend0 表示较大窗口路径。
# 当某一路核为 zeros(5, 5) 时，该路当前及后续运算全部跳过。

if (win_size_clip(i, j) < thresh0):
    avg0_factor_c = zeros(5, 5)
    avg1_factor_c = avg_factor_c_2x2
elif (win_size_clip(i, j) < thresh1):
    avg0_factor_c = avg_factor_c_3x3
    avg1_factor_c = avg_factor_c_2x2
elif (win_size_clip(i, j) < thresh2):
    avg0_factor_c = avg_factor_c_4x4
    avg1_factor_c = avg_factor_c_3x3
elif (win_size_clip(i, j) < thresh3):
    avg0_factor_c = avg_factor_c_5x5
    avg1_factor_c = avg_factor_c_4x4
else:
    avg0_factor_c = avg_factor_c_5x5
    avg1_factor_c = zeros(5, 5)
```

```text
avg0_factor_u = avg0_factor_c * avg_factor_u_mask
avg0_factor_d = avg0_factor_c * avg_factor_d_mask
avg0_factor_l = avg0_factor_c * avg_factor_l_mask
avg0_factor_r = avg0_factor_c * avg_factor_r_mask

avg1_factor_u = avg1_factor_c * avg_factor_u_mask
avg1_factor_d = avg1_factor_c * avg_factor_d_mask
avg1_factor_l = avg1_factor_c * avg_factor_l_mask
avg1_factor_r = avg1_factor_c * avg_factor_r_mask
```

### 3.4 平均值计算

```text
avg0_enable(i, j) = (sum(avg0_factor_c) != 0)
avg1_enable(i, j) = (sum(avg1_factor_c) != 0)

if (avg0_enable(i, j)):
    avg0_value_c(i, j) = sum(src_uv_s11_5x5 * avg0_factor_c) / sum(avg0_factor_c)
    avg0_value_u(i, j) = sum(src_uv_s11_5x5 * avg0_factor_u) / sum(avg0_factor_u)
    avg0_value_d(i, j) = sum(src_uv_s11_5x5 * avg0_factor_d) / sum(avg0_factor_d)
    avg0_value_l(i, j) = sum(src_uv_s11_5x5 * avg0_factor_l) / sum(avg0_factor_l)
    avg0_value_r(i, j) = sum(src_uv_s11_5x5 * avg0_factor_r) / sum(avg0_factor_r)

if (avg1_enable(i, j)):
    avg1_value_c(i, j) = sum(src_uv_s11_5x5 * avg1_factor_c) / sum(avg1_factor_c)
    avg1_value_u(i, j) = sum(src_uv_s11_5x5 * avg1_factor_u) / sum(avg1_factor_u)
    avg1_value_d(i, j) = sum(src_uv_s11_5x5 * avg1_factor_d) / sum(avg1_factor_d)
    avg1_value_l(i, j) = sum(src_uv_s11_5x5 * avg1_factor_l) / sum(avg1_factor_l)
    avg1_value_r(i, j) = sum(src_uv_s11_5x5 * avg1_factor_r) / sum(avg1_factor_r)
```

---

## 4. 梯度加权方向融合

### 4.1 边界处理

```text
grad_c = grad(i, j)

if (j == 0):
    grad_u = grad(i, j)
else:
    grad_u = grad(i, j - 1)

if (j == height - 1):
    grad_d = grad(i, j)
else:
    grad_d = grad(i, j + 1)

if (i == 0):
    grad_l = grad(i, j)
else:
    grad_l = grad(i - 1, j)

if (i == width - 1):
    grad_r = grad(i, j)
else:
    grad_r = grad(i + 1, j)
```

### 4.2 梯度逆序重映射

```text
# 保持原始方向关系不变，仅对五个方向的梯度值做逆序重映射：
#   - 原始梯度较大者，在乘法中使用较小的权重值；
#   - 原始梯度较小者，在乘法中使用较大的权重值。

grad_pair = [
    ("u", grad_u), ("d", grad_d), ("l", grad_l), ("r", grad_r), ("c", grad_c)
]
grad_pair_sorted = sort_desc_by_value(grad_pair)

for (k = 0; k < 5; k++):
    dir_k = grad_pair_sorted[k].dir
    grad_inv(dir_k) = grad_pair_sorted[4 - k].value

grad_sum = grad_inv_u + grad_inv_d + grad_inv_l + grad_inv_r + grad_inv_c
```

### 4.3 梯度融合

```text
if (grad_sum == 0):
    if (avg0_enable(i, j)):
        blend0_grad(i, j) = (
                                 avg0_value_c +
                                 avg0_value_u +
                                 avg0_value_d +
                                 avg0_value_l +
                                 avg0_value_r
                             ) / 5
    if (avg1_enable(i, j)):
        blend1_grad(i, j) = (
                                 avg1_value_c +
                                 avg1_value_u +
                                 avg1_value_d +
                                 avg1_value_l +
                                 avg1_value_r
                             ) / 5
else:
    if (avg0_enable(i, j)):
        blend0_grad(i, j) = (
                                 avg0_value_c * grad_inv_c +
                                 avg0_value_u * grad_inv_u +
                                 avg0_value_d * grad_inv_d +
                                 avg0_value_l * grad_inv_l +
                                 avg0_value_r * grad_inv_r
                             ) / grad_sum
    if (avg1_enable(i, j)):
        blend1_grad(i, j) = (
                                 avg1_value_c * grad_inv_c +
                                 avg1_value_u * grad_inv_u +
                                 avg1_value_d * grad_inv_d +
                                 avg1_value_l * grad_inv_l +
                                 avg1_value_r * grad_inv_r
                             ) / grad_sum
```

---

## 5. IIR 滤波与混合输出

### 5.1 中心像素与上方向均值融合

```text
blend_ratio_idx(i, j) = win_size_clip(i, j) / 8 - 2
ratio(i, j) = reg_siir_blending_ratio[blend_ratio_idx(i, j)]

if (avg0_enable(i, j)):
    blend0_hor(i, j) = (
                           ratio(i, j)        * blend0_grad(i, j) +
                           (64 - ratio(i, j)) * avg0_value_u(i, j)
                       ) / 64

if (avg1_enable(i, j)):
    blend1_hor(i, j) = (
                           ratio(i, j)        * blend1_grad(i, j) +
                           (64 - ratio(i, j)) * avg1_value_u(i, j)
                       ) / 64
```

### 5.2 窗混合

```python
# G_H / G_V 用于决定 2x2 patch 的主方向：
#   G_H 来源于 grad_v(i, j)
#   G_V 来源于 grad_h(i, j)
G_H = abs(grad_v(i, j))
G_V = abs(grad_h(i, j))

blend_factor_2x2_h = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]

blend_factor_2x2_v = [
    [0, 0, 0, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 0, 0, 0]
]

if (G_H > G_V):
    blend_factor_2x2_hv = blend_factor_2x2_h
else:
    blend_factor_2x2_hv = blend_factor_2x2_v

blend_factor_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
]

blend_factor_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
]

blend_factor_4x4 = [
    [1, 2, 2, 2, 1],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [1, 2, 2, 2, 1]
]

blend_factor_5x5 = [
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4]
]

# patch 融合按窗口内每个元素逐点计算：
# blend*_win_5x5(w, h; i, j) 的输出仍为一个 5x5 patch。

if (win_size_clip(i, j) < thresh0):
    if (avg1_enable(i, j)):
        blend10_win_5x5 = (
                               blend1_hor(i, j) * blend_factor_2x2_hv +
                               src_uv_s11_5x5   * (4 - blend_factor_2x2_hv)
                           ) / 4
        blend11_win_5x5 = (
                               blend1_hor(i, j) * blend_factor_2x2 +
                               src_uv_s11_5x5   * (4 - blend_factor_2x2)
                           ) / 4
        blend1_win_5x5 = (
                              blend10_win_5x5 * reg_edge_protect +
                              blend11_win_5x5 * (64 - reg_edge_protect)
                          ) / 64
elif (win_size_clip(i, j) < thresh1):
    if (avg1_enable(i, j)):
        blend10_win_5x5 = (
                               blend1_hor(i, j) * blend_factor_2x2_hv +
                               src_uv_s11_5x5   * (4 - blend_factor_2x2_hv)
                           ) / 4
        blend11_win_5x5 = (
                               blend1_hor(i, j) * blend_factor_2x2 +
                               src_uv_s11_5x5   * (4 - blend_factor_2x2)
                           ) / 4
        blend1_win_5x5 = (
                              blend10_win_5x5 * reg_edge_protect +
                              blend11_win_5x5 * (64 - reg_edge_protect)
                          ) / 64
    if (avg0_enable(i, j)):
        blend0_win_5x5 = (
                              blend0_hor(i, j) * blend_factor_3x3 +
                              src_uv_s11_5x5   * (4 - blend_factor_3x3)
                          ) / 4
elif (win_size_clip(i, j) < thresh2):
    if (avg1_enable(i, j)):
        blend1_win_5x5 = (
                              blend1_hor(i, j) * blend_factor_3x3 +
                              src_uv_s11_5x5   * (4 - blend_factor_3x3)
                          ) / 4
    if (avg0_enable(i, j)):
        blend0_win_5x5 = (
                              blend0_hor(i, j) * blend_factor_4x4 +
                              src_uv_s11_5x5   * (4 - blend_factor_4x4)
                          ) / 4
elif (win_size_clip(i, j) < thresh3):
    if (avg1_enable(i, j)):
        blend1_win_5x5 = (
                              blend1_hor(i, j) * blend_factor_4x4 +
                              src_uv_s11_5x5   * (4 - blend_factor_4x4)
                          ) / 4
    if (avg0_enable(i, j)):
        blend0_win_5x5 = (
                              blend0_hor(i, j) * blend_factor_5x5 +
                              src_uv_s11_5x5   * (4 - blend_factor_5x5)
                          ) / 4
else:
    if (avg0_enable(i, j)):
        blend0_win_5x5 = (
                              blend0_hor(i, j) * blend_factor_5x5 +
                              src_uv_s11_5x5   * (4 - blend_factor_5x5)
                          ) / 4
```

### 5.3 最终混合

```text
win_size_remain_8(i, j) = win_size_clip(i, j) % 8

if (win_size_clip(i, j) < thresh0):
    blend_uv_5x5(i, j) = blend1_win_5x5
elif (win_size_clip(i, j) >= thresh3):
    blend_uv_5x5(i, j) = blend0_win_5x5
else:
    blend_uv_5x5(i, j) = (
                              blend0_win_5x5 * win_size_remain_8 +
                              blend1_win_5x5 * (8 - win_size_remain_8)
                          ) / 8

# linebuffer 反馈更新规则：
#   1. 模块按光栅顺序逐像素处理，即从左到右、从上到下；
#   2. 对当前中心像素 (i, j)，先读取当前 linebuffer 中的 5x5 patch；
#   3. 基于该 patch 计算 blend_uv_5x5(i, j)；
#   4. 然后将该 5x5 patch 的结果写回 linebuffer；
#   5. 下一中心像素的计算，必须读取已经被上一中心像素更新后的 linebuffer 数据。
#
# 因此，该算法是带反馈的迭代式 patch 更新，而不是彼此独立的卷积处理。

for (h = -2; h <= 2; h++)
    for (w = -4; w <= 4; w = w + 2)
        src_uv_u10(
            clip(i + w, 0, reg_pic_width_m1),
            clip(j + h, 0, reg_pic_height_m1)
        ) = clip(blend_uv_5x5(i, j)(w, h) + 512, 0, 1023)
```

---

## 6. 参数配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `reg_win_size_thresh0` | 16 | 窗口大小阈值 0 |
| `reg_win_size_thresh1` | 24 | 窗口大小阈值 1 |
| `reg_win_size_thresh2` | 32 | 窗口大小阈值 2 |
| `reg_win_size_thresh3` | 40 | 窗口大小阈值 3 |
| `reg_siir_win_size_clip_y` | [15, 23, 31, 39] | 梯度裁剪阈值 |
| `reg_siir_blending_ratio` | [32, 32, 32, 32] | IIR 混合比例 |
| `reg_edge_protect` | 32 | 2x2 定向 patch 与 2x2 对称 patch 的混合比例 |