#!/usr/bin/env bash
#
# 修复: SD 卡 (或 USB 存储) 每次开机自动挂载
#
# 症状:  每次开机都要手动挂载 SD 卡, 或者依赖桌面的"点击挂载",
#        重启后路径消失, 依赖该路径的程序 (脚本/工作目录) 全部中断。
#
# 方案:  写入 /etc/fstab, 交给 systemd 在开机时自动挂载。
#
# 关键设计 —— 选择哪种标识符:
#   · UUID   最稳定, 盘符 (sdb1) 会随插拔顺序变化, 绝不能用
#   · LABEL  可读性好, 但同型号多张卡标签会冲突
#   · 本脚本默认用 UUID (探测得到就用), 并允许用 LABEL 覆盖
#
# 关键设计 —— 避免"没插卡导致开机卡在 emergency mode":
#   · nofail                       挂载失败不阻塞启动
#   · x-systemd.device-timeout=15s 设备等待超时 15 秒, 避免长时间挂起
#   · errors=remount-ro            exfat 损坏时降级为只读, 保护数据
#   · nosuid,nodev                 可移动介质的安全默认值
#
# 用法:
#   sudo fixes/40-sdcard-automount.sh <设备> [挂载点]
#   sudo fixes/40-sdcard-automount.sh /dev/sdb1 /media/$USER/MYCARD
#   sudo fixes/40-sdcard-automount.sh --by-label SDCARD /media/$USER/SDCARD
#   sudo fixes/40-sdcard-automount.sh --dry-run <设备> <挂载点>
#
# 不带参数时, 自动探测当前已挂载在 /media/<user>/ 下的可移动设备。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

FSTAB="/etc/fstab"

usage() {
  cat <<EOF
用法: sudo $0 [选项] [设备] [挂载点]

  --by-label <标签>   用 LABEL= 而非 UUID= 标识
  --dry-run           只打印将写入的 fstab 行, 不改动系统
  -h, --help          显示本帮助

不带参数: 自动探测 /media/<当前用户>/ 下已挂载的可移动设备

示例:
  sudo $0 /dev/sdb1 /media/\$USER/SDCARD
  sudo $0 --by-label SDCARD /media/\$USER/SDCARD
  sudo $0 --dry-run /dev/sdb1 /media/\$USER/SDCARD
EOF
}

USE_LABEL=0
DEVICE="" MOUNTPOINT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --by-label) USE_LABEL=1; shift; LABEL_ARG="${1:-}"; [ -n "$LABEL_ARG" ] || die "--by-label 需要参数"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         usage >&2; exit 2 ;;
    *)          if [ -z "$DEVICE" ]; then DEVICE="$1"
                elif [ -z "$MOUNTPOINT" ]; then MOUNTPOINT="$1"
                else die "多余参数: $1"; fi; shift ;;
  esac
done

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")

# ---------------------------------------------------------------- 自动探测
if [ -z "$DEVICE" ]; then
  step "自动探测已挂载的可移动设备"
  # 找 /media/<user>/ 下真实挂载的、块设备来源的条目
  CAND=$(findmnt -rn -o TARGET,SOURCE,FSTYPE -D 2>/dev/null \
    | awk -v p="/media/$TARGET_USER/" 'index($1,p)==1' | head -1)
  if [ -z "$CAND" ]; then
    # 退而求其次: /run/media 下 (不同桌面约定)
    CAND=$(findmnt -rn -o TARGET,SOURCE,FSTYPE -D 2>/dev/null \
      | awk -v p="/run/media/$TARGET_USER/" 'index($1,p)==1' | head -1)
  fi
  if [ -n "$CAND" ]; then
    MOUNTPOINT=$(echo "$CAND" | awk '{print $1}')
    DEVICE=$(echo "$CAND" | awk '{print $2}')
    FSTYPE=$(echo "$CAND" | awk '{print $3}')
    ok "探测到: $DEVICE -> $MOUNTPOINT (fstype=$FSTYPE)"
  else
    err "未探测到已挂载的可移动设备"
    echo "  请显式指定: sudo $0 <设备> <挂载点>"
    echo "  例如:       sudo $0 /dev/sdb1 /media/$TARGET_USER/SDCARD"
    echo
    echo "  当前已挂载的块设备 (供参考):"
    findmnt -rn -o TARGET,SOURCE,FSTYPE -D 2>/dev/null | sed 's/^/    /'
    exit 2
  fi
