# ISP-CSIIR ref 对齐检查清单

## 文档信息

| 项目 | 内容 |
|------|------|
| 版本 | v1.0 |
| 创建日期 | 2026-03-31 |
| 更新日期 | 2026-03-31 |
| 对应轮次 | ref 对齐与 backpressure 规格冻结 |

## 说明

- 本清单用于冻结 `/home/sheldon/rtl_project/isp-csiir/isp-csiir-ref.md` 与当前实现之间的 blocker。
- 所有条目均以 ref 语义为验收基线，不以当前 RTL 行为为例外。
- `valid/ready` backpressure 为强制要求，相关 blocker 不可降级。

## blocker 清单

- [ ] Stage2 双路径核选择与 enable/disable
- [ ] Stage3 方向绑定的逆序梯度映射
- [ ] Stage3 右方向梯度读取
- [ ] Stage4 patch 级混合
- [ ] Stage4 需要消费 5x5 patch、`grad_h`、`grad_v`、`reg_edge_protect`
- [ ] Stage4 → line buffer patch feedback handshake
- [ ] line buffer 真正消费 patch writeback
- [ ] end-to-end backpressure
