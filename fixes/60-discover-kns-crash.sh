#!/usr/bin/env bash
#
# 修复: KDE Discover 一打开就闪退 (SIGSEGV)
#
# 症状:  点开 Discover 窗口刚出现就消失, coredumpctl 里是一串
#           SIGSEGV  plasma-discover
#        连续打开几次会重复产生 core dump。
#
# 根因:  两个独立缺陷撞在一起, 崩溃点在 PackageKit 后端, 但导火索是 KNS:
#
#   1) Discover 的 KNS 后端 (kns-backend.so) 启动时会去
#        https://autoconfig.kde.org/ocs/providers.xml
#      拉"内容提供者"列表。在部分网络 (国内直连 / 企业代理) 该域名不可达,
#      于是每一个 .knsrc (壁纸/挂件/图标/GTK 主题/字体...) 都判定为
#      "无效的后端" 并逐个 self-invalidate:
#        invalid kns backend! ".../plasmoids.knsrc"
#        Invalidated backend, deactivating "plasmoids.knsrc"
#        org.kde.plasma.libdiscover: Discarding invalid backend "plasmoids.knsrc"
#
#   2) Discover 的 PackageKit 后端在 Browsing 页会发起一次上百个包名的
#      异步 resolve。KNS 后端成批 "Discarding" 时资源模型被重置,
#      而这次 resolve 的 PKResultsStream 仍挂在协程里 —— 典型的
#      use-after-free: 协程恢复时对已释放的 stream 调用 sendResources(),
#      读到残留的 backend 指针, 在
#        PackageKitBackend::resolvePackages() 里解引用崩溃。
#
#      实测 (gdb, 带 Debian dbgsym):
#        #8 PKResultsStream::sendResources()   this=0x5628…6180  (已释放并复用)
#        #7 PackageKitBackend::resolvePackages() this=0x56286b000067  (垃圾指针)
#      崩溃由时序决定, 因此表现为"有时能开、有时闪退", 与预热缓存无关。
#
# 方案:  停用 Discover 专用的 KNS 后端插件 (kns-backend.so)。
#        · 触发源消失 → PackageKit 的异步查询不再被打断, 崩溃不再发生
#        · PackageKit(apt) / Flatpak / 固件(fwupd) 后端全部保留, 功能不受影响
#        · 只有 Discover 内的"获取新内容"分类消失 —— 而它在这些网络下
#          本来就是 100% 失效 (providers.xml 拉不到), 等于零损失
#        · 系统设置 / KWin 等其它程序的"获取新内容"用的是 KNSCore 本身,
#          不使用这个插件, 完全不受影响
#
#        用 dpkg-divert 而不是 mv/rm: 转移记录写进 dpkg 数据库,
#        将来 apt 升级 plasma-discover 时新插件会自动落到 .disabled,
#        不会把修复覆盖掉。
#
# 说明:  上游 Display 的 use-after-free 仍未修 (Plasma 6.3.6)。
#        等 KDE 修好后可用 --restore 恢复 KNS 后端。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

RESTORE=0
TEST=0
TEST_RUNS=3
TEST_SECS=20

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run] [--restore] [--test]

  --dry-run    只打印将执行的操作, 不改动系统
  --restore    恢复 Discover 的 KNS 后端 (上游修好该崩溃后使用)
  --test       应用后自动做稳定性测试: 连续启动 Discover 数次, 统计是否闪退
               (会短暂弹出 Discover 窗口, 需要图形会话)
  -h, --help   显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --restore) RESTORE=1 ;;
    --test)    TEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

require_root

# ---------------------------------------------------------------- 探测
# 插件路径以 dpkg 的文件清单为准 (即使已 divert, 清单里仍是原始路径)
find_kns_so() {
  local p
  p=$(dpkg-query -L plasma-discover 2>/dev/null \
        | grep -E '/discover/kns-backend\.so$' | sed -n '1p' || true)
  if [ -z "$p" ]; then
    p=$(find /usr/lib /usr/lib64 -type f -path '*/discover/kns-backend.so' 2>/dev/null \
          | sed -n '1p' || true)
  fi
  printf '%s\n' "$p"
}

KNS_SO=$(find_kns_so)

# 稳定性测试: 以"调用者身份 + 其图形会话"启动 Discover 若干次, 统计是否 SIGSEGV。
# 以 root 直接跑无法连接 Wayland/X, 故必须降权并带上会话环境变量。
run_selftest() {
  step "稳定性测试 ($TEST_RUNS 次 × ${TEST_SECS}s)"
  local run_user run_uid rt_dir w_disp rc crash=0 i
  run_user="${SUDO_USER:-$USER}"
  run_uid=$(id -u "$run_user" 2>/dev/null || true)
  rt_dir="/run/user/${run_uid:-0}"
  w_disp=""
  if [ -d "$rt_dir" ]; then
    w_disp=$(ls "$rt_dir" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sed -n '1p' || true)
  fi
  if [ -z "$run_uid" ] || [ ! -d "$rt_dir" ] || [ -z "$w_disp" ]; then
    warn "当前无可用的图形会话 (缺 $rt_dir 或 wayland-*), 跳过自动测试"
    log "请手动打开一次 Discover 确认不再闪退"
    return 0
  fi
  for i in $(seq 1 "$TEST_RUNS"); do
    rc=0
    set +e
    sudo -u "$run_user" env \
      XDG_RUNTIME_DIR="$rt_dir" WAYLAND_DISPLAY="$w_disp" \
      XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE \
      timeout "$TEST_SECS" plasma-discover --mode Browsing \
      >/tmp/discover-selftest.log 2>&1
    rc=$?
    set -e
    case "$rc" in
      139) printf '  第 %d 次: 崩溃 (SIGSEGV)\n' "$i"; crash=$((crash+1)) ;;
      124) printf '  第 %d 次: 存活 %ss\n' "$i" "$TEST_SECS" ;;
      *)   printf '  第 %d 次: 退出码 %s\n' "$i" "$rc" ;;
    esac
  done
  if [ "$crash" -eq 0 ]; then
    ok "$TEST_RUNS 次全部未崩溃"
  else
    warn "$crash/$TEST_RUNS 次仍崩溃 —— 请反馈, 可能还有其他触发条件"
    return 1
  fi
}

