#!/bin/bash
# ============================================================
# 构建 macOS 桌面版「校园网一键连接」app
#
#   ./build.sh          → 产物在 app/dist/ 下（SZUConnect.app + 压缩包）
#
# 依赖：Xcode Command Line Tools（clang）。若未安装：
#       xcode-select --install
# 出图标需要 Python + Pillow，仅当你改动 icon/make_icon.py 时才用得上；
# 仓库里已带好编译完成的 app.icns，日常构建不需要 Python。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(cd .. && pwd)"
DIST="$PWD/dist"
APP="$DIST/SZUConnect.app"
SETUP="$APP/Contents/Resources/SZUConnectSetup.app"
ARCHS="-arch arm64 -arch x86_64"

command -v clang >/dev/null 2>&1 || {
  echo "✗ 需要 Xcode Command Line Tools，请先执行： xcode-select --install"
  exit 1
}

echo "==> 清理 dist/"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/cli" \
         "$SETUP/Contents/MacOS" "$SETUP/Contents/Resources"

echo "==> 编译首次配置窗口（通用二进制：Apple Silicon + Intel）"
clang -fobjc-arc -O2 $ARCHS -framework Cocoa \
  -o "$SETUP/Contents/MacOS/SZUConnectSetup" src/Setup.m
cp src/Info.plist.setup "$SETUP/Contents/Info.plist"
cp icon/app.icns "$SETUP/Contents/Resources/app.icns"
printf 'APPL????' > "$SETUP/Contents/PkgInfo"

echo "==> 组装主 app"
cp src/connect.sh "$APP/Contents/MacOS/connect"
chmod +x "$APP/Contents/MacOS/connect"
cp src/Info.plist "$APP/Contents/Info.plist"
cp icon/app.icns "$APP/Contents/Resources/app.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 内置登录脚本（这样用户不用另外 clone 仓库）"
cp "$REPO_ROOT/autologin.sh" "$APP/Contents/Resources/cli/autologin.sh"
cp "$REPO_ROOT/config.example.sh" "$APP/Contents/Resources/cli/config.example.sh"
chmod +x "$APP/Contents/Resources/cli/autologin.sh"

echo "==> 临时签名（降低下载后被 Gatekeeper 直接拦下的概率）"
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
  echo "    ✓ 已做 ad-hoc 签名"
else
  echo "    · 签名跳过（首次打开时若被拦，右键 → 打开 即可）"
fi

echo "==> 打包压缩包（保留可执行权限）"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/SZUConnect-mac.zip"

echo ""
echo "==== 构建完成 ===="
echo "app:   $APP"
echo "压缩包: $DIST/SZUConnect-mac.zip"
echo "安装:   ./install.sh"
