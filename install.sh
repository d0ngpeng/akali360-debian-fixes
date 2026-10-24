#!/usr/bin/env bash
#
# akali360-debian-fixes — 总安装入口
#
# 针对 Google Akali360 (Acer Spin 13) 刷 MrChromebox coreboot 后
# 安装 Debian 的一系列驱动/行为修复。
#
# 用法:
#   ./install.sh                  # 交互式选择
#   ./install.sh --all            # 全部应用 (推荐首次)
#   ./install.sh --only 20,30     # 只应用指定编号
#   ./install.sh --dry-run --all  # 预览, 不改动系统
#   ./install.sh --list           # 列出可用修复
#   ./install.sh --status         # 查看当前各项状态
#   ./install.sh --rollback <编号>  回滚某项 (用最近的 .bak)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

ALL_FIXES=(
  "10:avs-sound:扬声器无声 (MAX98357A 驱动缺失)"
  "20:hibernate-fan:休眠死机/风扇狂转 (coreboot S4 缺陷)"
  "30:da7219-headphone:重启后耳机输出失效 (profile 回退)"
  "40:sdcard-automount:SD 卡开机自动挂载"
  "50:smartd:smartmontools 开机报错 (无 SMART 设备)"
)

usage() {
  cat <<EOF
${C_BLD}akali360-debian-fixes${C_RESET} — Google Akali360 (Acer Spin 13) Debian 修复集

${C_BLD}用法:${C_RESET}
  $0                    交互式选择要应用的修复
  $0 --all              应用全部修复 (首次推荐)
  $0 --only 10,30       只应用指定编号, 逗号分隔
  $0 --dry-run --all    预览将执行的操作, 不改动系统
  $0 --list             列出全部修复项
  $0 --status           查看每项的当前状态
  $0 --rollback <编号>  用最近备份回滚某项
  $0 -h, --help         显示本帮助

${C_BLD}修复项:${C_RESET}
EOF
  for it in "${ALL_FIXES[@]}"; do
    IFS=: read -r num name desc <<<"$it"
    printf '  %-4s %-22s %s\n' "$num" "$name" "$desc"
  done
  cat <<EOF

${C_BLD}说明:${C_RESET}
  · 所有脚本均幂等, 可重复运行; 改配置前自动创建 .bak.$(date +%Y)MMDD 备份
  · 所有机器相关值 (swap UUID / 盘符 / 挂载点) 均运行时自动探测, 无硬编码
  · 需要 root 权限 (自动调用 sudo)
  · 建议先 --dry-run --all 预览
EOF
}

# ---------------------------------------------------------------- 状态查询
show_status() {
  printf '\n%s当前状态%s\n' "$C_BLD" "$C_RESET"
  printf '  %-4s %-22s %s\n' "编号" "名称" "状态"
  printf '  %s\n' "─────────────────────────────────────────────────────────────"

  # 10 扬声器
  if grep -q "MAX98357A" /proc/asound/cards 2>/dev/null; then
    s="✓ 已修复 (声卡已注册)"; c=$C_GRN
  elif [ -f "/lib/modules/$(uname -r)/kernel/sound/soc/intel/avs/boards/snd-soc-avs-max98357a.ko" ]; then
    s="△ 模块已装但声卡未出现"; c=$C_YLW
  else
    s="✗ 未修复"; c=$C_RED
  fi
  printf '  %-4s %-22s %b%s%b\n' "10" "avs-sound" "$c" "$s" "$C_RESET"

  # 20 休眠
  # 注: /boot/grub/grub.cfg 通常是 0600 root:root, 非 root 读不到,
  #     故以 /etc/default/grub (update-grub 的源文件, 通常 0644) 为准。
  if [ -f /etc/systemd/sleep.conf.d/hibernate.conf ] \
     && grep -q "^HibernateMode=shutdown" /etc/systemd/sleep.conf.d/hibernate.conf; then
    if grep -q "resume=UUID=" /etc/default/grub 2>/dev/null; then
      s="✓ 已修复 (shutdown + resume)"; c=$C_GRN
    else
      s="△ 已设 shutdown 但缺 resume 参数"; c=$C_YLW
    fi
  else
    s="✗ 未修复"; c=$C_RED
  fi
  printf '  %-4s %-22s %b%s%b\n' "20" "hibernate-fan" "$c" "$s" "$C_RESET"

  # 30 耳机
  if [ -f /etc/wireplumber/wireplumber.conf.d/50-avs-da7219-profile.conf ]; then
    P=$(pactl list cards 2>/dev/null | awk '/avs_da7219/{f=1} f&&/Active Profile/{print $NF;exit}' || true)
    if [ -z "$P" ]; then
      s="✓ 规则已装 (声卡当前未激活)"; c=$C_GRN
    elif [[ "$P" == output* ]]; then
      s="✓ 已修复 (profile=$P)"; c=$C_GRN
    else
      s="△ 规则已装但 profile=$P (重启 wireplumber?)"; c=$C_YLW
    fi
  else
    s="✗ 未修复"; c=$C_RED
  fi
  printf '  %-4s %-22s %b%s%b\n' "30" "da7219-headphone" "$c" "$s" "$C_RESET"

  # 40 SD 卡
  SDM=$(awk '$1 ~ /^UUID=/ && $2 ~ /\/media\// {print $2}' /etc/fstab 2>/dev/null | head -1)
  if [ -n "$SDM" ]; then
    if findmnt -n "$SDM" >/dev/null 2>&1; then
      s="✓ 已修复 (挂载于 $SDM)"; c=$C_GRN
    else
      s="△ fstab 有条目 ($SDM) 但当前未挂载"; c=$C_YLW
    fi
  else
    s="✗ 未修复"; c=$C_RED
  fi
  printf '  %-4s %-22s %b%s%b\n' "40" "sdcard-automount" "$c" "$s" "$C_RESET"

  # 50 smartd
  if ! systemctl is-enabled smartmontools.service >/dev/null 2>&1; then
    s="✓ 已禁用 (无 SMART 设备)"; c=$C_GRN
  elif systemctl is-active smartmontools.service >/dev/null 2>&1; then
    s="✓ 服务运行中"; c=$C_GRN
  else
    s="✗ 未修复 (服务启用但失败)"; c=$C_RED
  fi
  printf '  %-4s %-22s %b%s%b\n' "50" "smartd" "$c" "$s" "$C_RESET"

  echo
  printf '  失败单元: %s 个\n' "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  printf '  内核: %s\n' "$(uname -r)"
  # 机型: 用 /sys/class/dmi/id (无需特权), dmidecode 需 root
  printf '  机型: %s %s\n' "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" \
                         "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo
}

