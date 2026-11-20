#!/usr/bin/env bash
#
# 修复: 合盖只关屏 + 低电量不保护 → 电池耗尽硬断电 ("睡死")
#
# 症状:  合上盖子后屏幕熄灭, 以为机器睡了; 回来时机器已经没电关机,
#        开机后桌面 / 会话全部丢失, journal 里也找不到任何休眠或挂起记录:
#          · 没有 PM: suspend entry / PM: hibernation entry
#          · swap 头部没有 S1SUSPEND (从未写出休眠镜像)
#          · 下次开机没有 PM: Image loading (冷启动, 不是恢复)
#        更隐蔽的一点: 电量会一路掉到 0, 而不是在低电量时休眠。
#
# 根因 (三处):
#
#   1) KDE PowerDevil 的合盖动作被设成"关闭屏幕"而不是睡眠。
#      ~/.config/powerdevilrc 里:
#          [AC][SuspendAndShutdown]         LidAction=64
#          [Battery][SuspendAndShutdown]    LidAction=64
#          [LowBattery][SuspendAndShutdown] LidAction=64
#      对照上游 daemon/powerdevilenums.h:
#          NoAction=0  Sleep=1  Hibernate=2  Shutdown=8
#          LockScreen=32  TurnOffScreen=64  ToggleScreenOnOff=128
#      64 = TurnOffScreen —— 只关屏, 系统照常运行, 电池自然被耗光。
#
#   2) UPower 的关键电量动作是 HybridSleep, 且阈值定在 2%:
#          CriticalPowerAction=HybridSleep
#          PercentageAction=2.0
#      电量读数常常在 3% 停留十几分钟后直接掉电, 2% 根本来不及触发。
#
#   3) 本机的"休眠"(hibernate) 实际上从未成功过 —— 所以不能拿它当兜底。
#      证据 (2026-11-20 排查):
#        · 全部 journal 历史里 "PM: Image loading done" 出现 0 次
#        · 两次合盖休眠: 一次写镜像时黑屏卡死 (只能长按电源),
#          一次在异常低功耗态挂了 23 分钟才回滚, 镜像未恢复
#        · swap 2.9G < AnonPages+Shmem ≈ 3.7G, 镜像根本放不下;
#          即使 SSD 上的 swapfile 也因碎片化无法满足 resume 的连续读
#      因此本脚本不把任何动作指向 hibernate:
#        合盖 → Sleep (S3/deep, 开盖秒回, 本机历史多次 entry/exit 成功)
#        低电量合盖 → Shutdown (干净卸载, 避免在 S3 里被 EC 硬断电)
#
# 方案:
#   · PowerDevil: AC/Battery 合盖 → Sleep (1); LowBattery 合盖 → Shutdown (8)
#   · UPower:     PercentageCritical=10, PercentageAction=7,
#                 CriticalPowerAction=PowerOff (清醒时低电量干净关机)
#   · logind:     drop-in 兜底, 登录界面等无 PowerDevil 的场景也合盖睡眠
#
# 想要真正可用的休眠, 必须先把 swap 扩到大于 AnonPages+Shmem (本机需 4G+),
# 需要离线缩小根 LV, 不在本脚本范围内。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STATE_DIR=/var/lib/akali360-fixes
STATE_FILE="$STATE_DIR/70-sleep-safety.state"
UPOWER_CONF=/etc/UPower/UPower.conf
LOGIND_DROPIN=/etc/systemd/logind.conf.d/10-lid-sleep.conf
LOGIND_OLD=/etc/systemd/logind.conf.d/10-lid-hibernate.conf

# 目标用户 = 调用 sudo 的人 (PowerDevil 配置在用户家目录)
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run] [--restore]

  --dry-run    只打印将执行的操作, 不改动系统
  --restore    恢复修改前的设置 (合盖动作 / UPower / logind)
  -h, --help   显示本帮助

说明: PowerDevil 配置作用于调用 sudo 的用户 ($TARGET_USER)。
      多用户机器请对每个用户分别执行: sudo -u <用户> ... 或 su - <用户> 后运行。
      · 合盖 → 睡眠 (S3), 开盖即恢复
      · 低电量时合盖 → 关机, 防止在睡眠中被电池保护板直接断电
      · 本机休眠不可用 (swap 小于内存占用), 脚本不会把任何动作指向 hibernate
