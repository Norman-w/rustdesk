# Norman Remote Desktop fork 使用说明

本分支是基于 RustDesk 1.4.9 的 Norman Remote Desktop fork。它保留 RustDesk 的远程桌面协议和兼容性，同时加入 Norman 项目所需的 macOS 全屏/Space 焦点保护，以及可选的手机麦克风输入链路。

这不是 RustDesk 官方发布包。构建、签名、安装和升级时，应把它当作 Norman Remote Desktop 的独立发行物；RustDesk 的版权、许可证和上游归属仍然保留。

## Fork 特性

### macOS 全屏和 Space 焦点保护

- 支持以 `--cm-no-ui` 启动无界面的连接管理器。
- 连接管理在后台运行时不会为了显示连接窗口而抢占当前 Space 或全屏应用。
- 菜单栏应用在后台服务仍在工作时不会因为窗口生命周期而自动退出。
- 当受控端使用无界面连接管理器时，不会再因为远程连接弹出一个短暂窗口而把 Codex、全屏终端或其他全屏应用切回桌面。

### 手机麦克风输入

- 远端语音通话流可以在 macOS 受控端被解码，并路由到用户明确选择的输出设备。
- Norman 的 CoreAudio 虚拟设备 `Norman 手机麦克风` 将这一路音频提供给 Codex 或其他能够选择输入设备的应用。
- 音频路由是显式可选的，默认关闭；不改变系统默认输入/输出设备。
- 这条链路不会录制或上传受控端的物理麦克风，也不会把手机麦克风伪装成 macOS 的系统默认麦克风。
- 手机端使用按住说话；连接确认成功和首个音频包发送成功分别提供触觉反馈。

## 运行时组件

完整体验需要手机端一个应用和受控 Mac 端两个组件：

| 位置 | 组件 | 作用 |
| --- | --- | --- |
| HarmonyOS 手机 | `Norman Remote Desktop` HAP（包名 `com.norman.remotedesktop`） | 连接远程设备、显示画面、发送输入和可选的手机麦克风音频 |
| 受控 Mac | `NormanRemoteDesktop.app` | Norman fork 的 RustDesk 桌面程序，负责远程桌面会话和音频接收 |
| 受控 Mac | `NormanRemoteDesktop-CMHelper-*.pkg` | 安装 `--cm-no-ui` 后台管理、LaunchAgent 和 `Norman 手机麦克风` CoreAudio HAL 插件 |

CM Helper 不是手机插件，也不是第二个 RustDesk 主程序。它是受控 Mac 上的配套组件；Mac mini 只负责构建和签名，不需要作为运行时组件安装。

## 构建

### macOS RustDesk fork

建议在配有完整 Rust、Flutter、Xcode 和音视频依赖的 Mac mini 上构建：

```sh
git clone --recurse-submodules https://github.com/Norman-w/rustdesk.git
cd rustdesk
git checkout norman/remote-mic-1.4.9
git submodule update --init --recursive
./build.py --flutter --hwcodec --unix-file-copy-paste
```

正式构建完成后，产物应为：

```text
flutter/build/macos/Build/Products/Release/NormanRemoteDesktop.app
```

正式发布前要对整个应用及其嵌套 Framework/动态库完成 macOS Developer ID 签名和公证。没有签名和公证的包只适合开发机验证。

### macOS 配套组件

CM Helper 和虚拟声卡位于 Norman Remote Desktop 配套工程中，在已经安装目标 RustDesk fork 的 Mac 上构建：

```sh
./tools/build-rustdesk-cm-helper-pkg.sh
```

构建脚本会检查目标应用为 RustDesk 1.4.9 兼容构建，并生成包含以下内容的安装包：

- `--cm-no-ui` 连接管理 LaunchAgent；
- `NormanRemoteMic.driver` CoreAudio HAL 插件；
- 音频设备探测和显式路由配置脚本；
- 可审计的虚拟声卡源代码、许可证和 RustDesk 路由补丁。

## 受控 Mac 安装和配置

1. 退出旧版 RustDesk，再将 fork 应用安装到 `/Applications/NormanRemoteDesktop.app`。
2. 首次运行时，按照 macOS 实际提示授予屏幕录制、辅助功能/输入监控等远程控制所需权限。
3. 安装 CM Helper 包，并等待 CoreAudio 重新加载；必要时重新登录或重启 CoreAudio。
4. 检查并选择 Norman 虚拟设备：

   ```sh
   HELPER="$HOME/Library/Application Support/NormanRemoteDesktop/cm-helper"
   "$HELPER/remote-mic-config.sh" list
   "$HELPER/remote-mic-config.sh" select-norman-output
   "$HELPER/remote-mic-config.sh" restart
   "$HELPER/remote-mic-config.sh" status
   ```

5. 在 Codex 或其他目标应用的音频输入设置中，手动选择 `Norman 手机麦克风`。安装插件本身不会修改系统默认输入设备。
6. 在手机 HAP 中连接到该 Mac；连接后显示麦克风对讲按钮，按住按钮开始说话。

普通远程桌面音频和手机麦克风输入是两条不同用途的路径。CM 可以处于 ready，而音频仍保持 disabled；只有明确选择 Norman 输出并启用手机端对讲时，手机音频才会进入虚拟设备。

## 配置状态

受控端 Helper 状态的含义如下：

- `disabled`：音频路由关闭，默认状态；
- `requires-patched-rustdesk`：检测到设备配置，但 RustDesk 主程序不含 Norman 音频路由补丁；
- `not-configured`：主程序含补丁，但尚未选择输出设备；
- `candidate`：设备同时有输入/输出通道，但尚未完成用户确认；
- `ready`：已确认回环和路由，可供目标应用选择；
- `unavailable`：之前选择的设备当前不存在或不可用。

如果 Helper 已安装但手机仍提示“受控端虚拟麦克风未加载”，先运行 `status`，确认 CoreAudio 能看到 `Norman 手机麦克风`，再重启 Helper；不能仅凭目录存在就判断组件 ready。

## 升级和身份兼容

Mac 应用的用户可见名称是 `Norman Remote Desktop`，应用包目录名是 `NormanRemoteDesktop.app`。为兼容已有受控端安装和 CM 管理，本 fork 暂时保留 RustDesk 的内部 Bundle ID `com.carriez.rustdesk`；不要在普通升级中随意改成新的 Bundle ID，否则系统会把它当作新应用并要求重新授权。

HarmonyOS HAP 使用独立的包名 `com.norman.remotedesktop`。手机端 HAP 的签名必须与目标安装/升级策略一致；未签名 HAP 只能作为构建产物，不能直接安装到真机。

## 安全边界

- 远程麦克风功能只处理手机端明确发起的语音通话流。
- macOS 受控端默认不采集物理麦克风、不录音、不修改系统默认音频设备。
- CM Helper 负责后台连接管理和音频桥接，不执行手机端下发的任意 Shell 命令。
- 使用剪切板同步、麦克风输入和第三方虚拟音频设备前，应确认目标设备和网络属于自己或已获授权的范围。