# ---------------------------------------------------------------- 回滚
rollback() {
  local num="$1"
  require_root
  step "回滚修复 $num"
  local f
  f=$(find "$ROOT/fixes" -name "$num-*.sh" | head -1)
  [ -n "$f" ] || die "找不到编号 $num 的修复"
  log "每个修复会改动的文件 (最近的 .bak.* 即回滚源):"
  echo
  case "$num" in
    10)
      echo "  · /lib/modules/$(uname -r)/kernel/sound/soc/intel/avs/boards/snd-soc-avs-max98357a.ko"
      echo "  · /etc/modules-load.d/avs-max98357a.conf"
      echo
      echo "回滚命令:"
      echo "  sudo rm -f /etc/modules-load.d/avs-max98357a.conf"
      echo "  sudo rm -f /lib/modules/\$(uname -r)/kernel/sound/soc/intel/avs/boards/snd-soc-avs-max98357a.ko"
      echo "  sudo depmod -a"
      ;;
    20)
      echo "  · /etc/systemd/sleep.conf.d/hibernate.conf"
      echo "  · /etc/default/grub          (备份: $(ls /etc/default/grub.bak.* 2>/dev/null | tail -1 || echo 无))"
      echo "  · /etc/initramfs-tools/conf.d/resume"
      echo
      echo "回滚命令:"
      echo "  sudo rm -f /etc/systemd/sleep.conf.d/hibernate.conf"
      echo "  sudo cp /etc/default/grub.bak.* /etc/default/grub   # 取最新备份"
      echo "  sudo update-grub && sudo update-initramfs -u"
      ;;
    30)
      echo "  · /etc/wireplumber/wireplumber.conf.d/50-avs-da7219-profile.conf"
      echo
      echo "回滚命令:"
      echo "  sudo rm -f /etc/wireplumber/wireplumber.conf.d/50-avs-da7219-profile.conf"
      echo "  systemctl --user restart wireplumber.service"
      ;;
    40)
      echo "  · /etc/fstab  (备份: $(ls /etc/fstab.bak.* 2>/dev/null | tail -1 || echo 无))"
      echo
      echo "回滚命令:"
      echo "  sudo cp /etc/fstab.bak.* /etc/fstab   # 取最新备份, 请先 diff 确认"
      echo "  sudo systemctl daemon-reload"
      ;;
    50)
      echo "  · smartmontools.service 启用状态 (无文件改动)"
      echo
      echo "回滚命令:"
      echo "  sudo systemctl enable --now smartmontools.service"
      ;;
  esac
}

# ---------------------------------------------------------------- 执行
DRY_RUN=0; MODE=""; ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)      MODE=all; shift ;;
    --only)     MODE=only; ONLY="${2:-}"; [ -n "$ONLY" ] || die "--only 需要编号列表"; shift 2 ;;
    --list)     MODE=list; shift ;;
    --status)   MODE=status; shift ;;
    --rollback) MODE=rollback; ONLY="${2:-}"; [ -n "$ONLY" ] || die "--rollback 需要编号"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  list)
    printf '\n可用修复项:\n'
    for it in "${ALL_FIXES[@]}"; do
      IFS=: read -r num name desc <<<"$it"
      printf '  %-4s %-22s %s\n' "$num" "$name" "$desc"
    done
    echo
    exit 0 ;;
  status) show_status; exit 0 ;;
  rollback) rollback "$ONLY"; exit 0 ;;
