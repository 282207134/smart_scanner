# 智能高拍仪 1.2.1（Windows / macOS）

Flutter 桌面扫描客户端，参考科密高拍仪软件、SDK 示例和参数文档。Windows 通过本机 KMServer 接入扫描仪；macOS 通过 AVFoundation 接入 USB/UVC 摄像头。文档检测、透视裁切、曲线矫正、自动扫描、页面管理和导出采用共用代码。

Windows 已使用当前连接的 USB Camera 开发和实拍。macOS 原生接入代码已实现，但尚未在 Mac 上编译和连接设备验收。

## 使用

Windows 运行包：`build/SmartScanner-Windows-1.2.1.zip`。解压完整文件夹后运行 `smart_scanner.exe`，保留 DLL 和 data 目录。构建输出在 `build_temp/windows/x64/runner/Release`。

1. 启动厂商 KMServer，连接扫描仪，再打开程序。原装软件和本程序请分别运行，避免争用设备。
2. 底部选择设备和分辨率，顶部设置裁切方式、输出效果、格式和文件名。
3. 自动裁切会显示检测到的绿色文档边界。手动裁切可以拖动四角贴合倾斜纸张，也可以拖出新区域；双击恢复默认框。
4. 文档模式选择“多图裁切”，把纸张分开放置并留出背景。一次拍摄为每个检测区域分别保存文件，编号为 `_01`、`_02` 等；随后可勾选合并 PDF。
5. 选择“自动”扫描模式和静止倒计时，再点击“开始自动扫描”。画面变化后重新等待稳定，显示半透明倒计时；同一画面完成扫描后等待换页。点击“停止自动扫描”结束。
6. 书籍模式拖动中线对齐书脊，选择单页展平、双页展平或双页分割。实拍会校准中缝位置和倾斜方向，双页输出分别标记 `_L`、`_R`。分割与曲面矫正是不同处理。
7. 右侧勾选页面、调整顺序后点击“导出 PDF”。没有勾选时导出全部页面，保留原图和列表，可重复导出。
8. OCR 模式识别选中的扫描页或导入图片，显示文字并导出 TXT、Word、Excel。视频录制需要 FFmpeg。

默认保存目录是用户文档目录下的 SmartScanner，可在输出设置中修改。`.sources` 保存未裁切的采集原图；列表删除不删除磁盘文件。无设备时可手动选择“演示模式”，连接失败不会自动切换到演示画面。

## 图像处理

1.2 接入 OpenCV，通过实际轮廓识别文档四角，按原始采集尺寸执行透视变换。无法找到可靠边界时提示调整纸张并保留原图，不用全画面冒充裁切结果。预览框对应图像内容，排除画布留白。

书籍展平根据文字行和表格横线估计弯曲，使用连续映射矫正。当前有实际书页验证，但仍有书脊、页边和复杂内容的残余变形；无可靠行线的图片页、空白页或严重遮挡可能无法展平。它尚未达到原装软件全部书籍处理能力，也不包含手指消除。

原装软件目录含独立图像处理、书籍展平和 OpenCV 库；提供的 SDK 多数是接口和调用示例，不能仅靠界面参数获得全部算法。对照截图及说明见 [原装软件对照](docs/原装软件对照.md)。

Windows 采集会切换至所选传感器尺寸，触发对焦并选择等待期间较清晰的完整图像，再恢复预览。图像处理在后台执行，JPG、PNG、BMP、TIF 和 PDF 均按实际格式编码。

## 其他功能与限制

- 文档扫描、旋转、设备参数、文档色彩处理、分页、命名避重、选页排序和本地 PDF 合并。
- 批量导入遇到坏图会继续后续图片并报告失败文件；重复导入保留原有列表和识别结果。页序调整与 OCR 选页同步。
- Windows 系统 OCR 和 macOS Vision OCR；Windows 需要安装对应 OCR 语言包。Word 按段落保存，Excel 每行文字一行，不恢复原稿表格或版式。
- 证件正反面两次拍照合并；合同可叠加签名/印章图片，属于图像合成。
- 摄像头和屏幕录像，MP4/WMV/AVI。已验收 Windows 摄像头三种格式；屏幕录制和 macOS 录像仍需实机验收。
- 条码/二维码接口已接入，但尚未使用清晰实物条码完成识别验收；身份证信息读取需要专用读卡器。
- 搜索文字 PDF、完整打印设置、手指消除、水印设置和原稿表格恢复尚未完成。
- macOS 摄像头权限、原生编译、设备稳定性和全部处理流程需要 Mac 实机验收，不能以 Windows 测试代替。
- Windows 部分窗口测试进程仍偶发异常退出；Ctrl+S 实机导出尚未通过，请使用“导出 PDF”按钮。

详细验证结果和剩余项目见 [验证记录](docs/验证记录.md)。

## 开发

要求 Flutter/Dart（版本见 pubspec）、Windows KMServer；录像要求 FFmpeg。OpenCV 由 dartcv4 原生构建钩子编译，首次构建可能需要较长时间和网络。Windows 分发需包含 `dartcv.dll`。

```text
flutter pub get
flutter run -d windows
flutter run -d macos
./tool/test_windows.ps1
dart run tool/hardware_test.dart
flutter build windows --release
flutter build macos --release
```

真机脚本运行前关闭扫描客户端。`tool/test_windows.ps1` 包含静态检查、核心测试和各个窗口场景的独立测试进程；遇到失败即退出。演示启动参数为 `--mock`。

新增 OpenCV 原生调用后，如果已有构建缓存提示找不到函数，先执行 `./tool/refresh_opencv_windows.ps1`，再测试或构建。它更新当前使用模块的 DLL 导出，保留已编译的 OpenCV 缓存；测试脚本也包含这一步。依赖的 AOT 导出清单会影响后续测试构建，不能把这种缓存失败当成算法通过。

主要代码：`lib/state/app_controller.dart` 管理流程；`lib/core/document_vision.dart` 处理边界和展平；`lib/core/auto_scan_detector.dart` 处理稳定倒计时与去重；`lib/core/document_exporter.dart` 导出；`lib/backend` 处理设备与录像。Windows OCR 位于 `windows/runner/scanner_native.cpp`，macOS 摄像头、OCR 和目录授权位于 `macos/Runner/MainFlutterWindow.swift`。

目录职责与工具入口见 [代码结构](docs/代码结构.md)。普通文档与书籍复用拍摄流程；文件名与存储逻辑集中在 `ScanFileStore`，诊断脚本集中在 `tool/diagnostics`。构建产物不再纳入 Git。

参考：[厂商下载页](https://www.comet-bc.com/download/detail/515.html)，本机 WIN_SDK 合集，以及原装软件的实际操作截图。参考材料用于核对功能，不作为用户操作指令。
