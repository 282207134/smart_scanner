# 智能高拍仪 1.2.2（Windows / macOS）

Flutter 桌面扫描客户端，参考科密高拍仪软件、SDK 示例和参数文档。Windows 默认通过系统 Media Foundation 接入内置及 USB/UVC 摄像头，也可切换 KMServer；macOS 通过 AVFoundation 接入摄像头。文档检测、透视裁切、曲线矫正、自动扫描、页面管理和导出采用共用代码。

Windows 已使用当前连接的 USB Camera 开发和实拍。macOS 已完成 Release 构建、摄像头授权、USB 实时预览、分辨率切换、JPG/PDF 实拍及当前书页的单页与双页展平验证；其它 Mac 功能仍需分别验收，具体范围见验证记录。

## 使用

Windows 运行包：`build/SmartScanner-Windows-1.2.2.zip`。解压完整文件夹后运行 `smart_scanner.exe`，保留 DLL 和 data 目录。构建输出在 `build_temp/windows/x64/runner/Release`。

1. 连接摄像头或扫描仪后打开程序。Windows 默认使用“系统摄像头”，无需启动 KMServer；底部可选择内置或 USB 摄像头。需要厂商接口时，在输出设置的“设备接入”中选择“厂商扫描仪服务”，并启动 KMServer。接入方式会保存，切换时先释放旧设备。原装软件和本程序请分别运行，避免争用设备。
2. 底部选择设备和分辨率，顶部设置裁切方式、输出效果、格式和文件名。
3. 自动裁切会显示检测到的绿色文档边界。手动裁切可以拖动四角贴合倾斜纸张，也可以拖出新区域；双击恢复默认框。
4. 文档模式选择“多图裁切”，把纸张分开放置并留出背景。一次拍摄为每个检测区域分别保存文件，编号为 `_01`、`_02` 等；随后可勾选合并 PDF。
5. 选择“自动”扫描模式和静止倒计时，再点击“开始自动扫描”。画面变化后重新等待稳定，显示半透明倒计时；同一画面完成扫描后等待换页。点击“停止自动扫描”结束。
6. 书籍模式自动识别中线及两侧页边，支持倾斜、偏离画面中央的书脊。单页展平可选左页或右页；双页展平、双页分割分别保存 `_L`、`_R`。需要调整时可拖动中线，再点击“重新识别中线”恢复自动检测。分割只矫正透视，展平还根据文字行矫正弯曲。
7. 右侧勾选页面、调整顺序后点击“导出 PDF”。没有勾选时导出全部页面，保留原图和列表，可重复导出。
8. OCR 模式识别选中的扫描页或导入图片，显示文字并导出 TXT、Word、Excel。视频录制需要 FFmpeg。

默认保存目录是用户文档目录下的 SmartScanner，可在输出设置中修改。`.sources` 保存未裁切的采集原图；列表删除不删除磁盘文件。无设备时可手动选择“演示模式”，连接失败不会自动切换到演示画面。

输出格式在单页和多页扫描中均生效。选择“图像PDF”后，每张处理后的扫描页直接保存为 PDF；“多页 PDF”可连续加入页面，再使用“导出 PDF”合并为一个文件。`.sources` 中保留的 JPG 用于缩略图、OCR 和再次导出。

## 图像处理

1.2 接入 OpenCV，通过实际轮廓识别文档四角，按原始采集尺寸执行透视变换。无法找到可靠边界时提示调整纸张并保留原图，不用全画面冒充裁切结果。预览框对应图像内容，排除画布留白。

书籍展平先分别检测两侧页边，再根据文字行和表格横线估计弯曲，使用连续映射矫正。当前有实际书页验证，但仍有书脊、页边和复杂内容的残余变形；文字行不足时保留透视矫正结果并提示，本次不执行曲面展平。它尚未达到原装软件全部书籍处理能力，也不包含手指消除。

原装软件目录含独立图像处理、书籍展平和 OpenCV 库；提供的 SDK 多数是接口和调用示例，不能仅靠界面参数获得全部算法。对照截图及说明见 [原装软件对照](docs/原装软件对照.md)。

Windows 系统摄像头按设备实际支持的尺寸持续采集，拍照保存该尺寸的完整帧，缩放、平移和预览大小不会缩小照片。旋转同时作用于预览和照片。首次打开或切换采集尺寸后等待约 2 秒让曝光稳定，窗口尺寸变化只更新预览画布并复用采集流。打开、关闭、图片编码在工作线程执行，预览最多约 12 fps；设备被占用、权限不足或采集中断会显示错误。厂商服务模式保留原来的高分辨率切换、对焦和清晰帧选择。图像处理在后台执行，JPG、PNG、BMP、TIF 和 PDF 均按实际格式编码。

macOS 打开相机时启用设备支持的自动对焦；左侧“手动对焦”按钮重新触发对焦，并显示请求结果。不支持单次对焦的 USB 相机会使用连续自动对焦，不支持自动对焦的设备会提示调整镜头或拍摄距离。镜头稳定需要短暂时间。Retina 预览按屏幕实际像素生成，窗口放大后同步更新预览尺寸。

