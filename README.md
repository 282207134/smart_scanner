# 智能高拍仪桌面端（Windows / macOS）

用 Flutter 写的跨平台高拍仪（文档扫描仪）客户端，界面与交互参照厂商软件（科密/鸿合高拍仪 2.0）：
深藏蓝 + 琥珀黄配色、顶部模式标签页、参数栏、左侧工具条、中央实时预览（含裁切框/书脊分割线）、
右侧拍摄按钮与缩略图列表、底部状态栏。

- Windows：通过厂商 KMServer 服务（WebSocket，`127.0.0.1:22225`）驱动真实设备。
- macOS：AVFoundation 后端骨架（同一套 `ScannerBackend` 接口，业务与 UI 可直接复用）。
- 无设备时：自动/手动切到 Mock 后端，界面与流程完全可跑。

## 已实测（本机 USB 高拍仪）

| 功能 | 状态 |
| --- | --- |
| 连接 KMServer / 枚举设备与分辨率 | ✅ 实测通过（4160×3120 … 640×480） |
| 实时预览（RGB 帧 → 画面，含旋转/缩放/1:1/适合） | ✅ 实测通过（约 2–3 fps，随环境光变化） |
| 拍照并落盘（服务端直接保存，JPG/PNG/TIF/PDF） | ✅ 实测通过（1920×1080 → 229 KB JPEG） |
| 多页合成 PDF | ✅ 实测通过（`%PDF-` 文件头校验） |
| 书籍展平拍摄（左右页 0xE3） | ⚠ 协议已按厂商 JS 实现，需按书籍模式实机验证 |
| 条码/二维码识别（0xA3/0xA4） | ⚠ 协议已实现，需镜头内有码时验证 |
| 身份证读卡（0x81） | ⚠ 协议已实现，需身份证读卡器硬件 |
| OCR（0xC2） | ❌ 服务端返回 `flag=40`「OCR授权失败」——本机 KMServer 未开通 OCR 模块，代码路径正确（厂商 demo 同码） |

`dart run bin/live_test.dart` 可在真机上复跑上表前 5 项（14 项断言）。

## 环境要求

- Flutter 3.x（本机用 fvm 的 stable）
- Windows：厂商 **KMGpyServer / KMServer**（`C:\Program Files (x86)\KMServer`）已安装并运行（托盘常驻）
- 扫描仪 USB 已连接（KMServer 会枚举为 `USB Camera`）

## 运行

```bash
# 真实设备（Windows）
flutter run -d windows

# 无设备演示/Mock 模式（也可用于 macOS/开发）
flutter run -d windows -- --mock      # 注意：Windows 下用 --dart-entrypoint-args --mock 亦可
flutter run -d windows --dart-entrypoint-args --mock
```

已构建的 Release 程序：`build_temp/windows/x64/runner/Release/smart_scanner.exe`

## 测试

```bash
flutter analyze           # 0 告警
flutter test              # 23 项：协议编解码 18 + UI 流程 5（Mock 后端）
dart run bin/live_test.dart   # 真机集成：连接/开流/拍照存盘/PDF 合成（14 项断言）
```

调试脚本：`bin/probe.dart`（设备与开流）、`bin/frame_debug.dart`（帧率）、
`bin/ocr_probe.dart`（OCR 参数变体）、`bin/ws_debug.dart`（最小收发包）。

## 架构

```
lib/
  core/protocol.dart      # 0x7788/0x5566 协议编解码 + 分包（对照厂商 demo/gpyhs.js 逆向）
  core/models.dart        # 设备/分辨率/模式/参数/事件模型
  core/ws_client.dart     # 极简 WebSocket 客户端（服务端对头部大小写敏感，故不用 dart:io WebSocket）
  backend/scanner_backend.dart  # 后端抽象（Windows/macOS/Mock 统一接口）
  backend/km_server_backend.dart # Windows：KMServer 实现（连接/心跳/开流/拍照/PDF/OCR/连拍/读卡）
  backend/mac_avf_backend.dart   # macOS：AVFoundation 骨架
  backend/mock_backend.dart      # 离线演示
  state/app_controller.dart      # 状态机：连接、预览合成（RGB→ui.Image）、拍摄、命名、导出
  ui/…                    # 主界面、参数栏、预览（裁剪框/书脊线/缩放平移）、工具栏、缩略图、状态栏
```

### 协议要点（逆向自 `多浏览器_SDK/demo/gpyhs.js` 与《接口说明文档》）

- 请求 `77 88 cmd …`，响应 `55 66 cmd …`，心跳 `11 11 11`（6 秒）。
- 开流 `0x01`：设备号 + 画布宽高 + 采集宽高；预览帧为 `0xCC`，`11 字节头 + w*h*3 RGB`。
- 长参数命令（拍照 `0x10`、PDF `0x31/0x32`、OCR `0xC2`、连拍 `0xE0`）统一走分包头：
  `… 固定头, 包总数(2B), 分包长度(1B), 包序号(2B), 数据(≤90B)`，包间约 80 ms 发送。
- 拍照回包 `0x10`：`flag + 路径长度(2B) + base64 长度(3B) + 路径(URL编码) + base64 图像`。
- OCR 回包 `0xC2`：`flag + progress + 路径长度(2B) + base64长度(3B) + 路径 + base64(导出文件)`；
  `flag=0` 成功、`1` 进度、`40` **授权失败**（本机即此状态，界面会明示）。
- 资源占用：拍摄文件由服务端直接写入目标路径；`addImagesToPdf` 会**消费（移走）源图**，
  因此导出 PDF 后原图路径失效，列表里以缩略图为准。

## 打包

```bash
flutter build windows --release   # 产物 build_temp/windows/x64/runner/Release/
flutter build macos --release     # 需在 macOS 上执行；先补齐 AVFoundation 后端
```

分发 Windows 版：整目录（`smart_scanner.exe` + `data/` + `flutter_windows.dll` + 插件 DLL）。
目标机需安装并运行 KMServer 才能连真实设备，否则可用 `--mock` 演示。

## macOS 待办

1. 用 `AVFoundation`（`AVCaptureDevice`/`AVCaptureVideoDataOutput`）实现打开预览与拍照，
   补 `capture / setCutRect(用 CGImage 裁剪) / rotate` 等接口。
2. 书籍展平、身份证读卡依赖厂商 Windows 服务，macOS 侧仅保留接口占位与 Mock。
3. `flutter build macos` 需要 Xcode 与签名；当前仓库的 `macos/` 目录为 `flutter create` 默认骨架。