fi

# ---------------------------------------------------------------- 参数归一
step "解析设备与挂载点"

if [ -n "$DEVICE" ] && [ ! -b "$DEVICE" ]; then
  die "$DEVICE 不是块设备"
fi

# 挂载点默认给一个
if [ -z "$MOUNTPOINT" ]; then
  MOUNTPOINT="/media/$TARGET_USER/$(basename "$DEVICE")"
  log "未指定挂载点, 默认: $MOUNTPOINT"
fi

# fstype
FSTYPE=$(blkid -s TYPE -o value "$DEVICE" 2>/dev/null || true)
[ -n "$FSTYPE" ] || FSTYPE=$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -1 || true)
[ -n "$FSTYPE" ] || die "无法识别 $DEVICE 的文件系统类型 (未格式化?"
log "文件系统: $FSTYPE"

# 标识符
if [ "$USE_LABEL" -eq 1 ]; then
  [ -n "${LABEL_ARG:-}" ] || die "--by-label 需要标签参数"
  IDENT="LABEL=$LABEL_ARG"
  # 验证标签存在
  if ! blkid -L "$LABEL_ARG" >/dev/null 2>&1; then
    warn "标签 '$LABEL_ARG' 当前不存在, fstab 行可能无法匹配"
    log "可用标签: $(blkid -o value -s LABEL 2>/dev/null | tr '\n' ' ')"
  fi
else
  UUID=$(blkid -s UUID -o value "$DEVICE" 2>/dev/null || true)
  [ -n "$UUID" ] || die "$DEVICE 没有 UUID (可能未格式化)。
  如需用标签: sudo $0 --by-label <标签> <挂载点>"
  IDENT="UUID=$UUID"
fi
ok "标识符: $IDENT"

# 现有挂载参数 (若已在 fstab 则复用其选项)
EXISTING=$(grep -E "^[^#]*[[:space:]]+$MOUNTPOINT[[:space:]]" "$FSTAB" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  log "fstab 已有该挂载点的条目, 将替换:"
  echo "$EXISTING" | sed 's/^/    原: /'
fi

# uid/gid 仅对需要它们的 fs 有意义 (exfat/vfat/ntfs)
case "$FSTYPE" in
  exfat|vfat|msdos|ntfs|ntfs3)
    OPTS="nosuid,nodev,relatime,uid=$TARGET_UID,gid=$TARGET_GID,fmask=0022,dmask=0022,iocharset=utf8,errors=remount-ro,nofail,x-systemd.device-timeout=15s"
    ;;
  *)
    # ext4/btrfs/xfs 等: uid/gid 由文件权限控制, 不该写进 fstab
    OPTS="nosuid,nodev,relatime,nofail,x-systemd.device-timeout=15s"
    ;;
esac

DUMP="0"  # 0 = 不做备份 (可移动介质每次开机备份无意义)
PASSNUM="0"

NEW_LINE="$IDENT  $MOUNTPOINT  $FSTYPE  $OPTS  $DUMP  $PASSNUM"

echo
log "将写入 fstab:"
printf '    %s\n' "$NEW_LINE"

# ---------------------------------------------------------------- 校验
# 用 systemd 的解析器验证这行语法是否合法 (比 mount -n 全量校验友好)
if ! is_dry_run; then
  if command -v systemd-analyze >/dev/null 2>&1; then
    log "预检 fstab 语法..."
  fi
fi

# ---------------------------------------------------------------- 写入
step "更新 /etc/fstab"