EOF
}

RESTORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --restore) RESTORE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

require_root

# ---------------------------------------------------------------- 工具函数
# 以目标用户身份读写 powerdevilrc
kread_pd() { # kread_pd <group> <key>
  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    kreadconfig6 --file powerdevilrc --group "$1" --group SuspendAndShutdown --key "$2" 2>/dev/null
}
kwrite_pd() { # kwrite_pd <group> <key> <value>
  sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" \
    kwriteconfig6 --file powerdevilrc --group "$1" --group SuspendAndShutdown --key "$2" "$3"
}

restart_powerdevil() {
  local uid rt
  uid=$(id -u "$TARGET_USER" 2>/dev/null || true)
  rt="/run/user/${uid:-0}"
  [ -d "$rt" ] || return 0
  sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="$rt" \
    systemctl --user restart plasma-powerdevil.service 2>/dev/null \
    || warn "plasma-powerdevil 重启失败 (注销重登后同样生效)"
}

lid_desc() {
  case "$1" in
    0) echo "不做任何事" ;;
    1) echo "睡眠(S3)" ;;
    2) echo "休眠" ;;
    8) echo "关机" ;;
    32) echo "锁屏" ;;
    64) echo "仅关闭屏幕" ;;
    128) echo "切换屏幕开关" ;;
    *) echo "未设置" ;;
  esac
}

# 本机是否值得尝试 hibernate: swap 必须大于匿名页+tmpfs
swap_fits_hibernate() {
  local need swap
  need=$(awk '/^(AnonPages|Shmem):/{s+=$2} END{print s+0}' /proc/meminfo 2>/dev/null || echo 0)
  swap=$(awk '/^SwapTotal:/{print $2+0}' /proc/meminfo 2>/dev/null || echo 0)
  [ "$need" -gt 0 ] && [ "$swap" -ge "$need" ]
}

# ---------------------------------------------------------------- 诊断
step "诊断"

PD_OK=0
if [ -n "$TARGET_HOME" ] && [ -f "$TARGET_HOME/.config/powerdevilrc" ] \
   && command -v kreadconfig6 >/dev/null 2>&1 && command -v kwriteconfig6 >/dev/null 2>&1; then
  PD_OK=1
fi

if [ "$PD_OK" -eq 1 ]; then
  echo "  PowerDevil ($TARGET_USER):"
  for g in AC Battery LowBattery; do
    v=$(kread_pd "$g" LidAction || true)
    printf '    %-11s LidAction=%-4s (%s)\n' "$g" "${v:-?}" "$(lid_desc "${v:-}")"
  done
else
  warn "未找到 PowerDevil 配置或 kwriteconfig6, 将跳过合盖动作设置"
fi

echo "  UPower:"
if [ -f "$UPOWER_CONF" ]; then
  grep -E '^(PercentageLow|PercentageCritical|PercentageAction|CriticalPowerAction|AllowRiskyCriticalPowerAction)=' \
    "$UPOWER_CONF" | sed 's/^/    /'
else
  warn "  未安装 UPower ($UPOWER_CONF 不存在)"
fi

echo "  logind: $(grep -h '^HandleLidSwitch=' "$LOGIND_DROPIN" 2>/dev/null || echo '未设置')"

echo "  睡眠能力:"
printf '    /sys/power/state      = %s\n' "$(cat /sys/power/state 2>/dev/null || echo 未知)"
printf '    /sys/power/mem_sleep  = %s\n' "$(cat /sys/power/mem_sleep 2>/dev/null || echo 未知)"
if swap_fits_hibernate; then
  echo "    休眠可用性: swap 足够 (仍建议实测后再启用)"
else
  echo "    休眠可用性: ✗ swap 小于 AnonPages+Shmem, 休眠镜像放不下 → 本脚本不启用"
fi

