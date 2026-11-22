# 08 · 刷 EmuELEC 游戏系统

> 适用：想把盒子变成复古游戏机（EmulationStation + RetroArch）。
> 耗时：**2~3 分钟**（系统内流式刷入）或 5 分钟（短接 + 工具）。

---

## 一、这个镜像是什么

| 项 | 值 |
|---|---|
| 名称 | EmuELEC X96X6 aarch64 4.8-Nexus |
| 原始文件 | `EmuELEC-X96X6.aarch64-4.8-Nexus_devel_20260219175841.img` |
| 大小 | 2,197,815,296 B（2.05 GB） |
| 内核 | 4.19（EE 自带，非本工程内核） |
| dtb | `rk3566-x96-x6.dtb`（X96 X6 的，但基于同一参考设计，能跑） |

### 镜像在哪

| 位置 | 说明 |
|---|---|
| `emuelec/ee.img` | 已解压，2.05 GB，直接用 |
| `emuelec/ee.img.gz` | 压缩版，1.1 GB |
| `E:\BaiduNetdiskDownload\RK3566\EmuELEC-X96X6...rar` | 原始压缩包 |

### 镜像分区布局

| 分区 | 起始 LBA | 大小 | 文件系统 | 标签 / UUID |
|---|---|---|---|---|
| p1 | `0x8000`（16 MB） | 2048 MB | FAT32 | `EMUELEC` / `1902-0034` |
| p2 | `0x408000`（2064 MB） | 32 MB | ext4 | `STORAGE` / `576ce41a-c083-4b9b-88de-0b8dd7de4061` |

p1 里有：`KERNEL`(23MB)、`SYSTEM`(1.14GB squashfs)、`rk3566-x96-x6.dtb`、`extlinux.conf`、`config.ini`
p2 是 `/storage` 的种子分区，首次启动后会被扩展。

---

## 二、刷法 A：系统内流式刷入（推荐）

**前提**：Armbian 正跑着（U 盘或 eMMC 都行），eMMC 未被挂载。

### 原理

```
电脑读 ee.img（跳过前 16MB）
   ↓ SSH 流式传输（不在板子上落盘，避开 U 盘 7MB/s 的写瓶颈）
板子 dd 直接写 /dev/mmcblk0 seek=16
```

**为什么跳过 16MB**：前 16MB 是 MBR + L10 引导固件，跳过就**天然保留引导**，刷完不用重刷。

### 操作

```powershell
cd C:\Users\Administrator\WorkBuddy\rockchip\emuelec
python stream_flash.py
```

实测：**2080 MB / 83 秒 / 25 MB/s**。

脚本里的关键参数：

```python
SKIP  = 16 * 1024 * 1024             # 保留前 16MB
IMG   = 'ee.img'
cmd = f'dd of=/dev/mmcblk0 bs=1M seek={SKIP // 1048576} conv=fsync status=progress'
```

### 验证

```bash
# 在板子上
sudo dd if=/dev/mmcblk0 bs=512 skip=64 count=18365 status=none | sha256sum
# 引导应该还是 c5e17bfb...（H 模式）

sudo mkdir -p /mnt/ee && sudo mount -o ro /dev/mmcblk0p1 /mnt/ee
md5sum /mnt/ee/SYSTEM
# 必须是 c49f58cee3905a2e1762adc912c05fe6

sudo blkid /dev/mmcblk0p2
# 必须显示 TYPE="ext4" LABEL="STORAGE"
```

---

## 三、刷法 B：MASKROM + upgrade_tool

**前提**：能进 MASKROM（短接）或 LOADER（G 模式按 `r`）。

### 分片

```
emuelec\chunks16\
├── ee_d1.img   256 MB   LBA 0x8000
├── ee_d2.img   256 MB   LBA 0x88000
├── ...
└── ee_d9.img    32 MB   LBA 0x408000
```

> `chunks16` 是从 `ee.img` 偏移 16MB 处切的，**保留引导**。
> 旧的 `chunks/` 是从 0x0 切的，会覆盖引导，别用。

### 操作

```powershell
upgrade_tool ld
upgrade_tool db files\MiniLoaderAll_p3_l1.bin
cd C:\Users\Administrator\WorkBuddy\rockchip\emuelec
flash_emuelec_keepbl.bat
```

脚本逐片写入，每步检查，失败即停。

---

## 四、必做：加 `video` 参数（否则黑屏）

EE 的 `extlinux.conf` 默认没有显示参数，本板 **EDID 读不到**，结果是黑屏但系统在跑。

必须加：

```
video=HDMI-A-1:1920x1080@60e
```

> 结尾的 `e` 表示**强制启用**，忽略 EDID 协商。

### 改两个文件（都要改）

```bash
sudo mount -o rw /dev/mmcblk0p1 /mnt/ee

# 1) extlinux.conf：在 APPEND 行末尾追加
sudo sed -i 's|pci=nomsi|pci=nomsi video=HDMI-A-1:1920x1080@60e|' /mnt/ee/extlinux/extlinux.conf

# 2) config.ini：改 extra_cmds
sudo sed -i 's|^extra_cmds=.*|extra_cmds="quiet console=ttyFIQ0,1500000 console=tty0 ssh pci=nomsi video=HDMI-A-1:1920x1080@60e"|' /mnt/ee/config.ini

sudo sync && sudo umount /mnt/ee
```

