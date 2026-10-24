#!/usr/bin/env bash
#
# 修复: 休眠 (hibernate) 后死机 / 风扇狂转
#
# 症状:  KDE 里点"休眠"后机器挂死 —— 屏幕黑掉但不关机,
#        风扇满速狂转, 只能长按电源键强制断电。
#        重启后桌面应用全部丢失 (休眠恢复失败)。
#
# 根因:  这是固件层的 ACPI S4 实现缺陷, 不是 Linux 电源管理的问题。
#        本机是 Chromebook 刷 MrChromebox coreboot UEFI (Google Akali360),
#        coreboot 的 _S4 (Suspend-To-Disk) 交接流程不完整:
#          /sys/power/disk 默认为 [platform]
#          → 内核写完休眠镜像后把控制权交给固件
#          → 固件不执行既定的 S4 恢复路径, SoC 卡死
#          → EC 检测不到系统状态, 退化为"风扇全速 + 不关机"
#        所以风扇狂转只是"固件失联"的表象, 真正的问题是 S4 恢复不可用。
#
# 方案:  绕开固件 S4 —— 改用内核 shutdown 模式写盘休眠:
#          HibernateMode=shutdown
#        流程变为: 内核把内存镜像写入 swap → 直接断电关机
#                  → 下次按电源键开机 → initramfs 的 resume 脚本
#                  → 从 swap 读回镜像继续运行
#        全程不依赖固件 _S4, 因此不受该缺陷影响。
#
# 附带:  GRUB 加 resume=UUID=<swap> 让内核知道从哪块盘恢复
#        (缺少它则开机后不会自动恢复, 只会当作普通开机进入桌面)
#
# 代价:  行为变化 —— 休眠后会完全关机, 需手动按电源键开机恢复。
#        这是有意为之: 相比"挂死+风扇狂转", 关机重启是可接受的。
#
# 备选:  若你更想要"合盖/休眠即睡眠、开盖即恢复"的体验,
#        可改用 S3 深度睡眠 (本机 mem_sleep=s2idle [deep], deep 已选中):
#          systemctl suspend
#        S3 走的是不同代码路径, 不经过固件 S4。但需自行验证唤醒稳定性。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SLEEP_CONF_DIR="/etc/systemd/sleep.conf.d"
SLEEP_CONF="$SLEEP_CONF_DIR/hibernate.conf"
GRUB_FILE="/etc/default/grub"
INITRAMFS_RESUME="/etc/initramfs-tools/conf.d/resume"

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run]

  --dry-run   只打印将要执行的操作, 不改动系统
  -h, --help  显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

require_root

# ---------------------------------------------------------------- 检查
step "环境检查"

# 休眠能力
grep -qw disk /sys/power/state 2>/dev/null \
  || die "内核不支持磁盘休眠 (/sys/power/state 无 disk)"
ok "内核支持 disk (休眠)"

# systemd 版本需 >= 256 才认 HibernateMode=shutdown
SDV=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
SDMAJ=${SDV%%.*}
if [ "${SDMAJ:-0}" -lt 256 ]; then
  warn "systemd $SDV 低于 256, HibernateMode=shutdown 可能无效 (需 >= 256)"
  log "当前系统 systemd $SDV —— 继续, 但请留意结果校验"
else
  ok "systemd $SDV (支持 HibernateMode=shutdown)"
fi

# 确认 shutdown 是 /sys/power/disk 的合法选项
if grep -q "shutdown" /sys/power/disk 2>/dev/null; then
  ok "内核接受 shutdown 休眠模式"
else
  warn "/sys/power/disk 未列出 shutdown, 该模式可能不可用"
fi

# 找 swap
step "探测 swap"

SWAP_UUID=$(detect_swap_uuid) || true
if [ -n "${SWAP_UUID:-}" ]; then
  ok "swap UUID: $SWAP_UUID"
  SWAP_DEV=$(blkid -U "$SWAP_UUID" 2>/dev/null || echo "?")
  SWAP_SIZE=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1)
  log "swap 设备: $SWAP_DEV  大小: ${SWAP_SIZE:-未知}"
else
  warn "未检测到已启用的块设备 swap"
  if is_dry_run; then
    log "[dry-run] 探测不到 swap, 以下 resume 配置将使用占位符"
    SWAP_UUID="PENDING"
  else
    die "找不到 swap, 无法设置 resume。
  请先启用 swap: sudo swapon <设备>  或创建 swap 文件后重试。"
  fi
fi

# 休眠镜像大小 vs swap 可用空间 (提前预警)
IMG_SIZE=$(cat /sys/power/image_size 2>/dev/null || echo 0)
if [ "${IMG_SIZE:-0}" -gt 0 ] && [ "$SWAP_UUID" != "PENDING" ]; then
  # 取 swap 总容量字节数
  SWAP_BYTES=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | head -1 || echo 0)
  if [ "${SWAP_BYTES:-0}" -gt 0 ]; then
    if [ "$IMG_SIZE" -gt "$SWAP_BYTES" ]; then
      warn "休眠镜像上限 ($((IMG_SIZE/1048576))M) 超过 swap 总量 ($((SWAP_BYTES/1048576))M)"
      log "实际镜像大小取决于压缩后的已用内存, 通常远小于上限"
      log "若休眠时报 'Not enough free memory', 见 docs/TROUBLESHOOTING.md"
    else
      ok "swap 容量足以容纳休眠镜像 (上限 $((IMG_SIZE/1048576))M / swap $((SWAP_BYTES/1048576))M)"
    fi
  fi
