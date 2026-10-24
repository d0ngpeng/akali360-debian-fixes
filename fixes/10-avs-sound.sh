#!/usr/bin/env bash
#
# 修复: 扬声器无声 (MAX98357A I2S 功放)
#
# 症状:  开机后 /proc/asound/cards 里没有 MAX98357A 声卡,
#        系统只有 DMIC / DA7219 / HDMI 三块卡, 内置扬声器无声。
#
# 根因:  Debian 内核配置关闭了该机器驱动:
#          # CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A is not set
#        但同一 Makefile 里的其他 AVS machine driver (da7219/dmic/hdaudio...)
#        都是 =m。Akali360 的扬声器走 AVS DSP + MAX98357A 功放,
#        缺这个 board driver 就注册不出声卡。
#
# 方案:  不重编整个内核 —— 只把 max98357a.c 编译成外部模块,
#        装到 /lib/modules/$(uname -r)/.../avs/boards/ 下,
#        再用 modules-load.d 保证每次开机自动加载。
#
# 前置:  linux-headers-$(uname -r) 已安装 (构建必需)
#        linux-source-<VER> 或网络可达的内核源码 (取 max98357a.c)
#        CONFIG_SND_SOC_INTEL_AVS=m (AVS 核心必须是模块/内建)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

MOD_NAME="snd-soc-avs-max98357a"
PLATFORM_ALIAS="platform:avs_max98357a"
MOD_PATH="/lib/modules/$KVER/kernel/sound/soc/intel/avs/boards/$MOD_NAME.ko"
LOAD_CONF="/etc/modules-load.d/avs-max98357a.conf"

usage() {
  cat <<EOF
用法: sudo $0 [--dry-run] [--force]

  --dry-run   只打印将要执行的操作, 不改动系统
  --force     即使模块已存在也重新构建
  -h, --help  显示本帮助
EOF
}

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

require_root

# ---------------------------------------------------------------- 检查
step "环境检查"

if ! grep -q "^CONFIG_SND_SOC_INTEL_AVS=m\|^CONFIG_SND_SOC_INTEL_AVS=y" "/boot/config-$KVER" 2>/dev/null; then
  die "内核未启用 CONFIG_SND_SOC_INTEL_AVS —— 本修复不适用 (AVS 核心缺失)"
fi
ok "CONFIG_SND_SOC_INTEL_AVS 已启用"

if grep -q "^CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A=m\|^CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A=y" \
     "/boot/config-$KVER" 2>/dev/null; then
  ok "内核已自带该驱动, 无需外部构建"
  exit 0
fi
log "确认内核确实未编译该驱动 (符合本修复场景)"

KDIR="/lib/modules/$KVER/build"
[ -e "$KDIR/Makefile" ] || die "缺少内核 headers: $KDIR
  请先安装: sudo apt install linux-headers-$KVER"
ok "构建目录就绪: $KDIR"

if [ "$FORCE" -eq 0 ] && [ -f "$MOD_PATH" ]; then
  if modinfo "$MOD_PATH" 2>/dev/null | grep -q "vermagic:.*$KVER"; then
    ok "模块已存在且 vermagic 匹配, 跳过构建 (--force 可强制重建)"
    # 仍继续执行后面的安装/自动加载/验证
    EXISTING=1
  else
    warn "已存在模块但 vermagic 不匹配, 将重新构建"
    EXISTING=0
  fi
else
  EXISTING=0
fi

# ---------------------------------------------------------------- 取源码
step "获取 max98357a.c 源码"

WORK="$(mktemp -d /tmp/avsmax98357a.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
log "工作目录: $WORK"

