# SZUConnect 1.1.0 — MacBook 安装与验收（给 MacBook 上的 Agent）

**目标**：在 MacBook 上安装/替换 SZUConnect 1.1.0，停用旧的后台自动重登，完成验收并回报。不要修改 Mac mini、路由器、手机/平板。

## 0. 背景（一句话）

校园网的电脑名额只有一个。新 App 采用**手动点击登录**：点一次登录一次，没有后台心跳、没有自动重登。

- Mac mini 有线 / MacBook 在 `HUAWEI_2090` 上：点 App → 登录并保持路由器会话。
- MacBook 在 `SZU_WLAN` / `SZU_CTC&CMCC`（即“Shenzhen UniversityNet”）上：点 App → 加入校园 WiFi 并登录校园网，会把路由器顶掉（预期）。
- 回宿舍：点任意一台 Mac 上的 App → 路由器重新登录；MacBook 在 HUAWEI 上不会再抢。
- 手机/平板是独立名额，不要动。

## 1. 下载

- 下载地址：<https://raw.githubusercontent.com/KKKKahn/szu-net-autologin/main/dist/SZUConnect.app.zip>
- 仓库：<https://github.com/KKKKahn/szu-net-autologin>
- 版本：**1.1.0**（`CFBundleVersion` = 2）
- SHA-256：`6c32587f27543b24fed8d7b9ea85a0824f449db65bd5c8ed936fef7f58191330`

```bash
cd /tmp
curl -L --fail -o SZUConnect.app.zip \
  "https://raw.githubusercontent.com/KKKKahn/szu-net-autologin/main/dist/SZUConnect.app.zip"
shasum -a 256 SZUConnect.app.zip
```

必须等于上面的 SHA-256；不一致就停止并回报。

## 2. 解压与检查

```bash
rm -rf /tmp/SZUConnect-unzip
mkdir -p /tmp/SZUConnect-unzip
ditto -x -k /tmp/SZUConnect.app.zip /tmp/SZUConnect-unzip
plutil -p /tmp/SZUConnect-unzip/SZUConnect.app/Contents/Info.plist \
  | grep -E "CFBundleShortVersionString|CFBundleVersion"
codesign --verify --deep --strict /tmp/SZUConnect-unzip/SZUConnect.app
```

预期：`1.1.0` / `2` / 签名验证通过（ad-hoc 签名）。

## 3. 替换 App

先备份旧 App，再复制新 App。**不要直接 rm -rf 旧 App。**

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -d /Applications/SZUConnect.app ]; then
  mv /Applications/SZUConnect.app "$HOME/Desktop/SZUConnect.app.bak-$STAMP"
fi
ditto /tmp/SZUConnect-unzip/SZUConnect.app /Applications/SZUConnect.app
xattr -dr com.apple.quarantine /Applications/SZUConnect.app 2>/dev/null || true
codesign --verify --deep --strict /Applications/SZUConnect.app
plutil -p /Applications/SZUConnect.app/Contents/Info.plist | grep ShortVersion
```

如果 `/Applications` 权限不足，请让用户用管理员权限执行；不要删除旧 App。

## 4. 停用旧自动重登

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.szu.autologin.plist" 2>/dev/null || true
mv "$HOME/Library/LaunchAgents/com.szu.autologin.plist" \
   "$HOME/Desktop/com.szu.autologin.plist.disabled" 2>/dev/null || true
launchctl list | grep -i com.szu.autologin && echo "STILL LOADED" || echo "daemon not loaded"
```

**不要运行仓库里的 `install.sh` / `uninstall.sh`**：它们是旧的 launchd 自动重登方案，会重新装服务。新 App 只保留“点击登录”，首次运行也会自动停用这个服务。

## 4.1 残留自动重登录排查（只看 SZU 自动重登录程序）

只排查校园网自动重登录程序；**不要排查或修改其他 App**。

### 旧程序长什么样

旧的自动重登录是 launchd 定时任务，通常包含：

- `~/Library/LaunchAgents/com.szu.autologin.plist`
- 每 15 秒运行 `~/Library/Application Support/SZUAutoLogin/autologin.sh`
- 也可能出现在 `/Library/LaunchAgents/` 或 `/Library/LaunchDaemons/`（系统级）
- 登录项里可能有一个指向 `SZUConnect.app` 或 `autologin.sh` 的条目

### 只读检查