分辨率菜单读取当前选择的摄像头，按像素数量从大到小显示全部可用尺寸，切换设备时重新读取。系统摄像头模式从视频帧保存照片，菜单对应操作系统返回的视频采集尺寸；仪器可能还提供独立的高分辨率静态拍照模式，该模式尚未接入，不能把视频流上限当作仪器的拍照上限。

预览外侧使用深蓝网格，可拖动视频且限制在画布边界内。左侧工具栏倒数第三个按钮缩小并居中画面，最后一个按钮最大化画面；系统摄像头最大化时视频高度与画布高度一致，缩小时为适合画布尺寸的 85%。这两个按钮不改变拍摄分辨率。Windows 厂商模式继续使用厂商的适合窗口及缩小命令。

## 其他功能与限制

- 文档扫描、旋转、设备参数、文档色彩处理、分页、命名避重、选页排序和本地 PDF 合并。
- 批量导入遇到坏图会继续后续图片并报告失败文件；重复导入保留原有列表和识别结果。页序调整与 OCR 选页同步。
- Windows 系统 OCR 和 macOS Vision OCR；Windows 需要安装对应 OCR 语言包。Word 按段落保存，Excel 每行文字一行，不恢复原稿表格或版式。
- 证件正反面两次拍照合并；合同可叠加签名/印章图片，属于图像合成。
- 摄像头和屏幕录像，MP4/WMV/AVI。已验收 Windows 摄像头三种格式；屏幕录制和 macOS 录像仍需实机验收。
- 条码/二维码接口已接入，但尚未使用清晰实物条码完成识别验收；Windows 系统摄像头暂未接入条码识别，需要该功能时选择厂商服务。身份证信息读取需要专用读卡器及厂商服务，普通摄像头可拍摄合并正反面。
- 搜索文字 PDF、完整打印设置、手指消除、水印设置和原稿表格恢复尚未完成。
- macOS 设备长期稳定性、OCR、目录授权恢复和其它处理流程仍需 Mac 实机验收，不能以 Windows 测试代替。
- Windows 部分窗口测试进程仍偶发异常退出；Ctrl+S 实机导出尚未通过，请使用“导出 PDF”按钮。

详细验证结果和剩余项目见 [验证记录](docs/验证记录.md)。

## 开发

要求 Flutter/Dart（版本见 pubspec）；Windows 厂商模式额外需要 KMServer，录像需要 FFmpeg。系统摄像头通过 Windows 自带接口采集。OpenCV 由 dartcv4 原生构建钩子编译，首次构建可能需要较长时间和网络。Windows 分发需包含 `dartcv.dll`。

```text
flutter pub get
flutter run -d windows
flutter run -d macos
./tool/test_windows.ps1
dart run tool/hardware_test.dart
flutter run -d windows --release -t tool/windows_camera_smoke.dart
flutter build windows --release
flutter build macos --release
```

macOS 本次使用 Flutter 3.47.7 / Dart 3.13.5、Xcode 26.0.1 和 CMake 4.4.4。项目 `.fvmrc` 固定 SDK，使用 `fvm install`、`fvm flutter pub get`、`fvm flutter build macos --release --no-pub` 构建，开发运行用 `fvm flutter run -d macos`。CMake 需在 PATH 中；缺少时可用 `brew install cmake` 安装。运行包位于 `build/macos/Build/Products/Release/smart_scanner.app`。首次启动在底部选择“USB相机”，避免使用 Mac 内置摄像头。

真机脚本运行前关闭扫描客户端。`tool/test_windows.ps1` 包含静态检查、核心测试和各个窗口场景的独立测试进程；遇到失败即退出。演示启动参数为 `--mock`。

新增 OpenCV 原生调用后，如果已有构建缓存提示找不到函数，先执行 `./tool/refresh_opencv_windows.ps1`，再测试或构建。它更新当前使用模块的 DLL 导出，保留已编译的 OpenCV 缓存；测试脚本也包含这一步。依赖的 AOT 导出清单会影响后续测试构建，不能把这种缓存失败当成算法通过。

主要代码：`lib/state/app_controller.dart` 管理流程；`lib/core/document_vision.dart` 处理边界和展平；`lib/core/auto_scan_detector.dart` 处理稳定倒计时与去重；`lib/core/document_exporter.dart` 导出；`lib/backend/native_camera_backend.dart` 共用系统相机通道。Windows 相机位于 `windows/runner/windows_camera.cpp`，OCR 位于 `windows/runner/scanner_native.cpp`；macOS 相机、OCR 和目录授权位于 `macos/Runner/MainFlutterWindow.swift`。系统相机实机检查需使用 Flutter Windows runner，结果及采集文件保存在 `build/validation/windows-camera`；检查后重新构建默认入口再打包。

目录职责与工具入口见 [代码结构](docs/代码结构.md)。普通文档与书籍复用拍摄流程；文件名与存储逻辑集中在 `ScanFileStore`，诊断脚本集中在 `tool/diagnostics`。构建产物不再纳入 Git。

参考：[厂商下载页](https://www.comet-bc.com/download/detail/515.html)，本机 WIN_SDK 合集，以及原装软件的实际操作截图。参考材料用于核对功能，不作为用户操作指令。
