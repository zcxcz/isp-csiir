# ISP-CSIIR 算法参考文档

## 说明

若变量名称为 src_uv_u10, u10 后缀表明其数据类型为 10-bit 无符号数；
若变量名称为 src_uv_s11, s11 后缀表明其数据类型为 11-bit 有符号数（MSB 为 1-bit 符号位）；
若变量名称类似为 a_5x5(i, j), 5x5 标识说明这是一个二维矩阵，(i, j) 为当前矩阵中心像素坐标；
若变量名称类似 b(i, j), (i, j) 为当前像素坐标；
clip(a, b, c) 为限幅函数，当 a 在 (b, c) 区间内时，取 a 值，小于 b 则取 b，大于 c 则取 c；
当索引 src_uv_s11(i, j), 超出原二维数组边界时，对超出部分取临近值做 duplicating；
若未特别说明，本文所有缩放除法、插值和定点截位默认采用四舍五入；超出目标数值范围时采用饱和截位；

## 梯度计算与窗口大小确定

### Sobel 滤波器

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

src_uv_s11 = src_uv_u10 - 512

### 滤波窗数据更新

```
for (j=0; j<=reg_pic_height_m1; j++)
    for (i=0; i<=reg_pic_width_m1; i++)
        for (h=-2; h<=2; h++)
            for (w=-4; w<=4; w=w+2)
                src_uv_u10_5x5(w, h) = src_uv_u10( clip(i+w, 0, reg_pic_width_m1), clip(j+h, 0, reg_pic_height_m1) )
                src_uv_s11_5x5(w, h) = src_uv_s11( clip(i+w, 0, reg_pic_width_m1), clip(j+h, 0, reg_pic_height_m1) )
```
其中， (i, j) 为当前中心元素坐标，(w, h) 为滤波窗内偏移坐标，横向偏移集合为 {-4, -2, 0, 2, 4}，纵向偏移集合为 {-2, -1, 0, 1, 2}；

### 梯度计算
```
grad_h(i, j) = (src_uv_u10_5x5 * sobel_x)   # 基于原值 unsigned 窗口做卷积
grad_v(i, j) = (src_uv_u10_5x5 * sobel_y)   # 基于原值 unsigned 窗口做卷积
grad(i, j) = |grad_h(i, j)| / 5 + |grad_v(i, j)| / 5
```

### 窗口大小 LUT

```
win_size_clip_y    = [15, 23, 31, 39]
win_size_clip_sft  = [2, 2, 2, 2]

# LUT 定义：
#   x0 = 2^(win_size_clip_sft[0])
#   x1 = x0 + 2^(win_size_clip_sft[1])
#   x2 = x1 + 2^(win_size_clip_sft[2])
#   x3 = x2 + 2^(win_size_clip_sft[3])
# 对当前输入 x = Max(grad(i-1,j), grad(i,j), grad(i+1,j))：
#   - 当 x 位于相邻两个坐标点之间时，按对应 y 值做线性插值
#   - 线性插值的截位规则默认采用四舍五入
#   - 当 x 小于最小节点 x0 时，输出钳位为 y0
#   - 当 x 大于最大节点 x3 时，输出钳位为 y3
#   - 当前参数默认对应 4 个 x 节点: [4, 8, 12, 16]
#   - 当前参数默认对应 4 个 y 节点: [15, 23, 31, 39]

win_size_grad(i,j) = LUT(Max(grad(i-1,j), grad(i,j), grad(i+1,j)), win_size_clip_y, win_size_clip_sft)
win_size_clip(i, j) = clip(win_size_grad(i, j), 16, 40)
```

---

## 多尺度方向性平均

### 平均因子核

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

### 方向掩码

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

### 核选择逻辑

```
# 命名约定：
#   avg1 / blend1 表示较小窗口路径
#   avg0 / blend0 表示较大窗口路径
# 当某一路核为 zeros(5,5) 时，该路当前及后续运算全部跳过

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

avg0_factor_u = avg0_factor_c * avg_factor_u_mask
avg0_factor_d = avg0_factor_c * avg_factor_d_mask
avg0_factor_l = avg0_factor_c * avg_factor_l_mask
avg0_factor_r = avg0_factor_c * avg_factor_r_mask

avg1_factor_u = avg1_factor_c * avg_factor_u_mask
avg1_factor_d = avg1_factor_c * avg_factor_d_mask
avg1_factor_l = avg1_factor_c * avg_factor_l_mask
avg1_factor_r = avg1_factor_c * avg_factor_r_mask

### 平均值计算

```
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

