# PowerSaver-v2.ps1
# 用法:
#   powershell.exe -ExecutionPolicy Bypass -File PowerSaver-v2.ps1 -Mode Battery|AC|Auto
#   -Force       忽略 LastMode 幂等检查, 强制重新应用
#   -DryRun      只探测不修改 (所有写操作跳过)
#   -CpuCap N    覆盖 CPU 上限 (默认 80; -1 = 用配置文件值或默认)
#   -LogPath / -ConfigPath  覆盖日志/配置文件路径 (测试用)
#
# v2 修复内容 (对应旧版问题):
#   A. 恢复链: 保存原方案时不再用空对象覆盖已有 config
#   B. CPU 上限: 写入与删除都显式指向节能方案 GUID (旧版写节能删高性能, 永久残留)
#   C. 视觉效果: 自动化 (7 项动画 SystemParametersInfo 开关), 不再弹窗要求手动
#   D. WiFi: 节能方案出厂 DC 已是最省电(3), 无需再写
#   E. 触摸板: 移除注册表段 (方向反省电 + 权限不稳); 残留值由一次性清理脚本恢复
#   F. 健壮性: Get-CimInstance 替代 Get-WmiObject / 互斥锁 / 幂等 / 日志轮转 / 原子写 config
#   G. Lenovo 接口: 探测结果缓存到 config, 避免每次重复探测; 修复类名 (LENOVO_SET_FAN_TABLE_MODE -> LENOVO_FAN_TABLE_DATA);
#      Lenovo Process Management Event 只读探测, 不写入 (接口未验证)

param(
    [ValidateSet("Battery", "AC", "Auto")]
    [string] $Mode = "Auto",

    [switch] $Force,
    [switch] $DryRun,

    [ValidateRange(-1, 100)]
    [int] $CpuCap = -1,

    [string] $LogPath = "$env:USERPROFILE\powersaver-v2.log",
    [string] $ConfigPath = "$env:USERPROFILE\powersaver-v2.config.json"
)

$ErrorActionPreference = "Continue"

# ============================================================
# 常量
# ============================================================
$script:PowerSaverGUID  = "a1841308-3541-4fab-bc81-f71556f20b4a"   # 节能
$script:HighPerfGUID    = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"   # 高性能 (25H2 上被隐藏但仍可切换)
$script:SubProcessor    = "54533251-82be-4824-96c1-47b60b740d00"
$script:ProcThrottleMax = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$script:SubBattery      = "e73a048d-bf27-4f12-9731-8b2076e8891f"
$script:LenovoPme       = "71042a74-67c5-4a2d-9f50-dbf79f9e4899"   # Lenovo Process Management Event
$script:MaxPerfOverlay  = "ded574b5-45a0-4f42-8737-46345c09c238"   # 最大性能叠加方案

$script:FxEffects = @(
    @{ Name = "MenuAnimation";           Get = 0x1002; Set = 0x1003 },
    @{ Name = "ComboBoxAnimation";       Get = 0x1004; Set = 0x1005 },
    @{ Name = "ListBoxSmoothScrolling";  Get = 0x1006; Set = 0x1007 },
    @{ Name = "CursorShadow";            Get = 0x101A; Set = 0x101B },
    @{ Name = "DragFullWindows";         Get = 0x1024; Set = 0x1025 },
    @{ Name = "UIEffects";               Get = 0x103E; Set = 0x103F },
    @{ Name = "ClientAreaAnimation";     Get = 0x1042; Set = 0x1043 }
)

# ============================================================
# 日志 (含轮转, 256KB)
# ============================================================
function Write-Log($msg) {
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "$stamp  [V2]  $msg"
        if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 256KB)) {
            Remove-Item "$($script:LogPath).old" -Force -ErrorAction SilentlyContinue
            Move-Item $script:LogPath "$($script:LogPath).old" -Force -ErrorAction SilentlyContinue
        }
        $line | Out-File $script:LogPath -Append -Encoding UTF8
    } catch { }
}

# ============================================================
# config 读写 (原子写)
# ============================================================
function New-DefaultConfig {
    return [pscustomobject]@{
        PowerScheme     = $null
        LastMode        = $null
        CpuCapDc        = $null
        LenovoInterface = $null
        VisualFX        = $null
    }
}

function Load-Config {
    $c = New-DefaultConfig
    if (Test-Path $script:ConfigPath) {
        try {
            $loaded = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($loaded) {
                foreach ($p in $loaded.PSObject.Properties) {
                    $c.$($p.Name) = $p.Value
                }
            }
        } catch {
            Write-Log "Config parse failed: $_"
        }
    } else {
        Write-Log "No config found; starting fresh"
    }
    return $c
}

