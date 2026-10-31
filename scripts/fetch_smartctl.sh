#!/bin/bash
# 从 smartmontools 官方 macOS dmg 中提取 smartctl 与 drivedb.h。
# 不装 Homebrew、不需要 sudo、不运行安装器、不污染系统。
# 用法: fetch_smartctl.sh [安装前缀]   默认前缀 = 本脚本上两级目录（仓库安装根）
set -uo pipefail

PREFIX="${1:-}"
if [ -z "$PREFIX" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)"
  PREFIX="$(cd "$SELF/../.." && pwd)"
fi
mkdir -p "$PREFIX/bin" "$PREFIX/share"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "[1/5] 查询 smartmontools 最新 release 的 macOS dmg ..."
ASSET_ID=$(curl -sS --max-time 30 \
  "https://api.github.com/repos/smartmontools/smartmontools/releases/latest" \
  | /usr/bin/python3 -c "import sys,json
r=json.load(sys.stdin)
d=[a for a in r['assets'] if a['name'].endswith('.dmg')]
print(d[0]['id'] if d else '')" 2>/dev/null)
[ -n "$ASSET_ID" ] || { echo "未找到 dmg 资产"; exit 1; }
echo "  asset id=$ASSET_ID"

echo "[2/5] 取直链并分块下载（HTTP/1.1，绕开 HTTP/2 卡死与单连接尾段卡死）..."
REDIR=$(curl -sS --max-time 30 -D - -o /dev/null -H "Accept: application/octet-stream" \
  "https://api.github.com/repos/smartmontools/smartmontools/releases/assets/$ASSET_ID" 2>/dev/null \
  | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
[ -n "$REDIR" ] || { echo "拿不到重定向"; exit 1; }
TOTAL=$(curl -sS --http1.1 --max-time 30 -r 0-0 -D - -o /dev/null "$REDIR" 2>/dev/null \
  | tr -d '\r' | grep -i '^content-range:' | sed -E 's#.*/([0-9]+).*#\1#')
echo "  总大小 ${TOTAL} 字节"
OUT=smartmontools.dmg
CHUNK=524288; START=0; i=0
while [ "${START:-0}" -lt "${TOTAL:-0}" ]; do
  END=$((START+CHUNK-1)); [ $END -ge $TOTAL ] && END=$((TOTAL-1))
  PART=$(printf "%s.part-%02d" "$OUT" "$i")
  for try in 1 2 3 4; do
    curl -sS --http1.1 --max-time 35 -r ${START}-${END} -o "$PART" "$REDIR" 2>/dev/null && break
    sleep 1
  done
  START=$((END+1)); i=$((i+1))
done
cat "$OUT".part-* > "$OUT" 2>/dev/null; rm -f "$OUT".part-*
[ "$(stat -f%z "$OUT" 2>/dev/null)" = "$TOTAL" ] || { echo "下载不完整"; exit 1; }
echo "  下载完成并校验通过"

echo "[3/5] 挂载 dmg 取出 pkg ..."
MNT="$WORK/mnt"; mkdir -p "$MNT"
hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MNT" >/dev/null 2>&1
PKG=$(find "$MNT" -maxdepth 1 -name '*.pkg' | head -1)
[ -n "$PKG" ] || { echo "dmg 内无 pkg"; hdiutil detach "$MNT" >/dev/null 2>&1; exit 1; }
cp "$PKG" "$WORK/smt.pkg"; hdiutil detach "$MNT" >/dev/null 2>&1

echo "[4/5] xar 解包 + cpio 提取 Payload ..."
mkdir -p "$WORK/xar" "$WORK/root"
xar -xf "$WORK/smt.pkg" -C "$WORK/xar"
( cd "$WORK/root" && cat "$WORK/xar/Payload" | gunzip -dc | cpio -idm 2>/dev/null )
SMARTCTL=$(find "$WORK/root" -name smartctl -type f | head -1)
DRIVEDB=$(find "$WORK/root" -name drivedb.h | head -1)
[ -n "$SMARTCTL" ] || { echo "未找到 smartctl"; exit 1; }

echo "[5/5] 安装到 $PREFIX ..."
cp "$SMARTCTL" "$PREFIX/bin/smartctl"; chmod +x "$PREFIX/bin/smartctl"
xattr -c "$PREFIX/bin/smartctl" 2>/dev/null || true
[ -n "$DRIVEDB" ] && cp "$DRIVEDB" "$PREFIX/share/drivedb.h"
"$PREFIX/bin/smartctl" --version 2>&1 | head -1 | sed 's/^/  /'
echo "完成：$PREFIX/bin/smartctl"
