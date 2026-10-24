#!/usr/bin/env bash
#
# 修复: 耳机输出在重启后失效 (DA7219 profile 回退成纯输入)
#
# 症状:  重启后插耳机没声音, 排查发现:
#          pactl list cards | grep -A2 'avs_da7219'
#            Active Profile: input:stereo-fallback     ← 只剩输入
#          pactl list short sinks | grep da7219
#            (空)                                      ← 耳机 sink 不存在
#        需要手动执行
#          pactl set-card-profile ... output:stereo-fallback
#        才能临时恢复, 但下次重启又打回原形。
#
# 根因:  WirePlumber 的 profile 恢复逻辑里有一条可用性检查。
#        /usr/share/wireplumber/scripts/device/state-profile.lua 第 46 行:
#
#          if profile.name == profile_name and profile.available ~= "no" then
#
#        本机音频拓扑特殊 —— 扬声器在独立的 MAX98357A 声卡上,
#        DA7219 这块卡**只有**耳机/线缆输出, 没有常开的扬声器通路。
#        于是未插耳机时:
#          analog-output-headphones  availability = not available
#          analog-output-lineout     availability = not available
#          → 整个 output:stereo-fallback profile 被判 available: no
#          → state-profile.lua 跳过你保存的 profile
#          → 回退到 find-best 选中的 input:stereo-fallback
#        结果: 耳机 sink 不复存在, 插上耳机也无处可播。
#
# 方案:  用 WirePlumber 的 device.profile.priority.rules 做兜底。
#        关键在于钩子执行顺序 (见脚本内注释):
#          find-stored-profile   (state-profile.lua)  —— 检查 available, 可能跳过
#          find-preferred-profile(find-preferred-profile.lua) —— **不检查 available**
#          find-best-profile     —— 取可用性最高的
#          apply-profile
#        find-preferred-profile 跑在 stored 之后、best 之前,
#        且**完全不看 available**, 只按名字匹配。
#        所以: 存储的 profile 可用时 → 用你的选择, 规则不介入 (行为不变)
#              存储的 profile 不可用时 → 规则强制选 output, 避免回退到 input
#
# 效果:  重启后耳机 sink 始终存在, 插上耳机即可发声。
#        手动选过的 profile 仍然优先生效 —— 本规则只做"不可用时的兜底",
#        不会覆盖你的显式选择。
#
# A/B 实测 (本机):
#   无此规则: Active Profile=input:stereo-fallback,  DA7219 sink 数 = 0
#   有此规则: Active Profile=output:stereo-fallback, DA7219 sink 数 = 1
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONF_DIR="/etc/wireplumber/wireplumber.conf.d"
CONF_FILE="$CONF_DIR/50-avs-da7219-profile.conf"

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run]

  --dry-run   只打印将要写入的配置, 不改动系统
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

if ! grep -q "CONFIG_SND_SOC_INTEL_AVS_MACH_DA7219" "/boot/config-$KVER" 2>/dev/null; then
  log "内核配置里未见 DA7219 相关项, 继续 (可能为内建或命名不同)"
fi

command -v wireplumber >/dev/null 2>&1 || die "未安装 wireplumber"
ok "wireplumber: $(wireplumber --version 2>/dev/null | tail -1 || echo 已安装)"

WP_VER=$(wireplumber --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
if [ -n "$WP_VER" ]; then
  MAJ=${WP_VER%%.*}; MIN=${WP_VER##*.}
  if [ "$MAJ" -lt 0 ] || { [ "$MAJ" -eq 0 ] && [ "$MIN" -lt 5 ]; }; then
    warn "wireplumber $WP_VER 低于 0.5, 本规则可能不生效 (该机制在 0.5 引入)"
  else
    ok "wireplumber $WP_VER (支持 device.profile.priority.rules)"
  fi
fi

# 钩子脚本是否真如预期 —— 直接验证文件特征, 避免版本差异导致误判
SP="/usr/share/wireplumber/scripts/device/state-profile.lua"
PP="/usr/share/wireplumber/scripts/device/find-preferred-profile.lua"
if [ -f "$SP" ]; then
  if grep -q 'profile.available ~= "no"' "$SP"; then
    ok "确认存在可用性检查 (state-profile.lua): profile.available ~= \"no\""
  else
    warn "state-profile.lua 里未找到预期的可用性检查, 该版本逻辑可能不同"
    log "请人工确认后再继续, 见 $SP"
  fi
else
  warn "找不到 $SP —— 可能是发行版改了脚本布局"
fi
if [ -f "$PP" ]; then
  grep -q 'find-stored-profile' "$PP" && ok "find-preferred-profile 确实排在 stored 之后"
fi

# 当前 profile 状态 (诊断用)
step "当前状态"
if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
  CUR=$(pactl list cards 2>/dev/null | awk '/Name: alsa_card.platform-avs_da7219/{f=1} f&&/Active Profile/{print $NF;exit}')
  if [ -n "$CUR" ]; then
    log "DA7219 当前 profile: $CUR"
    case "$CUR" in
      input:*)
        warn "当前是 input (仅麦克风) —— 这正是本修复要解决的状态"
        log "写入规则后重启 wireplumber 即可修正" ;;
      output*)
        ok "当前已是 output (耳机可用)" ;;
    esac
  else
    log "未检测到 DA7219 声卡 —— 本修复在声卡出现前即已生效, 无需立即验证"
  fi