find_source() {
  # 1) 已安装的 linux-source-*
  local pkg tarball
  for pkg in $(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-source/ {print $2}'); do
    tarball=$(dpkg -L "$pkg" 2>/dev/null | grep -E '\.tar\.(xz|gz|zst)$' | head -1)
    if [ -n "$tarball" ] && [ -f "$tarball" ]; then
      echo "installed:$tarball"; return 0
    fi
  done
  # 2) /usr/src 下的 tarball
  for tarball in /usr/src/linux-source-*.tar.*; do
    [ -f "$tarball" ] || continue
  echo "file:$tarball"; return 0
  done
  return 1
}

# 内核主版本号 (linux-source-<MAJOR>) —— 无论走哪条分支都要用到, 故提前算出
KMAJOR=$(echo "$KVER" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')

SRC_TAR=""
if FOUND=$(find_source); then
  case "$FOUND" in
    *:*) SRC_TAR="${FOUND#*:}" ;;
  esac
  ok "找到已安装源码包: $(basename "$SRC_TAR")"
fi

if [ -z "$SRC_TAR" ] && ! is_dry_run; then
  log "未找到源码, 尝试用 apt 下载 (匹配当前内核系列)"
  PKG="linux-source-$KMAJOR"
  if apt-cache show "$PKG" >/dev/null 2>&1; then
    log "下载 $PKG ..."
    (cd "$WORK" && apt-get download "$PKG") || warn "下载失败, 请手动安装: sudo apt install $PKG"
    DEB=$(find "$WORK" -name "${PKG}_*.deb" | head -1)
    if [ -n "$DEB" ]; then
      mkdir -p "$WORK/deb"
      dpkg-deb -x "$DEB" "$WORK/deb"
      SRC_TAR=$(find "$WORK/deb" -name 'linux-source-*.tar.*' | head -1)
      ok "已解包 $PKG"
    fi
  fi
fi

if [ -z "$SRC_TAR" ] || [ ! -f "$SRC_TAR" ]; then
  if is_dry_run; then
    # dry-run 不因缺源码而中断 —— 后续步骤一并以模拟方式展示
    warn "未找到内核源码 (dry-run, 不阻断)。真实执行时将自动 apt 下载"
    log "或提前安装: sudo apt install linux-source-$KMAJOR"
    SRC_TAR=""
  else
    die "取不到内核源码。
  请先安装: sudo apt install linux-source-$KMAJOR
  然后重新运行本脚本。"
  fi
fi

if [ -n "$SRC_TAR" ]; then
  mkdir -p "$WORK/src"
  log "从 tarball 提取 AVS 目录 (只取需要的部分, 不解全量)..."
  TOP=$(tar -tf "$SRC_TAR" | head -1 | cut -d/ -f1)
  tar -xf "$SRC_TAR" -C "$WORK/src" --strip-components=1 "$TOP/sound/soc/intel/avs" 2>/dev/null \
    || tar -xf "$SRC_TAR" -C "$WORK/src" --strip-components=1 --wildcards "*/sound/soc/intel/avs"

  C_FILE="$WORK/src/sound/soc/intel/avs/boards/max98357a.c"
  [ -f "$C_FILE" ] || die "源码包里没有 max98357a.c"
  ok "取得源码: max98357a.c ($(wc -l < "$C_FILE") 行)"
else
  # dry-run 且无源码: 仅说明, 不中断后续模拟步骤
  log "[dry-run] 跳过源码提取 (无 tarball), 后续步骤以模拟方式展示"
fi

# ---------------------------------------------------------------- 构建
step "构建外部模块"

if is_dry_run; then
  log "[dry-run] 将在 $KDIR 下以 M=$WORK/build 编译 $MOD_NAME.ko"
else
  BDIR="$WORK/build"
  mkdir -p "$BDIR/sound/soc/intel/avs/boards"
  cp "$C_FILE" "$BDIR/sound/soc/intel/avs/boards/"
  cp "$WORK/src"/sound/soc/intel/avs/*.h "$BDIR/sound/soc/intel/avs/"

  cat > "$BDIR/Makefile" <<'MK'
# Intel AVS max98357a machine driver — external module
obj-m := snd-soc-avs-max98357a.o
snd-soc-avs-max98357a-y := sound/soc/intel/avs/boards/max98357a.o
ccflags-y += -I$(src)/sound/soc/intel/avs
MK

  make -C "$KDIR" M="$BDIR" modules >/dev/null \
    || die "构建失败 —— 请保留输出排查, 常见原因: 内核 headers 与源码版本不一致"

  NEW_KO="$BDIR/$MOD_NAME.ko"
  [ -f "$NEW_KO" ] || die "构建后未生成 $MOD_NAME.ko"

  # 产物校验
  modinfo "$NEW_KO" >/dev/null 2>&1 || die "modinfo 无法解析产物"
  V=$(modinfo "$NEW_KO" | awk -F: '/^vermagic/{gsub(/^ +/,"",$2);print $2}')
  case "$V" in
    "$KVER"*) ok "vermagic 匹配: $V" ;;
    *) die "vermagic 不匹配: $V (期望 $KVER...)" ;;
  esac
  ALIAS=$(modinfo "$NEW_KO" | awk -F: '/^alias/{gsub(/^ +/,"",$2);print $2}')
  [ "$ALIAS" = "$PLATFORM_ALIAS" ] || die "alias 不符: $ALIAS"
  ok "alias 正确: $ALIAS"

  # 比对既有安装 (若存在)
  if [ -f "$MOD_PATH" ]; then
    log "与已安装版本对比:"
    printf '    %-10s  新: %-12s 旧: %s\n' "大小" \
      "$(stat -c%s "$NEW_KO")" "$(stat -c%s "$MOD_PATH")"
    for k in description name depends license; do
      a=$(modinfo "$NEW_KO" | awk -F: -v k="$k" '$1==k{sub(/^ +/,"",$2);print $2}')
      b=$(modinfo "$MOD_PATH" | awk -F: -v k="$k" '$1==k{sub(/^ +/,"",$2);print $2}')
      [ "$a" = "$b" ] && s="一致" || s="不同"
      printf '    %-10s  %s\n' "$k" "$s"
    done
  fi
fi

# ---------------------------------------------------------------- 安装
step "安装模块"

if is_dry_run; then
  log "[dry-run] 将安装到 $MOD_PATH"
else
  mkdir -p "$(dirname "$MOD_PATH")"
  if [ -f "$MOD_PATH" ]; then
    bak="${MOD_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$MOD_PATH" "$bak"; log "已备份旧模块 ${bak##*/}"
  fi
  install -m 0644 "$NEW_KO" "$MOD_PATH"
  ok "已安装: $MOD_PATH"
  depmod -a "$KVER"
  ok "depmod 已更新 ($KVER)"
