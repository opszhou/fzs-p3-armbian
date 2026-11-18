# p3-armbian — 蜂助手 P3 (RK3566) 固件与内核流水线

**设备**：蜂助手 P3（RK3566 / 2GB DDR4 / 16GB eMMC）
**当前系统**：Armbian 26.11 noble，内核 `6.12.81-ophub`（真机验证：显示 / HDMI 音频 / CEC / 千兆网络 / MPP 硬解）

本仓库从 ophub/amlogic-s9xxx-armbian fork 而来，按 P3 的需求裁剪：只保留内核构建框架
（`compile-kernel/`）和 GPL 许可，ophub 的镜像构建、rebuild 工具链、文档均已移除。
固件的内核注入与打包由仓库自己的流水线完成。

## 目录

| 目录 | 内容 |
|---|---|
| `.github/workflows/` | 流水线（见下） |
| `firmware/` | 刷机包：01 引导二选一、p3boot、刷机命令、校验清单 |
| `bootloader/` | 引导固件：L9（U-Boot 2025.10）/ L10 双模式 + MiniLoader |
| `kernel-config/` | 内核配置模板（rk35xx，关闭 psci_checker） |
| `kernel-patches/` | 三个内核补丁（见下） |
| `scripts/` | bootloader 与固件构建脚本（L4~L9 阶段补丁、FIT 组装、dtb delay 修补） |
| `board/` | 板卡数据库（P3-WXY4 条目） |
| `compile-kernel/` | 内核 CI 构建框架（docker 工具链） |
| `LICENSE` | GPL |

## 流水线

```
编译内核 (Build Kernel)    rockchip 树 + kernel-config + 三补丁 → kernel_stable Release
                           → 成功后自动派发构建固件
构建固件 (Build Firmware)  kernel_stable 内核包注入基座（02/03）→ firmware 布局重组
                           → 01/02/03/slim + SHA256SUMS → firmware_YYYY.MM Release
清理历史 (Cleanup)
```

- **内核出包**：Actions → 编译内核 → Run（默认 `unifreq/linux-6.12.y-rockchip@main`）
- **固件出包**：Actions → 构建固件 → Run（内核版本默认取 kernel_stable 最新；基座默认 `flashkit_l10`）
- 内核变更 → 编译内核 → 自动触发构建固件，出固件全程不需要本地打包

## firmware — 刷机包

| 文件 | 写入地址 |
|---|---|
| `01_gpt_bootarea_l10h.img` / `_l10g.img`（二选一） | `0x00000000` |
| `02_boot.img` | `0x00008000` |
| `03_rootfs.img` | `0x000C8000` |
| `p3_armbian_slim.img.gz` | Etcher 写 U 盘 |
| `p3boot` | U 盘 / eMMC 启动切换 |

刷写流程与校验见 [firmware/README.md](firmware/README.md)。
（手把手的完整教程在用户侧仓库，含 G/H 模式判断、串口排错。）

## 内核补丁（kernel-patches/common-kernel-patches/）

1. **0001 板级 dts**：启用 HDMI / display-subsystem / i2s0_8ch，gmac1 魔数 0x22/0x15 出厂即对
2. **0002 dwmac-rk-tool**：`phy_lb_scan` 扫描后运行时应用最优 delayline（无需重启）
3. **0003 开机自检**：回环测试 dtb delayline，失败自动 cross-scan 自愈（不依赖外部网络）

## 板卡数据库（board/model_database.conf）

P3-WXY4 条目：`KERNEL_TAGS = stable/6.12.y_6.18.y`、`BOARDFAMILY = rk3566`、extlinux 引导。
