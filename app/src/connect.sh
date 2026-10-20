#!/bin/bash
# ============================================================
# 深大校园网 · 一键连接（桌面 app 入口）
#
# 作用：双击后立即执行一次"检查 + 网页登录"，不打开终端窗口。
#       与 launchd 定时服务共用同一套脚本与钥匙串凭据。
#       首次运行会弹窗让你填一次账号密码，之后不再打扰。
# 结束时会用系统通知 / 弹窗给出结果。
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin

APP_SUPPORT="$HOME/Library/Application Support/SZUAutoLogin"
SCRIPT="$APP_SUPPORT/autologin.sh"
CONFIG="$APP_SUPPORT/config.sh"
LOG="$HOME/Library/Logs/szu-autologin.log"
LAST_FILE="$APP_SUPPORT/.last_login"
LOCKDIR="/tmp/.szu-connect.lock"
CHECK_URL="https://www.baidu.com"
SELFLOG="$HOME/Library/Logs/szu-connect-click.log"
KC_SERVICE="szu-portal"

# app 自带一份登录脚本，首次点击时自动铺设，用户无需另外 clone 仓库
RES_DIR="$(cd "$(dirname "$0")/../Resources" 2>/dev/null && pwd)"
CLI_DIR="$RES_DIR/cli"
SETUP_APP="$RES_DIR/SZUConnectSetup.app"

# 单次点击会写几十行，方便事后定位；文件超 500KB 只留最近 800 行，避免无限膨胀
if [ -f "$SELFLOG" ]; then
  _sz=$(wc -c < "$SELFLOG" 2>/dev/null | tr -d ' ')
  if [ "${_sz:-0}" -gt 512000 ] 2>/dev/null; then
    tail -n 800 "$SELFLOG" > "$SELFLOG.tmp" 2>/dev/null && mv "$SELFLOG.tmp" "$SELFLOG"
  fi
fi

# 所有日志都带 [+Ns]（脚本已运行秒数），这样能直接看出卡在哪一步、每步花了多久
plog() { printf '%s [+%ss] %s\n' "$(date '+%H:%M:%S')" "$SECONDS" "$*" >> "$SELFLOG" 2>/dev/null; }

# ---------- 通知 ----------
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

notify() {  # $1=标题 $2=正文 $3=音效(可空)
  local t m s
  t=$(esc "$1"); m=$(esc "$2"); s="$3"
  plog "NOTIFY [$t] $m"
  if [ -n "$s" ]; then
    osascript -e "display notification \"$m\" with title \"$t\" sound name \"$s\"" >/dev/null 2>&1
    # 通知可能被"勿扰/专注模式"拦截，音效单独播放作为兜底反馈
    # 后台播放：afplay 默认会阻塞到声音放完，没必要让它拖慢主流程
    [ -f "/System/Library/Sounds/$s.aiff" ] && afplay "/System/Library/Sounds/$s.aiff" >/dev/null 2>&1 &
  else
    osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1
  fi
}

alert() {  # 失败时弹窗，确保一定被看到
  plog "ALERT [$1] $2"
  afplay "/System/Library/Sounds/Basso.aiff" >/dev/null 2>&1 &
  osascript -e "display dialog \"$(esc "$2")\" with title \"$(esc "$1")\" buttons {\"好\"} default button 1 with icon caution" >/dev/null 2>&1
}

# ---------- 首次配置 ----------
# 凭据只存在本机钥匙串（服务名 szu-portal），app 本身不含任何账号信息
has_cred() {
  [ -n "$(security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null)" ]
}

run_setup() {              # 打开原生配置窗口；用户保存成功返回 0
  if [ ! -d "$SETUP_APP" ]; then
    plog "缺少配置窗口组件: $SETUP_APP"
    alert "校园网连接" "安装包不完整（缺少配置窗口），请重新下载安装。"
    return 1
  fi
  plog "打开首次配置窗口"
  open -W -n "$SETUP_APP" 2>/dev/null
  has_cred
}

ask_redo_cred() {          # 认证失败时问是否重新输入；选"重新输入"返回 0
  osascript -e 'display dialog "账号或密码没有通过认证，要重新输入吗？" with title "校园网连接失败" buttons {"取消", "重新输入"} default button "重新输入" with icon caution' >/dev/null 2>&1
}