function Save-Config($cfg) {
    try {
        $tmp = "$($script:ConfigPath).tmp"
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $script:ConfigPath -Force
        Write-Log "Config saved"
    } catch {
        Write-Log "Config save failed: $_"
    }
}

# ============================================================
# 电源方案工具
# ============================================================
function Get-ActiveSchemeGuid {
    $out = powercfg /GETACTIVESCHEME 2>&1 | Out-String
    if ($out -match '([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})') {
        return $matches[1]
    }
    return $null
}

function Get-PowerSource {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($b -and $b.BatteryStatus -eq 1) { return "Battery" }
    return "AC"
}

# ============================================================
# 视觉效果 (SystemParametersInfo, 立即生效, 不重启 explorer)
# ============================================================
$script:FxTypeReady = $false

function Ensure-FxType {
    if ($script:FxTypeReady) { return }
    if (-not ("WinPower.SysParam" -as [type])) {
        $src = @'
using System;
using System.Runtime.InteropServices;
namespace WinPower {
    public static class SysParam {
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfo", SetLastError = true)]
        public static extern bool SystemParametersInfoGet(uint uiAction, uint uiParam, ref uint pvParam, uint fWinIni);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfo", SetLastError = true)]
        public static extern bool SystemParametersInfoSet(uint uiAction, uint uiParam, uint pvParam, uint fWinIni);
    }
}
'@
        Add-Type -TypeDefinition $src -ErrorAction Stop
    }
    $script:FxTypeReady = $true
}

function Get-FxState {
    Ensure-FxType
    $map = @{}
    foreach ($e in $script:FxEffects) {
        $v = [uint32]0
        $null = [WinPower.SysParam]::SystemParametersInfoGet([uint32]$e["Get"], 0, [ref]$v, 0)
        $map[$e["Name"]] = $v
    }
    return $map
}

function Set-FxState($state) {
    Ensure-FxType
    foreach ($e in $script:FxEffects) {
        if ($state.ContainsKey($e["Name"])) {
            $null = [WinPower.SysParam]::SystemParametersInfoSet([uint32]$e["Set"], 0, [uint32]$state[$e["Name"]], 3)
        }
    }
}

function Get-ZeroFx {
    $zero = @{}
    foreach ($e in $script:FxEffects) { $zero[$e["Name"]] = [uint32]0 }
    return $zero
}

# ============================================================
# Lenovo 接口 (探测 + 缓存; 本机实测三条路全部不可用 -> "None")
# ============================================================
function Resolve-LenovoInterface($cfg, [bool]$reprobe) {
    if (-not $reprobe -and $cfg.LenovoInterface) { return $cfg.LenovoInterface }

    # 1. GAMEZONE_DATA
    try {
        $gz = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop
        if ($gz -and ($gz.PSObject.Properties.Name -contains "IsBatterySaverMode")) {
            Write-Log "Lenovo probe: GAMEZONE_DATA usable"
            $cfg.LenovoInterface = "GameZone"
            return "GameZone"
        }
        Write-Log "Lenovo probe: GAMEZONE_DATA exists but lacks IsBatterySaverMode"
    } catch {
        Write-Log "Lenovo probe: GAMEZONE_DATA not supported ($($_.Exception.Message))"
    }

    # 2. FAN_TABLE_DATA (旧版类名 LENOVO_SET_FAN_TABLE_MODE 是无效类, 真实类名是这个)
    try {
        $fan = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_FAN_TABLE_DATA -ErrorAction Stop
        if ($fan -and ($fan.PSObject.Methods.Name -contains "SetFanTableMode")) {
            Write-Log "Lenovo probe: FAN_TABLE_DATA usable"
            $cfg.LenovoInterface = "FanTable"
            return "FanTable"
        }
    } catch {
        Write-Log "Lenovo probe: FAN_TABLE_DATA not supported ($($_.Exception.Message))"
    }

    # 3. Vantage CLI
    $vantageCLI = "${env:ProgramFiles}\Lenovo\VantageService\Lenovo.Vantage.CommandLine.exe"
    if (Test-Path $vantageCLI) {
        Write-Log "Lenovo probe: Vantage CLI present"
        $cfg.LenovoInterface = "VantageCli"
        return "VantageCli"
    }

    $cfg.LenovoInterface = "None"
    Write-Log "Lenovo probe: no interface on this machine -> powercfg CPU cap fallback"
    return "None"
}

