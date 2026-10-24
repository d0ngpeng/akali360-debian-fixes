#!/usr/bin/env bash
# 公共函数库 —— 被 fixes/*.sh 复用
# 设计原则: 不硬编码任何机器相关值 (swap UUID / 盘符 / 挂载点 / 主机名),
#           全部运行时自动探测, 以便公开分发与跨机复用。

set -o pipefail

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'
else
  C_RESET=; C_RED=; C_GRN=; C_YLW=; C_BLU=; C_BLD=
fi

log()   { printf '%s[·]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YLW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RESET"; }
die()   { err "$*"; exit 1; }

# ---------- root ----------
require_root() {
  [ "$EUID" -eq 0 ] || die "需要 root 权限, 请用: sudo $0 $*"
}

# ---------- 干跑 ----------
# 用法: if is_dry_run; then log "将执行 ..."; else 真正执行; fi
DRY_RUN=0
is_dry_run() { [ "$DRY_RUN" -eq 1 ]; }

# 写文件 (自动备份 + 支持干跑)
# write_file <目标路径> <内容通过 stdin>
write_file() {
  local target="$1" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if is_dry_run; then
    log "[dry-run] 将写入 $target:"
    sed 's/^/        | /' "$tmp"
    rm -f "$tmp"; return 0
  fi
  if [ -f "$target" ] && ! cmp -s "$tmp" "$target"; then
    local bak="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$target" "$bak"
    log "已备份 $target -> ${bak##*/}"
  fi
  mkdir -p "$(dirname "$target")"
  cat "$tmp" > "$target"
  rm -f "$tmp"
  ok "写入 $target"
}

# 幂等: 若目标内容与期望一致则跳过
# content_is <目标路径> ; 期望内容走 stdin
content_is() {
  local target="$1" tmp
  tmp=$(mktemp); cat > "$tmp"
  [ -f "$target" ] && cmp -s "$tmp" "$target"
  local r=$?; rm -f "$tmp"; return $r
}

# 在配置文件里确保某行存在 (幂等)
# ensure_line <文件> <行> [在某模式后插入]
ensure_line() {
  local file="$1" line="$2" after="${3:-}"
  if [ -f "$file" ] && grep -qxF "$line" "$file"; then
    ok "已存在 (跳过): $line"
    return 0
  fi
  if is_dry_run; then log "[dry-run] 将向 $file 追加: $line"; return 0; fi
  [ -f "$file" ] || { mkdir -p "$(dirname "$file")"; touch "$file"; }
  local bak="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  [ -f "$file" ] && [ -s "$file" ] && cp -p "$file" "$bak" && log "已备份 ${bak##*/}"
  if [ -n "$after" ] && grep -q "$after" "$file"; then
    # 插到匹配行之后
    awk -v l="$line" -v p="$after" '{print} $0 ~ p && !done {print l; done=1}' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  else
    printf '%s\n' "$line" >> "$file"
  fi
  ok "已添加: $line"
}

# 从 GRUB_CMDLINE_LINUX 里确保某参数存在 (自动去重)
# ensure_kernel_param <参数名> <值>   例如 resume UUID=xxx
ensure_kernel_param() {
  local key="$1" val="$2"
  local file=/etc/default/grub
  [ -f "$file" ] || die "找不到 $file"
  local current new
  current=$(grep -E '^GRUB_CMDLINE_LINUX=' "$file" | head -1 | sed -E 's/^GRUB_CMDLINE_LINUX="(.*)"$/\1/')
  [ -n "$current" ] || die "无法解析 GRUB_CMDLINE_LINUX"
  # 已含正确值则跳过
  if echo " $current " | grep -q " ${key}=${val} "; then
    ok "内核参数已存在: ${key}=${val}"
    return 0
  fi
  # 同名但值不同 → 移除旧的
  new=$(echo "$current" | tr ' ' '\n' | grep -v "^${key}=" | tr '\n' ' ' | sed 's/ *$//')
  new="$new ${key}=${val}"
  if is_dry_run; then
    log "[dry-run] GRUB_CMDLINE_LINUX 将变为: \"$new\""
    return 0
  fi
  local bak="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p "$file" "$bak"; log "已备份 ${bak##*/}"
  sed -i "s|^GRUB_CMDLINE_LINUX=\".*\"|GRUB_CMDLINE_LINUX=\"${new}\"|" "$file"
  ok "已设置 ${key}=${val}"
}

# ---------- 探测 ----------
KVER="$(uname -r)"

# 找出候选 swap 设备 (已激活的优先)
detect_swap_devs() {
  swapon --show=NAME --noheadings 2>/dev/null
  cat /proc/swaps 2>/dev/null | tail -n +2 | awk '{print $1}'
}

# 输出当前 swap 的 UUID (多块时取第一块非文件型的)
detect_swap_uuid() {
  local dev
  for dev in $(detect_swap_devs | sort -u); do
    [ -b "$dev" ] || continue          # 跳过 swap 文件
    local u
    u=$(blkid -s UUID -o value "$dev" 2>/dev/null)
    [ -n "$u" ] && { echo "$u"; return 0; }
  done
  return 1
}

# 输出 GRUB resume= 现有参数值 (用于校验/回退)
current_grub_resume() {
  [ -f /boot/grub/grub.cfg ] || return 1
  grep -oE 'resume=UUID=[0-9a-f-]+' /boot/grub/grub.cfg 2>/dev/null | head -1 | cut -d= -f3
}

# 判断系统是否为本机型 (Google Akali360 / Acer Spin 13)
# 用 /sys/class/dmi/id (无需 root); dmidecode 需 root, 非交互场景不可靠
is_akali360() {
  local prod
  prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
  echo "$prod" | grep -qiE 'akali360|spin ?13'
}

# ---------- 结果校验 ----------
check_root() {
  local mp="$1"
  findmnt -n "$mp" >/dev/null 2>&1
}

summary() {
  printf '\n%s──────────── 执行结果 ────────────%s\n' "$C_BLD" "$C_RESET"
  local s
  for s in "$@"; do printf '  %s\n' "$s"; done
}
