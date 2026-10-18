# PowerSaver-v2.ps1
# 用法:
#   powershell.exe -ExecutionPolicy Bypass -File PowerSaver-v2.ps1 -Mode Menu|Battery|AC|Auto|Toggle|HighPerf|PowerSaver
#   -Force       忽略 LastMode 幂等检查, 强制重新应用
#   -DryRun      只探测不修改 (所有写操作跳过)
#   -CpuCap N    覆盖 CPU 上限 (默认 80; -1 = 用配置文件值或默认)
#   -LogPath / -ConfigPath  覆盖日志/配置文件路径 (测试用)
#
# v2.2 更新:
#   1. CPU 睿频精细化控制 (PERFBOOSTMODE): 电池模式关闭激进睿频 (0)，彻底消除电压尖峰发热；高性能模式恢复激进睿频 (1)
#   2. Windows 11 EcoQoS (能效模式) 自动化分流: 拔电自动将后台闲置软件降至效率模式，锁入 E/LPE 核心，不卡前台；插电解除
#   3. 联想硬件功耗协同 (Fn+Q) 状态提示: 并在控制面板中提供野兽(红)/安静(蓝)/均衡(白)档位指引，实现软硬件双全开
#   4. 严格保持屏幕刷新率原样不动 (满足 120Hz 高刷刚需)

