# ISP-CSIIR 算法参考文档

## 说明

若变量名称为 src_uv_u10, u10 后缀表明其数据类型为 10-bit 无符号数；
若变量名称为 src_uv_s11, s11 后缀表明其数据类型为 11-bit 有符号数（MSB 为 1-bit 符号位）；
若变量名称类似为 a_5x5(i, j), 5x5 标识说明这是一个二维矩阵，(i, j) 为当前矩阵中心像素坐标；
若变量名称类似 b(i, j), (i, j) 为当前像素坐标；
clip(a, b, c) 为限幅函数，当 a 在 (b, c) 区间内时，取 a 值，小于 b 则取 b，大于 c 则取 c；
当索引 src_uv_s11(i, j), 超出原二维数组边界时，对超出部分取临近值做 duplicating；

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
    for (i=0; i<=reg_pic_height_m1; i++)
        for (h=-2; h<=2; h++)
            for (w=-2; w<=4; w=w+2)
                src_uv_u10_5x5(w, h) = src_uv_u10( clip(i+w, 0, reg_pic_width_m1), clip(j+h, 0, reg_pic_height_m1) )
                src_uv_s11_5x5(w, h) = src_uv_s11( clip(i+w, 0, reg_pic_width_m1), clip(j+h, 0, reg_pic_height_m1) )
```
其中， (i, j) 为当前中心元素坐标，(w, h) 为滤波窗内偏移坐标；

### 梯度计算
```
grad_h(i, j) = (src_uv_u10_5x5 * sobel_x)
grad_v(i, j) = (src_uv_u10_5x5 * sobel_y)
grad(i, j) = |grad_h(i, j)| / 5 + |grad_v(i, j)| / 5
```

### 窗口大小 LUT

```
win_size_clip_y    = [15, 23, 31, 39]
win_size_clip_sft  = [2, 2, 2, 2]

win_size_grad(i,j) = LUT(Max(grad(i-1,j), grad(i,j), grad(i+1,j)), win_size_clip_y, win_size_clip_sft)
win_size_clip(i, j) = clip(win_size(i, j), 16, 40)
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
if (win_size_clip(i, j) < thresh0):
    avg0_factor_c = zeros(5, 5)
    avg1_factor_c = avg_factor_c_2x2
elif (win_size_clip(i, j) < thresh1):
    avg0_factor_c = avg_factor_c_2x2
    avg1_factor_c = avg_factor_c_3x3
elif (win_size_clip(i, j) < thresh2):
    avg0_factor_c = avg_factor_c_3x3
    avg1_factor_c = avg_factor_c_4x4
elif (win_size_clip(i, j) < thresh3):
    avg0_factor_c = avg_factor_c_4x4
    avg1_factor_c = avg_factor_c_5x5
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
avg0_value_c(i, j) = sum(src_uv_s11_5x5 * avg0_factor_c) / sum(avg0_factor_c)
avg0_value_u(i, j) = sum(src_uv_s11_5x5 * avg0_factor_u) / sum(avg0_factor_u)
avg0_value_d(i, j) = sum(src_uv_s11_5x5 * avg0_factor_d) / sum(avg0_factor_d)
avg0_value_l(i, j) = sum(src_uv_s11_5x5 * avg0_factor_l) / sum(avg0_factor_l)
avg0_value_r(i, j) = sum(src_uv_s11_5x5 * avg0_factor_r) / sum(avg0_factor_r)

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

### 梯度排序 (逆序)

```
grad_u, grad_d, grad_l, grad_r, grad_c = invSort(grad_u, grad_d, grad_l, grad_r, grad_c)
grad_sum = grad_u + grad_d + grad_l + grad_r + grad_c
```

### 梯度融合

