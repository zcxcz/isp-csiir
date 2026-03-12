# Stage1

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
reg_siir_win_size_clip_y    = [15, 23, 31, 39]
reg_siir_win_size_clip_sft  = [2, 2, 2, 2]

grad_h(i, j) = (src_uv_5x5(i, j) * sobel_x)
grad_v(i, j) = (src_uv_5x5(i, j) * sobel_y)
grad(i, j) = abs(grad_h) / 5 + abs(grad_v) / 5
mot_sft[4] = { 2,2,2,2 }
win_size_grad   = LUT(  Max( grad(i-1, j), grad(i, j), grad(i+1, j) ), reg_siir_win_size_clip_y, reg_siir_win_size_clip_sft  )
win_size_motion = LUT( motion(i, j), reg_siir_mot_protect, mot_sft )
win_size(i, j) = win_size_grad + win_size_motion
win_size_clip(i, j) = clip( win_size(i, j), , 16, 40 )


# stage2

avg_factor_c_2x2 = [
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
]

avg_factor_c_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
]

avg_factor_c_4x4 = [
    [1, 1, 2, 1, 1],
    [1, 2, 4, 2, 1],
    [2, 4, 8, 4, 2],
    [1, 2, 4, 2, 1],
    [1, 1, 2, 1, 1]
]

avg_factor_c_5x5 = [
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]

avg_factor_mask_r = [
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1]
]
avg_factor_mask_l = [
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0]
]
avg_factor_mask_u = [
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
]
avg_factor_mask_d = [
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]

if (win_size_clip(i, j) < reg_win_size_thresh0) 
    avg0_factor_c = zeros(5, 5)
    avg1_factor_c = avg_factor_c_2x2
if (win_size_clip(i, j) >= reg_win_size_thresh0 && win_size_clip(i, j) < reg_win_size_thresh1) 
    avg0_factor_c = avg_factor_c_2x2
    avg1_factor_c = avg_factor_c_3x3
if (win_size_clip(i, j) >= reg_win_size_thresh1 && win_size_clip(i, j) < reg_win_size_thresh2) 
    avg0_factor_c = avg_factor_c_3x3
    avg1_factor_c = avg_factor_c_4x4
if (win_size_clip(i, j) >= reg_win_size_thresh2 && win_size_clip(i, j) < reg_win_size_thresh3) 
    avg0_factor_c = avg_factor_c_4x4
    avg1_factor_c = avg_factor_c_5x5
if (win_size_clip(i, j) >= reg_win_size_thresh3)
    avg0_factor_c = avg_factor_c_5x5
    avg1_factor_c = zeros(5, 5)

avg0_factor_u = avg0_factor_c * avg_factor_mask_u
avg0_factor_d = avg0_factor_c * avg_factor_mask_d
avg0_factor_l = avg0_factor_c * avg_factor_mask_l
avg0_factor_r = avg0_factor_c * avg_factor_mask_r

avg1_factor_u = avg1_factor_c * avg_factor_mask_u
avg1_factor_d = avg1_factor_c * avg_factor_mask_d
avg1_factor_l = avg1_factor_c * avg_factor_mask_l
avg1_factor_r = avg1_factor_c * avg_factor_mask_r

avg0_value_c(i, j) = sum( src_uv_5x5(i, j) * avg0_factor_c(i, j) ) / sum( avg0_factor_c(i, j) )
avg0_value_u(i, j) = sum( src_uv_5x5(i, j) * avg0_factor_u(i, j) ) / sum( avg0_factor_u(i, j) )
avg0_value_d(i, j) = sum( src_uv_5x5(i, j) * avg0_factor_d(i, j) ) / sum( avg0_factor_d(i, j) )
avg0_value_l(i, j) = sum( src_uv_5x5(i, j) * avg0_factor_l(i, j) ) / sum( avg0_factor_l(i, j) )
avg0_value_r(i, j) = sum( src_uv_5x5(i, j) * avg0_factor_r(i, j) ) / sum( avg0_factor_r(i, j) )

avg1_value_c(i, j) = sum( src_uv_5x5(i, j) * avg1_factor_c(i, j) ) / sum( avg1_factor_c(i, j) )
avg1_value_u(i, j) = sum( src_uv_5x5(i, j) * avg1_factor_u(i, j) ) / sum( avg1_factor_u(i, j) )
avg1_value_d(i, j) = sum( src_uv_5x5(i, j) * avg1_factor_d(i, j) ) / sum( avg1_factor_d(i, j) )
avg1_value_l(i, j) = sum( src_uv_5x5(i, j) * avg1_factor_l(i, j) ) / sum( avg1_factor_l(i, j) )
avg1_value_r(i, j) = sum( src_uv_5x5(i, j) * avg1_factor_r(i, j) ) / sum( avg1_factor_r(i, j) )


# stage3
if (j==0)
    grad_u(i, j) = grad(i, j)
else
    grad_u(i, j) = grad(i, j-1)

if (j==reg_pic_height_m1)
    grad_d(i, j) = grad(i, j)
else
    grad_d(i, j) = grad(i, j+1)

