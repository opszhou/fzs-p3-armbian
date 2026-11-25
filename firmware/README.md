# firmware/ — 发布件源（小件入 git，大件走 Release）

这里放**构成发布包的源文件**。`02_boot.img` / `03_rootfs.img` / 整盘 img 体积大，不入 git，
由 CI 按 `firmware_<内核>_<时间>` 发布；git 里只保留下面这些小件。

| 文件 | 大小 | 写入地址 | 用途 |
|---|---|---|---|
| `gpt.img` | 32 KiB | `0x0`（LBA 0） | 保护 MBR + 主 GPT（头 + 分区项），不含固件 |
| `u-boot.bin` | 9.2 MiB | `0x40`（LBA 64） | U-Boot（eMMC 引导 + 网页刷机），版本见 `u-boot.version` |
| `04_backup_gpt.img` | 16,896 B | 盘尾（`0x01D1EFDF`） | 备份 GPT，可选；主 GPT 有效时不会被读 |
| `u-boot.version` | — | — | 发布版号，CI 会与二进制内嵌版本双向校验 |
| `SHA256SUMS.txt` | — | — | 上面三个镜像的 sha256；同时是 CI 的引导件门禁 |

GPT 与固件分离的好处：换 U-Boot 不碰分区表，改分区表不碰 U-Boot。
MASKROM 救砖 Loader 在 [../bootloader/](../bootloader/)。

## 三条刷写路径

### 1. 网页刷机（推荐，无需装任何 PC 工具）

板子进入救援页（上电窗口按 `r`，或 U-Boot 下 `recovery`）→ 上传 `.fit` 或整盘镜像 →
板上自行解析分区、分段写盘、回读校验 → `FLASH_OK` 后重启。

写入范围固定为 boot（LBA 32768）与 rootfs（LBA 819200），引导区不参与，因此
**换系统不会把 U-Boot 刷坏**。

### 2. 整盘镜像（Rufus / Etcher / dd）

`p3_armbian_full-<内核>.img.xz` 可直接写盘（Rufus、Etcher、`dd` 都认 xz）。
2.4.0 起档位已合并为运行时闸门，单一 `u-boot.bin` 即含完整功能；
2.2.0 及以前的旧版中 basic 档没有 USB host 栈，从 U 盘引导需要 plus / pro 档。

### 3. 分件写入（RKDevTool / upgrade_tool，产线与救砖）

| 行 | 地址 | 文件 |
|---|---|---|
| 1 | `0x00000000` | `gpt.img` |
| 2 | `0x00004000` | `u-boot.bin` |
| 3 | `0x00008000` | `02_boot.img` |
| 4 | `0x000C8000` | `03_rootfs.img` |

```bat
upgrade_tool.exe wl 0x0      gpt.img
upgrade_tool.exe wl 0x40     u-boot.bin
upgrade_tool.exe wl 0x8000   02_boot.img
upgrade_tool.exe wl 0xC8000  03_rootfs.img
```

RKDevTool 里勾「强制按地址写」，Loader 行不要勾（已在刷机模式的板子不需要重下 Loader）。
只想换引导时只写前两行；只想换系统时只写后两行。

## 写后校验（必须做）

`wl` 报 100% 不等于写进去了。读回比对，一致才断电：

```bat
upgrade_tool.exe rl 0      64     rb_gpt_uboot.bin
upgrade_tool.exe rl 32768  786432 rb_boot.bin
certutil -hashfile rb_gpt_uboot.bin SHA256
certutil -hashfile rb_boot.bin     SHA256
```

与 `SHA256SUMS.txt` 对应行一致才上电；不一致就留在刷机模式重写。

## 铁律

- 写入过程不能断电；写完后断电 ≥10 s 再上电（不是 reset）
- 写物理盘前核对盘号与容量（16 GB eMMC ≈ 15,634,268,160 B）；Windows 弹格式化一律拒绝
- 校验不一致不带病启动
