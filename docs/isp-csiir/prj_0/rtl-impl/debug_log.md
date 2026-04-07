# rtl-impl Debug 记录

## 问题记录

### 2026-04-02 Stage4 顶层 metadata 未接入
- 现象: `tb_isp_csiir_stage4_align.sv` 报 `reg_edge_protect=zz`、`src_patch_5x5=Zzz`、`grad_h/grad_v=zzzz`
- 定位: `rtl/isp_csiir_top.v` 的 `u_stage4` 实例缺失 `src_patch_5x5 / grad_h / grad_v / reg_edge_protect` 连接
- 原因: 顶层 Stage4 集成未把必需 metadata 从上游域传到子模块
- 方案: 仅做 top-level 最小接线修复，不扩展到其它功能修改
- 验证: `iverilog -g2012 -f verification/iverilog_csiir.f -o verification/tb_stage4_align_red verification/tb/tb_isp_csiir_stage4_align.sv && vvp verification/tb_stage4_align_red`
- 状态: 进行中
