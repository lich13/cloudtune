# CloudTune

原生三端天翼云盘（`189CloudPC`）无损音乐与媒体播放器，支持 **macOS**、**iOS / iPadOS** 与 **Android**。

## 平台与技术栈

| 平台 | 技术栈 | 最低系统要求 | 发布产物 |
| --- | --- | --- | --- |
| **macOS** | Swift 6 + SwiftUI + AppKit + AVFoundation | macOS 14+ (Apple Silicon) | `CloudTune-<ver>-arm64.dmg` |
| **iOS / iPadOS** | Swift 6 + SwiftUI + UIKit/AVKit | iOS / iPadOS 17+ (`arm64`) | `CloudTune-<ver>-ios-arm64.ipa` + `ios/CloudTuneIOS.xcodeproj` |
| **Android** | Kotlin 2.4.21 + Jetpack Compose + AndroidX Media3 | Android 12+ (`minSdk 31`, `targetSdk 36`, `16 KB` 页对齐) | `CloudTune_<ver>_arm64-v8a.apk` |

## 核心特性

- **双通道安全登录**：支持天翼云盘 App 二维码扫码登录（支持一键保存二维码图片到系统相册）及**内嵌天翼官方网页一键回调登录**（解决单机无法扫自身屏幕痛点）。
- **四模块原生解耦导航**：`曲库`、`视频`、`云盘`、`传输` 独立分工（macOS `NavigationSplitView` + 原生多列可排序 `Table` + `Cmd+,` 独立偏好设置窗口；iOS/iPadOS 自适应 `TabView`/侧栏 + 磨砂迷你播放条 + 大页正在播放 + PiP 画中画；Android Material 3 自适应导航 + 预测性返回 + PiP 画中画），云盘目录切换不打断当前在播曲目与待播队列。
- **账号级数据与缓存隔离**：按 `SHA-256(normalizedAccountId)` 独立隔离曲库索引、设置、缓存与传输队列；退出登录时立即吊销回环流令牌并取消在途任务。
- **双播放模式与严格 Range 写穿代理**：支持 `优先缓存` 与 `边播边缓存`；本机 `127.0.0.1` HTTP Range 流式代理严格区分探测请求（如 `bytes=0-1`）与完整流，非零断点续传强制校验 `206 Partial Content` 与 `Content-Range` 起点，写穿完成后自动回填内嵌封面与曲目元数据。
- **统一并发配额与私有暂存导出**：流式代理、下一首预取、播放整曲缓存、多线程分片下载共享全局并发信号量（`<= 8`），私有目录合并校验后通过 macOS/iOS Security-Scoped Bookmark 或 Android SAF 安全导出。
- **系统媒体中心与后台播放**：macOS 支持点关闭隐藏窗口继续播放、键盘媒体键、控制中心、Dock 右键菜单、菜单栏快捷控制与 AirPlay 输出切换；iOS 支持锁屏、灵动岛、音频中断恢复与蓝牙拔出自动暂停；Android 基于 `MediaSessionService` 支持通知栏点击唤醒、锁屏控制与系统音频输出切换器。
- **纯净中性与磨砂通透视觉**：浅色通透纯中性（`#F7F8FA` / `#FFFFFF`）+ 深色中性炭灰（`#111315` / `#181B1F`）配合原生磨砂材质与低饱和松青强调色（Android 12+ 可选开启 Material You 壁纸动态取色），二维码固定暖白深松高对比衬底（`#F6F1E8` / `#13271F`）。

## 本地构建与验证

### macOS & iOS

```bash
# 校验脚本单测
python3 -m unittest discover -s scripts -p 'test_*.py'

# 核心单测 + macOS 9 景深浅色全状态离屏 PNG 快照断言
CLOUDTUNE_RENDER_SNAPSHOTS=1 swift test

# 打包 macOS Release .app 与 .dmg
APP_VERSION="1.1.0" PACKAGE_DMG=1 ./scripts/build-macos.sh release

# 打包 iOS 真机 ARM64 .ipa 并执行 vtool / ATS / 隐私门禁校验
APP_VERSION="1.1.0" ./scripts/build-ios.sh release
```

### Android

```bash
cd android
CLOUDTUNE_RENDER_SNAPSHOTS=1 ./gradlew testDebugUnitTest lintRelease assembleRelease --no-daemon -PappVersion="1.1.0"
```
