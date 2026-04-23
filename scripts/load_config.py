#!/usr/bin/env python3
"""
ISP-CSIIR 配置加载器 - 从 JSON 文件加载配置

用法:
    from load_config import load_config
    config = load_config('config.json')
"""

import json
from typing import Dict, Any, Optional


def load_config(config_path: str) -> Dict[str, Any]:
    """加载配置文件"""
    with open(config_path, 'r') as f:
        return json.load(f)


def get_config_value(config: Dict[str, Any], key: str, default: Any) -> Any:
    """获取配置值，如果不存在则返回默认值"""
    return config.get(key, default)


def to_hls_params(config: Dict[str, Any]) -> str:
    """
    将配置转换为 HLS C++ 参数格式

    返回格式: "width,height,win_thresh0,win_thresh1,..."
    """
    width = config.get('width', 16)
    height = config.get('height', 16)
    win_thresh = config.get('win_thresh', [100, 200, 400, 800])
    grad_clip = config.get('grad_clip', [15, 23, 31, 39])
    blend_ratio = config.get('blend_ratio', [32, 32, 32, 32])
    edge_protect = config.get('edge_protect', 32)

    params = [
        str(width),
        str(height),
        str(win_thresh[0]), str(win_thresh[1]), str(win_thresh[2]), str(win_thresh[3]),
        str(grad_clip[0]), str(grad_clip[1]), str(grad_clip[2]), str(grad_clip[3]),
        str(blend_ratio[0]), str(blend_ratio[1]), str(blend_ratio[2]), str(blend_ratio[3]),
        str(edge_protect)
    ]
    return ','.join(params)


def to_hls_define(config: Dict[str, Any]) -> str:
    """
    生成 HLS C++ #define 语句
    """
    defines = []
    defines.append(f"#define IMG_WIDTH {config.get('width', 16)}")
    defines.append(f"#define IMG_HEIGHT {config.get('height', 16)}")

    win_thresh = config.get('win_thresh', [100, 200, 400, 800])
    grad_clip = config.get('grad_clip', [15, 23, 31, 39])
    blend_ratio = config.get('blend_ratio', [32, 32, 32, 32])
    edge_protect = config.get('edge_protect', 32)

    defines.append(f"#define WIN_THRESH0 {win_thresh[0]}")
    defines.append(f"#define WIN_THRESH1 {win_thresh[1]}")
    defines.append(f"#define WIN_THRESH2 {win_thresh[2]}")
    defines.append(f"#define WIN_THRESH3 {win_thresh[3]}")
    defines.append(f"#define GRAD_CLIP0 {grad_clip[0]}")
    defines.append(f"#define GRAD_CLIP1 {grad_clip[1]}")
    defines.append(f"#define GRAD_CLIP2 {grad_clip[2]}")
    defines.append(f"#define GRAD_CLIP3 {grad_clip[3]}")
    defines.append(f"#define BLEND_RATIO0 {blend_ratio[0]}")
    defines.append(f"#define BLEND_RATIO1 {blend_ratio[1]}")
    defines.append(f"#define BLEND_RATIO2 {blend_ratio[2]}")
    defines.append(f"#define BLEND_RATIO3 {blend_ratio[3]}")
    defines.append(f"#define EDGE_PROTECT {edge_protect}")

    return '\n'.join(defines)


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 2:
        print("用法: python3 load_config.py <config.json>")
        sys.exit(1)

    config = load_config(sys.argv[1])
    print("配置内容:")
    print(json.dumps(config, indent=2))
    print("\nHLS 参数:")
    print(to_hls_params(config))
    print("\nHLS Defines:")
    print(to_hls_define(config))
