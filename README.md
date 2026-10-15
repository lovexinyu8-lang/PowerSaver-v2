# PowerSaver v2

一个用于 Windows 系统的轻量级、自动化笔记本智能省电与性能调控方案（原生 PowerShell + WPF 架构，无第三方依赖）。

---

## 📖 项目简介

`PowerSaver v2` 专为 Windows 笔记本电脑打造，提供 **日常插拔电全自动无感调度** 与 **脱电状态自主强开高性能** 的完整解决方案。

在保证优异续航的同时，彻底解决 Windows 笔记本在拔电状态下被系统锁死在低性能、打字卡顿或高负载场景无法发挥全速性能的痛点。

### ✨ 核心特性

- 🖥️ **现代控制面板（WPF 卡片）**：双击桌面快捷方式即可秒级弹窗，直观查看当前供电（电池百分比/交流电）与性能状态，支持鼠标或快捷键一键切换。
- 🚀 **支持不插电强开高性能**：电池供电下也能一键解除 80% CPU 限制、恢复全部系统视觉特效并激活高性能方案，满足移动办公与应急高性能场景。
- 🛡️ **独家 `ManualOverride` 防误切机制**：在电池下手动开启高性能后，即使合盖睡眠、现代待机（Modern Standby）唤醒，也不会被系统任务误切回省电模式；插电后自动解除锁定并恢复全自动管理。
- ⚡ **电源事件驱动自动调度**：后台自动监听系统 `Kernel-Power (104/105)` 事件，拔电自动削减功耗、插电自动满血释放。
- 🎯 **能效比拐点优化（CPU 80% 压制）**：电池模式默认封顶 80% 频率，砍去功耗与发热呈指数飙升的极值区间，杜绝发热降频，流畅度与续航兼备。
- 🎨 **无感视觉动效自动优化**：通过 Win32 API（`SystemParametersInfo`）直接控制 7 项 Windows 动效，无需重启 Explorer，即刻生效。
- 🔒 **健壮稳定设计**：
  - 全局命名互斥锁（Mutex）与 3 秒防冲突保护；
  - 基于 CIM 实例查询，淘汰过时的 WMI；
  - 配置文件原子写入，日志自动轮转（上限 256KB）。

---

## 📂 文件结构

| 文件名 | 说明 |
| :--- | :--- |
| **`PowerSaver-v2.ps1`** | 核心调度与 UI 脚本（支持控制面板、高性能强开、翻转、自检与纯后台调用） |
| **`Install-PowerSaverTasks-v2.ps1`** | 一键安装与计划任务部署脚本（管理员权限运行一次即可） |
| **`Toggle-PowerMode.ps1`** | 便捷调用包装脚本（默认调用交互式菜单） |
| **`Cleanup-Touchpad-Once.ps1`** | 历史触摸板残留值修复兜底脚本（安装时自动处理） |
| **`使用说明.txt`** | 简易纯文本版操作备忘 |

---

## 🚀 快速安装与部署

### 1. 部署文件
推荐将脚本存放至 `D:\Scripts\`（若存放在其他目录，请同步调整快捷方式与任务路径）：
```text
D:\Scripts\
├── PowerSaver-v2.ps1
├── Install-PowerSaverTasks-v2.ps1
├── Toggle-PowerMode.ps1
└── Cleanup-Touchpad-Once.ps1
```

### 2. 执行一键安装
以 **管理员身份** 启动 PowerShell，执行以下命令：

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell.exe -ExecutionPolicy Bypass -File "D:\Scripts\Install-PowerSaverTasks-v2.ps1"
```

**安装脚本将自动完成：**
1. 停用旧版任务，创建新版事件监听任务（`PowerSaver_OnBattery_v2` / `PowerSaver_OnAC_v2`），并配置允许在电池下启动。
2. 在桌面生成/更新 **`Toggle Power Mode.lnk`** 快捷方式（双击即打开控制面板）。
3. 自动扫描并纠正历史触摸板配置残留。
4. 立即按当前系统供电状态应用一次配置。

---

## 🎮 控制面板与使用方式

### 1. 桌面快捷方式（图形控制面板）
双击桌面的 **`Toggle Power Mode.lnk`**，将弹出控制卡片：
* **[ 🚀 高性能模式 (全速运行) ]**：不插电也可全速运行，CPU 上限 100%，动效全开，启用防误切锁定。
* **[ 🔋 节能省电模式 (长续航) ]**：CPU 锁定 80%，精简系统动画，降低发热。
* **[ 🔄 自动模式 (跟随供电状态) ]**：重置手动锁定，根据是否插电自动切换。
* **键盘快捷键**：按 **`1`**（高性能）、**`2`**（省电）、**`3`**（自动）、**`Esc`**（退出）。

### 2. 命令行与静默调用
如需在第三方启动器（如 Quicker、PowerToys Run、脚本等）中直接调度，可传参运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\PowerSaver-v2.ps1 [参数]
```

| 参数 | 可选值 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- |
| `-Mode` | `Menu`, `HighPerf`, `PowerSaver`, `Auto`, `Toggle`, `Battery`, `AC` | `Auto` | 运行模式：`Menu` 为图形面板，`HighPerf` 为强制高性能，`Toggle` 为一键翻转 |
| `-Force` | 开关 (`Switch`) | 关 | 忽略幂等检查，强制重新写入并激活方案 |
| `-DryRun` | 开关 (`Switch`) | 关 | 只测不改模式：探测并打印日志，跳过所有写操作 |
| `-CpuCap` | `0` ~ `100` (`-1` 为默认) | `80` | 自定义省电模式下的 CPU 上限百分比（`0` 表示不设限） |
| `-LogPath` | 文件路径 | `~\powersaver-v2.log` | 指定运行日志路径 |
| `-ConfigPath`| 文件路径 | `~\powersaver-v2.config.json` | 指定状态配置存储路径 |

---

## 🔍 日志与状态验证

- **运行日志**：`C:\Users\<用户名>\powersaver-v2.log`
  - 拔电自动切换：`CPU cap DC -> 80% (explicit PowerSaver GUID)`
  - 插电自动恢复：`CPU cap DC reset to 100% (explicit PowerSaver GUID)`
  - 不插电手开高性能：`===== AC/HIGH-PERF (manual=True) =====`
  - 待机唤醒防误切：`ManualOverride=HighPerf active; skipping automatic Battery switch`
- **状态配置**：`C:\Users\<用户名>\powersaver-v2.config.json`

---

## 📄 开源许可

本项目遵循 [MIT License](LICENSE) 开源。
