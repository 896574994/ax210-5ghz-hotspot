# AX210 5GHz 热点助手（网线上行绕行方案）

Windows 笔记本使用 Intel AX210 等单射频网卡时，**只插网线**的情况下无法开启 5GHz 移动热点，系统提示「所选网络频段不可用」。

本项目提供一个可用绕行：**先连 5GHz 网络把射频引到 5GHz → 以以太网为共享源起热点 → 断开 WiFi**，热点会留在 5GHz，上网走网线。

## 背景

AX210 为单射频网卡，同一时刻只能工作在一个频段一个信道。

- 连着 5GHz 网络时，射频已锁定信道，热点可用同一信道，启 AP 成功。
- 仅网线上行时射频闲置，驱动需自选 5GHz 信道，启 AP 失败（事件 8007，错误码 31）。
- 2.4GHz 不受影响，信道规则简单且不涉及 DFS。

更详细的排查过程见 [docs/diagnosis.md](docs/diagnosis.md)。

## 快速开始

```powershell
# 以管理员身份运行 Windows PowerShell 5.1（不要用 PowerShell 7）
.\HotspotTool.ps1
```

或双击 `Start-Hotspot-Tool.bat`，脚本会自行请求管理员权限。

首次运行需要备份的原有热点设置不会被修改，脚本只读写当前的访问点配置。

## 参数

| 参数 | 说明 |
|---|---|
| `-SeedSSID` | 附近可连接的 5GHz 网络名，用于把射频引到 5GHz。必填。 |
| `-HotspotSSID` | 热点名称，默认 `MyHotspot` |
| `-HotspotPassword` | 热点密码，8 位以上，默认 `12345678` |
| `-MaxTry` | 启动重试轮数，默认 3 |
| `-SelfTest` | 只做环境自检，不启动热点 |

示例：

```powershell
.\HotspotTool.ps1 -SeedSSID "MyRouter_5G" -HotspotSSID "LaptopAP" -HotspotPassword "abcd1234"
```

## 判定成功的标准

脚本不使用 WinRT `StartTetheringAsync` 的返回码判定成功，因为它可能只表示请求被受理。

脚本改为读取 `Microsoft-Windows-WLAN-AutoConfig/Operational` 事件日志：

- `8006`：承载网络已启动，真成功
- `8007`：启动失败，错误码 31

## 限制

- 每次开启都需重跑脚本，种子连接不会保留。
- 附近没有可用 5GHz 网络时不可用，只能退回 2.4GHz。
- 热点信道跟随种子网络。
- 单射频卡无法同时提供 2.4GHz 与 5GHz 两个热点。
- 依赖 Windows PowerShell 5.1 的 WinRT 互操作，PowerShell 7 下 `AsTask` 扩展方法不可用。

## 已排除的无效方案

- 升级 Intel 无线驱动（含官方最新版本）：行为不变
- 解绑 WinpkFilter / Npcap 等 NDIS 筛选器：无效
- 强制网卡「仅 5GHz」无线模式：无效
- 清理 Wi-Fi Direct 幽灵适配器：仅缓解 2.4GHz 偶发失败

## 免责

本项目为个人排查记录与工具，不保证适用于所有机型与驱动组合。操作涉及网络适配器与系统服务，请在了解风险后使用。

## 许可

MIT
