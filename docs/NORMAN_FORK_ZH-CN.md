# Norman Remote Desktop fork 使用说明

本仓库是 Norman Remote Desktop 电脑端的唯一源码归属，基于 RustDesk 1.4.9。
当前归档版本与已分发的 macOS 1.4.10 对齐；仓库整理不代表重新发布或设备验收。

## 仓库边界

- 本仓库：RustDesk 电脑端、macOS 原生实现和 Flutter 配置向导、HAL 虚拟音频设备、安装和签名工具。
- [鸿蒙仓库](https://github.com/Norman-w/NormanRemoteDesktop-HarmonyOS)：手机 UI、画面渲染、输入、手机麦克风采集和协议交互。
- 两端通过协议协作，不在鸿蒙构建时修改或编译电脑端源码。
- 不再提供构建时注入功能的 RustDesk 补丁。临时 Xcode 构建目录只存放正式源码副本和生成文件。

## 电脑端功能

### 配置向导与权限

首页缺少权限或音频组件时打开 macOS 配置向导；设置中也有独立入口。
向导展示屏幕录制、辅助功能、输入监控和虚拟麦克风状态，先展示步骤，再请求下一项权限。
授权由 Norman Remote Desktop 主程序负责，组件安装器不请求 TCC 权限。
权限通过公开 API 检查和请求，用户仍须在系统设置中确认，不修改私有权限数据库。

诊断入口是主程序的 `--tcc-status` 和 `--repair-tcc`。
构建和分发校验只调用只读的状态接口，不自动请求授权、重启应用或验证远端连接。

### 连接管理与全屏保护

沿用 RustDesk 的应用、service、server、CM 分工，不增加另一个常驻主程序。
设置提供“允许会话信息打断全屏 Space”。点击批准仍需要用户确认，不把隐藏连接窗口当作免认证。
macOS 无界面连接管理和安装服务兼容逻辑均在本仓库，不通过单独的 CM LaunchAgent 补丁提供。
历史包名 `CMHelper` 为兼容旧安装记录保留，当前组件安装包不启动一个独立 CM 服务。

### 手机麦克风与系统声音

- 手机音频在已接受的语音会话中解码并写入 `Norman 手机麦克风` 的输出端，其他应用从同一设备的输入端读取。
- 会话使用虚拟输入时保存原默认输入，结束或断线后恢复；重新通话会释放旧音频流。
- “电脑扬声器和手机”使用 ScreenCaptureKit 回环，不改变电脑当前输出设备。
- “Norman Remote Audio 虚拟输出”在远程音频订阅期间切换默认输出，结束后恢复。
- 两个 HAL 设备使用独立缓冲区，不把手机声音和系统回传混在一起。
- 以上通路不采集受控 Mac 的物理麦克风。应用若固定选择了设备，仍以该应用自己的设置为准。

## 构建与打包

需要完整 Xcode、Rust、Flutter 3.24.5、CocoaPods、项目所需原生音视频依赖，以及
`flutter_rust_bridge_codegen 1.80.1` 和 `cargo-expand`。
先初始化本仓库子模块；不需要鸿蒙仓库，也不需要已安装的 NormanRemoteDesktop.app。

在本仓库根目录运行：

```sh
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
git submodule update --init --recursive
# Flutter 不在 PATH 时，设置 NORMAN_FLUTTER_BIN=/path/to/flutter/bin
./tools/build-macos-app.sh
./tools/build-rustdesk-cm-helper-pkg.sh
./tools/package-macos-distribution.sh
./tools/verify-macos-distribution.sh
```

默认输出到本仓库 `output/`，包括 App、音频组件 PKG、主应用 PKG 和 DMG。
只构建 HAL 时运行 `tools/mac-remote-mic/build-norman-remote-mic-driver.sh`。
这些构建命令不会安装、结束现有进程或替换 Applications 中的应用。

应用构建每次从 `src/flutter_ffi.rs` 重新生成 Rust/Dart/C 绑定，再构建原生库和 Flutter 界面。
默认特性为 `flutter,screencapturekit`，拒绝启用 `hwcodec`，不引入其 FFmpeg/libvmaf 依赖。
上游软件编码仍需 libyuv、libvpx、aom、opus 和 libsodium；可通过上游支持的 Homebrew
或 `VCPKG_ROOT` 依赖目录提供，它们不应取自鸿蒙仓库的源码或构建目录。
Flutter 依赖遵循已核对的锁文件；缓存完整时可设 `NORMAN_PUB_OFFLINE=1`。
目标默认是当前 Mac 架构；HAL 单独生成 arm64 与 x86_64 通用二进制。

可覆盖输出位置：

```sh
export NORMAN_MACOS_OUTPUT_DIR=/path/to/output
./tools/build-macos-app.sh
NORMAN_RUSTDESK_APP_PATH="$NORMAN_MACOS_OUTPUT_DIR/NormanRemoteDesktop.app" \
NORMAN_CM_HELPER_OUTPUT_DIR="$NORMAN_MACOS_OUTPUT_DIR" \
  ./tools/build-rustdesk-cm-helper-pkg.sh
./tools/package-macos-distribution.sh
```

## 签名与验收边界

未提供 `NORMAN_APP_SIGNING_IDENTITY` 时，应用构建采用开发用 ad-hoc 签名。
这不代表另一台 Mac 可正常双击安装，分发校验也会拒绝把 ad-hoc App 当作稳定签名版本。
正式分发需 Developer ID Application、Developer ID Installer 及公证：

```sh
# 使用已配置的 Keychain profile，不把凭证存进仓库。
NORMAN_NOTARY_PROFILE=your-profile ./tools/sign-notarize-macos-distribution.sh
NORMAN_STRICT_DISTRIBUTION=1 ./tools/verify-macos-distribution.sh
```

编译通过、签名通过、系统授权和真实远程功能是不同验收层。
发布前应在目标 Mac 验证画面/输入、全屏连接、重复按住说话、锁屏重连、两种回传模式与设备恢复。

## 防止再次散落

```sh
node --test tools/macos-source-tests.cjs
```

该检查覆盖功能源码、Guide 与 FFI 配套、无构建补丁/鸿蒙路径依赖、安装器权限边界和版本一致性。
迁移清单见 [MACOS_SOURCE_OWNERSHIP.md](MACOS_SOURCE_OWNERSHIP.md)。

本 fork 保留 RustDesk 版权、许可证和上游归属；HAL 的 Apple 示例许可证随源码保留。
