# 故障排查

本文覆盖各修复项可能遇到的问题。先看通用排查手段，再看具体项。

---

## 通用排查

```bash
./install.sh --status                    # 各项当前状态 (无需 root)
sudo ./install.sh --dry-run --only <编号>  # 重新预览某项将做什么

journalctl -b -p err                     # 本次启动的错误日志
systemctl --failed                       # 失败的 systemd 单元
dmesg | grep -iE 'error|fail|avs|hda'    # 内核相关消息
```

---

## 10 · 扬声器

### 内核升级后扬声器又没声了

外部模块绑定 vermagic，`linux-image` 更新后必须重新构建：

```bash
sudo ./install.sh --only 10
```

脚本是幂等的：若已安装模块的 vermagic 与当前内核匹配，会跳过源码下载（165 MB）与编译，
只做自动加载配置和验证；确实需要重建时用 `sudo bash fixes/10-avs-sound.sh --force`。

判断当前状态：

```bash
uname -r                                                    # 当前内核
ls /lib/modules/$(uname -r)/kernel/sound/soc/intel/avs/boards/
modinfo snd-soc-avs-max98357a | grep vermagic               # 应匹配 uname -r
grep MAX98357A /proc/asound/cards                           # 应有输出
lsmod | grep snd_soc_avs_max98357a                          # 应已加载
```

### 构建失败

常见原因与处理：

| 报错 | 原因 | 处理 |
|---|---|---|
| `找不到内核 headers` | 未装 headers | `sudo apt install linux-headers-$(uname -r)` |
| `取不到内核源码` | 未装源码包且无网络 | `sudo apt install linux-source-7.2` 后重跑 |
| `vermagic 不匹配` | headers 与运行内核版本不一致 | 确认 `linux-headers-$(uname -r)` 与 `uname -r` 完全相同 |
| `undefined reference to ...` | 源码与 headers 的 AVS API 不一致 | 用与内核**同版本**的源码包 |

保留完整构建输出排查：

```bash
sudo bash -x ./fixes/10-avs-sound.sh --force 2>&1 | tee /tmp/build.log
```

### 声卡出现了但仍无声

驱动已加载、声卡已注册，但默认输出设备不对：

```bash
pactl info | grep 'Default Sink'        # 应为 avs_max98357a
pactl list short sinks
pactl set-default-sink <max98357a 的 sink 名>
```

若仍无声，检查 PipeWire 是否真的连上了这块卡：

```bash
pw-dump | grep -A3 max98357a
wpctl status
```

---

## 20 · 休眠 / 风扇

### 休眠时报 "Not enough free memory"，或写完镜像却黑屏假死

> **先说结论（2026-11 实测）**：本机 2.9 G 的 swap LV **不可能**装下休眠镜像。
> 镜像大小约等于 `AnonPages + Shmem`（正常使用约 3.7 G）。写盘阶段会失败，
> 表现为屏幕黑掉后长时间假死、最后回滚；`journalctl` 里
> `PM: Image loading done` 一次都不会出现。
>
> 因此默认策略是**合盖走 S3 睡眠**（见 70 项）。只有在把 swap 扩到
> 4 G 以上（建议 5 G）之后，才值得重新尝试休眠。

**为什么不能用 swap 文件补**：休眠恢复时内核要**线性读取**镜像，
swap 文件在 ext4 上必须物理连续。本机根分区碎片化严重，`fallocate` 出来的
8 G 文件有 25 个 extent，`e4defrag` 后仍有 9 个，resume 必然失败。
可行的路只有**离线缩小根 LV**、给 swap LV 扩容：

```bash
# 必须在 U 盘启动的环境里做（根文件系统不能在线缩小）
sudo vgchange -ay
sudo e2fsck -f /dev/mapper/<vg>-root
sudo resize2fs /dev/mapper/<vg>-root 44G      # 先把文件系统缩到目标大小
sudo lvreduce -L 44G /dev/mapper/<vg>-root    # 再缩 LV
sudo lvextend -l +100%FREE /dev/mapper/<vg>-swap_1
# 保留原 UUID，避免改 resume= / fstab
sudo mkswap -U "$(blkid -s UUID -o value /dev/mapper/<vg>-swap_1)" /dev/mapper/<vg>-swap_1
```

> 操作前务必备份。缩小根分区有风险，脚本不会自动执行。
> 扩容后按 `free -h` 确认 swap ≥ `AnonPages + Shmem`，再实测
> `sudo systemctl hibernate` 并检查 `PM: Image loading done` 是否出现。

### 按电源键开机后没有恢复桌面，直接进了新桌面