```
if (grad_sum == 0):
    blend0_grad(i, j) =  (   avg0_value_c + 
                                avg0_value_u + 
                                avg0_value_d + 
                                avg0_value_l + 
                                avg0_value_r
                            ) / 5
    blend1_grad(i, j) =  (   avg1_value_c + 
                                avg1_value_u + 
                                avg1_value_d + 
                                avg1_value_l + 
                                avg1_value_r
                            ) / 5
else:
    blend0_grad(i, j) =  (   avg0_value_c * grad_c + 
                                avg0_value_u * grad_u + 
                                avg0_value_d * grad_d + 
                                avg0_value_l * grad_l +
                                avg0_value_r * grad_r
                            ) / grad_sum
    blend1_grad(i, j) =  (   avg1_value_c * grad_c + 
                                avg1_value_u * grad_u + 
                                avg1_value_d * grad_d + 
                                avg1_value_l * grad_l +
                                avg1_value_r * grad_r
                            ) / grad_sum
```

---

## IIR 滤波与混合输出

### 水平混合

```
blend_ratio_idx(i, j) = win_size_clip(i, j) / 8 - 2
ratio(i, j) = reg_siir_blending_ratio[blend_ratio_idx(i, j)]

blend0_hor(i, j) = (     ratio(i, j)   * blend0_grad(i, j) + 
                    ( ( 64 - ratio(i, j) ) * avg0_value_u(i, j) 
                ) / 64
blend1_hor(i, j) = (     ratio(i, j)   * blend1_grad(i, j) + 
                    ( ( 64 - ratio(i, j) ) * avg1_value_u(i, j) 
                ) / 64
``` 

### 窗混合

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

if (G_H > G_V)
    blend_factor_2x2_hv = blend_factor_2x2_h
else
    blend_factor_2x2_hv = blend_factor_2x2_v


blend_factor_2x2 = [
    [0, 0, 0, 0, 0]
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

if (win_size_clip(i, j) < thresh0):
    blend00_win_5x5 = blend0_hor(i, j) * blend_factor_2x2_hv + src_uv_s11_5x5 * ( 4-blend_factor_2x2_hv)
    blend01_win_5x5 = blend0_hor(i, j) * blend_factor_2x2    + src_uv_s11_5x5 * ( 4-blend_factor_2x2)
    blend0_win_5x5 = blend00_win_5x5 * reg_edge_protect + blend01_win_5x5 * (64-reg_edge_protect)
elif (win_size_clip(i, j) < thresh1):
    blend00_win_5x5 = blend0_hor(i, j) * blend_factor_2x2_hv + src_uv_s11_5x5 * ( 4-blend_factor_2x2_hv)
    blend01_win_5x5 = blend0_hor(i, j) * blend_factor_2x2    + src_uv_s11_5x5 * ( 4-blend_factor_2x2)
    blend0_win_5x5 = blend00_win_5x5 * reg_edge_protect + blend01_win_5x5 * (64-reg_edge_protect)
    blend1_win_5x5 = blend1_hor * blend_factor_3x3 + src_uv_s11_5x5 * (4-blend_factor_3x3)
elif (win_size_clip(i, j) < thresh2):
    blend0_win_5x5 = blend0_hor * blend_factor_3x3 + src_uv_s11_5x5 * (4-blend_factor_3x3)
    blend1_win_5x5 = blend1_hor * blend_factor_4x4 + src_uv_s11_5x5 * (4-blend_factor_4x4)
elif (win_size_clip(i, j) < thresh3):
    blend0_win_5x5 = blend0_hor * blend_factor_4x4 + src_uv_s11_5x5 * (4-blend_factor_4x4)
    blend1_win_5x5 = blend1_hor * blend_factor_5x5 + src_uv_s11_5x5 * (4-blend_factor_5x5)
else:
    blend1_win_5x5 = blend1_hor * blend_factor_5x5 + src_uv_s11_5x5 * (4-blend_factor_5x5)
```

### 最终混合

```
win_size_remain_8(i, j) = win_size_clip(i, j)%8
if (win_size_clip(i, j) < thresh0):
    blend_uv(i, j) = blend0_win_5x5
elif (win_size_clip(i, j) >= thresh3):
    blend_uv(i, j) = blend1_win_5x5
else:
    blend_uv(i, j) = blend0_win_5x5 * win_size_remain_8 + blend1_win_5x5 * (8 - win_size_remain_8)

for (h=-2; h<=2; h++)
    if ( i>=0 && j+h>=0 )
        src_uv_u10(i, j+h)=clip( blend_uv(i, j)+512, 0 , 1023)
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
