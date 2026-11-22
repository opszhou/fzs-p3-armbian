# legacy：L7–L10 时代资产索引（不再演进的引导链）

本目录只服务于**还在跑 L10 及更早引导的板子**。当前交付链是 2025.10 basic/plus/pro
+ extlinux，新板、新链与本目录无关，不要混用两套刷机步骤。

历史仓库 `zhouxiaochen/p3-image-builder`（Gitea，已归档只读）里的二进制没有复制过来：
大件留在归档仓库的 git 与 release 附件里，用 URL 取，避免在本仓库重复几十 MB。

## 1. L10 引导二进制

| 文件 | 大小 | sha256（前 12） | 写入位置 | 来源 |
|---|---|---|---|---|
| `u-boot-rockchip-L10-H.bin` | 9,402,880 | — | eMMC LBA `0x40` | release `l10`（U 盘引导 / U 盘救援） |
| `u-boot-rockchip-L10-G.bin` | 9,402,880 | — | eMMC LBA `0x40` | release `l10`（rockusb 刷机） |

release 地址：`http://192.168.0.110:3000/zhouxiaochen/p3-image-builder/releases/tag/l10`

> 归档仓库的 release 附件仍可下载；仓库只读，不能再推送。

## 2. 救砖 / 整盘套件（手册配套版）

原件在归档仓库 `handmade/files/`（git 内，46 MB），`SHA256SUMS.txt` 在旁：

| 文件 | 大小 | sha256 | 用途 |
|---|---|---|---|
| `01_gpt_bootarea_l10h.img` | 10,485,760 | `a6f24095e0ee4951…` | GPT + L10-H U-Boot + bootarea，`wl 0x0` 一次写 |
| `01_gpt_bootarea_l10g.img` | 10,485,760 | `2b219b4badbc7818…` | 同上，L10-G（rockusb） |
| `01_gpt_bootarea.img` | 9,437,696 | `7ff83efe65274c80…` | 早期 L9 版，仍有效，用于回 L9 链 |
| `04_backup_gpt.img` | 16,896 | `b9c6bda65c738176…` | 盘尾备份 GPT，配合任意主表写入 |
| `MiniLoaderAll_p3_l1.bin` | 481,728 | `8950ed56bec34191…` | MaskRom 救砖 Loader（仅载入 RAM，不写盘） |
| `p3boot` | 1,521 | `54b013837c51d977…` | 一次性启动目标切换脚本（L10 标志位 LBA 24576） |

`MiniLoaderAll_p3_l1.bin` 与本仓库 `bootloader/` 里那份 sha256 完全一致，不用取两份。

两个 L10-H 文件不要混用：release `l10` 的是 9,402,880 B，`handmade/files/` 的是
9,505,792 B（`b57890fed6e6ec4e…` / `14884f3124244906…`），是不同时间的两次构建，
按你手上手册写的 sha 选对应那份。

## 3. 手工刷机手册

`docs/legacy/handmade/` 是原手册正文（12 个 md，约 66 KB），描述 RKDevTool 界面操作、
MASKROM 救砖、双系统切换等 L9/L10 时代流程。手册里引用的 `files/` 指归档仓库的
`handmade/files/`，二进制不在本仓库。

## 4. 与当前链的边界

| | L7–L10（本目录） | 2025.10（当前） |
|---|---|---|
| 引导配置 | `bootcmd=boot_fit` 或 env 补丁 + `sysboot` | `extlinux.conf` + bootstd |
| 网页刷机 | webflash L10（FIT-only） | webflash + P3WFS1 / 整盘 img.xz |
| 刷写构件 | `01_gpt_bootarea*.img` + `boot_fit.img` + env 三件 | `bootarea-basic.img` / `gpt.img` + `u-boot-basic.bin` |
| 地址 | env 在 `0x48000` | 无 env 依赖 |

跨代混刷会把板子刷成半套（例如用 L10 的 env 配 2025.10 的 extlinux），
一旦跨代，按目标代的完整刷机组合重刷，不要只补一件。