# ---------------------------------------------------------------- 恢复
if [ "$RESTORE" -eq 1 ]; then
  step "恢复修改前的设置"
  if is_dry_run; then
    log "[dry-run] 将恢复 PowerDevil / UPower / logind 设置"
    summary "dry-run 完成, 未改动系统"
    exit 0
  fi

  if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        lid_*)
          if [ "$PD_OK" -eq 1 ] && [ -n "$v" ]; then
            kwrite_pd "${k#lid_}" LidAction "$v" && ok "LidAction(${k#lid_})=$v"
          fi ;;
        upower_backup)
          [ -f "$v" ] && cp -p "$v" "$UPOWER_CONF" && ok "已恢复 $UPOWER_CONF" ;;
      esac
    done < "$STATE_FILE"
  else
    warn "没有状态文件 $STATE_FILE, PowerDevil/UPower 无法精确恢复"
  fi

  for f in "$LOGIND_DROPIN" "$LOGIND_OLD"; do
    if [ -f "$f" ]; then
      rm -f "$f"
      ok "已删除 $f"
    fi
  done

  restart_powerdevil
  systemctl restart systemd-logind 2>/dev/null || true
  [ -f "$UPOWER_CONF" ] && systemctl restart upower 2>/dev/null || true
  ok "已恢复 (合盖动作 / 低电量动作回到修改前)"
  summary "恢复完成" "重启或注销后完全生效"
  exit 0
fi

# ---------------------------------------------------------------- 应用
step "应用设置"

is_dry_run || mkdir -p "$STATE_DIR"

# 记录原始值 (只记一次, 供 --restore 使用)
if [ "$PD_OK" -eq 1 ] && [ ! -f "$STATE_FILE" ] && ! is_dry_run; then
  {
    for g in AC Battery LowBattery; do
      printf 'lid_%s=%s\n' "$g" "$(kread_pd "$g" LidAction || echo 1)"
    done
    printf 'upower_backup=%s\n' "$(ls -1t "$UPOWER_CONF".bak.* 2>/dev/null | sed -n '1p' || true)"
  } > "$STATE_FILE"
  log "已记录原始值: $STATE_FILE"
fi

