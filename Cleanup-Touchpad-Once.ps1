# Cleanup-Touchpad-Once.ps1
# 由 Install-PowerSaverTasks-v2.ps1 创建的一次性 SYSTEM 任务运行 (Enum 键只有 SYSTEM 稳定可写)
# 作用: 恢复旧脚本残留的触摸板注册表值 (EPM/D3Cold 被设为 0), 恢复系统默认 1
# 结束后自删任务 PowerSaver_TouchpadCleanup
$logFile = "D:\Scripts\powersaver-touchpad-cleanup.log"

Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  cleanup start"

$p = "HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\SYNA2BA6\1\Device Parameters"
$ok = $true

try {
    Set-ItemProperty -Path $p -Name "EnhancedPowerManagementEnabled" -Value 1 -Type DWord -ErrorAction Stop
    Add-Content $logFile "  EPM -> 1 OK"
} catch {
    $ok = $false
    Add-Content $logFile "  EPM restore failed: $_"
}

$d3 = "$p\e5b3b5ac-9725-4f78-963f-03dfb1d828c7"
try {
    Set-ItemProperty -Path $d3 -Name "D3ColdSupported" -Value 1 -Type DWord -ErrorAction Stop
    Add-Content $logFile "  D3Cold -> 1 OK"
} catch {
    $ok = $false
    Add-Content $logFile "  D3Cold restore failed: $_"
}

schtasks /Delete /TN "PowerSaver_TouchpadCleanup" /F 2>$null | Out-Null
Add-Content $logFile "  done, ok=$ok, task self-deleted"