function Apply-LenovoBattery($iface) {
    switch ($iface) {
        "GameZone" {
            try {
                $gz = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop
                $gz.IsBatterySaverMode = 1
                Set-CimInstance -InputObject $gz -ErrorAction Stop
                Write-Log "Lenovo GAMEZONE: battery saver ON"
            } catch { Write-Log "Lenovo GAMEZONE set failed: $_" }
        }
        "FanTable" {
            try {
                $fan = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_FAN_TABLE_DATA -ErrorAction Stop
                Invoke-CimMethod -InputObject $fan -MethodName SetFanTableMode -Arguments @{ Mode = 1 } -ErrorAction Stop
                Write-Log "Lenovo FAN_TABLE: mode 1"
            } catch { Write-Log "Lenovo FAN_TABLE set failed: $_" }
        }
        "VantageCli" {
            $vantageCLI = "${env:ProgramFiles}\Lenovo\VantageService\Lenovo.Vantage.CommandLine.exe"
            try { & $vantageCLI /PowerMode:BatterySaving 2>&1 | Out-Null; Write-Log "Lenovo Vantage CLI: battery saver" }
            catch { Write-Log "Lenovo Vantage CLI failed: $_" }
        }
    }
}

function Apply-LenovoAc($iface) {
    switch ($iface) {
        "GameZone" {
            try {
                $gz = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop
                $gz.IsBatterySaverMode = 0
                Set-CimInstance -InputObject $gz -ErrorAction Stop
                Write-Log "Lenovo GAMEZONE: battery saver OFF"
            } catch { Write-Log "Lenovo GAMEZONE set failed: $_" }
        }
        "FanTable" {
            try {
                $fan = Get-CimInstance -Namespace root/WMI -ClassName LENOVO_FAN_TABLE_DATA -ErrorAction Stop
                Invoke-CimMethod -InputObject $fan -MethodName SetFanTableMode -Arguments @{ Mode = 3 } -ErrorAction Stop
                Write-Log "Lenovo FAN_TABLE: mode 3"
            } catch { Write-Log "Lenovo FAN_TABLE set failed: $_" }
        }
        "VantageCli" {
            $vantageCLI = "${env:ProgramFiles}\Lenovo\VantageService\Lenovo.Vantage.CommandLine.exe"
            try { & $vantageCLI /PowerMode:Performance 2>&1 | Out-Null; Write-Log "Lenovo Vantage CLI: performance" }
            catch { Write-Log "Lenovo Vantage CLI failed: $_" }
        }
    }
}

# G: Lenovo Process Management Event 只读探测 (不写入, 接口未验证)
function Get-LenovoPmeInfo {
    $out = powercfg /Q $script:MaxPerfOverlay $script:SubBattery $script:LenovoPme 2>&1 | Out-String
    $ac = ""; $dc = ""
    if ($out -match "当前交流电源设置索引:\s*(0x[0-9a-fA-F]+)") { $ac = $matches[1] }
    if ($out -match "当前直流电源设置索引:\s*(0x[0-9a-fA-F]+)") { $dc = $matches[1] }
    if ($ac -ne "" -or $dc -ne "") { return "present (AC=$ac DC=$dc)" }
    return "not present"
}

# ============================================================
# 电池模式
# ============================================================
function Invoke-BatteryMode($cfg) {
    Write-Log "===== BATTERY ====="

    # 幂等: 重复 105 事件不重复执行
    if (-not $Force -and $cfg.LastMode -eq "Battery") {
        Write-Log "LastMode=Battery, already applied; skip (use -Force to re-apply)"
        return
    }

    # A: 保存原方案 (修复: 不清空已有值)
    $active = Get-ActiveSchemeGuid
    if ($active -and $active -ne $script:PowerSaverGUID) {
        $cfg.PowerScheme = $active
        Write-Log "Saved original scheme: $active"
    } elseif ($cfg.PowerScheme) {
        Write-Log "Already on Power Saver; keep saved original: $($cfg.PowerScheme)"
    } else {
        Write-Log "Already on Power Saver and no original saved; AC will default to hidden High-Performance plan"
    }

    # 1. 切节能方案
    if ($DryRun) {
        Write-Log "[DRYRUN] would switch to Power Saver scheme"
    } else {
        powercfg /S $script:PowerSaverGUID 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Scheme switched: Power Saver" }
        else { Write-Log "Scheme switch FAILED (exit $LASTEXITCODE)" }
    }

    # G: Lenovo 接口 (缓存; -Force 重探)
    $iface = Resolve-LenovoInterface $cfg $Force
    if ($iface -ne "None") {
        if ($DryRun) { Write-Log "[DRYRUN] would apply Lenovo battery mode via $iface" }
        else { Apply-LenovoBattery $iface }
    }

    # B: CPU 上限显式写节能方案 (只在无 Lenovo 接口时兜底)
    if ($iface -eq "None") {
        $cap = if ($CpuCap -ge 0) { $CpuCap } elseif ($cfg.CpuCapDc) { [int]$cfg.CpuCapDc } else { 80 }
        if ($cap -eq 0) {
            Write-Log "CpuCap=0 -> no CPU cap applied"
        } else {
            $cfg.CpuCapDc = $cap
            if ($DryRun) {
                Write-Log "[DRYRUN] would set PROCTHROTTLEMAX DC=$cap on PowerSaver scheme (explicit GUID)"
            } else {
                powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:ProcThrottleMax $cap 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "CPU cap DC -> ${cap}% (explicit PowerSaver GUID)"
                } else {
                    Write-Log "CPU cap set FAILED (exit $LASTEXITCODE)"
                }
                powercfg /SETACTIVE $script:PowerSaverGUID 2>&1 | Out-Null
            }
        }
    }

    # G: Lenovo PME 只读探测
    Write-Log ("Lenovo PME probe (max-perf overlay): " + (Get-LenovoPmeInfo))

    # C: 视觉效果自动化
    if ($DryRun) {
        Write-Log "[DRYRUN] would disable 7 animation effects and save originals"
    } else {
        try {
            $fx = Get-FxState
            $cfg.VisualFX = @{ Saved = $fx }
            Set-FxState (Get-ZeroFx)
            Write-Log "Visual effects: 7 animation effects OFF (originals saved to config)"
        } catch {
            Write-Log "Visual effects apply failed: $_"
        }
    }

    $cfg.LastMode = "Battery"
    if (-not $DryRun) { Save-Config $cfg } else { Write-Log "[DRYRUN] config not written" }
    Write-Log "===== DONE ====="
}