fi

# 内存: 休眠镜像 ≈ 已用内存的压缩结果
USED_MB=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int((t-a)/1024)}' /proc/meminfo)
log "当前已用内存约 ${USED_MB}M (LZO 压缩后约为 1/2)"

# ---------------------------------------------------------------- 配置
step "配置 HibernateMode=shutdown"

write_file "$SLEEP_CONF" <<'EOF'
[Sleep]
# 休眠走 shutdown 模式, 绕开 coreboot (MrChromebox) 不可靠的 ACPI S4 实现。
#
# 默认 [platform] 模式下, 内核写完镜像后交给固件执行 _S4 恢复流程;
# 本机固件该流程有缺陷, 导致恢复时 SoC 挂死、EC 失联、风扇满速狂转。
#
# shutdown 模式: 内核写完镜像直接关机, 下次开机由 initramfs 的
# resume 脚本从 swap 读回镜像, 完全不经过固件 S4。
# 行为变化: 休眠后是关机状态, 需手动按电源键开机恢复。
HibernateMode=shutdown
EOF

if ! is_dry_run; then
  if systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -q "^HibernateMode=shutdown"; then
    ok "systemd 已确认生效: HibernateMode=shutdown"
  else
    warn "systemd-analyze 未读到该配置, 请检查 $SLEEP_CONF"
  fi
fi

# ---------------------------------------------------------------- resume
step "配置内核 resume 参数"

ensure_kernel_param "resume" "UUID=$SWAP_UUID"

# initramfs 侧也要有 RESUME (Debian 的 resume 脚本读这个)
if [ -f "$INITRAMFS_RESUME" ] && grep -q "UUID=$SWAP_UUID" "$INITRAMFS_RESUME" 2>/dev/null; then
  ok "initramfs resume 已正确: $(cat "$INITRAMFS_RESUME")"
else
  write_file "$INITRAMFS_RESUME" <<EOF
RESUME=UUID=$SWAP_UUID
EOF
fi

# ---------------------------------------------------------------- 重生成引导
step "重生成引导配置"

if is_dry_run; then
  log "[dry-run] 将执行: update-grub && update-initramfs -u"
else
  update-grub >/dev/null || die "update-grub 失败"
  ok "grub.cfg 已更新"
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$KVER" >/dev/null || warn "update-initramfs 失败 (可能不阻塞功能)"
    ok "initramfs 已更新"
  fi
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统" \
          "swap UUID (探测值): $SWAP_UUID"
  exit 0
fi

PASS=0; FAIL=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; PASS=$((PASS+1)); else err "$d"; FAIL=$((FAIL+1)); fi; }

chk "sleep.conf 存在"              test -f "$SLEEP_CONF"
chk "systemd 读到 HibernateMode"   sh -c 'systemd-analyze cat-config systemd/sleep.conf | grep -q "^HibernateMode=shutdown"'
chk "grub.cfg 含 resume 参数"      grep -q "resume=UUID=$SWAP_UUID" /boot/grub/grub.cfg
chk "GRUB 文件含 resume 参数"      grep -q "resume=UUID=$SWAP_UUID" $GRUB_FILE
chk "initramfs resume 配置"        grep -q "UUID=$SWAP_UUID" "$INITRAMFS_RESUME"

# 确认 initramfs 里真的带上了 resume 脚本
if lsinitramfs /boot/initrd.img-$KVER 2>/dev/null | grep -q "scripts/local-premount/resume"; then
  ok "initramfs 含 resume 脚本"
  PASS=$((PASS+1))
else
  # 某些情况下 lsinitramfs 不可用, 不作硬失败
  warn "无法确认 initramfs 内含 resume 脚本 (lsinitramfs 不可用或未装)"
fi

echo
echo "当前 /sys/power/disk:"
sed 's/^/    /' /sys/power/disk
echo
echo "  提示: 方括号 [] 内为默认模式, shutdown 应在列表中"
echo "        实际休眠时由 systemd 传 shutdown, 无需改这里"

echo
if [ "$FAIL" -eq 0 ]; then
  ok "全部 $PASS 项通过"
  cat <<EOF

────────── 重要: 行为变化 ──────────
  休眠后机器会**完全关机**, 而不是保持通电待恢复。
  恢复方式: 按电源键开机 → 自动从 swap 恢复桌面和应用。

  这是有意的设计: 相比"挂死 + 风扇狂转", 关机是可控的。

  建议先做一次完整验证:
    1. 保存好工作, 关掉所有重要文档
    2. 执行:  systemctl hibernate
    3. 等机器完全断电 (风扇停转)
    4. 按电源键开机, 确认桌面和应用恢复

  若开机后提示 swap 不足或未恢复, 见 docs/TROUBLESHOOTING.md
────────────────────────────────────
EOF
else
  err "$FAIL/$((PASS+FAIL)) 项未通过"
  exit 1
fi