# 1) PowerDevil 合盖: AC/电池 → 睡眠, 低电量 → 关机
if [ "$PD_OK" -eq 1 ]; then
  need=0
  [ "$(kread_pd AC LidAction || true)" = "1" ] || need=$((need + 1))
  [ "$(kread_pd Battery LidAction || true)" = "1" ] || need=$((need + 1))
  [ "$(kread_pd LowBattery LidAction || true)" = "8" ] || need=$((need + 1))

  if [ "$need" -eq 0 ]; then
    ok "合盖动作已是目标配置 (AC/Battery=睡眠, LowBattery=关机), 跳过"
  elif is_dry_run; then
    for pair in AC:1 Battery:1 LowBattery:8; do
      g=${pair%%:*}; target=${pair##*:}
      cur=$(kread_pd "$g" LidAction || true)
      if [ "$cur" = "$target" ]; then
        log "[dry-run] LidAction($g) 已是 $(lid_desc "$target") (跳过)"
      else
        log "[dry-run] LidAction($g): ${cur:-未设置} → $target ($(lid_desc "$target"))"
      fi
    done
  else
    bk="$TARGET_HOME/.config/powerdevilrc.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$TARGET_HOME/.config/powerdevilrc" "$bk" 2>/dev/null || true
    chown "$TARGET_USER:" "$bk" 2>/dev/null || true
    log "已备份 powerdevilrc -> ${bk##*/}"

    for pair in AC:1 Battery:1 LowBattery:8; do
      g=${pair%%:*}; target=${pair##*:}
      cur=$(kread_pd "$g" LidAction || true)
      if [ "$cur" = "$target" ]; then
        ok "LidAction($g) 已是 $(lid_desc "$target") (跳过)"
      else
        kwrite_pd "$g" LidAction "$target"
        ok "LidAction($g): ${cur:-未设置} → $target ($(lid_desc "$target"))"
      fi
    done
    restart_powerdevil
  fi
else
  warn "跳过 PowerDevil (未安装 KDE 或找不到配置)"
fi

# 2) UPower: 低电量 → 干净关机, 阈值提前
if [ -f "$UPOWER_CONF" ]; then
  need=0
  grep -q '^CriticalPowerAction=PowerOff$' "$UPOWER_CONF" || need=1
  grep -q '^PercentageAction=7\.0$' "$UPOWER_CONF" || need=1
  grep -q '^PercentageCritical=10\.0$' "$UPOWER_CONF" || need=1
  if [ "$need" -eq 0 ]; then
    ok "UPower 已是目标配置 (跳过)"
  elif is_dry_run; then
    log "[dry-run] $UPOWER_CONF: CriticalPowerAction=PowerOff, PercentageAction=7.0, PercentageCritical=10.0"
  else
    bk="${UPOWER_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$UPOWER_CONF" "$bk"
    log "已备份 $UPOWER_CONF -> ${bk##*/}"
    if [ -f "$STATE_FILE" ]; then
      sed -i "s|^upower_backup=.*|upower_backup=$bk|" "$STATE_FILE"
      grep -q '^upower_backup=' "$STATE_FILE" || printf 'upower_backup=%s\n' "$bk" >> "$STATE_FILE"
    else
      printf 'upower_backup=%s\n' "$bk" > "$STATE_FILE"
    fi
    sed -i -e 's/^#\?PercentageCritical=.*/PercentageCritical=10.0/' \
           -e 's/^#\?PercentageAction=.*/PercentageAction=7.0/' \
           -e 's/^#\?CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' \
           "$UPOWER_CONF"
    ok "低电量动作已改为关机 (7% 触发, 10% 进入 critical 提示)"
    systemctl restart upower 2>/dev/null || warn "upower 重启失败, 下次开机生效"
  fi
else
  warn "跳过 UPower (未安装)"
fi

# 3) logind 兜底 (登录界面 / 无 PowerDevil 的场景)
if [ -f "$LOGIND_OLD" ]; then
  if is_dry_run; then
    log "[dry-run] 将删除旧配置 $LOGIND_OLD (合盖休眠)"
  else
    rm -f "$LOGIND_OLD"
    ok "已移除旧的合盖休眠配置 $LOGIND_OLD"
  fi
fi

if [ -f "$LOGIND_DROPIN" ]; then
  ok "$LOGIND_DROPIN 已存在 (跳过)"
elif is_dry_run; then
  log "[dry-run] 将写入 $LOGIND_DROPIN (HandleLidSwitch=suspend)"
else
  mkdir -p "$(dirname "$LOGIND_DROPIN")"
  cat > "$LOGIND_DROPIN" <<'EOF'
# 合盖动作兜底: Plasma 运行时由 PowerDevil 接管, 这里覆盖登录界面等无抑制剂场景。
# 本机 coreboot 的 S4 与休眠镜像均不可靠, 合盖统一走 S3, 开盖即恢复。
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
EOF
  ok "已写入 $LOGIND_DROPIN"
  systemctl restart systemd-logind 2>/dev/null || warn "systemd-logind 重启失败, 下次开机生效"
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统"
  exit 0
fi

if [ "$PD_OK" -eq 1 ]; then
  echo "  合盖动作: AC=$(kread_pd AC LidAction) / Battery=$(kread_pd Battery LidAction) / LowBattery=$(kread_pd LowBattery LidAction)  (1=睡眠, 8=关机)"
fi
if [ -f "$UPOWER_CONF" ]; then
  echo "  UPower 动作: $(grep '^CriticalPowerAction=' "$UPOWER_CONF" | cut -d= -f2) (阈值 $(grep '^PercentageAction=' "$UPOWER_CONF" | cut -d= -f2)%)"
  echo "  运行时生效: $(upower -d 2>/dev/null | awk '/critical-action/{print $2}' || echo 未知)"
fi
[ -f "$LOGIND_DROPIN" ] && echo "  logind 兜底: $(grep '^HandleLidSwitch=' "$LOGIND_DROPIN")"
echo "  mem_sleep:   $(cat /sys/power/mem_sleep 2>/dev/null || echo 未知)"

echo
if ! grep -q 'deep' /sys/power/mem_sleep 2>/dev/null; then
  warn "内核未提供 S3 (deep) 睡眠态, 合盖睡眠可能退化为 s2idle"
fi
if swap_fits_hibernate; then
  warn "检测到 swap 足够大, 若想改用休眠: 修改本脚本与 20-hibernate-fan.sh 后实测"
else
  log "休眠不可用已确认: swap 小于 AnonPages+Shmem, 所有动作均不使用 hibernate"
fi

summary "合盖 → 睡眠 S3 (AC/电池)" \
        "低电量合盖 → 干净关机 (PowerDevil LowBattery)" \
        "低电量 7% → 干净关机 (UPower)" \
        "登录界面合盖 → 睡眠 (logind 兜底)" \
        "回滚: sudo bash fixes/70-sleep-safety.sh --restore"