说明 resume 没生效。检查：

```bash
grep resume /boot/grub/grub.cfg | head -3          # 内核参数 (需 root: sudo grep)
cat /etc/initramfs-tools/conf.d/resume             # RESUME=UUID=...
lsinitramfs /boot/initrd.img-$(uname -r) | grep resume   # initramfs 是否含 resume 脚本
sudo swapoff -a && sudo swapon -a                  # 重置 swap (会清掉未恢复的镜像)
```

若 `grub.cfg` 里没有 `resume=`：

```bash
sudo ./install.sh --only 20
```

### 休眠后风扇仍在转 / 机器没完全断电

确认 shutdown 模式已生效：

```bash
systemd-analyze cat-config systemd/sleep.conf | grep -i hibernate
cat /sys/power/disk
```

- `/sys/power/disk` 应列出 `shutdown`（方括号内是**默认**模式，但实际由 systemd 传参）
- 若 `HibernateMode=shutdown` 未出现在 cat-config 输出里，检查文件是否写对：
  `ls -l /etc/systemd/sleep.conf.d/hibernate.conf`

systemd **< 256** 不支持 `HibernateMode=shutdown`。本机为 systemd 257，正常。

### 合盖即睡眠、开盖即恢复（现在是默认行为）

S3 深度睡眠走的是**不同代码路径**，不经过固件 S4。本机 `mem_sleep` 支持
`[s2idle] deep`，且 `deep` 已选中：

```bash
cat /sys/power/mem_sleep     # s2idle [deep]
systemctl suspend            # 手动测一次 S3
```

70 号修复默认就是：AC/电池合盖 → S3，低电量合盖 → 干净关机。
历史上本机 S3 的 entry/exit 多次成功；如果某次 KDE 会话无法恢复，
先用 `Ctrl+Alt+F3` 切 TTY 看是否只是图形栈问题，而不是内核没醒。

---

## 30 · 耳机

### 规则已装但 profile 仍是 input

```bash
# 1. 确认配置文件存在且语法平衡
ls -l /etc/wireplumber/wireplumber.conf.d/50-avs-da7219-profile.conf

# 2. 确认 wireplumber 读到了规则
wireplumber --dump-config | grep -B2 -A6 da7219

# 3. 确认声卡名能被规则匹配 (设备名应匹配 alsa_card.platform-avs_da7219.*)
pactl list cards | grep 'alsa_card.platform-avs'

# 4. 看日志
journalctl --user -u wireplumber -n 100 | grep -iE 'preferred|profile|da7219'
```

### WirePlumber 版本太旧

`device.profile.priority.rules` 机制在 WirePlumber **0.5** 引入。确认版本：

```bash
wireplumber --version
```

Debian 13 自带 0.5.8，正常。若为 0.4.x，需升级或改用其它途径（如源码补丁，本仓库不涉及）。

### 插上耳机了但自动切换不生效

profile 已是 output 时，插入耳机的自动切换由 ALSA 控制的 jack 检测 + PipeWire 路由处理，
与本修复项无关。检查 jack 状态：

```bash
# 需 root 读取输入设备
sudo evtest /dev/input/event12     # 插拔耳机观察事件
wpctl status                        # 查看默认节点
```

---

## 40 · SD 卡

### 开机卡在 emergency mode / 等待设备 90 秒

fstab 里缺 `nofail` 或 `x-systemd.device-timeout`。确认：

```bash
grep SDCARD /etc/fstab     # 或 grep UUID= /etc/fstab
```

应含 `nofail,x-systemd.device-timeout=15s`。补上后：

```bash
sudo systemctl daemon-reload
```

### 挂载了但权限不对（无法写入）

exfat/vfat 需要在 fstab 里用 `uid=`/`gid=` 指定属主。确认：

```bash
id -u $USER; id -g $USER          # 应与 fstab 里的 uid/gid 一致
ls -ld /media/$USER/SDCARD
```

若用 ext4/btrfs 等原生 Linux 文件系统，则**不应**写 `uid=`/`gid=`（由文件权限控制），
脚本会自动区分。

### 插多张卡时挂载点冲突

用 `--by-label` 区分：

```bash
sudo ./fixes/40-sdcard-automount.sh --by-label CARD_A /media/$USER/CARD_A
```

---

## 50 · smartd

### 禁用后想恢复（加装了硬盘）

```bash
sudo ./fixes/50-smartd.sh --restore
# 或
sudo systemctl enable --now smartmontools.service
```

