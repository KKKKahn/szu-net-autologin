#!/bin/bash
# ============================================================
# 构建并安装「校园网一键连接」到 /Applications
#
#   ./install.sh                    装到 /Applications
#   ./install.sh --local            装到当前用户目录（无需管理员）
#
# 装好后直接在启动台/应用程序里点图标即可。首次点击会弹窗要一次账号密码。
# 本脚本不会注册后台定时服务；想要断网自动重连，用仓库根目录的 install.sh。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

if [ "${1:-}" = "--local" ]; then
  TARGET="$HOME/Applications/SZUConnect.app"
  mkdir -p "$HOME/Applications"
else
  TARGET="/Applications/SZUConnect.app"
fi

echo ""
echo "==> 安装到 $TARGET"
if [ -d "$TARGET" ] && [ ! -w "$(dirname "$TARGET")" ]; then
  echo "✗ 没有写入权限，请改用： ./install.sh --local"
  exit 1
fi
rm -rf "$TARGET"
cp -R "dist/SZUConnect.app" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo ""
echo "==== 安装完成 ===="
echo "位置: $TARGET"
echo "用法: 打开「启动台」搜索「校园网一键连接」，或用 Finder 双击"
echo "首次点击会弹窗要账号密码，之后不再打扰。"
echo "想换账号： $TARGET/Contents/MacOS/connect --setup"
