#requires -Version 5.1
<#
.SYNOPSIS
    深圳大学校园网自动登录 —— Windows 一键安装脚本。
.DESCRIPTION
    1) 交互式录入账号密码，用 DPAPI（当前用户）加密保存到 cred.xml；
    2) 复制 autologin.ps1（及可选 config.ps1）到 %LOCALAPPDATA%\SZUAutoLogin；
    3) 注册任务计划程序：登录时启动 + 每 1 分钟重复一次（后台静默运行）。
    全程不显示、不记录、不上传密码明文。
.NOTES
    若因执行策略被拦截，请先在当前 PowerShell 窗口运行：
        Set-ExecutionPolicy -Scope Process Bypass -Force
    然后再运行本脚本。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:LOCALAPPDATA 'SZUAutoLogin'
$TaskName = 'SZU AutoLogin'

function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }

# ---------------- ① 录入账号密码 ----------------
Write-Host ''
Write-Host '深圳大学校园网自动登录 - 安装' -ForegroundColor Green
Write-Host ''
$account = Read-Host -Prompt '请输入校园网账号（6 位校园卡号）'
$passSecure = Read-Host -Prompt '请输入密码' -AsSecureString

if ([string]::IsNullOrWhiteSpace($account)) { throw '账号不能为空。' }
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passSecure)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
if ([string]::IsNullOrEmpty($plain)) { throw '密码不能为空。' }

# ---------------- ② 保存凭据（DPAPI） ----------------
Write-Step '保存凭据（DPAPI 加密，仅当前 Windows 用户可读取）'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$credObj = [pscustomobject]@{ Account = $account.Trim(); Password = $passSecure }
$credObj | Export-Clixml -Path (Join-Path $StateDir 'cred.xml')

# ---------------- ③ 复制脚本 ----------------
Write-Step "复制脚本到 $StateDir"
$src = $PSScriptRoot
Copy-Item -Path (Join-Path $src 'autologin.ps1') -Destination $StateDir -Force
$srcCfg = Join-Path $src 'config.ps1'
if (Test-Path $srcCfg) { Copy-Item -Path $srcCfg -Destination $StateDir -Force }

# ---------------- ④ 注册任务计划 ----------------
Write-Step "注册任务计划：$TaskName（登录启动，每 1 分钟重复）"
$target = Join-Path $StateDir 'autologin.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""

# 登录触发
$trigger = New-ScheduledTaskTrigger -AtLogOn
# 借用 Once 触发器的 Repetition 对象（PT1M，无限期），实现登录后每 1 分钟重复
$once = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$trigger.Repetition = $once.Repetition

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# ---------------- ⑤ 立即自检一次 ----------------
Write-Step '立即执行一次检测...'
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 6

Write-Host ''
Write-Host '安装完成！' -ForegroundColor Green
Write-Host ''
Write-Host '日志文件：' (Join-Path $StateDir 'szu-autologin.log')
Write-Host '可在“任务计划程序”中查看/管理任务：' $TaskName
Write-Host '卸载请运行 uninstall.ps1'
Write-Host ''
