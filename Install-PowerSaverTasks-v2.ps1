# Install-PowerSaverTasks-v2.ps1 - Run as Administrator once
# 1. 停用旧任务 PowerSaver_OnBattery / PowerSaver_OnAC (保留, 可 /ENABLE 回滚)
# 2. 创建新任务 PowerSaver_OnBattery_v2 / PowerSaver_OnAC_v2 -> PowerSaver-v2.ps1
# 3. 桌面快捷方式改指 v2 (-Mode Auto)
# 4. 以 SYSTEM 运行一次性任务, 恢复旧脚本残留的触摸板注册表值 (EPM/D3Cold), 任务自删
# 5. 立即运行一次 v2 应用当前电源状态
# 注意: EAP 必须用 Continue — PS 5.1 在 Stop 下 2>$null 对原生命令无效,
#       删除不存在的任务会把 stderr 变成终止性错误直接杀死脚本
$ErrorActionPreference = "Continue"

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Run as Administrator" -ForegroundColor Red
    pause
    exit 1
}

$scriptDir = "D:\Scripts"
$v2Script = "$scriptDir\PowerSaver-v2.ps1"
$cleanupScript = "$scriptDir\Cleanup-Touchpad-Once.ps1"
$psCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File"

if (-not (Test-Path $v2Script)) { Write-Host "Missing: $v2Script" -ForegroundColor Red; pause; exit 1 }

Write-Host "===== PowerSaver v2 Task Installer =====" -ForegroundColor Cyan
Write-Host ""

# --- 1. Disable old tasks (keep for rollback) ---
Write-Host "Disabling old tasks (kept for rollback) ..." -ForegroundColor Cyan
cmd /c "schtasks /Change /TN PowerSaver_OnBattery /DISABLE 2>nul"
Write-Host "  PowerSaver_OnBattery -> disabled"
cmd /c "schtasks /Change /TN PowerSaver_OnAC /DISABLE 2>nul"
Write-Host "  PowerSaver_OnAC -> disabled"

$user = "$env:USERDOMAIN\$env:USERNAME"

# --- 2. Create v2 tasks ---
Write-Host "Creating PowerSaver_OnBattery_v2 ..." -ForegroundColor Cyan
$batteryCmd = "$psCmd `"$v2Script`" -Mode Battery"
$batteryFilter = "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=105]]"
schtasks /Create /TN "PowerSaver_OnBattery_v2" /TR "$batteryCmd" /SC ONEVENT /EC System /MO "$batteryFilter" /RU "$user" /RL HIGHEST /F 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  [OK] PowerSaver_OnBattery_v2" -ForegroundColor Green }
else { Write-Host "  [FAIL] PowerSaver_OnBattery_v2 (exit: $LASTEXITCODE)" -ForegroundColor Red }

Write-Host "Creating PowerSaver_OnAC_v2 ..." -ForegroundColor Cyan
$acCmd = "$psCmd `"$v2Script`" -Mode AC"
$acFilter = "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=104]]"
schtasks /Create /TN "PowerSaver_OnAC_v2" /TR "$acCmd" /SC ONEVENT /EC System /MO "$acFilter" /RU "$user" /RL HIGHEST /F 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  [OK] PowerSaver_OnAC_v2" -ForegroundColor Green }
else { Write-Host "  [FAIL] PowerSaver_OnAC_v2 (exit: $LASTEXITCODE)" -ForegroundColor Red }

# Fix default task settings that prevent running on battery
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Set-ScheduledTask -TaskName "PowerSaver_OnBattery_v2" -Settings $taskSettings | Out-Null
Set-ScheduledTask -TaskName "PowerSaver_OnAC_v2" -Settings $taskSettings | Out-Null
Write-Host "  [OK] Task settings fixed (AllowStartIfOnBatteries)" -ForegroundColor Green

# --- 3. Repoint desktop shortcut to v2 ---
Write-Host "Updating desktop shortcut -> v2 ..." -ForegroundColor Cyan
$desktop = [Environment]::GetFolderPath("Desktop")
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut("$desktop\Toggle Power Mode.lnk")
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$v2Script`" -Mode Menu"
$shortcut.WorkingDirectory = $scriptDir
$shortcut.WindowStyle = 7
$shortcut.IconLocation = "shell32.dll,167"
$shortcut.Save()
Write-Host "  [OK] Toggle Power Mode.lnk -> PowerSaver-v2.ps1 -Mode Menu" -ForegroundColor Green

# --- 4. Restore leftover touchpad reg values: direct elevated write first, SYSTEM task fallback ---
# 本机实测: 管理员直写可成功; 而 SYSTEM 任务在此机器上不派发, 只能作兜底
Write-Host "Restoring touchpad reg leftovers ..." -ForegroundColor Cyan
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\SYNA2BA6\1\Device Parameters"
$restored = $true
try {
    Set-ItemProperty -Path $regPath -Name "EnhancedPowerManagementEnabled" -Value 1 -Type DWord -ErrorAction Stop
} catch {
    $restored = $false
    Write-Host "  EPM direct write failed: $_" -ForegroundColor Yellow
}
try {
    Set-ItemProperty -Path "$regPath\e5b3b5ac-9725-4f78-963f-03dfb1d828c7" -Name "D3ColdSupported" -Value 1 -Type DWord -ErrorAction Stop
} catch {
    $restored = $false
    Write-Host "  D3Cold direct write failed: $_" -ForegroundColor Yellow
}
if ($restored) {
    Write-Host "  [OK] EPM/D3Cold -> 1 (direct write)" -ForegroundColor Green
} else {
    Write-Host "  Direct write failed; falling back to SYSTEM one-shot task (may not dispatch on this machine)" -ForegroundColor Yellow
    if (Test-Path $cleanupScript) {
        schtasks /Delete /TN "PowerSaver_TouchpadCleanup" /F 2>&1 | Out-Null
        schtasks /Create /TN "PowerSaver_TouchpadCleanup" /TR "$psCmd `"$cleanupScript`"" /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
        schtasks /Run /TN "PowerSaver_TouchpadCleanup" 2>&1 | Out-Null
        Write-Host "  cleanup task launched; log: D:\Scripts\powersaver-touchpad-cleanup.log" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] cleanup script missing: $cleanupScript" -ForegroundColor Yellow
    }
}

# --- 5. Apply current power state once ---
Write-Host "Applying current power state (v2) ..." -ForegroundColor Cyan
& powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "$v2Script" -Mode Auto
Write-Host "  done (see $env:USERPROFILE\powersaver-v2.log)" -ForegroundColor Green

Write-Host ""
Write-Host "===== DONE =====" -ForegroundColor Cyan
Write-Host "Auto-trigger: PowerSaver_OnBattery_v2 (unplug) / PowerSaver_OnAC_v2 (plug in)" -ForegroundColor White
Write-Host "Manual toggle: desktop shortcut (now points to v2)" -ForegroundColor White
Write-Host "Rollback: schtasks /Change /TN PowerSaver_OnBattery /ENABLE (and _OnAC)" -ForegroundColor White
Write-Host ""
pause
