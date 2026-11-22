# fzs-p3-armbian — 蜂助手 P3（RK3566）固件与内核流水线

**设备**：蜂助手 P3 / Onething WXY4 V10（RK3566 / 2 GB DDR4 / 16 GB eMMC / 千兆网 / HDMI）
**当前系统**：Armbian 26.11 noble，内核 `6.12.81-ophub`（真机验证：显示 / HDMI 音频 / CEC / 千兆网络 / MPP 硬解）
**当前引导**：basic 档 U-Boot 2025.10，由 [fzs-p3/uboot](http://192.168.0.110:3000/fzs-p3/uboot) CI 产出，版本钉在 [`firmware/u-boot-basic.version`](firmware/u-boot-basic.version)

本仓库只做两件事：**出内核**、**出固件包**。U-Boot 源码不在这里（在 `fzs-p3/uboot`），
也没必要把两份源码同时维护。从 ophub/amlogic-s9xxx-armbian fork 而来，只保留了内核构建框架。

## 目录

| 目录 | 内容 |
|---|---|
| `.github/workflows/` | 两条流水线（内核 / 固件）与历史清理 |
| `firmware/` | 发布件源：GPT、basic U-Boot、盘尾备份 GPT、校验清单 |
| `bootloader/` | 只有 MASKROM 救砖用的 MiniLoader（其余引导件归 `fzs-p3/uboot`） |
| `tools/` | 打包 / 自检 / 首启注入（P3WFS1 与首启一次性配置） |
| `kernel-config/` | 内核配置模板（rk35xx，关闭 psci_checker） |
| `kernel-patches/` | 三个内核补丁（板级 dts / dwmac delayline / 开机自检） |
| `board/` | 板卡数据库（P3-WXY4 条目） |
| `compile-kernel/` | 内核 CI 构建框架（docker 工具链） |
| `docs/legacy/` | L7–L10 时代引导链、救砖件与手工手册（归档只读，当前链不用） |

## 流水线

```
编译内核 (Compile kernel)   rockchip 树 + kernel-config + 三补丁 → kernel_stable Release
                            → 成功后自动派发构建固件
构建固件 (Build firmware)   kernel_stable 内核包注入基座（02/03）→ 首启配置注入 → 打包
                            → FIT / 整盘 img.xz / 分件 + SHA256SUMS → firmware_<内核>_<时间> Release
```

- **出内核**：Actions → 编译内核 → Run（默认 `unifreq/linux-6.12.y-rockchip@main`）
- **出固件**：Actions → 构建固件 → Run（内核默认取 `kernel_stable` 最新；基座留空 = 自动取最新一个带 02/03 的 Release）
- 两者都不需要本地打包，真机交付一律取自 Release。

## 固件产物与刷写路径

| 形态 | 文件 | 怎么用 |
|---|---|---|
| **网页刷机（推荐）** | `p3-installer-<内核>.fit` | 打开板子网页 → 上传 → 自动校验写盘 → 重启 |
| **整盘镜像** | `p3_armbian_full-<内核>.img.xz` | Rufus / Etcher 直写；或 `unxz` 后 `dd` |
| **分件（RKDevTool / upgrade_tool）** | `gpt.img` + `u-boot-basic.bin` + `02_boot.img` + `03_rootfs.img` | 按地址逐件写，适合产线与救砖 |

所有路径都只写两个固定分区：boot（LBA 32768 起）与 rootfs（LBA 819200 起），
**LBA0-32767 的引导区与盘尾备份 GPT 永不写入**，因此换系统不会损坏板上 U-Boot。
详细步骤见 [firmware/README.md](firmware/README.md)。

> 🔴 从 **U 盘**引导需要 plus / pro 档 U-Boot：basic 档没有 USB host 栈，
> `boot_targets` 只有 `mmc1 mmc0`（eMMC 引导 + 网页刷机就是这个档位的全部职责）。
> 把整盘 img 写到 U 盘、再从 U 盘起系统，请配套 plus 档引导。

## 首启行为（不需要键鼠 / 串口）

镜像里带一个一次性服务 `p3-firstboot.service`，首次开机自动完成：

1. `root` 密码设为 `password`，root shell 设为 bash，删掉 Armbian 首登向导（`/root/.not_logged_in_yet`）
2. 把本机的 rootfs 与 `/boot` 换成随机 UUID，同步 `extlinux.conf`、`armbianEnv.txt`、`/etc/fstab`，然后**自动重启一次**（约 10 秒）

第 2 步是必须的：CI 镜像整盘逐字节复制，用它 dd 出来的 U 盘与 eMMC 共用同一组
`root=UUID=`，内核按探测顺序选设备 → “选 U 盘启动却起了 eMMC”。每台机器首启就把 UUID
换成本机独有，以后用同一镜像做的任何盘都不会再撞。实现与自检见
[`tools/p3-firstboot-inject.sh`](tools/p3-firstboot-inject.sh)、[`tools/p3-firstboot.sh`](tools/p3-firstboot.sh)。

首次开机日志：`/root/p3-firstboot.log`；完成后标记：`/etc/p3-firstboot.done`（在就永不再跑，
包括失败路径——宁可少换 UUID，也不会把板子重启成循环）。

## 引导切换（U-Boot 内置，不在系统侧）

U-Boot 提供一次性启动目标开关：`p3boot usb|emmc|net|clear|status`，网页刷机页也有对应面板。
标志位在 LBA 24576，不在任何分区内；只影响下一次启动，消费后自动恢复默认。
系统侧不再需要任何脚本（旧 `p3boot` 脚本已退役）。

## 内核补丁（`kernel-patches/common-kernel-patches/`）

1. **0001 板级 dts**：启用 HDMI / display-subsystem / i2s0_8ch，gmac1 delayline 出厂值即对
2. **0002 dwmac-rk-tool**：`phy_lb_scan` 扫描后运行时应用最优 delayline（无需重启）
3. **0003 开机自检**：回环测试 dtb delayline，失败自动 cross-scan 自愈（不依赖外部网络）

## 板卡数据库（`board/model_database.conf`）

P3-WXY4 条目：`KERNEL_TAGS = stable/6.12.y_6.18.y`、`BOARDFAMILY = rk3566`、extlinux 引导。
