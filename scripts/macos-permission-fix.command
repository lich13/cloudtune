#!/bin/bash
set -euo pipefail

APP_NAME="CloudTune.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"

pause() {
  printf '\n按回车键退出...'
  read -r _
}

clear
echo "CloudTune macOS 权限修复"
echo
echo "这个脚本会尝试："
echo "1. 把当前 DMG 里的 CloudTune.app 复制到 /Applications"
echo "2. 去掉隔离属性（quarantine）"
echo "3. 尝试启动一次 CloudTune"
echo

if [[ -d "$SOURCE_APP" ]]; then
  echo "检测到 DMG 内的 CloudTune.app，准备安装到 /Applications..."
  sudo -v
  sudo rm -rf "$TARGET_APP"
  sudo ditto "$SOURCE_APP" "$TARGET_APP"
elif [[ -d "$TARGET_APP" ]]; then
  echo "未检测到 DMG 内的 app，直接修复 /Applications/CloudTune.app ..."
  sudo -v
else
  echo "没有找到 CloudTune.app。请把脚本和 app 放在同一个 DMG 里，或先把 app 拖到 /Applications。"
  pause
  exit 1
fi

echo
echo "移除隔离属性..."
sudo xattr -dr com.apple.quarantine "$TARGET_APP" || true

echo "补充可执行权限..."
sudo chmod +x "$TARGET_APP/Contents/MacOS/"* || true

echo "尝试登记到 Gatekeeper 白名单..."
sudo spctl --add --label CloudTune "$TARGET_APP" >/dev/null 2>&1 || true

echo "尝试启动 CloudTune..."
open "$TARGET_APP" || true

echo
echo "处理完成。"
echo "如果系统仍然阻止打开，请在系统设置 -> 隐私与安全性里允许一次，然后再运行。"
pause