fi

# ---------------------------------------------------------------- 自动加载
step "开机自动加载"

write_file "$LOAD_CONF" <<EOF
# Intel AVS MAX98357A 扬声器驱动 (Akali360)
# Debian 内核未编译 CONFIG_SND_SOC_INTEL_AVS_MACH_MAX98357A, 以外部模块补充
$MOD_NAME
EOF

if is_dry_run; then
  log "[dry-run] 将执行: modprobe $MOD_NAME"
else
  # 若声卡尚未注册则加载
  if ! grep -q "AVS I2S MAX98357A" /proc/asound/cards 2>/dev/null; then
    modprobe "$MOD_NAME" || die "modprobe 失败"
    sleep 1
  fi
fi

# ---------------------------------------------------------------- 验证
step "验证"

if is_dry_run; then
  summary "dry-run 完成, 未改动系统"
  exit 0
fi

PASS=0; FAIL=0
chk() { # chk <描述> <命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; PASS=$((PASS+1));
  else err "$desc"; FAIL=$((FAIL+1)); fi
}

chk "模块文件存在"           test -f "$MOD_PATH"
chk "modinfo 解析正常"       modinfo "$MOD_NAME"
chk "已注册 MAX98357A 声卡"  grep -q "MAX98357A" /proc/asound/cards
chk "自动加载配置存在"       test -f "$LOAD_CONF"
chk "模块当前已加载"         lsmod | grep -q "^$MOD_NAME"
chk "平台别名已匹配"         grep -q "$PLATFORM_ALIAS" /sys/bus/platform/devices/*/modalias 2>/dev/null

echo
if [ "$FAIL" -eq 0 ]; then
  ok "全部 $PASS 项通过"
  echo
  echo "当前声卡列表:"
  sed 's/^/    /' /proc/asound/cards
  echo
  log "提示: 若声卡已出现但仍无声, 检查 PipeWire 默认输出设备:"
  echo "      pactl info | grep 'Default Sink'"
else
  err "$FAIL/$((PASS+FAIL)) 项未通过"
  exit 1
fi
