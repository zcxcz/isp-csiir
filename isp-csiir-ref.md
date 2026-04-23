# ISP-CSIIR 算法参考文档

本文按处理顺序描述 ISP-CSIIR 参考算法，依次包括：梯度计算与窗口大小确定、多尺度方向性平均、梯度加权方向融合，以及 IIR 滤波与混合输出。

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
grad(i, j)   = clip(|grad_h(i, j)| / 5 + |grad_v(i, j)| / 5, 0, 127)
```

说明：`grad_h` 和 `grad_v` 均基于原始无符号窗口 `src_uv_u10_5x5` 做卷积计算。

### 2.4 窗口大小 LUT

LUT 输入为 `Max(grad(i-1, j), grad(i, j), grad(i+1, j))`，输出为 `win_size_grad(i, j)`，随后再做一次限幅得到 `win_size_clip(i, j)`。

```text
win_size_clip_y   = [15, 23, 31, 39]z
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
avg_factor_u_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 3, 1, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_d_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 1, 3, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_l_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 0, 0],
    [0, 1, 3, 0, 0],
    [0, 1, 1, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_r_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 0, 1, 1, 0],
    [0, 0, 3, 1, 0],
    [0, 0, 1, 1, 0],
    [0, 0, 0, 0, 0]
]

# 3x3 核
avg_factor_c_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_u_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_d_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_l_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 0, 0],
    [0, 2, 2, 0, 0],
    [0, 1, 1, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_r_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 0, 1, 1, 0],
    [0, 0, 2, 2, 0],
    [0, 0, 1, 1, 0],
    [0, 0, 0, 0, 0]
]

# 4x4 核
avg_factor_c_4x4 = [
    [1, 2, 2, 2, 1],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [1, 2, 2, 2, 1]
]
avg_factor_u_4x4 = [
    [1, 2, 2, 2, 1],
    [2, 2, 4, 2, 2],
    [2, 2, 4, 2, 2],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_d_4x4 = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [2, 2, 4, 2, 2],
    [2, 2, 4, 2, 2],
    [1, 2, 2, 2, 1]
]
avg_factor_l_4x4 = [
    [1, 2, 2, 0, 0],
    [2, 2, 2, 0, 0],
    [2, 4, 4, 0, 0],
    [2, 2, 2, 0, 0],
    [1, 2, 2, 0, 0]
]
avg_factor_r_4x4 = [
    [0, 0, 2, 2, 1],
    [0, 0, 2, 2, 2],
    [0, 0, 4, 4, 2],
    [0, 0, 2, 2, 2],
    [0, 0, 2, 2, 1]
]


# 5x5 核
avg_factor_c_5x5 = [
    [1, 2, 1, 2, 1],
    [1, 1, 1, 1, 1],
    [2, 1, 2, 1, 2],
    [1, 1, 1, 1, 1],
    [1, 2, 1, 2, 1]
]
avg_factor_u_5x5 = [
    [1, 1, 1, 1, 1],
    [1, 1, 2, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_d_5x5 = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]，
    [1, 1, 1, 1, 1],
    [1, 1, 2, 1, 1],
    [1, 1, 1, 1, 1]
]
avg_factor_l_5x5 = [
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 2, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0]
]
avg_factor_r_5x5 = [
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 2, 1],
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
    avg0_factor_u = zeros(5, 5)
    avg0_factor_d = zeros(5, 5)
    avg0_factor_l = zeros(5, 5)
    avg0_factor_r = zeros(5, 5)
    avg1_factor_c = avg_factor_c_2x2
    avg1_factor_u = avg_factor_u_2x2
    avg1_factor_d = avg_factor_d_2x2
    avg1_factor_l = avg_factor_l_2x2
    avg1_factor_r = avg_factor_r_2x2
elif (win_size_clip(i, j) < thresh1):
    avg0_factor_c = avg_factor_c_2x2
    avg0_factor_u = avg_factor_u_2x2
    avg0_factor_d = avg_factor_d_2x2
    avg0_factor_l = avg_factor_l_2x2
    avg0_factor_r = avg_factor_r_2x2
    avg1_factor_c = avg_factor_c_3x3
    avg1_factor_u = avg_factor_u_3x3
    avg1_factor_d = avg_factor_d_3x3
    avg1_factor_l = avg_factor_l_3x3
    avg1_factor_r = avg_factor_r_3x3
elif (win_size_clip(i, j) < thresh2):
    avg0_factor_c = avg_factor_c_3x3
    avg0_factor_u = avg_factor_u_3x3
    avg0_factor_d = avg_factor_d_3x3
    avg0_factor_l = avg_factor_l_3x3
    avg0_factor_r = avg_factor_r_3x3
    avg1_factor_c = avg_factor_c_4x4
    avg1_factor_u = avg_factor_u_4x4
    avg1_factor_d = avg_factor_d_4x4
    avg1_factor_l = avg_factor_l_4x4
    avg1_factor_r = avg_factor_r_4x4