### 改完的样子

```
APPEND boot=UUID=1902-0034 disk=UUID=576ce41a-... quiet quiet console=ttyFIQ0,1500000 console=tty0 ssh pci=nomsi video=HDMI-A-1:1920x1080@60e
```

---

## 五、启动 EE

```bash
p3boot emmc --reboot
```

会跳过 U 盘，直接从 eMMC 启动 EE。

也可以开机按住 ADC 键进菜单选 `Armbian (eMMC)`（同一分区，U-Boot 扫到的是 EE 的 extlinux）。

### 首次启动

- 屏幕会先显示 EmuELEC logo，然后进 EmulationStation
- **首次启动 1~2 分钟**：扩展 `/storage` 到剩余空间（约 12.7 GB）
- 之后可以在设置里导入 ROM

### 回 Armbian

```bash
# 在 EE 里没法执行 p3boot，所以：
# 断电重启 → 如果 U 盘插着，默认回 Armbian（boot_targets 里 usb 优先）
```

或者插着 U 盘启动，`boot_targets='usb mmc1 mmc0'` 会优先走 U 盘。

---

## 六、踩过的坑（都验证过）

### 坑 1：`SYSTEM.md5` / `KERNEL.md5` 被破坏

**症状**：串口显示 `Could not mount /flash/SYSTEM`

**原因**：`SYSTEM.md5` 应该是 48 字节的文本（`c49f58ce...  target/SYSTEM`），
如果被写成二进制（比如 48 字节 ARM64 机器码），`md5sum -c` 解析失败 → EE 拒绝挂载。

**判断**：

```bash
od -An -c /mnt/ee/SYSTEM.md5 | head -2
# 正常：c 4 9 f 5 8 c e ...   t a r g e t / S Y S T E M
# 异常：乱七八糟的二进制
```

**解决**：重刷（别手改——如果 SYSTEM 内容也变了，改 md5 只是让它"看起来通过"）。

### 坑 2：p2 分区不是 ext4

**症状**：`/storage` 挂不上，EE 卡在启动或无限重启

**判断**：

```bash
blkid /dev/mmcblk0p2
# 正常：TYPE="ext4" LABEL="STORAGE" UUID="576ce41a-..."
# 异常：只有 PARTUUID，没有 TYPE
```

**解决**：重刷 p2（`wl 0x408000 ee_d9.img`）。如果数据不重要，也可以：

```bash
sudo mkfs.ext4 -L STORAGE -U 576ce41a-c083-4b9b-88de-0b8dd7de4061 /dev/mmcblk0p2
```

⚠️ UUID 必须指定为 `576ce41a-...`，否则 extlinux 的 `disk=UUID=` 找不到。

### 坑 3：黑屏但系统在跑

**原因**：缺 `video=` 参数（见第四节）。

**验证系统活着**：串口有内核日志、网口灯亮、SSH 能尝试连接。

### 坑 4：用补丁扇区改 extlinux 会毁数据

**症状**：改完分辨率后，SYSTEM 挂载失败

**原因**：如果往 FAT 分区写"补丁扇区"，而那个扇区恰好落在 SYSTEM 占用的簇上，
会把 SYSTEM 内容覆盖（我们用 `s_25f330.bin` 之类就踩过这个坑）。

**正确做法**：**挂载文件系统改文件**（第三节/第四节的方法），不要写裸扇区。

---

## 七、和本工程其他系统的关系

| | Armbian | EmuELEC |
|---|---|---|
| 内核 | 6.12.69（主线） | 4.19（EE 自带） |
| 引导 | L10 的 extlinux | 同一套 L10 的 extlinux |
| 分区 | p1 boot + p2 rootfs | p1 FAT + p2 STORAGE |
| 用途 | 通用 Linux | 复古游戏 |

**两者不能共存于同一分区表**——它们各自定义自己的 p1/p2。

所以「双系统」的正确组合是：

```
eMMC  = EmuELEC（游戏机，240 MB/s 加载快）
U 盘  = Armbian（Linux，通用用途）
```

切换靠 `p3boot` 或开机菜单。

---

## 八、速查

```bash
# 刷（系统内）
python stream_flash.py

# 验证
sudo dd if=/dev/mmcblk0 bs=512 skip=64 count=18365 status=none | sha256sum   # c5e17bfb...
sudo mount -o ro /dev/mmcblk0p1 /mnt/ee && md5sum /mnt/ee/SYSTEM            # c49f58ce...
sudo blkid /dev/mmcblk0p2                                                   # ext4 STORAGE

# 补 video
sudo mount -o rw /dev/mmcblk0p1 /mnt/ee
sudo sed -i 's|pci=nomsi|pci=nomsi video=HDMI-A-1:1920x1080@60e|' /mnt/ee/extlinux/extlinux.conf
sudo sync && sudo umount /mnt/ee

# 启动
p3boot emmc --reboot
```

### 关键校验值

| 项 | 值 |
|---|---|
| SYSTEM md5 | `c49f58cee3905a2e1762adc912c05fe6` |
| KERNEL md5 | `16572d9164c1c066977530516910bf92` |
| p2 UUID | `576ce41a-c083-4b9b-88de-0b8dd7de4061` |
| p1 UUID | `1902-0034` |
