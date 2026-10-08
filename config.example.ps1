# ============================================================
# Windows 版可选配置示例
# 用法：复制本文件为 config.ps1（与 autologin.ps1 同目录），按需取消注释修改。
# 注意：config.ps1 已被 .gitignore 排除，不会上传到仓库。
# 深圳大学用户通常无需任何修改。
# ============================================================

# --- WiFi 名称（SSID）列表 ---
# $DormSSIDs  = @('SZU_CTC&CMCC')            # 宿舍区
# $TeachSSIDs = @('SZU_WLAN', 'SZU-WLAN')    # 教学区

# --- 教学区深澜（Srun）---
# $SrunBase   = 'https://net.szu.edu.cn'     # 门户域名
# $SrunAuthIP = '172.31.63.36'              # 认证服务器 IP（未登录时的主通道）
# $SrunAcId   = '8'                         # ac_id 兜底值（登录前会动态获取）

# --- 宿舍区新版 eportal ---
# $DormPortalUrl  = 'http://172.30.255.42:801/eportal/portal/login'
# $DormPortalHost = 'http://172.30.255.42:801/'

# --- 区域识别用 IP 段前缀 ---
# $DormNetPrefix  = '172.24.'
# $TeachNetPrefix = '172.26.'

# --- 行为参数 ---
# $WiredMode     = 1       # 有线/无法识别时按宿舍区处理（0=不处理）
# $LoginCooldown = 100     # 登录失败冷却（秒）
# $DebugNet      = 1       # 1=输出区域识别/网络诊断日志；0=更安静
# $HttpTimeout   = 8       # 单次 HTTP 超时（秒）
