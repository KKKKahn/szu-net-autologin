# 校园网一键连接 · macOS 桌面版

> 一个放在「启动台 / 桌面」里的图标,点一下就把校园网连上。
> 不用开终端、不用记命令、不用打开浏览器输账号。

这是仓库主项目 [szu-net-autologin](../README.md) 的**图形界面外壳**:核心仍然是同一个
`autologin.sh`,只是把它包成一个双击即可运行的 `.app`,并补上了「首次使用填账号密码」的窗口。

---

## ⬇️ 下载

到 [**Releases**](https://github.com/KKKKahn/szu-net-autologin/releases/latest) 页面,
下载最新一版的 `SZUConnect-mac.zip`,解压得到 `SZUConnect.app`。

> 想自己编译也行,见文末「从源码构建」。

## 📥 安装

1. 把 `SZUConnect.app` 拖进**「应用程序」**文件夹(或直接放桌面)。
2. 第一次打开:在图标上**右键 → 打开** → 弹窗里再点「打开」。
   (因为安装包没有 Apple 开发者签名,系统第一次会拦一下,右键打开即可放行,之后不再询问。)

## 🚀 使用

点一下图标,大约 **10~15 秒**出结果,全程不弹终端窗口:

- **第一次点** → 弹出一个窗口,填一次校园网账号和密码 → 「保存并开始连接」
- **之后每次点** → 直接连,不再问
- 已经在线 → 提示「已经在网了,无需重连」,不做多余动作
- 掉线了 → 自动登录,提示「已连接 · 教学区 ✓」
- 失败了 → 弹窗告诉你原因(账号密码错、网络未就绪……),不会静默失败

**它还顺带解决了两件手动麻烦事**:

| 你遇到的情况 | app 会怎么做 |
|---|---|
| Wi-Fi 是关着的 | 先自动打开 Wi-Fi,再连校园网、再登录 |
| Wi-Fi 开着但连的是别的网络 | 自动切到 `SZU_WLAN`,连上后登录 |
| 附近根本没有校园网 | 保持你原来的网络不动,只提示一句,不会把你断网 |

## 🔁 换账号 / 改密码

在终端里执行一次(把路径换成你实际放的位置):

```bash
/Applications/SZUConnect.app/Contents/MacOS/connect --setup
```

会重新弹出配置窗口,填完即覆盖旧凭据。

## 🗑️ 卸载

```bash
# 1. 删掉 app
rm -rf /Applications/SZUConnect.app

# 2. 删掉本地凭据(可选,如果不再使用本工具)
security delete-generic-password -s szu-portal

# 3. 删掉运行数据和日志(可选)
rm -rf "$HOME/Library/Application Support/SZUAutoLogin"
rm -f  "$HOME/Library/Logs/szu-autologin.log" \
       "$HOME/Library/Logs/szu-connect-click.log"
```

## 🔒 隐私说明

- app 里**不含任何人的账号信息**,下载的安装包对所有人生效。
- 账号密码只写进**你本机的 macOS 钥匙串**(服务名 `szu-portal`),由系统加密保管。
- 密码不联网、不写文件、不进日志;配置窗口里输入的内容直接交给系统的 `security` 命令。
- 运行日志里只有 Wi-Fi 名、IP、认证结果,**没有账号和密码**:
  `~/Library/Logs/szu-connect-click.log`(点击流程)、`~/Library/Logs/szu-autologin.log`(认证细节)。

## ❓ 常见问题

**打开时提示「无法验证开发者」**
右键 → 打开,或执行 `xattr -dr com.apple.quarantine /Applications/SZUConnect.app`。

**第一次连接弹出「想访问钥匙串」**
点**「始终允许」**,只问这一次。

**点了没反应**
连结果通知都没看到的话,看自检日志(它记录了每次点击走了哪一步、每步耗时):
```bash
cat ~/Library/Logs/szu-connect-click.log
```

**提示账号或密码错误**
app 会主动问要不要重新输入,选「重新输入」即可;也可以按上面「换账号」的方法重来。

**想要"断了自动连"而不是每次手动点**
用仓库根目录的 [install.sh](../install.sh),它会注册一个每 15 秒检查一次的后台服务;
那个服务和这个 app 共用同一套脚本与钥匙串凭据,两者可以同时装、互不冲突。

## 🛠️ 从源码构建

需要 Xcode Command Line Tools(`xcode-select --install`)。

```bash
cd app
./build.sh          # 产物: app/dist/SZUConnect.app 与 app/dist/SZUConnect-mac.zip
./install.sh        # 构建并装到 /Applications(加 --local 则装到 ~/Applications)
```

## 📁 目录结构

```
app/
├── src/
│   ├── connect.sh        # 主流程:Wi-Fi 保障 → 连通性检查 → 网页认证 → 通知
│   ├── Setup.m           # 首次配置窗口(Objective-C + AppKit,自己画的圆角卡片)
│   ├── Info.plist        # 主 app
│   └── Info.plist.setup  # 配置窗口(内嵌在主 app 的 Resources 里)
├── icon/
│   ├── make_icon.py      # 生成图标(Pillow;配色为深大标准色「荔枝红」PANTONE 208C)
│   └── app.icns          # 已生成好的图标,构建时直接用
├── build.sh              # 构建
└── install.sh            # 构建 + 安装
```

## 📄 许可证

与主项目一致,[MIT](../LICENSE)。
