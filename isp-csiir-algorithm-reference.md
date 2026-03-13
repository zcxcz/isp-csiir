# ISP-CSIIR 算法参考文档

## Stage 1: 梯度计算与窗口大小确定

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

### 梯度计算

```
grad_h(i, j) = (src_uv_5x5 * sobel_x) / 5
grad_v(i, j) = (src_uv_5x5 * sobel_y) / 5
grad(i, j) = |grad_h| + |grad_v|
```

### 窗口大小 LUT

```
win_size_clip_y    = [15, 23, 31, 39]
win_size_clip_sft  = [2, 2, 2, 2]

win_size_grad = LUT(Max(grad(i-1,j), grad(i,j), grad(i+1,j)),
                    win_size_clip_y, win_size_clip_sft)
win_size_clip(i, j) = clip(win_size(i, j), 16, 40)
```

---

## Stage 2: 多尺度方向性平均

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
avg_factor_mask_r = [  # 右
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1]
]

avg_factor_mask_l = [  # 左
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0]
]

avg_factor_mask_u = [  # 上
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]

avg_factor_mask_d = [  # 下
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]
```

### 核选择逻辑

```
if (win_size_clip < thresh0):
    avg0_factor_c = zeros(5, 5)
    avg1_factor_c = avg_factor_c_2x2
elif (win_size_clip < thresh1):
    avg0_factor_c = avg_factor_c_2x2
    avg1_factor_c = avg_factor_c_3x3
elif (win_size_clip < thresh2):
    avg0_factor_c = avg_factor_c_3x3
    avg1_factor_c = avg_factor_c_4x4
elif (win_size_clip < thresh3):
    avg0_factor_c = avg_factor_c_4x4
    avg1_factor_c = avg_factor_c_5x5
else:
    avg0_factor_c = avg_factor_c_5x5
    avg1_factor_c = zeros(5, 5)
```

### 平均值计算

```
avg_value_c = sum(window * factor) / sum(factor)
avg_value_u = sum(window * factor_u) / sum(factor_u)
avg_value_d = sum(window * factor_d) / sum(factor_d)
avg_value_l = sum(window * factor_l) / sum(factor_l)
avg_value_r = sum(window * factor_r) / sum(factor_r)
```

---

## Stage 3: 梯度加权方向融合

### 边界处理

```
if (j == 0): grad_u = grad(i, j)
else:        grad_u = grad(i, j-1)

if (j == height-1): grad_d = grad(i, j)
else:               grad_d = grad(i, j+1)

if (i == 0): grad_l = grad(i, j)
else:        grad_l = grad(i-1, j)

if (i == width-1): grad_r = grad(i, j)
else:              grad_r = grad(i+1, j)
```

### 梯度排序 (逆序)

```
grad_u, grad_d, grad_l, grad_r, grad_c = invSort(grad_u, grad_d, grad_l, grad_r, grad_c)
grad_sum = grad_u + grad_d + grad_l + grad_r + grad_c
```

### 加权融合

```
if (grad_sum == 0):
    blend_avg = (avg_u + avg_d + avg_l + avg_r + avg_c) / 5
else:
    blend_avg = (avg_u * grad_u + avg_d * grad_d + avg_l * grad_l +
                 avg_r * grad_r + avg_c * grad_c) / grad_sum
```

---

## Stage 4: IIR 滤波与混合输出

### IIR 混合

```
blend_ratio_idx = win_size_clip / 8 - 2
ratio = reg_siir_blending_ratio[blend_ratio_idx]

blend_iir_avg = (ratio * blend_dir_avg + (64 - ratio) * avg_u) / 64
```

### 混合因子核

```python
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
```

### 最终混合

```
win_size_remain_8 = win_size_clip - (win_size_clip >> 3)
blend_uv = blend0_uv * win_size_remain_8 + blend1_uv * (8 - win_size_remain_8)
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