```bash
echo "== launchctl =="
launchctl list | grep -iE "com\.szu\.autologin|SZUAutoLogin|autologin" || echo "no loaded job"

echo "== plists =="
for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$d" ] && { echo "-- $d"; ls -la "$d" | grep -iE "szu|autologin" || true; }
done

echo "== processes =="
pgrep -fl "autologin\.sh|SZUAutoLogin" || echo "no process"

echo "== cron =="
crontab -l 2>/dev/null | grep -iE "szu|autologin" || echo "no cron"

echo "== login items =="
osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null \
  | tr ',' '\n' | grep -iE "szu|autologin|SZUConnect" || echo "no SZU login item"

echo "== script copies =="
mdfind "kMDItemFSName == 'autologin.sh'" 2>/dev/null || true

echo "== state dir =="
ls -la "$HOME/Library/Application Support/SZUAutoLogin" 2>/dev/null || true
```

如果 `osascript` 弹出自动化权限请求，允许一次即可；如果拒绝，把“无法读取登录项”写进回报。

### Mac mini 实测样例（2026-10-24）

Mac mini 上已经查过一遍，结果是：

- `launchctl`：没有 `com.szu.autologin`。
- `/Library/LaunchAgents`、`/Library/LaunchDaemons`：没有 SZU 项。
- `pgrep autologin.sh`：没有后台进程。
- `crontab`：没有 SZU 项。
- `mdfind -name autologin.sh` 找到 5 份：

  ```text
  ~/Library/Application Support/SZUAutoLogin/autologin.sh
      ← 新 App 使用的 CLI，必须保留
  ~/Desktop/SZUnet/backup/SZUConnect.app.bak/Contents/Resources/cli/autologin.sh
      ← 旧 App 备份，不会自启
  ~/Desktop/SZUnet/backup/SZUAutoLogin.bak/autologin.sh
      ← 旧 CLI 备份，不会自启
  ~/Desktop/课外项目/szu-net-autologin-mac-main/autologin.sh
      ← 旧项目副本，不会自启
  ~/szu-net-autologin/autologin.sh
      ← 旧仓库副本，不会自启
  ```

关键判断：**文件存在 ≠ 自动重登。** 只有被 `com.szu.autologin`、登录项或 cron 引用，才会自动运行。Mac mini 上真正的自动重登服务已经不在，剩下的是旧副本。

MacBook 上如果 `mdfind` 也找到多份，按同样方式分类：

1. `~/Library/Application Support/SZUAutoLogin/autologin.sh`：保留，新 App 要用。
2. 其他路径：旧备份/旧项目副本，不会自启；先列给用户，确认后再归档，不要直接删。
3. 如果 `com.szu.autologin` 或登录项引用了其中某一份，才是需要处理的自动重登。

### 处理

- 如果 `com.szu.autologin` 还在 `launchctl list`：

  ```bash
  launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.szu.autologin.plist" 2>/dev/null || true
  mv "$HOME/Library/LaunchAgents/com.szu.autologin.plist" \
     "$HOME/Desktop/com.szu.autologin.plist.disabled" 2>/dev/null || true
  ```

- 如果系统级 `/Library/LaunchAgents` 或 `/Library/LaunchDaemons` 里有 `com.szu.autologin`，先报告，让用户用管理员权限处理；不要直接删。
- 如果登录项里有 `SZUConnect` 或 `autologin`，先报告，让用户确认后删除。
- 如果 shell 启动文件（`~/.zshrc`、`~/.bash_profile`、`~/.profile`）里有 `autologin.sh` 或 `SZUConnect`，先报告，不要擅自改。
- `~/Library/Application Support/SZUAutoLogin/autologin.sh` 是**新 App 要用的登录脚本**，不要删除；旧 daemon 只是调用它。`config.sh` 也不含密码，不要动。
- Keychain 里的 `szu-portal` 是新 App 的凭据，不要删。
- `~/Library/Logs/szu-*.log` 是诊断日志，不要删。

### 预期最终状态

- `launchctl list` 里没有 `com.szu.autologin`。
- 没有后台 `autologin.sh` 进程。
- 没有 SZU 相关登录项/cron。
- 唯一触发登录的方式是点击 `SZUConnect.app`。

> 注意：仓库里的 `install.sh` / `uninstall.sh` 是旧 daemon 的安装/卸载脚本，不要运行。

## 5. 凭据检查

```bash
security find-generic-password -s szu-portal >/dev/null 2>&1 \
  && echo "credential present" || echo "credential missing"
```

如果 missing：打开 App，会弹原来的配置窗口，让用户自己输入账号/密码。**不要打印、复制或写入任何密码。**

## 6. Wi-Fi 首选顺序

```bash
WIFI_IF=$(networksetup -listallhardwareports \
  | awk '/Hardware Port: (Wi-Fi|AirPort)/{f=1;next} f&&/Device:/{print $2;exit}')
networksetup -listpreferredwirelessnetworks "$WIFI_IF"
```

