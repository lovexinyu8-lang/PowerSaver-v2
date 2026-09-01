# PowerSaver v2

一个用于 Windows 系统的轻量级、自动化笔记本智能省电调优脚本方案。

---

## 📖 项目简介

`PowerSaver v2` 专为笔记本电脑在 **电池供电** 与 **插电状态** 之间提供无缝、自动化的性能与电源配置切换。

相比旧版本，v2 在保证节能效果的同时，大幅提升了稳定性与自动化程度，修复了残留配置无法回滚、误触硬件反向耗电等问题。

### ✨ 核心特性

- ⚡ **自动事件触发**：监听系统 `Kernel-Power (105/104)` 事件，拔电自动切换节能、插电自动恢复高性能/原电源方案。
- 🎯 **精确 CPU 压制与恢复**：电池模式下显式限制 CPU 频率上限（默认 80%），插电时精准清除限制并恢复。
- 🎨 **无感视觉动效自动优化**：自动开关 7 项 Windows 渲染与窗口动效（`SystemParametersInfo` API），省电且无需重启或手动操作。
- 🛡️ **健壮且安全**：
  - 采用 `Get-CimInstance` 替换过时的 WMI 接口。
  - 全局互斥锁与幂等机制，防止高频插拔电源导致重复执行冲突。
  - 配置文件原子写入，日志自动轮转（上限 256KB）。
- 💻 **联想机型优化**：自动探测联想特有 WMI 接口并缓存结果。

---

## 📂 文件结构

| 文件名 | 说明 |
| :--- | :--- |
| **`PowerSaver-v2.ps1`** | 核心调度脚本（支持 `-Mode Battery/AC/Auto` 及 `-DryRun` 调试模式） |
| **`Install-PowerSaverTasks-v2.ps1`** | 一键安装与计划任务部署脚本（管理员权限运行） |
| **`Cleanup-Touchpad-Once.ps1`** | 触摸板残留值修复兜底脚本（安装时自动处理，无需手动执行） |
| **`使用说明.txt`** | 简易文本版操作备忘 |

---

## 🚀 快速安装与使用

### 1. 部署脚本
推荐将脚本目录解压至 `D:\Scripts\`（如无此目录可先创建）：
```text
D:\Scripts\
├── PowerSaver-v2.ps1
├── Install-PowerSaverTasks-v2.ps1
└── Cleanup-Touchpad-Once.ps1
```

### 2. 执行一键安装
以 **管理员身份** 启动 PowerShell，执行以下命令：

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
powershell.exe -ExecutionPolicy Bypass -File "D:\Scripts\Install-PowerSaverTasks-v2.ps1"
```

**安装脚本将自动完成：**
1. 停用旧版任务计划并创建新版任务（`PowerSaver_OnBattery_v2` / `PowerSaver_OnAC_v2`）。
2. 在桌面生成/更新一键切换快捷方式（指向 `-Mode Auto`）。
3. 检查并修复历史触摸板配置残留。
4. 立即按当前电源状态执行一次应用。

---

## 🛠️ 参数说明

如需手动调试或自定义参数，可直接运行 `PowerSaver-v2.ps1`：

```powershell
powershell -ExecutionPolicy Bypass -File .\PowerSaver-v2.ps1 [参数]
```

| 参数 | 可选值 / 范围 | 默认值 | 描述 |
| :--- | :--- | :--- | :--- |
| `-Mode` | `Battery`, `AC`, `Auto` | `Auto` | 指定运行模式（`Auto` 自动检测当前供电状态） |
| `-Force` | 开关 (`Switch`) | 关 | 忽略幂等性检查，强制重新应用当前模式 |
| `-DryRun` | 开关 (`Switch`) | 关 | 自检模式：只探测和打印日志，不修改任何系统配置 |
| `-CpuCap` | `0` ~ `100` (`-1` 为默认) | `80` | 自定义电池模式下的 CPU 上限百分比（`0` 表示不限制） |
| `-LogPath` | 文件路径 | `~\powersaver-v2.log` | 指定运行日志输出路径 |
| `-ConfigPath`| 文件路径 | `~\powersaver-v2.config.json` | 指定状态配置文件路径 |

---

## 🔍 日志与状态验证

- **运行日志**：`C:\Users\<用户名>\powersaver-v2.log`
  - 拔掉电源可观察到：`CPU cap DC -> 80% (explicit PowerSaver GUID)`
  - 插上电源可观察到：`CPU cap removed from PowerSaver scheme`
- **状态配置**：`C:\Users\<用户名>\powersaver-v2.config.json`

---

## 📄 开源许可

本项目遵循 [MIT License](LICENSE) 开源。