ensure_cli() {             # 登录脚本没装过就从 app 自带的 Resources 铺设一份
  if [ -x "$SCRIPT" ]; then return 0; fi
  plog "本地还没有登录脚本，从 app 内置副本安装到 $APP_SUPPORT"
  if [ ! -f "$CLI_DIR/autologin.sh" ]; then
    alert "校园网连接" "安装包不完整（缺少登录脚本），请重新下载安装。"
    return 1
  fi
  mkdir -p "$APP_SUPPORT" 2>/dev/null
  cp "$CLI_DIR/autologin.sh" "$SCRIPT" 2>/dev/null && chmod +x "$SCRIPT" 2>/dev/null || {
    alert "校园网连接" "无法写入 ${APP_SUPPORT}，请检查磁盘权限。"
    return 1
  }
  [ -f "$CONFIG" ] || cp "$CLI_DIR/config.example.sh" "$CONFIG" 2>/dev/null
  plog "登录脚本已就位"
  return 0
}

# ---------- 在线判定 ----------
# 离线时这个探测必然走满整个超时（未认证时请求会被静默丢弃），
# 所以超时值直接等于"白等多久"。默认压到 3 秒，需要时再传大一点。
is_online() {
  local code tmo="${1:-3}"
  code=$(curl -s -m "$tmo" -o /dev/null -w '%{http_code}' "$CHECK_URL" 2>/dev/null)
  plog "  在线探测 $CHECK_URL → HTTP ${code:-超时}（上限 ${tmo}s）"
  [ "$code" = "200" ]
}

# 读取当前 WiFi 名（与 autologin.sh 同款方法：ipconfig 数据键固定英文，
# networksetup 仅在兜底时用，兼容中英文系统）
wifi_name() {
  local s
  s="$(ipconfig getsummary "$WIFI_IF" 2>/dev/null | awk -F' : ' '/^[[:space:]]*SSID/{print $2; exit}')"
  if [ -n "$s" ]; then
    printf '%s' "$s"; return
  fi
  networksetup -getairportnetwork "$WIFI_IF" 2>/dev/null \
    | sed -n -e 's/^Current Wi-Fi Network: //p' -e 's/^当前 Wi-Fi 网络: //p' | head -1
}

wifi_name_fast() {         # 只读 ipconfig（约 0.13s），给高频轮询用；空=未关联
  ipconfig getsummary "$WIFI_IF" 2>/dev/null \
    | awk -F' : ' '/^[[:space:]]*SSID/{print $2; exit}'
}

# ---------- WiFi 控制（关着自动开、没连校园网自动切） ----------
WIFI_IF="$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Hardware Port: (Wi-Fi|AirPort)/{f=1;next} f&&/Device:/{print $2;exit}')"
WIFI_IF="${WIFI_IF:-en0}"
CAMPUS_SSIDS=("SZU_WLAN" "SZU-WLAN" "SZU_CTC&CMCC")

wifi_is_on() { ! networksetup -getairportpower "$WIFI_IF" 2>/dev/null | grep -qiE "off|关闭"; }

wifi_power_on() {          # 关着就打开，并等射频就绪；成功返回 0
  local i out
  wifi_is_on && return 0   # 状态已由 ensure_campus_wifi 记录
  plog "  电源: 执行 setairportpower on"
  out=$(networksetup -setairportpower "$WIFI_IF" on 2>&1)
  [ -n "$out" ] && plog "  setairportpower 返回: $out"
  for i in $(seq 1 20); do
    wifi_is_on && break
    sleep 0.3
  done
  plog "  电源: 已就绪（等待 $((i * 3 / 10))s）"
  # 这里不再盲等固定 3 秒：驱动是否扫到周边网络，交给 join_campus 的
  # "连不上就重试"兜底——就绪得快就立刻连上，不再白等。
  wifi_is_on
}

is_campus_ssid() {
  local s="$1" t
  [ -n "$s" ] || return 1
  for t in "${CAMPUS_SSIDS[@]}"; do [ "$s" = "$t" ] && return 0; done
  return 1
}