## 梯度加权方向融合

### 边界处理

```
grad_c = grad(i, j)

if (j == 0): grad_u = grad(i, j)
else:        grad_u = grad(i, j-1)

if (j == height-1): grad_d = grad(i, j)
else:               grad_d = grad(i, j+1)

if (i == 0): grad_l = grad(i, j)
else:        grad_l = grad(i-1, j)

if (i == width-1): grad_r = grad(i, j)
else:              grad_r = grad(i+1, j)
```

### 梯度逆序重映射

```
# 保持原始方向关系不变，仅对五个方向的梯度值做逆序重映射：
# 原始梯度较大者，在乘法中使用较小的权重值；
# 原始梯度较小者，在乘法中使用较大的权重值。

grad_pair = [
    ("u", grad_u), ("d", grad_d), ("l", grad_l), ("r", grad_r), ("c", grad_c)
]
grad_pair_sorted = sort_desc_by_value(grad_pair)

for (k=0; k<5; k++):
    dir_k = grad_pair_sorted[k].dir
    grad_inv(dir_k) = grad_pair_sorted[4-k].value

grad_sum = grad_inv_u + grad_inv_d + grad_inv_l + grad_inv_r + grad_inv_c
```

### 梯度融合

```
if (grad_sum == 0):
    if (avg0_enable(i, j)):
        blend0_grad(i, j) =  (
                                  avg0_value_c +
                                  avg0_value_u +
                                  avg0_value_d +
                                  avg0_value_l +
                                  avg0_value_r
                              ) / 5
    if (avg1_enable(i, j)):
        blend1_grad(i, j) =  (
                                  avg1_value_c +
                                  avg1_value_u +
                                  avg1_value_d +
                                  avg1_value_l +
                                  avg1_value_r
                              ) / 5
else:
    if (avg0_enable(i, j)):
        blend0_grad(i, j) =  (
                                  avg0_value_c * grad_inv_c +
                                  avg0_value_u * grad_inv_u +
                                  avg0_value_d * grad_inv_d +
                                  avg0_value_l * grad_inv_l +
                                  avg0_value_r * grad_inv_r
                              ) / grad_sum
    if (avg1_enable(i, j)):
        blend1_grad(i, j) =  (
                                  avg1_value_c * grad_inv_c +
                                  avg1_value_u * grad_inv_u +
                                  avg1_value_d * grad_inv_d +
                                  avg1_value_l * grad_inv_l +
                                  avg1_value_r * grad_inv_r
                              ) / grad_sum
```

---

## IIR 滤波与混合输出

### 中心像素与上方向均值融合

```
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

### 窗混合

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

if (G_H > G_V)
    blend_factor_2x2_hv = blend_factor_2x2_h
else
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
# blend*_win_5x5(w, h; i, j) 的输出仍然是一个 5x5 patch

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

### 最终混合

```
win_size_remain_8(i, j) = win_size_clip(i, j)%8
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
#   - 模块按光栅顺序逐像素处理（从左到右，从上到下）
#   - 对于当前中心像素 (i, j)，先读取当前 linebuffer 中的 5x5 patch
#   - 基于该 patch 计算 blend_uv_5x5(i, j)
#   - 然后将该 5x5 patch 的结果写回 linebuffer
#   - 下一中心像素的计算必须读取到已经被上一中心像素更新后的 linebuffer 数据
# 因此该算法是带反馈的迭代式 patch 更新，而不是彼此独立的卷积处理

for (h=-2; h<=2; h++)
    for (w=-4; w<=4; w=w+2)
        src_uv_u10(
            clip(i+w, 0, reg_pic_width_m1),
            clip(j+h, 0, reg_pic_height_m1)
        ) = clip(blend_uv_5x5(i, j)(w, h) + 512, 0, 1023)
```

---

## 参数配置

| 参数 | 默认值 | 描述 |
|------|--------|------|
| reg_win_size_thresh0 | 16 | 窗口大小阈值 0 |
| reg_win_size_thresh1 | 24 | 窗口大小阈值 1 |
| reg_win_size_thresh2 | 32 | 窗口大小阈值 2 |
| reg_win_size_thresh3 | 40 | 窗口大小阈值 3 |
| reg_siir_win_size_clip_y | [15, 23, 31, 39] | 梯度裁剪阈值 |
| reg_siir_blending_ratio | [32, 32, 32, 32] | IIR 混合比例 |
| reg_edge_protect | 32 | 2x2 定向 patch 与 2x2 对称 patch 的混合比例 |