esac

# 交互式选择
select_fixes() {
  echo
  printf '%s选择要应用的修复项%s (回车=全部, 编号用空格分隔, q=退出)\n\n' "$C_BLD" "$C_RESET"
  local i=1
  for it in "${ALL_FIXES[@]}"; do
    IFS=: read -r num name desc <<<"$it"
    printf '  %d) %-4s %-22s %s\n' "$i" "$num" "$name" "$desc"
    i=$((i+1))
  done
  echo
  read -r -p "选择 [1-$((i-1)) 或回车=全部]: " ans
  case "$ans" in
    q|Q) log "退出"; exit 0 ;;
    ""|all|a|A) MODE=all; return ;;
  esac
  MODE=only
  ONLY=""
  for n in $ans; do
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le $((i-1)) ]; then
      IFS=: read -r num _ <<<"${ALL_FIXES[$((n-1))]}"
      ONLY="$ONLY,$num"
    else
      die "无效选择: $n"
    fi
  done
  ONLY="${ONLY#,}"
}

[ -n "$MODE" ] || select_fixes

# 组装要跑的脚本
declare -a TARGETS=()
if [ "$MODE" = "all" ]; then
  for it in "${ALL_FIXES[@]}"; do IFS=: read -r num _ <<<"$it"; TARGETS+=("$num"); done
else
  IFS=',' read -ra parts <<<"$ONLY"
  for p in "${parts[@]}"; do
    p=$(echo "$p" | tr -d ' ')
    [ -n "$p" ] || continue
    if find "$ROOT/fixes" -name "$p-*.sh" | grep -q .; then
      TARGETS+=("$p")
    else
      die "未知修复编号: $p   (用 --list 查看可用项)"
    fi
  done
fi

[ ${#TARGETS[@]} -gt 0 ] || die "没有选择任何修复"

step "执行计划"
log "模式:   $([ "$DRY_RUN" -eq 1 ] && echo 'dry-run (预览)' || echo '实际执行')"
log "目标:   ${TARGETS[*]}"
log "内核:   $KVER"
log "机型:   $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 未知)"

if is_dry_run; then
  echo
  warn "dry-run 模式 —— 不会改动系统"
fi

FAIL_LIST=()
for num in "${TARGETS[@]}"; do
  script=$(find "$ROOT/fixes" -name "$num-*.sh" | head -1)
  echo
  printf '%s╔══════════════════════════════════════════════╗%s\n' "$C_BLD" "$C_RESET"
  printf '%s║  运行  %s%s\n' "$C_BLD" "$(basename "$script")" "$C_RESET"
  printf '%s╚══════════════════════════════════════════════╝%s\n' "$C_BLD" "$C_RESET"

  ARGS=()
  is_dry_run && ARGS+=(--dry-run)

  if bash "$script" "${ARGS[@]+"${ARGS[@]}"}"; then
    ok "完成: $num"
  else
    err "失败: $num"
    FAIL_LIST+=("$num")
  fi
done

# ---------------------------------------------------------------- 总结
echo
printf '%s%s%s\n' "$C_BLD" "══════════════ 执行总结 ══════════════" "$C_RESET"
for num in "${TARGETS[@]}"; do
  if [[ " ${FAIL_LIST[*]-} " == *" $num "* ]]; then
    printf '  %b✗%s %s\n' "$C_RED" "$C_RESET" "$num"
  else
    printf '  %b✓%s %s\n' "$C_GRN" "$C_RESET" "$num"
  fi
done

echo
if [ ${#FAIL_LIST[@]} -eq 0 ]; then
  if is_dry_run; then
    ok "dry-run 预览完成, 未改动系统"
    echo "  去掉 --dry-run 即可实际执行"
  else
    ok "全部完成"
    cat <<'EOF'

  重要提醒:
    · 20 (休眠) 改动后建议重启一次使内核参数与 initramfs 生效:
        sudo reboot
    · 重启后再核对状态:
        ./install.sh --status
    · 20 的行为变化: 休眠后机器完全关机, 需按电源键开机恢复
    · 若某项出错, 查看对应备份:  ls -la /etc/**/*.bak.*
EOF
  fi
  echo
  exit 0
else
  err "以下项失败: ${FAIL_LIST[*]}"
  echo "  单独重跑:  sudo $0 --only ${FAIL_LIST[*]}"
  echo "  回滚某项:  sudo $0 --rollback <编号>"
  exit 1
fi