if (i==0)
    grad_l(i, j) = grad(i, j)
else
    grad_l(i, j) = grad(i-1, j)

if (i==reg_pic_width_m1)
    grad_r(i, j) = grad(i, j)
else
    grad_r(i, j) = grad(i+1, j)

grad_u(i, j), grad_d(i, j), grad_l(i, j), grad_r(i, j), grad_c(i, j) = invSort( grad_u(i, j), grad_d(i, j), grad_l(i, j), grad_r(i, j), grad_c(i, j) )
grad_sum(i, j) = grad_u(i, j) + grad_d(i, j) + grad_l(i, j) + grad_r(i, j) + grad_c(i, j)
if ( grad_sum(i, j)==0 )
    blend0_dir_avg(i, j) = ( avg0_value_u(i, j) + avg0_value_d(i, j) + avg0_value_l(i, j) + avg0_value_r(i, j) + avg0_value_c(i, j) ) / 5
    blend1_dir_avg(i, j) = ( avg1_value_u(i, j) + avg1_value_d(i, j) + avg1_value_l(i, j) + avg1_value_r(i, j) + avg1_value_c(i, j) ) / 5
else
    blend0_dir_avg(i, j) = ( avg0_value_u(i, j) * grad_u(i, j) + avg0_value_d(i, j) * grad_d(i, j) + avg0_value_l(i, j) * grad_l(i, j) + avg0_value_r(i, j) * grad_r(i, j) + avg0_value_c(i, j) * grad_c(i, j) ) / grad_sum(i, j)
    blend1_dir_avg(i, j) = ( avg1_value_u(i, j) * grad_u(i, j) + avg1_value_d(i, j) * grad_d(i, j) + avg1_value_l(i, j) * grad_l(i, j) + avg1_value_r(i, j) * grad_r(i, j) + avg1_value_c(i, j) * grad_c(i, j) ) / grad_sum(i, j)


# stage4

blend0_iir_avg(i, j) = ( reg_siir_blending_ratio[win_size_clip(i, j)/8 - 2] * blend0_dir_avg(i, j) + (64 - reg_siir_blending_ratio[win_size_clip(i, j)/8 - 2]) * avg0_value_u(i, j) ) / 64
blend1_iir_avg(i, j) = ( reg_siir_blending_ratio[win_size_clip(i, j)/8 - 2] * blend1_dir_avg(i, j) + (64 - reg_siir_blending_ratio[win_size_clip(i, j)/8 - 2]) * avg1_value_u(i, j) ) / 64

blend0_uv_5x5(i, j) = src_uv_5x5(i, j)
blend1_uv_5x5(i, j) = src_uv_5x5(i, j)

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

if ( grad_h(i, j) >= grad_v(i, j) )
    blend_factor_2x2 = blend_factor_2x2_h
else
    blend_factor_2x2 = blend_factor_2x2_v

blend_factor_3x3 = [
    [0, 0, 0, 0, 0],
    [0, 4, 4, 4, 0],
    [0, 4, 4, 4, 0],
    [0, 4, 4, 4, 0],
    [0, 0, 0, 0, 0]
]

blend_factor_4x4 = [
    [1, 2, 2, 2, 1],
    [1, 4, 4, 4, 2],
    [1, 4, 4, 4, 2],
    [1, 4, 4, 4, 2],
    [1, 2, 2, 2, 1],
]

blend_factor_5x5 = [
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
]

if (win_size_clip(i, j) < 16)
    blend0_factor = zeros(5, 5)
    blend1_factor = blend_factor_2x2
if (win_size_clip(i, j) >= reg_win_size_thresh0 && win_size_clip(i, j) < reg_win_size_thresh1) 
    blend0_factor = blend_factor_2x2
    blend1_factor = blend_factor_3x3
if (win_size_clip(i, j) >= reg_win_size_thresh1 && win_size_clip(i, j) < reg_win_size_thresh2) 
    blend0_factor = blend_factor_3x3
    blend1_factor = blend_factor_4x4
if (win_size_clip(i, j) >= reg_win_size_thresh2 && win_size_clip(i, j) < reg_win_size_thresh3) 
    blend0_factor = blend_factor_4x4
    blend1_factor = blend_factor_5x5
if (win_size_clip(i, j) >= reg_win_size_thresh3)
    blend0_factor = blend_factor_5x5
    blend1_factor = zeros(5, 5)

blend0_add_avg(i, j) = blend0_iir_avg(i, j) * blend0_factor
blend1_add_avg(i, j) = blend1_iir_avg(i, j) * blend1_factor

blend0_uv_5x5 = blend0_iir_avg(i, j) * blend0_factor + （ （4-blend0_factor) * src_uv_5x5(i, j) ) 
blend1_uv_5x5 = blend1_iir_avg(i, j) * blend1_factor + （ （4-blend1_factor) * src_uv_5x5(i, j) ) 

win_size_clip_remain_8 = win_size_clip - (win_size_clip >> 3)
blend_uv_5x5(i, j) = blend0_uv_5x5(i, j)*win_size_clip_remain_8 + blend1_uv_5x5(i, j)*(8-win_size_clip_remain_8)
