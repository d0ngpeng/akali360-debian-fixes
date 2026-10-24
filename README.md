# akali360-debian-fixes

针对 **Google Akali360（Acer Spin 13）** 刷 [MrChromebox](https://mrchromebox.tech/) coreboot
固件后安装 **Debian** 的一系列驱动与行为修复。

> 机器特征：`/sys/class/dmi/id/product_name` = `Akali360`
> 固件：coreboot / MrChromebox UEFI　·　SoC：Intel Sunrise Point-LP（i5-8350U）
> 已在 Debian 13 (trixie) + 内核 `7.2.6+deb13-amd64` + KDE Plasma 6 (Wayland) 上验证

---

## 为什么需要这些修复

Chromebook 原本运行 ChromeOS，其音频、电源管理大量依赖 Google 自有的 EC / 固件接口。
刷成 coreboot UEFI + 装标准 Debian 内核后，**上游内核配置默认关闭了这台机器所需的若干驱动**，
且 coreboot 的部分 ACPI 实现有缺陷。结果是：系统能启动，但若干关键功能不正常。

本仓库把这些修复整理成**幂等、可重复执行、可回滚**的脚本。

---

## 一键安装

```bash
git clone <本仓库>
cd akali360-debian-fixes

./install.sh --dry-run --all   # 先预览, 不改动系统
sudo ./install.sh --all        # 确认无误后实际执行
```

装完后随时核对各项状态（无需 root）：

```bash
./install.sh --status
```

---

## 修复清单

| 编号 | 脚本 | 问题 | 根因 | 方案 |
|---|---|---|---|---|
| **10** | `fixes/10-avs-sound.sh` | 内置扬声器无声 | Debian 内核未编译 `CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A` | 只编译该机器驱动为外部模块 |
| **20** | `fixes/20-hibernate-fan.sh` | 休眠后死机 + **风扇满速狂转** | coreboot 的 ACPI `_S4` 恢复流程有缺陷 | 休眠改走 `shutdown` 模式，绕开固件 S4 |
| **30** | `fixes/30-da7219-headphone.sh` | 重启后耳机输出失效 | WirePlumber 的 `available ~= "no"` 检查导致 profile 回退成纯输入 | 加 `device.profile.priority.rules` 兜底 |
| **40** | `fixes/40-sdcard-automount.sh` | SD 卡每次开机需手动挂载 | 未写入 fstab | 写 fstab（用 UUID，带 `nofail` 防止卡启动） |
| **50** | `fixes/50-smartd.sh` | `smartmontools.service` 开机必失败 | 本机无可监控的 SMART 设备（eMMC 不支持、USB 读卡器不支持 SAT） | 禁用服务，消除假警报 |

---

## 各项详解

### 10 · 扬声器无声（MAX98357A）

**症状**：`/proc/asound/cards` 里没有 `MAX98357A` 声卡，只有 DMIC / DA7219 / HDMI 三块卡。

**根因**：Debian 内核配置里：

```
CONFIG_SND_SOC_INTEL_AVS=m                ← AVS 核心已启用
CONFIG_SND_SOC_INTEL_AVS_MACH_DA7219=m    ← 这些机器驱动都编译了
CONFIG_SND_SOC_INTEL_AVS_MACH_DMIC=m
CONFIG_SND_SOC_INTEL_AVS_MACH_HDAUDIO=m
# CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A is not set   ← 唯独漏了这个
```

Akali360 的扬声器走 **AVS DSP + MAX98357A I²S 功放**，缺这个 board driver 就注册不出声卡。

**方案**：不重编整个内核，只把 `max98357a.c` 编译成**外部模块**装进
`/lib/modules/$(uname -r)/.../avs/boards/`，再用 `modules-load.d` 保证开机自动加载。
构建时自动探测已安装的 `linux-source-*`，没有就 `apt-get download`。

> ⚠️ **内核升级后需重跑**：外部模块绑定 vermagic，`linux-image` 更新后必须重新执行
> `sudo ./install.sh --only 10`，否则新内核下模块失效、扬声器再次无声。

### 20 · 休眠死机 + 风扇狂转（**本仓库的核心修复**）

**症状**：KDE 里点"休眠"，屏幕黑掉但不关机，**风扇满速狂转**，只能长按电源键强制断电。

> **风扇狂转不是独立的风扇驱动问题**，而是"固件失联"的表象——见下。

**根因**：这是**固件层**的 ACPI S4 缺陷，不是 Linux 电源管理的问题。

- `/sys/power/disk` 默认为 `[platform]`
- 内核写完休眠镜像后，把控制权交给固件执行 `_S4`（Suspend-To-Disk）恢复流程
- coreboot 的 `_S4` 交接流程不完整 → SoC 挂死
- EC 检测不到系统状态 → 退化为"风扇全速 + 不关机"

**方案**：绕开固件 S4，改用内核 **shutdown 模式**写盘休眠：

```
HibernateMode=shutdown
```

流程变为：内核把内存镜像写入 swap → 直接关机 → 下次按电源键开机 →
initramfs 的 resume 脚本从 swap 读回镜像继续运行。**全程不经过固件 S4。**

同时给 GRUB 加 `resume=UUID=<swap>` 让内核知道从哪块盘恢复。

> ### ⚠️ 行为变化（有意为之）
> 休眠后机器会**完全关机**，而非保持通电待恢复。恢复方式：**按电源键开机**，
> 自动恢复桌面和应用。相比"挂死 + 风扇狂转"，关机重启是可控的。
>
> 验证方法：`sudo systemctl hibernate` → 等完全断电（风扇停转）→ 按电源键开机 →
> 确认窗口都还在。

### 30 · 耳机输出重启后失效（DA7219 profile 回退）

**症状**：重启后插耳机没声音。`pactl list cards | grep -A2 avs_da7219` 显示
`Active Profile: input:stereo-fallback`（只剩输入），耳机 sink 不存在。

**根因**：WirePlumber 的 profile 恢复逻辑里有一条可用性检查。
`/usr/share/wireplumber/scripts/device/state-profile.lua` 第 46 行：

```lua
if profile.name == profile_name and profile.available ~= "no" then
```

本机拓扑特殊——扬声器在**独立的 MAX98357A 声卡**上，DA7219 这块卡**只有**耳机/线缆输出，
没有常开的扬声器通路。于是**未插耳机时**：

- `analog-output-headphones` / `analog-output-lineout` 的 availability = not available
- 整个 `output:stereo-fallback` profile 被判 `available: no`
- `state-profile.lua` 跳过你保存的 profile → 回退到 `input:stereo-fallback`
- 结果：耳机 sink 不复存在，插上耳机也无处可播

**方案**：用 WirePlumber 的 `device.profile.priority.rules` 做兜底。关键在于钩子执行顺序：

```
find-stored-profile    (state-profile.lua)          —— 检查 available, 可能跳过
find-preferred-profile (find-preferred-profile.lua) —— **不检查 available**, 只按名字匹配
find-best-profile                                     —— 取可用性最高的
apply-profile
```

`find-preferred-profile` 排在 stored 之后、best 之前，且**完全不看 available**。
所以：存储 profile 可用时 → 用你的显式选择，规则不介入；
存储 profile 不可用时 → 规则强制选 output，避免回退到 input。

**A/B 实测**：

| | Active Profile | DA7219 sink 数 |
|---|---|---|
| 无规则 | `input:stereo-fallback` | 0 |
| 有规则 | `output:stereo-fallback` | 1 |

> 本规则**不会覆盖**你手动设置过的、可用的 profile——它只做"不可用时的兜底"。

### 40 · SD 卡自动挂载

写 `/etc/fstab`，用 **UUID**（盘符 `sdb1` 会随插拔顺序变化，绝不能用）。
带 `nofail` + `x-systemd.device-timeout=15s`，**没插卡时不会卡在 emergency mode**。
`errors=remount-ro` 在卡损坏时降级为只读，保护数据。

```bash
sudo ./install.sh --only 40                # 自动探测当前已挂载的可移动设备
sudo ./fixes/40-sdcard-automount.sh /dev/sdb1 /media/$USER/MYCARD
sudo ./fixes/40-sdcard-automount.sh --by-label SDCARD /media/$USER/SDCARD
```

### 50 · smartd 开机报错

**症状**：每次开机 `smartmontools.service` 都失败（`No devices to monitor`），
让人误以为硬盘坏了。

**根因**：`smartd.conf` 用 `DEVICESCAN`，等价于 `smartctl --scan`。本机**确实没有**可监控设备：

- 内置 eMMC（DA4064）：非 ATA/SCSI，本版 smartctl 未启用 mmc 类型
- USB SD 读卡器：仅支持 SCSI inquiry，**不支持 SAT 直通**，无法读真实 SMART 属性

> 注意：`smartctl -d scsi -i /dev/sda` 会返回序列号，`-d scsi -H` 会返回
> `SMART Health Status: OK`——**这是假阳性**，伴随的
> `query_cmd_support response too short` 说明只是 USB 读卡器的通用回复。
> 本脚本因此改用 smartd 自身做检查（`smartd -q onecheck`），与开机运行同一逻辑。

**结论**：不是磁盘故障，是配置与硬件不匹配。

**查 eMMC 真实健康**（用 mmc-utils 读 EXT_CSD 寄存器）：

```bash
sudo apt install mmc-utils
sudo mmc extcsd read /dev/mmcblk0 | grep -iE 'LIFE_TIME|PRE_EOL'
#   LIFE_TIME_EST_TYP_A/B : 1=0-10% ... 10=90-100%, 值越小越新
#   PRE_EOL_INFO          : 1=正常  2=警告  3=紧急
```

> 将来加装了 SATA/NVMe 硬盘后，恢复服务：`sudo ./install.sh --only 50 --rollback`
> 或 `sudo ./fixes/50-smartd.sh --restore`

---

## 卸载 / 回滚

```bash
sudo ./install.sh --rollback 20    # 查看某项改动了哪些文件及回滚命令
```

各项改动的文件：

| 编号 | 改动的文件 |
|---|---|
| 10 | `/lib/modules/<ver>/.../snd-soc-avs-max98357a.ko`、`/etc/modules-load.d/avs-max98357a.conf` |
| 20 | `/etc/systemd/sleep.conf.d/hibernate.conf`、`/etc/default/grub`、`/etc/initramfs-tools/conf.d/resume` |
| 30 | `/etc/wireplumber/wireplumber.conf.d/50-avs-da7219-profile.conf` |
| 40 | `/etc/fstab` |
| 50 | `smartmontools.service` 启用状态（无文件改动） |

改配置前会自动创建 `.bak.YYYYMMDD-HHMMSS` 备份，可用 `ls /etc/**/*.bak.*` 查看。

---

## 设计原则

- **无硬编码机器信息**：swap UUID、盘符、挂载点、机型等**全部运行时自动探测**，
  便于跨机复用与公开分发。
- **幂等**：可重复运行，重复执行时自动跳过已完成的步骤。
- **可预览**：所有脚本支持 `--dry-run`，先看清楚要做什么再动手。
- **改前备份**：写配置前自动留 `.bak` 快照。
- **改后验证**：每步执行完都做结果校验并明确报告通过/失败。

---

## 故障排查

见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。常见入口：

- 休眠时报 `Not enough free memory` → 需要加 swap（本机 swap LV 无剩余空间）
- 内核升级后扬声器又没声了 → `sudo ./install.sh --only 10`
- HDMI 音频异常 → 缺 `hda-8086280b-tplg.bin`，但驱动有内置 fallback，通常无需处理

---

## 许可

脚本部分采用 MIT（见 [LICENSE](LICENSE)）。
`fixes/10-avs-sound.sh` 会在构建时从内核源码包提取 `max98357a.c`（GPL-2.0），
该文件**不在本仓库内**，构建时由 apt 现取，因此本仓库不含内核源码副本。