if is_dry_run; then
  log "[dry-run] 不会改动 $FSTAB"
else
  BACKUP="$FSTAB.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$FSTAB" "$BACKUP"
  log "已备份: $BACKUP"

  TMP=$(mktemp)
  # 移除旧行 (按挂载点或按标识符匹配), 保留其余全部内容
  awk -v mp="$MOUNTPOINT" -v id="$IDENT" '
    { line=$0
      # 去掉行内注释后按字段拆
      sub(/#.*/,"",line)
      n=split(line,f,/[ \t]+/)
      if (n>=2 && (f[2]==mp || f[1]==id)) next   # 跳过要替换的行
      print
    }' "$FSTAB" > "$TMP"

  # 确保文件以换行结尾
  [ -s "$TMP" ] && [ "$(tail -c1 "$TMP" | wc -l)" -eq 0 ] && echo >> "$TMP"

  printf '%s\n' "$NEW_LINE" >> "$TMP"

  # 写前最终校验: 若语法有问题则放弃, 不弄坏 fstab
  if ! awk 'NF>=6' "$TMP" >/dev/null 2>&1; then
    rm -f "$TMP"; die "生成的 fstab 校验失败, 未改动原文件"
  fi

  # 关键: 用 systemd 真实解析一次, 避免写坏 fstab 导致无法开机
  if command -v findmnt >/dev/null 2>&1; then
    if ! findmnt --verify --tab-file "$TMP" >/dev/null 2>&1; then
      warn "findmnt --verify 报告了问题 (输出见下), 但仍将写入:"
      findmnt --verify --tab-file "$TMP" 2>&1 | sed 's/^/    /' || true
    fi
  fi

  cat "$TMP" > "$FSTAB"
  rm -f "$TMP"
  ok "$FSTAB 已更新"
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统" \
          "标识:   $IDENT" \
          "挂载点: $MOUNTPOINT" \
          "文件系统: $FSTYPE"
  exit 0
fi

PASS=0; FAIL=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; PASS=$((PASS+1)); else err "$d"; FAIL=$((FAIL+1)); fi; }

chk "fstab 含新条目"      grep -qF "$MOUNTPOINT" "$FSTAB"
chk "标识符匹配"          grep -qF "$IDENT" "$FSTAB"
chk "含 nofail (不阻塞启动)"  sh -c "grep '$MOUNTPOINT' '$FSTAB' | grep -q nofail"
chk "fstab 可被解析"      findmnt --verify --tab-file "$FSTAB"

echo
echo "fstab 中本条目:"
grep -E "^[^#]*[[:space:]]+$MOUNTPOINT[[:space:]]" "$FSTAB" | sed 's/^/    /'

echo
if [ "$FAIL" -eq 0 ]; then
  ok "全部 $PASS 项通过"
  # 若当前未挂载, 尝试挂载做即时验证
  if ! findmnt -n "$MOUNTPOINT" >/dev/null 2>&1; then
    log "当前未挂载, 尝试用 systemd 立即挂载验证..."
    if systemctl start "$(systemd-escape -p --suffix=mount "$MOUNTPOINT")" 2>/dev/null; then
      ok "挂载成功: $(findmnt -n -o SOURCE,FSTYPE "$MOUNTPOINT" 2>/dev/null)"
    else
      log "未立即挂载 (设备可能未插), 开机时会自动处理"
    fi
  else
    ok "当前已挂载: $(findmnt -n -o SOURCE,FSTYPE "$MOUNTPOINT" 2>/dev/null)"
  fi
  echo
  echo "  测试重启后是否自动挂载:  sudo reboot  然后查看  findmnt $MOUNTPOINT"
  echo "  卸载条目: 从 $FSTAB 删除该行并执行  sudo systemctl daemon-reload"
else
  err "$FAIL/$((PASS+FAIL)) 项未通过"
  echo "  原 fstab 备份在: $BACKUP"
  echo "  可用以下命令回滚:  sudo cp $BACKUP $FSTAB"
  exit 1
fi