wait_for_ip() {            # 等 DHCP 把 IP 配下来，最多 15 秒；成功返回 0
  local i ip
  for i in $(seq 1 50); do
    ip=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)
    [ -n "$ip" ] && { plog "  IP 已就绪: ${ip}（等待 $((i * 3 / 10)).$(( (i * 3) % 10 ))s）"; return 0; }
    sleep 0.3
  done
  plog "  ⚠ 15 秒内仍未拿到 IP（认证大概率会失败）"
  return 1
}

join_ssid() {              # 连指定 SSID。注意：setairportnetwork 失败也返回 0，
  local ssid="$1" i j out ip cur   # 所以只能靠"SSID 是否真的变过去"来判断成败
  plog "  尝试连接 [$ssid]"
  out=$(networksetup -setairportnetwork "$WIFI_IF" "$ssid" 2>&1)
  [ -n "$out" ] && plog "    setairportnetwork 返回: $out"
  # 附近根本没有这个网络 / 需要密码 → 立刻判失败，不必空等
  case "$out" in
    *"Could not find"*|*"找不到"*|*"password"*|*"密码"*)
      plog "    失败: 网络不存在或需要密码"
      return 1 ;;
  esac
  for i in $(seq 1 24); do
    cur=$(wifi_name_fast)
    if [ "$cur" = "$ssid" ]; then
      plog "    已关联 [$ssid]，等待分配 IP"
      for j in $(seq 1 20); do
        ip=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null)
        [ -n "$ip" ] && { plog "    拿到 IP=${ip}，耗时约 $((j * 3 / 10)).$(( (j * 3) % 10 ))s"; return 0; }
        sleep 0.3
      done
      plog "    已关联但 6 秒内没拿到 IP，继续往下走"
      return 0             # 已关联但 IP 还没下来，交给后续认证流程
    fi
    sleep 0.3
  done
  plog "    超时: 7 秒内 SSID 未变成 [$ssid]，当前=[$(wifi_name_fast)]"
  return 1
}

join_campus() {            # $1=最多重试轮数。逐个尝试校园网 SSID；
  local round s cur max="${1:-2}"   # 驱动没扫完就等 1 秒再试，不盲等固定秒数
  for round in $(seq 1 "$max"); do
    # macOS 有时会自己把上次的校园网重连回来，先看一眼，能省一批命令
    cur=$(wifi_name_fast)
    if is_campus_ssid "$cur"; then
      plog "  系统已自动连上 [$cur]"
      wait_for_ip
      return 0
    fi
    for s in "${CAMPUS_SSIDS[@]}"; do
      join_ssid "$s" && return 0
    done
    if [ "$round" -lt "$max" ]; then
      plog "  第 ${round} 轮没连上（驱动可能还在扫描），1 秒后重试"
      sleep 1
    fi
  done
  return 1
}

ensure_campus_wifi() {     # 0=本来就在校园网 1=本次连上了 2=附近无校园网 3=WiFi 打不开
  local cur need=0 rounds=2
  plog "--- [1/3] WiFi 保障开始（接口 ${WIFI_IF}）---"
  if [ "${PRE_OFF:-0}" = 1 ]; then
    need=1
    plog "  电源: 原本关闭（启动时已抢先打开）"
  else
    plog "  电源: 已开启"
    cur=$(wifi_name_fast)
    plog "  当前 SSID=[${cur:-无}]"
    is_campus_ssid "$cur" || need=1
  fi
  # 只要需要动 WiFi（开开关或换网络），动手前先"啵"一声，
  # 让用户知道点到了、正在处理，而不是以为没反应
  if [ "$need" = 1 ]; then
    plog "  需要介入 WiFi（关着 或 不在校园网）→ 播放提示音"
    afplay /System/Library/Sounds/Pop.aiff >/dev/null 2>&1 &
  else
    plog "  已在校园网，无需切换"
  fi

  wifi_power_on || { plog "  ✗ WiFi 打不开"; return 3; }
  cur=$(wifi_name_fast)
  # 注意：WiFi 一开，macOS 常会自动重连上次的网络，这条路径不经过 join_ssid，
  # 所以必须自己等一次 DHCP，否则会拿"没有 IP 的网络"去认证 → challenge 全不可达
  if is_campus_ssid "$cur"; then
    plog "  结果: 留在 [$cur]"
    wait_for_ip
    return 0
  fi
  plog "  SSID [${cur:-空}] 不是校园网，开始尝试: ${CAMPUS_SSIDS[*]}"
  # 刚开射频时驱动还没扫完，多给几轮；本来就在扫描状态的，最多试 2 轮就走，
  # 免得"附近确实没有校园网"时白等好几秒
  [ "${PRE_OFF:-0}" = 1 ] && rounds=6
  join_campus "$rounds" && { plog "  ✓ 已连接 [$(wifi_name_fast)]"; return 1; }
  plog "  ✗ 所有校园网 SSID 均未连上"
  return 2
}

