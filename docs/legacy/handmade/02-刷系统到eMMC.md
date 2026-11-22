# 02 · 刷一个完整系统到 eMMC

> 适用：盒子是空的 / 系统坏了要重装 / 想把这台机器变成一台干净的 Linux 主机。
> 耗时：约 30 分钟（其中写入 3~5 分钟）。

## ⚡ 一条龙最简步骤（先看这里，其余是详解）

短接进 MASKROM 后，在 Windows 上按顺序敲：

```powershell
upgrade_tool ld                                   # 确认识别到 Maskrom
upgrade_tool db files\MiniLoaderAll_p3_l1.bin     # 加载 loader
upgrade_tool wl 0x0     files\01_gpt_bootarea_l10h.img   # 分区表 + L10-H 引导（日常用）
upgrade_tool wl 0x8000  files\02_boot.img                # boot 分区
upgrade_tool wl 0xC8000 files\03_rootfs.img              # rootfs（3~5 分钟）
```

- 想以后用 RKDevTool 刷机/救砖？把第一行 `01_..._l10h.img` 换成 `01_gpt_bootarea_l10g.img`（L10-G 引导），其余不变。
- **`01_..._<模式>.img` 已内含对应引导，不用再单独刷引导**，也不用再执行 03 里的步骤。
- 写完**断电 10 秒**再上电（原因见文末铁律）。首次启动 2~3 分钟，别断电。

> 引导模式二选一：**H** = 日常/U 盘启动可用；**G** = rockusb 刷机可用、但 U 盘启动失效。选错可在系统里按 [03](03-只更新引导.md) 重刷引导（不动系统）。

## 开始前确认

| 项 | 要求 |
|---|---|
| 盒子状态 | 无所谓，砖机也能刷（走 MASKROM） |
| 需要文件 | `01_gpt_bootarea_l10h.img`（或 `..._l10g.img`）、`02_boot.img`、`03_rootfs.img` |
| 会清空 | **eMMC 上的所有内容**（Android / 旧系统 / 数据全没） |

⚠️ **U 盘不会被碰**，只动 eMMC。

## 一、文件准备

三个镜像加起来约 3.55 GB。如果拿到的是离线包，解压后应该在同一个目录。

确认文件大小（**大小不对说明下载/解压不完整**）：

| 文件 | 精确字节数 |
|---|---|
| `01_gpt_bootarea_l10h.img` / `01_gpt_bootarea_l10g.img`（二选一） | 9,437,696 |
| `02_boot.img` | 402,653,184 |
| `03_rootfs.img` | 3,144,679,424 |

```powershell
# PowerShell 看大小
Get-ChildItem *.img | Select-Object Name, Length
```

## 二、让盒子进 MASKROM

详见 [04-救砖-MASKROM.md](04-救砖-MASKROM.md)，简述：

1. 盒子**断电**（拔电源）
2. 用镊子短接主板背面 eMMC 附近的两个圆点（CLK + GND）
3. **保持短接**的同时插 USB 到电脑、上电
4. 1~2 秒后松开镊子
5. 电脑识别为 MASKROM

```powershell
upgrade_tool ld
# 期望：... Maskrom
```

## 三、先加载 loader

MASKROM 里只有 BootROM，能力最小，写盘前必须先把 loader 塞进去：

```powershell
upgrade_tool db files\MiniLoaderAll_p3_l1.bin
```

| 输出 | 含义 |
|---|---|
| `Download Boot Succeed` | ✅ 成功，设备变成 LOADER |
| `Open loader failed` | ❌ 文件路径错（检查路径和文件名） |
| `Download Boot Fail` | ❌ USB 通信问题（换口/换线） |

## 四、写三个镜像（严格按顺序）

```powershell
# ① 分区表 + 引导区（9 MB，几秒）—— 按模式二选一，镜像已内含对应引导
upgrade_tool wl 0x0      files\01_gpt_bootarea_l10h.img   # 日常/U盘启动（默认选这个）
# upgrade_tool wl 0x0    files\01_gpt_bootarea_l10g.img   # 刷机/rockusb 用

# ② boot 分区（384 MB，约 20 秒）
upgrade_tool wl 0x8000   files\02_boot.img

# ③ rootfs 系统本体（2.93 GB，3~5 分钟）
upgrade_tool wl 0xC8000  files\03_rootfs.img
```