else
  log "PulseAudio/PipeWire 未运行, 跳过状态查询"
fi

# ---------------------------------------------------------------- 写配置
step "写入 WirePlumber 规则"

write_file "$CONF_FILE" <<'WPEOF'
# 修复: Akali360/Acer Spin 13 重启后耳机输出失效 (DA7219 profile 回退)
#
# 问题: 扬声器在独立的 MAX98357A 声卡上, DA7219 卡只有耳机/线缆输出。
#       未插耳机时 ACP 把 output:stereo-fallback 判为 available=no,
#       state-profile.lua 的 `profile.available ~= "no"` 检查因此跳过
#       用户保存的 profile, 回退到 input:stereo-fallback,
#       导致耳机 sink 不存在。
#
# 原理: device/profile/find-preferred-profile.lua 排在
#       find-stored-profile 之后、find-best-profile 之前,
#       且**不检查 profile 可用性**, 只按名字匹配。
#       故: 存储 profile 可用时 → 用用户的显式选择, 本规则不介入;
#           存储 profile 不可用时 → 本规则强制选中 output, 避免回退。
#
# 本规则不会覆盖用户手动设置过的可用 profile。
device.profile.priority.rules = [
  {
    matches = [
      { device.name = "~alsa_card.platform-avs_da7219.*" }
    ]
    actions = {
      update-props = {
        priorities = "[ \"output:stereo-fallback\", \"output:stereo-fallback+input:stereo-fallback\" ]"
      }
    }
  }
]
WPEOF

# ---------------------------------------------------------------- 重载
step "重载 WirePlumber 使规则生效"

if is_dry_run; then
  log "[dry-run] 将执行: systemctl --user restart wireplumber.service"
else
  # 需在用户会话里重启; 通过 loginctl 定位活跃会话
  TARGET_USER="${SUDO_USER:-$USER}"
  log "目标用户: $TARGET_USER"
  if runuser -u "$TARGET_USER" -- systemctl --user restart wireplumber.service 2>/dev/null; then
    ok "wireplumber 已重启"
    sleep 3
  else
    warn "无法自动重启 (可能不在图形会话中)"
    log "请在桌面会话里手动执行: systemctl --user restart wireplumber.service"
  fi
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统"
  exit 0
fi

# 语法自检 (花括号/中括号平衡)
if [ -f "$CONF_FILE" ]; then
  python3 - "$CONF_FILE" <<'PY' || die "配置文件语法不平衡"
import re, sys
t = re.sub(r'#.*', '', open(sys.argv[1]).read())
assert t.count('{') == t.count('}'), "花括号不平衡"
assert t.count('[') == t.count(']'), "中括号不平衡"
PY
  ok "配置文件语法平衡"
fi

TARGET_USER="${SUDO_USER:-$USER}"
NEW_PROFILE=$(runuser -u "$TARGET_USER" -- pactl list cards 2>/dev/null \
  | awk '/Name: alsa_card.platform-avs_da7219/{f=1} f&&/Active Profile/{print $NF;exit}')
SINK_N=$(runuser -u "$TARGET_USER" -- pactl list short sinks 2>/dev/null | grep -c da7219 || true)

echo
if [ -n "$NEW_PROFILE" ]; then
  log "DA7219 当前 profile: $NEW_PROFILE"
  log "DA7219 sink 数量:    $SINK_N"
  echo
  case "$NEW_PROFILE" in
    output*)
      if [ "$SINK_N" -ge 1 ]; then
        ok "修复生效 —— 耳机输出 sink 已存在"
        echo
        echo "  验证方法: 插上耳机后播放声音:"
        echo "    pactl set-default-sink alsa_output.platform-avs_da7219.21.auto.stereo-fallback"
        echo "    pw-play /usr/share/sounds/alsa/Front_Center.wav"
        echo
        echo "  查看可用输出设备:"
        echo "    pactl list short sinks"
      else
        warn "profile 已是 output 但未见 sink, 请检查 WirePlumber 日志:"
        echo "    journalctl --user -u wireplumber -n 50"
      fi ;;
    input*)
      err "仍回退到 input —— 规则未生效"
      echo "  排查步骤:"
      echo "    1. journalctl --user -u wireplumber -n 50 | grep -i preferred"
      echo "    2. 确认配置被读取: wireplumber --dump-config | grep -A5 priority"
      echo "    3. 确认声卡名匹配: pactl list cards | grep 'alsa_card.platform-avs'"
      exit 1 ;;
    *)
      warn "profile 值异常: $NEW_PROFILE" ;;
  esac
else
  warn "未检测到 DA7219 声卡 (可能尚未加载)"
  log "规则已写入, 声卡出现时会自动应用"
  echo
  echo "  稍后验证: pactl list cards | grep -A2 avs_da7219"
fi
