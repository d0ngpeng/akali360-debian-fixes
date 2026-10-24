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

### 休眠时报 "Not enough free memory"

**本机最可能遇到的问题。** swap LV 只有约 2.9G 且无剩余空间，若休眠时已用内存较多
（本机 8G RAM，已用可达 4.4G+），LZO 压缩后仍可能超过 swap 容量。

**处理**：在**根分区**上加一个 swap 文件，并给它配 `resume_offset`：

```bash
# 1. 确认根分区剩余空间 (至少 8G)
df -h /

# 2. 创建 8G swap 文件 (示例大小, 按实际内存已用量调整)
sudo fallocate -l 8G /swapfile.img
sudo chmod 600 /swapfile.img
sudo mkswap /swapfile.img
sudo swapon /swapfile.img

# 3. 写入 fstab (用 swapon --show=NAME --noheadings 得到路径)
echo '/swapfile.img none swap sw 0 0' | sudo tee -a /etc/fstab

# 4. 计算 resume_offset (单位为 4K 页)
sudo filefrag -v /swapfile.img | awk '$1=="0:"{print "offset:",$4}'

# 5. 给内核加 resume=UUID=<swap的UUID>:<offset>  (UUID 用 swap 分区的, 不是 swap 文件的)
#    或者更简单: 用 resume= 后跟 swap 文件所在分区的 UUID 加 offset
```

> initramfs 已确认支持 `resume_offset`。若不熟悉 offset 计算，也可直接把 swap LV
> 扩容（`lvextend` + `mkswap`），但需先确认卷组有空闲 PE（本机 `Free PE = 0`，需先腾空间）。

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

### 想改回"合盖即睡眠、开盖即恢复"的体验

S3 深度睡眠走的是**不同代码路径**，不经过固件 S4。本机 `mem_sleep` 支持
`[s2idle] deep`，且 `deep` 已选中：

```bash
systemctl suspend          # S3 睡眠, 不是休眠
```

S3 的唤醒稳定性需自行验证（coreboot 对 S3 的支持通常好于 S4，但非绝对）。
若 S3 也挂死，只能依赖休眠（20 项的 shutdown 模式）。

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