param(
    [ValidateSet("Battery", "AC", "Auto", "Menu", "Toggle", "HighPerf", "PowerSaver")]
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
$script:PowerSaverGUID  = "a1841308-3541-4fab-bc81-f71556f20b4a"   # 节能方案
$script:HighPerfGUID    = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"   # 高性能方案
$script:SubProcessor    = "54533251-82be-4824-96c1-47b60b740d00"
$script:ProcThrottleMax = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$script:PerfBoostMode   = "be337238-0d82-4146-a960-4f3749d470c7"   # 处理器性能提升模式 (睿频控制)
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
        ManualOverride  = $null
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
# Windows 11 EcoQoS (能效模式) 调度支持
# ============================================================
$script:EcoQoSTypeReady = $false

function Ensure-EcoQoSType {
    if ($script:EcoQoSTypeReady) { return }
    if (-not ("WinPower.EcoQoS" -as [type])) {
        $src = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace WinPower {
    public static class EcoQoS {
        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_POWER_THROTTLING_STATE {
            public uint Version;
            public uint ControlMask;
            public uint StateMask;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetProcessInformation(
            IntPtr hProcess,
            int ProcessInformationClass,
            ref PROCESS_POWER_THROTTLING_STATE ProcessInformation,
            uint ProcessInformationSize
        );

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        public static uint GetForegroundProcessId() {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return 0;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return pid;
        }

        public static bool SetProcessEcoQoS(IntPtr hProcess, bool enable) {
            PROCESS_POWER_THROTTLING_STATE s = new PROCESS_POWER_THROTTLING_STATE();
            s.Version = 1;
            s.ControlMask = 1; // PROCESS_POWER_THROTTLING_EXECUTION_SPEED
            s.StateMask = enable ? 1u : 0u;
            return SetProcessInformation(hProcess, 4, ref s, (uint)Marshal.SizeOf(s));
        }
    }
}
'@
        Add-Type -TypeDefinition $src -ErrorAction Stop
    }
    $script:EcoQoSTypeReady = $true
}

function Set-EcoQoSForBackgroundApps([bool]$enable) {
    try {
        Ensure-EcoQoSType
        $fgPid = [WinPower.EcoQoS]::GetForegroundProcessId()

        # 典型后台高耗电软件名单 (不影响前台正在使用的应用)
        $targetNames = @(
            'msedge', 'chrome', 'firefox', 'qq', 'wechat', 'wemeet', 'dingtalk',
            'feishu', 'onedrive', 'dropbox', 'steam', 'clash-verge', 'clash',
            'searchindexer', 'powershell', 'wscript'
        )

        $count = 0
        foreach ($name in $targetNames) {
            $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                # 排除当前前台焦点窗口和自身进程，保证活动软件丝滑
                if ($p.Id -ne $fgPid -and $p.Id -ne $PID) {
                    try {
                        $ok = [WinPower.EcoQoS]::SetProcessEcoQoS($p.Handle, $enable)
                        if ($ok) { $count++ }
                    } catch { }
                }
            }
        }
        $actionStr = if ($enable) { "applied to" } else { "removed from" }
        Write-Log "EcoQoS: $actionStr $count background processes (foreground PID $fgPid excluded)"
    } catch {
        Write-Log "EcoQoS operation failed: $_"
    }
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

    # 2. FAN_TABLE_DATA
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

function Get-LenovoPmeInfo {
    $out = powercfg /Q $script:MaxPerfOverlay $script:SubBattery $script:LenovoPme 2>&1 | Out-String
    $ac = ""; $dc = ""
    if ($out -match "当前交流电源设置索引:\s*(0x[0-9a-fA-F]+)") { $ac = $matches[1] }
    if ($out -match "当前直流电源设置索引:\s*(0x[0-9a-fA-F]+)") { $dc = $matches[1] }
    if ($ac -ne "" -or $dc -ne "") { return "present (AC=$ac DC=$dc)" }
    return "not present"
}

# ============================================================
# 电池/节能模式
# ============================================================
function Invoke-BatteryMode($cfg, [bool]$manual = $false) {
    Write-Log "===== BATTERY (manual=$manual) ====="

    # 如果系统事件自动触发且处于用户手动锁定高性能模式，跳过
    if (-not $Force -and -not $manual -and $cfg.ManualOverride -eq "HighPerf") {
        Write-Log "ManualOverride=HighPerf active; skipping automatic Battery switch"
        return
    }

    if ($manual) {
        $cfg.ManualOverride = "Battery"
    } elseif (-not $Force -and $cfg.LastMode -eq "Battery") {
        Write-Log "LastMode=Battery, already applied; skip (use -Force to re-apply)"
        return
    }

    # A: 保存原方案
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

    # G: Lenovo 接口
    $iface = Resolve-LenovoInterface $cfg $Force
    if ($iface -ne "None") {
        if ($DryRun) { Write-Log "[DRYRUN] would apply Lenovo battery mode via $iface" }
        else { Apply-LenovoBattery $iface }
    }

    # B: CPU 上限与睿频模式 (只在无 Lenovo 接口时兜底)
    if ($iface -eq "None") {
        $cap = if ($CpuCap -ge 0) { $CpuCap } elseif ($cfg.CpuCapDc) { [int]$cfg.CpuCapDc } else { 80 }
        if ($cap -eq 0) {
            Write-Log "CpuCap=0 -> no CPU cap applied"
        } else {
            $cfg.CpuCapDc = $cap
            if ($DryRun) {
                Write-Log "[DRYRUN] would set PROCTHROTTLEMAX DC=$cap on PowerSaver scheme"
                Write-Log "[DRYRUN] would set PERFBOOSTMODE DC=0 (Disabled) on PowerSaver scheme"
            } else {
                # 设定 CPU 80% 频率上限
                powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:ProcThrottleMax $cap 2>&1 | Out-Null
                # 设定关闭激进睿频 (0=Disabled)，消除大电压脉冲与尖峰发热
                powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:PerfBoostMode 0 2>&1 | Out-Null
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "CPU cap DC -> ${cap}% and BoostMode -> 0 (Disabled)"
                } else {
                    Write-Log "CPU settings FAILED (exit $LASTEXITCODE)"
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

    # D: Windows 11 EcoQoS (能效模式) 后台分流
    if ($DryRun) {
        Write-Log "[DRYRUN] would apply EcoQoS to background processes"
    } else {
        Set-EcoQoSForBackgroundApps $true
    }

    $cfg.LastMode = "Battery"
    if (-not $DryRun) { Save-Config $cfg } else { Write-Log "[DRYRUN] config not written" }
    Write-Log "===== DONE ====="
}

# ============================================================
# AC/高性能模式
# ============================================================
function Invoke-AcMode($cfg, [bool]$manual = $false) {
    Write-Log "===== AC/HIGH-PERF (manual=$manual) ====="

    if ($manual) {
        $cfg.ManualOverride = "HighPerf"
    } else {
        $wasOverridden = ($null -ne $cfg.ManualOverride)
        $cfg.ManualOverride = $null
        if (-not $Force -and $cfg.LastMode -eq "AC") {
            Write-Log "LastMode=AC, already applied; skip (use -Force to re-apply)"
            if ($wasOverridden -and -not $DryRun) { Save-Config $cfg }
            return
        }
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

    # B: 解除 CPU 上限并恢复激进睿频 (PROCTHROTTLEMAX=100, PERFBOOSTMODE=1)
    if ($DryRun) {
        Write-Log "[DRYRUN] would reset PROCTHROTTLEMAX to 100% and PERFBOOSTMODE to 1 (Aggressive)"
    } else {
        powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:ProcThrottleMax 100 2>&1 | Out-Null
        powercfg /SETDCVALUEINDEX $script:PowerSaverGUID $script:SubProcessor $script:PerfBoostMode 1 2>&1 | Out-Null
        powercfg /SETDCVALUEINDEX $target $script:SubProcessor $script:PerfBoostMode 1 2>&1 | Out-Null
        powercfg /SETACVALUEINDEX $target $script:SubProcessor $script:PerfBoostMode 1 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Log "CPU cap reset to 100% and BoostMode reset to 1 (Aggressive)"
        } else {
            Write-Log "CPU cap reset FAILED (exit $LASTEXITCODE)"
        }
        powercfg /SETACTIVE $target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "SETACTIVE failed (exit $LASTEXITCODE)" }
    }

    # Lenovo 反向
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

    # D: 恢复后台进程正常 QoS
    if ($DryRun) {
        Write-Log "[DRYRUN] would remove EcoQoS from background processes"
    } else {
        Set-EcoQoSForBackgroundApps $false
    }

    $cfg.LastMode = "AC"
    if (-not $DryRun) { Save-Config $cfg } else { Write-Log "[DRYRUN] config not written" }
    Write-Log "===== DONE ====="
}

# ============================================================
# 自动模式 (清除手动覆盖, 根据当前插电状态重算)
# ============================================================
function Invoke-AutoMode($cfg) {
    Write-Log "===== AUTO ====="
    $cfg.ManualOverride = $null
    $source = Get-PowerSource
    if ($source -eq "Battery") {
        Invoke-BatteryMode $cfg $false
    } else {
        Invoke-AcMode $cfg $false
    }
}

# ============================================================
# 翻转模式 (Toggle: 节能 <-> 高性能)
# ============================================================
function Invoke-ToggleMode($cfg) {
    Write-Log "===== TOGGLE ====="
    $active = Get-ActiveSchemeGuid
    if ($active -eq $script:PowerSaverGUID -or $cfg.LastMode -eq "Battery") {
        Invoke-AcMode $cfg $true
        return "HighPerf"
    } else {
        Invoke-BatteryMode $cfg $true
        return "Battery"
    }
}

# ============================================================
# 互斥锁执行器 (超时 3 秒, 避免死锁或冲突)
# ============================================================
function Invoke-WithLock([scriptblock]$action) {
    $mtx = New-Object System.Threading.Mutex($false, "Local\PowerSaverV2")
    $hasLock = $false
    try {
        $hasLock = $mtx.WaitOne(3000)
        if (-not $hasLock) {
            Write-Log "Could not acquire mutex within 3s; exit"
            return $false
        }
        & $action
        return $true
    } finally {
        if ($hasLock) {
            $mtx.ReleaseMutex()
        }
    }
}

# ============================================================
# 图形界面 (WPF 现代卡片设计)
# ============================================================
function Show-PowerMenu {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $cfg = Load-Config
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $isBattery = ($bat -and $bat.BatteryStatus -eq 1)
    $percent = if ($bat) { $bat.EstimatedChargeRemaining } else { $null }
    $activeGuid = Get-ActiveSchemeGuid

    $sourceText = if ($isBattery) { "🔋 电池供电 (${percent}%)" } else { "⚡ 交流电源 (已插电)" }
    $isSaver = ($activeGuid -eq $script:PowerSaverGUID)
    $isHigh = ($activeGuid -eq $script:HighPerfGUID)

    $statusTitle = if ($isSaver) { "🍃 节能省电模式 (80% CPU · 关闭睿频 · EcoQoS)" } elseif ($isHigh) { "🚀 高性能模式 (CPU 100% · 激进睿频 · 全速)" } else { "⚖️ 平衡 / 自定义方案" }
    $statusColor = if ($isSaver) { "#4ade80" } elseif ($isHigh) { "#38bdf8" } else { "#fbbf24" }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="⚡ 电源模式切换" Height="445" Width="390"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#18181b" Foreground="#f4f4f5"
        FontFamily="Segoe UI, Microsoft YaHei UI, sans-serif"
        Topmost="True">
    <Grid Margin="18,16,18,16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <DockPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="⚡ 电源模式选择" FontSize="16" FontWeight="Bold" Foreground="#ffffff"/>
            <TextBlock x:Name="TxtPowerSource" Text="$sourceText" HorizontalAlignment="Right" FontSize="12" Foreground="#a1a1aa" VerticalAlignment="Center"/>
        </DockPanel>

        <!-- Current Status Banner -->
        <Border Grid.Row="1" Background="#27272a" CornerRadius="6" Padding="10,7" Margin="0,0,0,10">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="当前状态：" FontSize="11.5" Foreground="#a1a1aa" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtCurrentStatus" Text="$statusTitle" FontSize="11.5" FontWeight="SemiBold" Foreground="$statusColor" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>

        <!-- Lenovo Hardware Fn+Q Synergy Card -->
        <Border Grid.Row="2" Background="#202026" CornerRadius="6" Padding="10,7" Margin="0,0,0,12" BorderBrush="#3f3f46" BorderThickness="1">
            <StackPanel>
                <DockPanel Margin="0,0,0,3">
                    <TextBlock Text="💻 联想硬件档位协同指引" FontSize="11" FontWeight="SemiBold" Foreground="#cbd5e1"/>
                    <TextBlock Text="按 [Fn + Q] 切换指示灯" HorizontalAlignment="Right" FontSize="10" Foreground="#94a3b8"/>
                </DockPanel>
                <TextBlock x:Name="TxtLenovoTip" Text="• 🚀 高性能建议 🔴 红色灯（野兽） · 🔋 节能建议 🔵 蓝色灯（安静）" FontSize="10" Foreground="#a1a1aa" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <!-- Mode Buttons -->
        <StackPanel Grid.Row="3">
            <!-- High Perf Button -->
            <Button x:Name="BtnHigh" Height="50" Margin="0,0,0,9" Cursor="Hand"
                    Background="#1e293b" BorderBrush="#0284c7" BorderThickness="1.5">
                <StackPanel HorizontalAlignment="Left" Margin="12,0,0,0">
                    <TextBlock Text="🚀 高性能模式 (全速运行)" FontSize="12.5" FontWeight="Bold" Foreground="#38bdf8"/>
                    <TextBlock Text="CPU 100% · 激进睿频全开 · 特效全开 (不插电也可全速)" FontSize="10" Foreground="#94a3b8" Margin="0,2,0,0"/>
                </StackPanel>
            </Button>

            <!-- Saver Button -->
            <Button x:Name="BtnSaver" Height="50" Margin="0,0,0,9" Cursor="Hand"
                    Background="#14291e" BorderBrush="#16a34a" BorderThickness="1.5">
                <StackPanel HorizontalAlignment="Left" Margin="12,0,0,0">
                    <TextBlock Text="🔋 节能省电模式 (长续航)" FontSize="12.5" FontWeight="Bold" Foreground="#4ade80"/>
                    <TextBlock Text="CPU 80% · 关闭睿频防发热 · 后台 EcoQoS 能效分流" FontSize="10" Foreground="#86efac" Margin="0,2,0,0"/>
                </StackPanel>
            </Button>

            <!-- Auto Button -->
            <Button x:Name="BtnAuto" Height="46" Margin="0,0,0,6" Cursor="Hand"
                    Background="#27272a" BorderBrush="#52525b" BorderThickness="1">
                <StackPanel HorizontalAlignment="Left" Margin="12,0,0,0">
                    <TextBlock Text="🔄 自动模式 (跟随供电状态)" FontSize="12" FontWeight="SemiBold" Foreground="#e4e4e7"/>
                    <TextBlock Text="插电高性能 · 拔电自动节能与能效分流" FontSize="10" Foreground="#a1a1aa" Margin="0,1,0,0"/>
                </StackPanel>
            </Button>
        </StackPanel>

        <!-- Footer -->
        <DockPanel Grid.Row="4" Margin="0,2,0,0">
            <TextBlock x:Name="TxtFeedback" Text="快捷键: [1] 高性能  [2] 节能  [3] 自动  [Esc] 退出" FontSize="10.5" Foreground="#71717a" VerticalAlignment="Center"/>
        </DockPanel>
    </Grid>
</Window>
"@

    $win = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $btnHigh = $win.FindName("BtnHigh")
    $btnSaver = $win.FindName("BtnSaver")
    $btnAuto = $win.FindName("BtnAuto")
    $txtFeedback = $win.FindName("TxtFeedback")
    $txtCurrentStatus = $win.FindName("TxtCurrentStatus")
    $txtLenovoTip = $win.FindName("TxtLenovoTip")

    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds(1300)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $win.Close()
    })

    $applyAction = {
        param([string]$targetMode)
        $btnHigh.IsEnabled = $false
        $btnSaver.IsEnabled = $false
        $btnAuto.IsEnabled = $false

        $txtFeedback.Text = "⏳ 正在应用 $targetMode..."
        $txtFeedback.Foreground = "#facc15"

        [System.Windows.Forms.Application]::DoEvents()

        $null = Invoke-WithLock {
            $cfg = Load-Config
            switch ($targetMode) {
                "HighPerf" {
                    Invoke-AcMode $cfg $true
                    $txtCurrentStatus.Text = "🚀 高性能模式 (CPU 100% · 睿频全开)"
                    $txtCurrentStatus.Foreground = "#38bdf8"
                    $txtLenovoTip.Text = "• 建议配合 [Fn + Q] 切至 🔴 红色指示灯（野兽模式，彻底解开功耗墙）"
                    $txtLenovoTip.Foreground = "#38bdf8"
                    $txtFeedback.Text = "✅ 已切换为【高性能模式】 (建议按 Fn+Q 切红灯)"
                    $txtFeedback.Foreground = "#38bdf8"
                }
                "Battery" {
                    Invoke-BatteryMode $cfg $true
                    $txtCurrentStatus.Text = "🍃 节能省电模式 (80% CPU · 关睿频 · EcoQoS)"
                    $txtCurrentStatus.Foreground = "#4ade80"
                    $txtLenovoTip.Text = "• 建议配合 [Fn + Q] 切至 🔵 蓝色指示灯（安静模式，15W 控温静音）"
                    $txtLenovoTip.Foreground = "#4ade80"
                    $txtFeedback.Text = "✅ 已切换为【节能省电模式】 (建议按 Fn+Q 切蓝灯)"
                    $txtFeedback.Foreground = "#4ade80"
                }
                "Auto" {
                    Invoke-AutoMode $cfg
                    $src = Get-PowerSource
                    if ($src -eq "Battery") {
                        $txtCurrentStatus.Text = "🍃 自动模式 -> 节能省电 (当前电池供电)"
                        $txtCurrentStatus.Foreground = "#4ade80"
                        $txtLenovoTip.Text = "• 当前电池供电：建议按 [Fn + Q] 切至 🔵 蓝色安静模式"
                        $txtLenovoTip.Foreground = "#4ade80"
                    } else {
                        $txtCurrentStatus.Text = "🚀 自动模式 -> 高性能 (当前交流插电)"
                        $txtCurrentStatus.Foreground = "#38bdf8"
                        $txtLenovoTip.Text = "• 当前已接电源：建议按 [Fn + Q] 切至 ⚪ 均衡或 🔴 野兽模式"
                        $txtLenovoTip.Foreground = "#38bdf8"
                    }
                    $txtFeedback.Text = "✅ 已恢复【自动模式】 (将随插拔电自动调度)"
                    $txtFeedback.Foreground = "#a1a1aa"
                }
            }
        }
        $closeTimer.Start()
    }

    $btnHigh.Add_Click({ & $applyAction "HighPerf" })
    $btnSaver.Add_Click({ & $applyAction "Battery" })
    $btnAuto.Add_Click({ & $applyAction "Auto" })

    $win.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::D1 -or $e.Key -eq [System.Windows.Input.Key]::NumPad1 -or $e.Key -eq [System.Windows.Input.Key]::H) {
            & $applyAction "HighPerf"
        } elseif ($e.Key -eq [System.Windows.Input.Key]::D2 -or $e.Key -eq [System.Windows.Input.Key]::NumPad2 -or $e.Key -eq [System.Windows.Input.Key]::B -or $e.Key -eq [System.Windows.Input.Key]::S) {
            & $applyAction "Battery"
        } elseif ($e.Key -eq [System.Windows.Input.Key]::D3 -or $e.Key -eq [System.Windows.Input.Key]::NumPad3 -or $e.Key -eq [System.Windows.Input.Key]::A) {
            & $applyAction "Auto"
        } elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            $win.Close()
        }
    })

    $win.ShowDialog() | Out-Null
}

# ============================================================
# 主流程
# ============================================================
if ($Mode -eq "Menu") {
    Show-PowerMenu
    exit 0
}

$null = Invoke-WithLock {
    $cfg = Load-Config
    switch ($Mode) {
        "Toggle" {
            Invoke-ToggleMode $cfg
        }
        "HighPerf" {
            Invoke-AcMode $cfg $true
        }
        "PowerSaver" {
            Invoke-BatteryMode $cfg $true
        }
        "Auto" {
            $mode = Get-PowerSource
            Write-Log ("===== RUN Auto -> $mode =====")
            if ($mode -eq "Battery") { Invoke-BatteryMode $cfg $false } else { Invoke-AcMode $cfg $false }
        }
        "Battery" {
            Invoke-BatteryMode $cfg $false
        }
        "AC" {
            Invoke-AcMode $cfg $false
        }
    }
}