if ! dpkg-query -W -f='${Status}' plasma-discover 2>/dev/null | grep -q 'install ok installed'; then
  warn "未安装 plasma-discover, 本机无需此修复 —— 跳过"
  summary "跳过 (未安装 Discover)"
  exit 0
fi

[ -n "$KNS_SO" ] || die "找不到 kns-backend.so (plasma-discover 的文件清单里没有), 本脚本不适用"
KNS_DISABLED="${KNS_SO}.disabled"

step "诊断"
echo "  Discover 版本: $(dpkg-query -W -f='${Version}' plasma-discover 2>/dev/null)"
echo "  KNS 插件:      $KNS_SO"
echo "  插件状态:      $([ -e "$KNS_SO" ] && echo '存在 (KNS 后端会在启动时激活)' || echo '不存在 (已停用)')"
echo "  转移记录:      $(dpkg-divert --list "$KNS_SO" 2>/dev/null | sed -n '1p' || true)"
echo
echo "  崩溃历史 (最近 5 条):"
if command -v coredumpctl >/dev/null 2>&1; then
  coredumpctl list --no-pager 2>/dev/null | grep -i 'plasma-discover' | tail -5 \
    | sed 's/^/    /' || echo "    (无)"
else
  echo "    (无 coredumpctl)"
fi

# ---------------------------------------------------------------- 恢复
if [ "$RESTORE" -eq 1 ]; then
  step "恢复 KNS 后端"
  if [ ! -e "$KNS_DISABLED" ] && [ -e "$KNS_SO" ]; then
    ok "KNS 后端本来就在原位, 无需恢复"
    summary "无需改动"
    exit 0
  fi
  if is_dry_run; then
    log "[dry-run] 将执行: dpkg-divert --remove --rename \"$KNS_SO\""
    summary "dry-run 完成, 未改动系统"
    exit 0
  fi
  dpkg-divert --remove --rename "$KNS_SO" 2>&1 | sed 's/^/  /'
  if [ -e "$KNS_SO" ] && [ ! -e "$KNS_DISABLED" ]; then
    ok "已恢复 $KNS_SO"
    warn "注意: 若 providers.xml 仍不可达, Discover 可能再次闪退"
  else
    die "恢复后状态异常, 请检查: ls -la $(dirname "$KNS_SO")"
  fi
  summary "已恢复 KNS 后端"
  exit 0
fi

# ---------------------------------------------------------------- 应用
step "停用 Discover 的 KNS 后端插件"

if [ ! -e "$KNS_SO" ]; then
  if [ -e "$KNS_DISABLED" ]; then
    ok "已停用 (跳过): $KNS_DISABLED"
    [ "$TEST" -eq 1 ] && run_selftest
    summary "已是目标状态"
    exit 0
  fi
  die "$KNS_SO 不存在, 也没有 $KNS_DISABLED —— 状态异常, 请重装 plasma-discover"
fi

if is_dry_run; then
  log "[dry-run] 将执行:"
  log "  dpkg-divert --add --rename --divert \"$KNS_DISABLED\" \"$KNS_SO\""
  echo
  log "[dry-run] 效果: Discover 只剩 PackageKit(apt) / Flatpak / fwupd 后端"
  summary "dry-run 完成, 未改动系统"
  exit 0
fi

dpkg-divert --add --rename --divert "$KNS_DISABLED" "$KNS_SO" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------- 验证
step "验证"

[ -e "$KNS_SO" ] && die "原插件仍存在, 停用失败"
[ -e "$KNS_DISABLED" ] || die "未找到 $KNS_DISABLED, 停用失败"
ok "插件已转移到: $KNS_DISABLED"

if dpkg-divert --list "$KNS_SO" 2>/dev/null | grep -q 'diversion of'; then
  ok "dpkg 转移记录已登记 (apt 升级 plasma-discover 后依然生效)"
else
  warn "未查到 dpkg 转移记录, 升级后可能失效"
fi

echo "  其余后端:"
for s in flatpak fwupd packagekit; do
  [ -e "$(dirname "$KNS_SO")/${s}-backend.so" ] && echo "    ✓ ${s}-backend.so"
done

# ---------------------------------------------------------------- 可选测试
[ "$TEST" -eq 1 ] && run_selftest

summary "已停用 Discover 的 KNS 后端" \
        "PackageKit(apt) / Flatpak / fwupd 后端保持可用" \
        "如需恢复: sudo bash fixes/60-discover-kns-crash.sh --restore"
