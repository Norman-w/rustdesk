# Windows x64 测试包

本包由 Norman RustDesk fork 构建，适用于 Intel / AMD 的 64 位 Windows。
这是首次 Windows 分发验证，不代表 macOS 增强功能已经移植。

## 文件

- `NormanRemoteDesktop-Windows-<版本>-x64.exe`：自解压便携程序，直接运行。
- `NormanRemoteDesktop-Windows-<版本>-x64-portable.zip`：解压完整目录后运行 `rustdesk.exe`，不能只拿走 EXE。
- `NormanRemoteDesktop-Windows-<版本>-x64.msi`：沿用上游 Windows 安装流程的安装包。
- `SHA256SUMS.txt`、`build-info.json`：文件校验值、源码提交、架构及实际执行的检查。

首次测试建议使用便携版。当前保留 RustDesk 的 Windows 程序名、配置和服务身份，界面可能显示 RustDesk；MSI 可能升级或影响已有的 RustDesk 安装，不应把两者当作相互独立的服务同时安装。
本包未配置 Windows Authenticode 签名，可能出现未知发布者提示。不要为此关闭系统安全防护；只使用本 fork 的文件并核对散列。

## 功能边界

沿用 RustDesk 的画面、鼠标键盘、文件传输和 Windows 音频功能，以及 fork 中共享的音频流生命周期修改。
不包含 macOS 的 HAL 虚拟麦克风、默认音频设备自动切换恢复、TCC 配置向导或全屏 Space 保护。
本次仅启用软件编解码，不启用 `hwcodec`、`vram`，不构建 FFmpeg/libvmaf，也不附带可选虚拟显示器或打印机驱动。
CI 检查架构、版本命令、原生库加载和 MSI 元数据；手机到 Windows 的画面、控制、重连、音频及安装卸载仍需目标电脑实测。

## 构建

`.github/workflows/norman-windows-x64.yml` 使用 Windows 2022 x64 runner，先从同一提交生成 Flutter/Rust 绑定，再执行 `tools/build-windows-x64.ps1`。
版本来自 Cargo 和 Flutter 元数据，输出到 `output/windows-x64/`。流程仅上传构建产物，不自动发布 Release、不安装服务，也不读取本地 macOS / 鸿蒙签名材料。
本源码保留 RustDesk 及其依赖的版权和许可证；分发包附带上游 AGPL 许可证。