恢复后若仍报 `No devices to monitor`，说明确实还是没有可监控设备，
可改 `/etc/smartd.conf`，把 `DEVICESCAN` 换成显式设备：

```bash
sudoedit /etc/smartd.conf
# 例如:
# /dev/nvme0 -d nvme -a -m root -M exec /usr/share/smartmontools/smartd-runner
```

### 查 eMMC 寿命（smartd 管不到，需单独装 mmc-utils）

```bash
sudo apt install mmc-utils
sudo mmc extcsd read /dev/mmcblk0 | grep -iE 'LIFE_TIME|PRE_EOL'
```

- `LIFE_TIME_EST_TYP_A` / `_B`：1=0-10% … 10=90-100%，**值越小越新**
- `PRE_EOL_INFO`：1=正常　2=警告　3=紧急

---

## 70 · 合盖 / 低电量

### 合盖后机器没睡，几小时后电池耗尽关机

判断是不是"只关屏"：

```bash
# 1. 合盖动作（1=睡眠 2=休眠 8=关机 64=仅关屏）
for g in AC Battery LowBattery; do
  printf '%s=%s\n' "$g" "$(kreadconfig6 --file powerdevilrc --group "$g" \
    --group SuspendAndShutdown --key LidAction)"
done

# 2. 上一次启动到底有没有睡
sudo journalctl -b -1 | grep -E 'PM: suspend entry|PM: hibernation entry|PM: Image loading'
#    什么都没有 = 根本没睡, 是硬断电
```

修复：

```bash
sudo bash fixes/70-sleep-safety.sh --dry-run
sudo bash fixes/70-sleep-safety.sh
```

### 低电量阈值怎么定的

- `PercentageLow=20`：Plasma 切到"低电量"配置 → 此时合盖会**关机**
- `PercentageCritical=10` / `PercentageAction=7`：UPower 在 7% 触发动作
- `CriticalPowerAction=PowerOff`：干净卸载后关机

电量读数在 3% 附近可能停留十几分钟再直接掉电，所以动作阈值必须提前到 7%。

### 合盖后黑屏很久、按电源键才回来

这是**休眠失败**的典型表现（不是 S3）。确认日志里是否有
`PM: hibernation: hibernation entry` 却没有 `PM: Image loading done`：

```bash
sudo journalctl -b -1 | grep -iE 'hibernation|Image loading|PM: suspend'
sudo grep -c 'PM: Image loading done' /var/log/syslog 2>/dev/null || true
```

本机 swap 2.9 G 小于 `AnonPages + Shmem`（约 3.7 G），休眠镜像写不下。
把任何动作指回 hibernate 都会复现黑屏假死：

```bash
# 确认没有残留的 hibernate 配置
grep -rH 'hibernate' /etc/systemd/logind.conf.d/ /etc/systemd/sleep.conf.d/ 2>/dev/null
grep -E '^CriticalPowerAction=' /etc/UPower/UPower.conf
```

### 想彻底恢复原状

```bash
sudo bash fixes/70-sleep-safety.sh --restore
```

原始值记录在 `/var/lib/akali360-fixes/70-sleep-safety.state`，
UPower 原始配置在 `/etc/UPower/UPower.conf.bak.*`。

---

## 残留的内核告警（通常无需处理）

排查时可能在 `dmesg` 里看到以下消息，**经确认为良性噪音**：

| 消息 | 说明 |
|---|---|
| `EC failed to respond in time` / `cannot register EC` | cros-ec-spi 试图声明 ACPI 里已声明的 EC；真实 EC 走 LPC（`GOOG0004:00` 已绑定，`/dev/cros_ec` 存在） |
| `Direct firmware load for intel/avs/hda-8086280b-tplg.bin failed with error -2` | 该型号拓扑文件未打包，驱动自动回退到 `hda-8086-generic-tplg.bin`，HDMI 音频正常 |
| `Endpoint format configuration not found.` | 同上，回退路径的正常输出 |
| DA7219 `Invalid jack detect rate` / `Invalid VDDIO voltage` | 机器驱动用了非默认参数表，DA7219 按实际配置工作 |
| `i8042: Warning: Keylock active` | PS/2 键盘锁状态检测，Chromebook 常见 |
| `MDS/MMIO: SMT vulnerable` | CPU 微码侧信道缓解状态，与本机功能无关 |

3 个未绑定的 PCI 设备（`9d4e` LPC、`9d21` PMC、`9d24` unclassified）也无需处理：
`lpc_ich` 对 9d4e 无匹配 alias，且功能上无缺口（SMBus→`i801_smbus`、EC→`cros_ec_lpcs`、
gpiochip0 均已就位）。
