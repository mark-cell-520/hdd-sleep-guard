#!/bin/bash
# HDD Sleep Guard 一键安装（macOS，Apple Silicon / Intel 均可）。
# 用法: install.sh [安装前缀]   默认 ~/hdd-sleep-guard
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-$HOME/hdd-sleep-guard}"

echo "安装前缀: $PREFIX"
mkdir -p "$PREFIX"/daemon "$PREFIX"/cli "$PREFIX"/logs "$PREFIX"/launchd "$PREFIX"/app "$PREFIX"/bin "$PREFIX"/share

# 1. 源码
cp "$SRC/daemon/hddguard_core.py" "$PREFIX/daemon/"
cp "$SRC/cli/hddguard" "$PREFIX/cli/"; chmod +x "$PREFIX/cli/hddguard"
[ -f "$PREFIX/config.json" ] || cp "$SRC/config.json" "$PREFIX/config.json"

# 2. 获取 smartctl 与驱动库
bash "$SRC/scripts/fetch_smartctl.sh" "$PREFIX"

# 3. launchd 守护（登录自启、崩溃自重启）
sed "s#__PREFIX__#$PREFIX#g" "$SRC/launchd/com.user.hddsleepguard.plist.template" \
  > "$HOME/Library/LaunchAgents/com.user.hddsleepguard.plist"
UID_=$(id -u)
launchctl bootout "gui/$UID_/com.user.hddsleepguard" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$HOME/Library/LaunchAgents/com.user.hddsleepguard.plist" 2>/dev/null \
  || launchctl load "$HOME/Library/LaunchAgents/com.user.hddsleepguard.plist"

# 4. 编译菜单栏 app 并组装 .app（核心按前缀安装，app 经 install_prefix.txt 定位）
xcrun swiftc -o "$PREFIX/app/hdd-guard" "$SRC/app/main.swift"
APP="$PREFIX/app/HDD Sleep Guard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$PREFIX/app/hdd-guard" "$APP/Contents/MacOS/hdd-guard"
cp "$SRC/app/Info.plist" "$APP/Contents/Info.plist"
printf '%s' "$PREFIX" > "$APP/Contents/Resources/install_prefix.txt"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP" 2>/dev/null || true

# 5. 命令行入 PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$PREFIX/cli/hddguard" "$HOME/.local/bin/hddguard"

echo
echo "安装完成。"
echo "  启动菜单栏 app:  open \"$APP\""
echo "  查看状态:        hddguard status"
echo "  日志:            $PREFIX/logs/hddguard.log"
