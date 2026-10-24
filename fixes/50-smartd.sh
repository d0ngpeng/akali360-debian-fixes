#!/usr/bin/env bash
#
# 修复: smartmontools.service 每次开机都失败
#
# 症状:  systemctl --failed 显示
#          × smartmontools.service - ... SMART Daemon
#            Result: exit-code   Status: "No devices to monitor"
#        每次开机都置为 failed, 让人误以为硬盘出了问题。
#
# 根因:  smartd 配置里有 DEVICESCAN, 期望扫描到可监控设备并退出码 0;
#        但扫描结果为空时它以 exit 17 ("No devices to monitor") 退出,
#        systemd 视为失败。
#
#        本机 (Chromebook 类) 无 SMART 设备, 属于"配置与硬件不匹配":
#          · 内置存储是 eMMC → 不是 ATA/SCSI, 本版 smartctl 不支持
#            (需 smartctl -d mmc, 但 Debian 默认编译未启用该类型)
#          · 若有 USB 读卡器/U盘 → 不支持 SAT 直通, 同样扫不到
#          · 没有传统 SATA/NVMe 硬盘
#        结论: 不是磁盘坏了, 是"这台机器根本没有可监控的盘"。
#
# 方案:  禁用该服务 —— 既然无设备可监控, 让它运行只是制造假警报。
#        若将来加装了 SATA/NVMe 硬盘, 重新 enable 即可。
#
#        另一条路 (本脚本不采用, 供参考):
#          修改 /etc/smartd.conf, 把 DEVICESCAN 换成显式设备列表。
#          对本机无意义 —— 显式列表同样是空的。
#
# eMMC 健康怎么查?  用 mmc-utils (读 EXT_CSD 寄存器):
#     sudo apt install mmc-utils
#     sudo mmc extcsd read /dev/mmcblk0 | grep -iE 'LIFE_TIME|PRE_EOL'
#   LIFE_TIME_EST_TYP_A/B: 1=0-10% ... 10=90-100% (越小越新)
#   PRE_EOL_INFO: 1=正常 2=警告 3=紧急
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SVC="smartmontools.service"

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run] [--restore]

  --dry-run    只打印将执行的操作, 不改动系统
  --restore    恢复服务 (重新 enable, 适用于加装了可监控硬盘后)
  -h, --help   显示本帮助
EOF
}

RESTORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --restore)  RESTORE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

require_root

command -v smartctl >/dev/null 2>&1 \
  || die "未安装 smartmontools, 无需处理: sudo apt install smartmontools 后才有此服务"
ok "smartmontools 已安装: $(smartctl -V 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 诊断
step "诊断: 确实无 SMART 设备?"

# 权威判定 = 完全复现 smartd 自身的行为。
#   之前用"逐设备试 -d 类型"会产生假阳性:
#     smartctl -d scsi -i  /dev/sda  → 返回序列号 (仅 SCSI inquiry, 非 SMART)
#     smartctl -d scsi -H  /dev/sda  → "SMART Health Status: OK"
#         但伴随 "query_cmd_support response too short" (USB 读卡器的通用回复)
#     smartctl -d sat  -H  /dev/sda  → "unsupported scsi opcode"
#         说明该读卡器**不支持 SAT**, 无法透传真实 SMART 数据
#   而 smartd 用的是 DEVICESCAN → 等价于 smartctl --scan, 结果为空。
#   故此处直接调用 smartd 自己做一次前台检查, 得到与开机时一致的结论。
log "调用 smartd 自身做配置检查 (与开机运行同一逻辑, 仅检查后退出)..."
SMARTD_OUT=$(smartd -q onecheck 2>&1) || SMARTD_RC=$?
SMARTD_RC=${SMARTD_RC:-0}
SCAN_OUT=$(smartctl --scan 2>/dev/null || true)

printf '%s\n' "$SMARTD_OUT" | sed 's/^/    /'

echo
if [ "$SMARTD_RC" -eq 0 ] && [ -n "$SCAN_OUT" ]; then
  warn "smartd 报告可监控设备:"
  printf '%s\n' "$SCAN_OUT" | sed 's/^/    /'
  echo
  log "注意: 禁用服务会失去这些设备的健康告警。"
  if is_dry_run; then
    warn "[dry-run] 若真实执行将在此询问确认。已取消自动禁用。"
    summary "dry-run 完成, 未改动系统 (检测到可监控设备, 需人工确认)"
    exit 0
  fi
  read -r -p "仍要禁用 smartd? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) log "继续禁用" ;;
    *) log "已取消, 保留服务"; exit 0 ;;
  esac
else
  case "$SMARTD_RC" in
    17) ok "确认: smartd exit 17 = 'No devices to monitor' (与开机失败一致)" ;;
    *)  log "smartd 检查退出码: $SMARTD_RC" ;;
  esac
  log "eMMC 与 USB 读卡器均不满足条件:"
  cat <<'EOF'
      · 内置 eMMC (DA4064)  非 ATA/SCSI, 本版 smartctl 未启用 mmc 类型
      · USB SD 读卡器       仅支持 SCSI inquiry, 不支持 SAT 直通,
                           因此无法读取真实 SMART 属性
  结论: 不是磁盘故障, 是"这台机器根本没有可监控的 SMART 设备"。
EOF
fi

# ---------------------------------------------------------------- 执行
if [ "$RESTORE" -eq 1 ]; then
  step "恢复 smartd 服务"
  if is_dry_run; then
    log "[dry-run] 将执行: systemctl enable --now $SVC"
  else
    systemctl enable --now "$SVC" && ok "已启用并启动"
  fi
else
  step "禁用 smartd"
  if is_dry_run; then
    log "[dry-run] 将执行: systemctl disable --now $SVC && systemctl reset-failed $SVC"
  else
    systemctl disable --now "$SVC" 2>/dev/null || warn "disable 时有告警 (可能服务已停止)"
    ok "已禁用并停止"
    # 清除已记录的失败状态, 让 systemctl --failed 立刻干净
    systemctl reset-failed "$SVC" 2>/dev/null || true
    ok "已清除失败状态"
  fi
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统"
  exit 0
fi

echo "  服务状态:  $(systemctl is-active "$SVC" 2>/dev/null) / $(systemctl is-enabled "$SVC" 2>/dev/null)"
echo "  失败单元数: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"

echo
if [ "$(systemctl --failed --no-legend 2>/dev/null | wc -l)" -eq 0 ]; then
  ok "systemctl --failed 已无失败单元"
  echo
  if [ "$RESTORE" -eq 0 ]; then
    log "eMMC 健康监测改用 mmc-utils:"
    cat <<'EOF'
      sudo apt install mmc-utils
      sudo mmc extcsd read /dev/mmcblk0 | grep -iE 'LIFE_TIME|PRE_EOL'
        LIFE_TIME_EST_TYP_A/B : 1=0-10% ... 10=90-100%, 值越小越新
        PRE_EOL_INFO          : 1=正常  2=警告  3=紧急
EOF
  else
    log "已恢复 —— 若再次出现 'No devices to monitor', 说明确实无设备"
  fi
else
  warn "仍有失败单元:"
  systemctl --failed --no-legend | sed 's/^/    /'
  echo "  与本修复无关的失败项请另行排查"
fi