> 第①步的 `01_..._l10h.img` / `01_..._l10g.img` 内嵌了对应模式的 L10 引导；
> 写完这步引导就已就位，**不用再单独刷引导**。旧的 `01_gpt_bootarea.img`（内嵌旧引导）仅保留兼容，新刷机别用。

### 参数含义

| 参数 | 含义 |
|---|---|
| `wl` | write LBA —— 按扇区写 |
| `0x0` / `0x8000` / `0xC8000` | 起始扇区号（十六进制） |
| 文件名 | 要写的镜像 |

### 关于速度

USB 2.0 下大约 **20~25 MB/s**，3.55 GB 总共约 3~5 分钟。

| 现象 | 正常吗 |
|---|---|
| 进度条卡在某个百分比不动几秒 | ✅ 正常（大块擦写） |
| 整体超过 15 分钟 | ❌ 可能通信异常，考虑换 USB 口/线 |
| 报错中断 | ❌ 停下来看 [06-故障排查.md](06-故障排查.md) |

⚠️ **写入过程中绝对不能断电**。断了 eMMC 会处于半写状态，只能重新短接重刷。

## 五、校验（别跳过）

读回来比对校验值，确认真的写进去了：

```powershell
upgrade_tool rl 0x0     0x47C1 readback_01.bin
upgrade_tool rl 0x8000  0x48000 readback_02.bin
```

> `rl` = read LBA，参数是「起始扇区 扇区数 输出文件」。
> `0x47C1` = 18432 扇区（9,437,696 / 512），`0x48000` = 294,912 扇区（402,653,184 / 512）

比对哈希：

```powershell
# Git Bash / WSL —— 01 用你实际刷的那份（这里以 l10h 为例）
sha256sum readback_01.bin files/01_gpt_bootarea_l10h.img
sha256sum readback_02.bin files/02_boot.img
```

两行各自的哈希必须**完全相同**（对应值见 `files/SHA256SUMS.txt`）。

> `03_rootfs.img` 有 2.93 GB，读回校验要 3 分钟。如果时间紧可以跳过，但**建议第一次做的时候校验**，确认线材和盘都没问题。

## 六、断电重启

```powershell
# 没有"退出"命令，直接断电
```

**断电 10 秒**（让 eMMC 缓存落盘、电源彻底放电），然后上电。

## 七、首次启动

### 串口会看到

```
U-Boot 2025.10-dirty (...)
Model: Onething P3 RK3566 BOX
SoC:   RK3566
DRAM:  2 GiB
...
+-------+----------+---------+-------+
| MODE  | USB-boot | rockusb | UMS   |
+-------+----------+---------+-------+
| L10-H |   YES    |   no    |  no   |  <== active
| L10-G |    no    |   YES   |  YES  |
+-------+----------+---------+-------+
...
Scanning bootdev 'mmc@fe310000.bootdev':
1  extlinux  ready  mmc  1  ... /extlinux/extlinux.conf
** Booting bootflow ... with extlinux
1:      Armbian
Starting kernel ...
```

### 首次启动要等

**2~3 分钟**，因为要做：

- 扩展分区到整盘
- 生成 SSH 主机密钥
- 初始化 systemd 服务

这期间 HDMI 可能是黑屏或停在某个界面，**正常，别断电**。

### 登录

| 项 | 值 |
|---|---|
| 默认用户 | `root` |
| 默认密码 | `1234` |
| 首次登录 | **强制改密码**，改完才能用 |

通过串口或 HDMI 都能登录。网络起来后可以用 SSH：

```powershell
ssh root@<盒子IP>
```

## 八、装完检查

```bash
# 1) 系统信息
uname -a
cat /etc/armbian-release 2>/dev/null | head -5

# 2) 存储布局
lsblk

# 3) 引导固件版本（确认是我们要的）
sudo dd if=/dev/mmcblk0 bs=512 skip=64 count=18365 status=none | sha256sum
```

第三行的输出应等于 `files/SHA256SUMS.txt` 里 `u-boot-L10-H.bin` 那一行的值。

## 常见分支

| 情况 | 下一步 |
|---|---|
| 想改成 G 模式（以后刷机不用短接） | [03-只更新引导.md](03-只更新引导.md) |
| 想加一个 U 盘系统做双系统 | [05-双系统与切换.md](05-双系统与切换.md) |
| 起不来 / 卡住 / 黑屏 | [06-故障排查.md](06-故障排查.md) |
