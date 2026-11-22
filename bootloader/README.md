# bootloader/ — MASKROM 救砖 Loader

这里只放一个东西：`MiniLoaderAll_p3_l1.bin`（481,728 B）。
它是**p3 专用**的（RK3566 + DDR4 时序），通用版 `rk356x-MiniLoaderAll.bin` 在这块板上
DDR 初始化必崩，会直接弹回 MASKROM。

## 什么时候用

板子完全进不了 LOADER（`upgrade_tool ld` 也认不到），只能走 MASKROM：

```bat
upgrade_tool.exe db MiniLoaderAll_p3_l1.bin   :: 仅载入 RAM（下载 Boot），不写盘
upgrade_tool.exe wl 0x0    gpt.img
upgrade_tool.exe wl 0x40   u-boot-basic.bin
```

要点：

- **DC 电源与 USB 线必须同时接**，只插 USB 供电不足，MASKROM 会反复掉线
- `db` 只是把 Loader 放进 RAM，不会写入 eMMC；真正的写入靠后面的 `wl`
- RKDevTool 里对应操作是「下载Boot」选中本文件，**随即取消 Loader 行的勾选**再按地址写
- 进了 LOADER 之后就不需要这个文件了，直接用 `wl` 写分区

## 和 U-Boot 的关系

本目录**不再存放 U-Boot 固件**。basic 档 U-Boot 由 [fzs-p3/uboot](http://192.168.0.110:3000/fzs-p3/uboot)
的 CI 产出，随发布包放在 [../firmware/](../firmware/)：`u-boot-basic.bin`（写入 `0x40`），
版本号在 `firmware/u-boot-basic.version`。
源码、档位划分与符号守卫都在那个仓库，这里只消费产物。

## 校验

```bat
certutil -hashfile MiniLoaderAll_p3_l1.bin SHA256
```

与本目录 `SHA256SUMS.txt` 一致再用。