# ============================================================
# AC 模式
# ============================================================
function Invoke-AcMode($cfg) {
    Write-Log "===== AC ====="

    if (-not $Force -and $cfg.LastMode -eq "AC") {
        Write-Log "LastMode=AC, already applied; skip (use -Force to re-apply)"
        return
    }

    # A: 恢复方案
    $target = if ($cfg.PowerScheme) { $cfg.PowerScheme } else { $script:HighPerfGUID }
    if (-not $cfg.PowerScheme) { Write-Log "No saved scheme; defaulting to hidden High-Performance plan" }
    if ($DryRun) {
        Write-Log "[DRYRUN] would switch to $target"
    } else {
        powercfg /S $target 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Scheme restored: $target"
        } else {
            powercfg /S $script:HighPerfGUID 2>&1 | Out-Null
            Write-Log "Restore FAILED (exit $LASTEXITCODE); fallback High-Performance plan"
        }
    }

    # B: 解除 CPU 上限 (显式节能方案 GUID; 25H2 已移除 /DELETEVALUEINDEX 命令, 改为显式写回 100 = 无限制)
    if ($DryRun) {
        Write-Log "[DRYRUN] would reset PROCTHROTTLEMAX DC to 100% on PowerSaver scheme"
    } else {
        powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:ProcThrottleMax 100 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "CPU cap DC reset to 100% (explicit PowerSaver GUID)"
        } else {
            Write-Log "CPU cap reset FAILED (exit $LASTEXITCODE)"
        }
        powercfg /SETACTIVE $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "SETACTIVE failed (exit $LASTEXITCODE)" }
    }

    # Lenovo 反向 (本机缓存 None -> 跳过)
    $iface = Resolve-LenovoInterface $cfg $Force
    if ($iface -ne "None") {
        if ($DryRun) { Write-Log "[DRYRUN] would apply Lenovo performance mode via $iface" }
        else { Apply-LenovoAc $iface }
    } else {
        Write-Log "Lenovo: no interface (cached); skip performance mode"
    }

    # C: 恢复视觉效果
    if ($cfg.VisualFX.Saved) {
        if ($DryRun) {
            Write-Log "[DRYRUN] would restore saved visual effects"
        } else {
            try {
                $fx = @{}
                $cfg.VisualFX.Saved.PSObject.Properties | ForEach-Object { $fx[$_.Name] = [uint32]$_.Value }
                Set-FxState $fx
                Write-Log "Visual effects restored"
            } catch {
                Write-Log "Visual effects restore failed: $_"
            }
        }
    } else {
        Write-Log "Visual effects: no saved state, skip restore"
    }

    $cfg.LastMode = "AC"
    if (-not $DryRun) { Save-Config $cfg } else { Write-Log "[DRYRUN] config not written" }
    Write-Log "===== DONE ====="
}

# ============================================================
# 主流程
# ============================================================
$mtx = New-Object System.Threading.Mutex($false, "Local\PowerSaverV2")
if (-not $mtx.WaitOne(0)) {
    Write-Log "Another instance running; exit"
    exit 1
}
$acquired = $true

try {
    $cfg = Load-Config
    $mode = if ($Mode -eq "Auto") { Get-PowerSource } else { $Mode }
    Write-Log ("===== RUN $mode =====")
    if ($mode -eq "Battery") { Invoke-BatteryMode $cfg } else { Invoke-AcMode $cfg }
} finally {
    if ($acquired) { $mtx.ReleaseMutex() }
}