# ---------- 执行一次网页认证（结果回填到全局变量 new） ----------
do_auth() {
  local before after run_start rc_script pid watcher
  before=0
  [ -f "$LOG" ] && before=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  [ -n "$before" ] || before=0

  plog "--- [3/3] 执行网页认证（脚本基线 ${before} 行）---"
  RUNOUT="/tmp/szu-connect-run-$$.out"
  run_start=$SECONDS
  "$SCRIPT" > "$RUNOUT" 2>&1 &
  pid=$!
  ( sleep 75; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null
  rc_script=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  plog "登录脚本退出码=${rc_script}，耗时 $((SECONDS - run_start))s"
  if [ -s "$RUNOUT" ]; then
    plog "脚本原始输出: $(tr '\n' '|' < "$RUNOUT" 2>/dev/null | cut -c1-800)"
  else
    plog "脚本无 stdout/stderr 输出（正常，它只写自己的日志）"
  fi
  rm -f "$RUNOUT" 2>/dev/null

  after=0
  [ -f "$LOG" ] && after=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  [ -n "$after" ] || after=0
  new=""
  if [ "$after" -gt "$before" ]; then
    new=$(tail -n "+$((before + 1))" "$LOG" 2>/dev/null)
  fi
  plog "脚本新增日志行数: $((after - before))"
  [ -n "$new" ] && plog "新增内容: $(printf '%s' "$new" | tr '\n' '|')"
}

# 根据 do_auth 回填的 $new 给出结果通知；成功返回 0
report_auth_result() {
  printf '%s' "$new" | grep -q "成功" || return 1
  local zone
  zone=$(printf '%s' "$new" | grep -oE "教学区|宿舍区" | head -1)
  plog "分支: 认证成功（区域 ${zone:-未识别}）"
  if [ -n "$zone" ]; then
    notify "校园网" "已连接 · ${zone} ✓" "Glass"
  else
    notify "校园网" "已连接 ✓" "Glass"
  fi
  return 0
}

# ---------- 并发锁 ----------
acquire_lock() {
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    local mtime age
    mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    if [ "$age" -lt 120 ]; then
      plog "上一次还在跑（锁 ${age}s），本次跳过"
      notify "校园网" "正在连接中，请稍候…"
      exit 0
    fi
    plog "发现残留锁（${age}s），已清理"
    rm -rf "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
  fi
  # 退出时统一收尾：记录总耗时 + 释放锁
  trap 'plog "========== 结束，总耗时 ${SECONDS}s =========="; rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
}

# ---------- 主流程 ----------
acquire_lock
plog ""
plog "################ 点击触发 $(date '+%Y-%m-%d %H:%M:%S') ################"

# 1) 依赖就位：登录脚本没装过就从 app 内自带的副本铺一份
ensure_cli || exit 1

# 2) 凭据：第一次点（或传 --setup 想换账号）才弹配置窗口，之后不再打扰
if [ "${1:-}" = "--setup" ] || ! has_cred; then
  if [ "${1:-}" = "--setup" ]; then
    plog "收到 --setup，主动打开配置窗口"
  else
    plog "钥匙串里还没有凭据 → 首次配置"
  fi
  if ! run_setup; then
    plog "用户取消或保存失败，结束"
    notify "校园网" "还没有保存账号，已取消连接" "Basso"
    exit 0
  fi
  plog "凭据已保存"
fi

# 3) 抢时间：WiFi 关着就立刻开射频，不把这几百毫秒花在写日志上
PRE_OFF=0
wifi_is_on || { PRE_OFF=1; networksetup -setairportpower "$WIFI_IF" on >/dev/null 2>&1; }

plog "环境: macOS $(sw_vers -productVersion 2>/dev/null) | 接口 $WIFI_IF | 电源 $([ "$PRE_OFF" = 1 ] && printf 'Off → 已开' || printf 'On')"

# 0) 先保证站在校园网 WiFi 上：WiFi 关着就打开，开着但没连校园网就切过去
ensure_campus_wifi
wifi_state=$?
plog "--- [1/3] WiFi 保障返回 ${wifi_state}，当前 SSID=[$(wifi_name)]（0=本就在 1=本次连上 2=找不到 3=打不开）---"

case "$wifi_state" in
  3)
    plog "分支: WiFi 无法打开"
    notify "校园网" "Wi-Fi 打不开，请到控制中心手动开启后重试" "Basso"
    exit 0 ;;
  2)
    plog "分支: 附近没有可用校园网"
    if is_online; then
      notify "校园网" "附近没有校园网信号，已保持当前网络不动" "Basso"
    else
      notify "校园网" "找不到 SZU_WLAN / SZU_CTC&CMCC，可能是离得太远或不在校内" "Basso"
    fi
    exit 0 ;;
