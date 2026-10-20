#requires -Version 5.1
<#
.SYNOPSIS
    深圳大学校园网自动登录 —— Windows 卸载脚本。
.DESCRIPTION
    删除任务计划与脚本；可选择是否一并删除 DPAPI 加密保存的账号密码。
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'

$StateDir = Join-Path $env:LOCALAPPDATA 'SZUAutoLogin'
$TaskName = 'SZU AutoLogin'

Write-Host ''
Write-Host '深圳大学校园网自动登录 - 卸载' -ForegroundColor Green
Write-Host ''

# ---------------- ① 删除任务计划 ----------------
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
} catch {}
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host '==> 已删除任务计划' -ForegroundColor Cyan
} catch {
    Write-Host '==> 任务计划不存在或已删除，跳过' -ForegroundColor DarkGray
}

# ---------------- ② 决定是否删除凭据 ----------------
$delCred = Read-Host '是否同时删除保存的校园网账号密码？ [y/N]'
if ($delCred -eq 'y' -or $delCred -eq 'Y') {
    if (Test-Path $StateDir) { Remove-Item -Path $StateDir -Recurse -Force }
    Write-Host '==> 已删除脚本与凭据' -ForegroundColor Cyan
} else {
    # 仅删除脚本，保留 cred.xml
    foreach ($f in @('autologin.ps1', 'config.ps1')) {
        $p = Join-Path $StateDir $f
        if (Test-Path $p) { Remove-Item -Path $p -Force }
    }
    Write-Host '==> 已删除脚本，凭据保留（重装无需再输）' -ForegroundColor Cyan
}

Write-Host ''
Write-Host '==== 卸载完成 ====' -ForegroundColor Green
Write-Host ''
Write-Host '运行日志（如仍存在）：' (Join-Path $StateDir 'szu-autologin.log')
Write-Host '不想要日志可手动删除该文件或整个文件夹。'
Write-Host ''
