# P3 webflash 通用刷机（P3WFS1 规范）

板上刷过我们的 U-Boot（basic / pro / 任意版本）后，**任何人**都可以把自己的
系统镜像打包成 FIT，通过网页刷入。引导区永远不会被写入。

## 格式定义：P3WFS1

```
偏移 0        4KB 明文头部（首行 magic，随后 KEY=VALUE 行，其余补 0）
偏移 4096     xz 压缩的数据流（内容 = 从 WRITE_LBA 起的原始镜像内容）
```

头部字段：

| 字段 | 含义 |
|---|---|
| `P3WFS1`（第一行） | 格式 magic |
| `IMAGE_SECTORS` | 解压后内容的扇区数（512B/扇区） |
| `WRITE_LBA` | 写盘起始 LBA，**必须 ≥ 32768** |
| `IMAGE_SHA256` | 解压后内容的 sha256 |
| `CREATED` | 打包时间（可选元数据） |

## 第三方打包三步

```sh
# 0) 准备：你的分区镜像 system.img（raw、512 对齐、内容从 LBA32768 对应处开始）
#    即：不含 GPT/引导区，第一个字节对应板上 LBA32768

# 1) 打包
tools/mkwebflash.sh system.img           # -> system.wfs

# 2) 自检（模拟板上所有强制校验 + 全量内容 sha 验证）
tools/p3wfs-check.sh system.wfs          # OK 才能刷；FAIL 会给出具体原因

# 3) 出 FIT（kernel/dtb/busybox 用我们 release 的 fit_base 组件）
tools/mkfit.sh system.wfs Image board.dtb busybox-arm64 p3-installer-my.fit
```

## 怎么判断"我的镜像能不能刷"

`p3wfs-check.sh` 就是判据，它执行与板上 installer 完全相同的强制校验：

1. magic / 头部字段齐全、数值合法
2. 文件大小 = 4096 + IMAGE_SECTORS×512（声明与文件自洽）
3. **WRITE_LBA ≥ 32768**——想覆盖 GPT/U-Boot 引导区的包直接拒绝
4. WRITE_LBA + IMAGE_SECTORS ≤ 板子 eMMC 总扇区（默认 3125281）
5. 全量解压后 sha256 与 IMAGE_SHA256 一致

任何一条不过 → 刷机前就拦下；即便绕过 check，板上 installer 也会再次强制
执行 3/4 两条，并在写盘后回读比对 sha，任何不一致都会停在 shell（fail-safe，
不会带病重启）。

## 安全边界（installer 强制，不信任镜像）

- 写盘起点 < LBA32768 → 拒绝（保护 GPT + U-Boot bootarea）
- 镜像越过盘尾 → 拒绝
- 写完必须回读逐扇区校验通过才 `FLASH_OK` + 重启；否则停留在 busybox shell

## 我们的 CI 怎么用

`build-firmware-p3.yml` 的 FIT 构建走同一条链：注入内核后的
`data.img → mkwebflash.sh → p3wfs-check.sh → mkfit.sh`。CI 自己的镜像没有
任何特权，和第三方镜像走完全相同的校验路径。

---

# 首启一次性配置（密码 / shell / UUID）

| 文件 | 作用 |
|---|---|
| `p3-firstboot.sh` | 运行在盒子上的脚本：设 root 密码与 bash、删首登向导、换 rootfs 与 `/boot` 的 UUID 并同步 `extlinux.conf` / `armbianEnv.txt` / `fstab`，然后重启一次 |
| `p3-firstboot.service` | oneshot 包装，`WantedBy=multi-user.target`，以 `/etc/p3-firstboot.done` 为条件 |
| `p3-firstboot-inject.sh` | 构建期注入器：把上面两个文件写进 ext4 根分区并 enable，同时打开 `metadata_csum_seed` |

```sh
tools/p3-firstboot-inject.sh rootfs.img          # 装脚本 + 建 unit + enable + 开特性
tools/p3-firstboot-inject.sh --seed-only fs.img  # 只开特性（给 boot 分区用）
```

注入器用 `debugfs` 而非 loop 挂载：CI runner、笔记本、容器里行为一致，不需要 root，也不依赖 `/dev/loop`。
每一步都回读校验（脚本内容逐字节 `cmp`、符号链接类型、脚本权限 0755），任何一步没落地都会 `FATAL` 退出，
不会让一个“什么都没装”的镜像发布出去。

## 为什么必须换 UUID

CI 镜像是整盘逐字节复制。用它 dd 出来的 U 盘，rootfs UUID 与源 eMMC 完全相同，
内核按探测顺序解析 `root=UUID=` → 会抡到 eMMC，现象就是“选了 U 盘启动却起了 eMMC”。
首启把本机 UUID 改成随机值后，以后用同一镜像做的盘都不可能再撞。

## 硬前提：`metadata_csum_seed`

未开启这个特性的 ext4 在**挂载状态下**拒绝改 UUID（`tune2fs` 会报
“The UUID may only be changed when the filesystem is unmounted”）。注入器用
`tune2fs -O metadata_csum_seed` 在未挂载时打开它，之后首启才能在线改。
特性缺失时脚本**不改任何东西**，只写完成标记退出，系统仍可正常启动。