esac

# 1) 已经在线就不用折腾
#    wifi_state=1 表示"这次才刚连上这个网络"，此时必然还没过认证，
#    再探测一次只会白等超时（离线时 curl 会走满整个超时），直接跳过
if [ "$wifi_state" = 1 ]; then
  plog "--- [2/3] 跳过连通性探测（刚接入的网络必然未认证）---"
else
  plog "--- [2/3] 连通性检查 ---"
  if is_online 3; then
    plog "分支: 已在线，直接退出"
    notify "校园网" "已经在网了，无需重连" "Glass"
    exit 0
  fi
fi
plog "当前不在线，准备登录"

# 2) 清掉冷却时间戳，允许本次立即重试
#    （该文件只在"确认离线"后才被读取，删除对在线状态无副作用）
if [ -f "$LAST_FILE" ]; then
  plog "清掉冷却时间戳（原值 $(cat "$LAST_FILE" 2>/dev/null)）"
  rm -f "$LAST_FILE" 2>/dev/null
fi

# 3) 执行认证；若报"网络未就绪"（WiFi 刚起来常见），等几秒自动重试一次，
#    免得用户还得手动点第二下
do_auth
if printf '%s' "$new" | grep -q "未就绪\|跳过本轮"; then
  plog "首次认证报网络未就绪 → 等 6 秒自动重试一次"
  sleep 6
  rm -f "$LAST_FILE" 2>/dev/null
  do_auth
fi

if report_auth_result; then
  :
elif printf '%s' "$new" | grep -q "未在钥匙串"; then
  plog "分支: 钥匙串无凭据"
  if run_setup; then
    rm -f "$LAST_FILE" 2>/dev/null
    do_auth
    report_auth_result || alert "校园网连接失败" "已保存账号，但认证仍未通过，请再点一次图标。"
  fi
elif printf '%s' "$new" | grep -q "未就绪\|跳过本轮"; then
  plog "分支: 网络未就绪"
  notify "校园网" "网络尚未就绪，稍后再点一次" "Basso"
elif printf '%s' "$new" | grep -q "失败"; then
  reason=$(printf '%s' "$new" | grep "失败" | tail -1 | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9:]\{8\} //')
  plog "分支: 认证失败 → ${reason}"
  # 账号/密码类错误直接给"重新输入"入口，省得用户去终端敲命令
  if printf '%s' "$reason" | grep -qE "密码|账号|凭据"; then
    if ask_redo_cred && run_setup; then
      rm -f "$LAST_FILE" 2>/dev/null
      do_auth
      report_auth_result || alert "校园网连接失败" "换过账号密码后仍未通过，请确认有没有输错。"
    fi
  else
    alert "校园网连接失败" "$reason"
  fi
else
  # 没有产生新日志：WiFi 已就位但认证没写日志，再确认一次连通性
  plog "分支: 脚本没有新增日志，复查连通性"
  sleep 1
  if is_online; then
    notify "校园网" "已连接 ✓" "Glass"
  else
    notify "校园网" "已连上校园 WiFi，但认证服务器没响应，等几秒再点一次" "Basso"
  fi
fi

exit 0