`HUAWEI_2090` 应在 `SZU_WLAN` / `SZU_CTC&CMCC` 之上。若不在，请让用户在“系统设置 → Wi-Fi → 详细信息 → 已知网络”里把 `HUAWEI_2090` 拖到最上面。

不要删除校园网；校外登录需要它。App 的路由器模式识别 `HUAWEI_2090` 或网关 `192.168.1.1`；校园模式识别 `SZU_WLAN` / `SZU_CTC&CMCC`。

## 7. 在 HUAWEI_2090 上启动一次

```bash
open -a /Applications/SZUConnect.app
sleep 5
tail -30 "$HOME/Library/Logs/szu-connect-click.log"
```

预期日志：

- `识别为路由器/宿舍有线模式`
- `已经在网了，无需重连`（路由器已在线）或 `已连接 · 宿舍区`（路由器被重新登录）
- **不应出现** `尝试连接 [SZU_...]`，也不应切换 Wi-Fi
- App 版本 1.1.0

如果 MacBook 不在 `HUAWEI_2090` 上，先连上再测；不要在一个随便的咖啡店 WiFi 上测路由器模式。

## 8. 验收清单

- [ ] App 版本 = 1.1.0，`codesign --verify --deep --strict` 通过。
- [ ] `4.1` 只读审计完成：没有 `com.szu.autologin`、没有后台 `autologin.sh`、没有 SZU 登录项/cron。
- [ ] `mdfind` 找到的 `autologin.sh` 已分类：保留 `~/Library/Application Support/SZUAutoLogin/autologin.sh`，其余旧副本无自启引用。
- [ ] `com.szu.autologin` 未加载；没有 `SZUAutoLogin/autologin.sh` 在后台常驻。
- [ ] 在 `HUAWEI_2090` 上：日志出现路由器模式；不尝试校园 WiFi；已在线时不重登。
- [ ] 在校外 `SZU_WLAN` / `SZU_CTC&CMCC` 上：点 App 能加入并登录校园网；日志出现校园认证成功；Mac mini/路由器离线（预期）；Mac mini 不会自动抢回。
- [ ] 回宿舍：连回 `HUAWEI_2090`，点 MacBook 或 Mac mini 上的 App；路由器重新登录，两台 Mac 都通过 HUAWEI 上网。
- [ ] 手机/平板未被修改；它们是独立名额。

## 9. 第一次“路由器离线”测试（重要）

当前路由器在线，App 的“从路由器后面重新登录”这条路径还没有真实验证。请按自然流程测，不要故意断网：

1. MacBook 在外面点 App 连上校园网 → 路由器被顶掉。
2. 回宿舍连回 `HUAWEI_2090`，点 MacBook 或 Mac mini 上的 App。
3. 如果路由器上线 → 成功；如果失败，收集：
   - `tail -50 "$HOME/Library/Logs/szu-connect-click.log"`
   - `tail -50 "$HOME/Library/Logs/szu-autologin.log"`
   - App 的通知文字
   不要包含钥匙串密码。

## 10. 回滚

- 旧 App 在 `~/Desktop/SZUConnect.app.bak-*`，直接移回 `/Applications/SZUConnect.app`。
- 旧的 `com.szu.autologin.plist` 在 `~/Desktop/com.szu.autologin.plist.disabled`；**不建议**重新启用自动重登。

## 11. 不要做

- 不要运行仓库里的 `install.sh` / `uninstall.sh`。
- 只排查自动重登录程序；不要排查或修改其他 App。
- 不要从 MacBook 修改 Mac mini 或路由器设置。
- 不要修改手机/平板/校园网账号设置。
- 不要把 Keychain 密码、GitHub token 写进任何文件、日志或回报。

## 12. 回报格式

- App 版本 + SHA-256 校验结果。
- `4.1` 审计结果：plist、进程、登录项、cron、`mdfind` 找到的 `autologin.sh` 路径及分类（哪些是旧副本、哪些被自启项引用）。
- `launchctl list | grep com.szu.autologin` 的结果。
- 每个测试场景的最后 20 行 click log。
- 第 8 节最后一项（路由器是否恢复）的结果。
- 任何失败：附日志片段，不要附密码。

## 13. 下载入口

**如果要下这个 APP，就从这里下：**

<https://raw.githubusercontent.com/KKKKahn/szu-net-autologin/main/dist/SZUConnect.app.zip>

- 仓库：<https://github.com/KKKKahn/szu-net-autologin>
- 本文档：`MACBOOK_AGENT_INSTALL.md`
- 校验文件：`dist/SZUConnect.app.zip.sha256`