elif (win_size_clip(i, j) < thresh3):
    avg0_factor_c = avg_factor_c_4x4
    avg0_factor_u = avg_factor_u_4x4
    avg0_factor_d = avg_factor_d_4x4
    avg0_factor_l = avg_factor_l_4x4
    avg0_factor_r = avg_factor_r_4x4
    avg1_factor_c = avg_factor_c_5x5
    avg1_factor_u = avg_factor_u_5x5
    avg1_factor_d = avg_factor_d_5x5
    avg1_factor_l = avg_factor_l_5x5
    avg1_factor_r = avg_factor_r_5x5
else:
    avg0_factor_c = avg_factor_c_5x5
    avg0_factor_u = avg_factor_u_5x5
    avg0_factor_d = avg_factor_d_5x5
    avg0_factor_l = avg_factor_l_5x5
    avg0_factor_r = avg_factor_r_5x5
    avg1_factor_c = zeros(5, 5)
    avg1_factor_u = zeros(5, 5)
    avg1_factor_d = zeros(5, 5)
    avg1_factor_l = zeros(5, 5)
    avg1_factor_r = zeros(5, 5)
```

### 3.4 平均值计算

仅当对应核非零时，才启用该路径的平均值计算。

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

### 4.3 梯度融合

这里如果有两路滤波，则两路滤波需要分别根据自身 avg 值作如下运算：
```text
min0_grad=2048
min0_grad_avg=0
if (grad_u <= min0_grad):
    min0_grad=grad_u
    min0_grad_avg=avg0_value_u
if (grad_l <= min0_grad):
    min0_grad=grad_l
    min0_grad_avg=(avg0_value_l+min0_grad_avg+1)/2
if (grad_c <= min0_grad):
    min0_grad=grad_c
    min0_grad_avg=(avg0_value_c+min0_grad_avg+1)/2
if (grad_r <= min0_grad):
    min0_grad=grad_r
    min0_grad_avg=(avg0_value_r+min0_grad_avg+1)/2
if (grad_d <= min0_grad):
    min0_grad=grad_d
    min0_grad_avg=(avg0_value_d+min0_grad_avg+1)/2

min1_grad=2048
min1_grad_avg=0
if (grad_u <= min1_grad):
    min1_grad=grad_u
    min1_grad_avg=avg0_value_u
if (grad_l <= min1_grad):
    min1_grad=grad_l
    min1_grad_avg=(avg0_value_l+min1_grad_avg+1)/2
if (grad_c <= min1_grad):
    min1_grad=grad_c
    min1_grad_avg=(avg0_value_c+min1_grad_avg+1)/2
if (grad_r <= min1_grad):
    min1_grad=grad_r
    min1_grad_avg=(avg0_value_r+min1_grad_avg+1)/2
if (grad_d <= min1_grad):
    min1_grad=grad_d
    min1_grad_avg=(avg0_value_d+min1_grad_avg+1)/2

blend0_grad = min0_grad_avg
blend1_grad = min1_grad_avg
---

## 5. IIR 滤波与混合输出

### 5.1 中心像素与上方向均值融合

该步骤使用 `reg_siir_blending_ratio` 在梯度融合结果与上方向均值之间做线性混合。

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

最终输出根据 `win_size_clip(i, j)` 所在区间，在大小两条窗口路径之间切换或插值。

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

# linebuffer / stage 内部反馈更新规则：
#   1. 模块按光栅顺序逐像素处理，即从左到右、从上到下；
#   2. 对当前中心像素 (i, j)，先读取当前可见 linebuffer 数据与 stage 内部暂存列，共同构成当前 5x5 patch；
#   3. 基于该 patch 计算 blend_uv_5x5(i, j)；
#   4. 对于当前 patch 中，后续同一行中心像素仍会继续依赖的重叠列，不允许立刻写回 linebuffer，
#      而应暂存在 stage 内部寄存器中；
#   5. 仅当某一列已经成为“后续同一行 patch 不再依赖的安全列”时，才允许将该 5x1 列提交回 linebuffer；
#   6. 到达右侧边界时，需要把 stage 内部尚未提交、且横向坐标仍在图像有效范围内的剩余列一次性释放到 linebuffer；
#      因此在右侧边界附近，提交宽度会退化为：
#        - 倒数第 2 个中心像素：释放剩余有效列，不允许 padding 列覆盖有效列；
#        - 最后 1 个中心像素：释放最终剩余有效列，不允许 padding 列覆盖有效列。
#
# 因此，算法语义上是“patch 计算 + 局部列暂存 + 安全列提交”的反馈过程，
# linebuffer 只保存已经正式提交的历史结果；同一行 patch 的重叠部分由 stage 内部状态维护，
# 不是把每个中心像素得到的整幅 5x5 patch 立刻回写到 linebuffer。
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
