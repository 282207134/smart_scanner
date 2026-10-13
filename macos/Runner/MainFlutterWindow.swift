import Cocoa
import FlutterMacOS
import AVFoundation
import Vision
import CoreImage

class MainFlutterWindow: NSWindow {
  private var scanner: NativeScanner?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    scanner = NativeScanner(messenger: flutterViewController.engine.binaryMessenger)
    self.title = "智能高拍仪"
    self.minSize = NSSize(width: 960, height: 640)

    super.awakeFromNib()
  }
}

final class NativeScanner: NSObject, FlutterStreamHandler, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "smart_scanner.camera")
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var sink: FlutterEventSink?
  private var latest: CIImage?
  private var devices: [AVCaptureDevice] = []
  private var canvasW = 640, canvasH = 480
  private var rotation = 0, colorMode = 0, cutMode = 0
  private var cutRect: CGRect?
  private var zoom: CGFloat = 1, pan = CGPoint.zero
  private var lastFrameTime = CFAbsoluteTimeGetCurrent()
  private var removeBg = false, smartEdge = false
  private var folderAccess: URL?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let methods = FlutterMethodChannel(name: "smart_scanner/native", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    FlutterEventChannel(name: "smart_scanner/frames", binaryMessenger: messenger).setStreamHandler(self)
  }
  deinit { folderAccess?.stopAccessingSecurityScopedResource() }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func reply(_ result: @escaping FlutterResult, _ value: Any?) { DispatchQueue.main.async { result(value) } }
  private func failure(_ result: @escaping FlutterResult, _ message: String) { reply(result, FlutterError(code: "SCANNER", message: message, details: nil)) }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "connect" {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: result(nil)
      case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { allowed in
        if allowed { self.reply(result, nil) } else { self.failure(result, "请在系统设置中允许智能高拍仪使用摄像头") }
      }
      default: failure(result, "摄像头权限未授权，请在系统设置中允许摄像头访问")
      }
      return
    }
    queue.async {
      do {
        switch call.method {
        case "bookmarkFolder":
          guard let path = args["path"] as? String else { throw NSError(domain: "缺少目录路径", code: 1) }
          let url = URL(fileURLWithPath: path, isDirectory: true)
          let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
          self.folderAccess?.stopAccessingSecurityScopedResource()
          self.folderAccess = url.startAccessingSecurityScopedResource() ? url : nil
          self.reply(result, FlutterStandardTypedData(bytes: data))
        case "restoreFolder":
          guard let data = args["bookmark"] as? FlutterStandardTypedData else { throw NSError(domain: "缺少目录授权", code: 1) }
          var stale = false
          let url = try URL(resolvingBookmarkData: data.data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
          guard url.startAccessingSecurityScopedResource() else { throw NSError(domain: "请重新选择保存目录", code: 1) }
          self.folderAccess?.stopAccessingSecurityScopedResource(); self.folderAccess = url
          let refreshed = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
          self.reply(result, ["path": url.path, "bookmark": FlutterStandardTypedData(bytes: refreshed)])
        case "devices":
          self.devices = AVCaptureDevice.devices(for: .video)
          self.reply(result, self.devices.map { $0.localizedName })
        case "resolutions":
          let index = args["device"] as? Int ?? 0
          guard self.devices.indices.contains(index) else { throw NSError(domain: "设备不存在", code: 1) }
          var seen = Set<String>()
          let list = self.devices[index].formats.compactMap { format -> [String: Int]? in
            let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dim.width)x\(dim.height)"
            guard seen.insert(key).inserted else { return nil }
            return ["width": Int(dim.width), "height": Int(dim.height)]
          }.sorted { $0["width"]! > $1["width"]! }
          self.reply(result, list)
        case "open":
          let index = args["device"] as? Int ?? 0
          guard self.devices.indices.contains(index) else { throw NSError(domain: "设备不存在", code: 1) }
          if self.session.isRunning { self.session.stopRunning() }
          self.session.beginConfiguration()
          self.session.inputs.forEach { self.session.removeInput($0) }
          self.session.outputs.forEach { self.session.removeOutput($0) }
          let device = self.devices[index]
          do {
            let input = try AVCaptureDeviceInput(device: device)
            guard self.session.canAddInput(input) else { throw NSError(domain: "无法打开摄像头", code: 1) }
            self.session.addInput(input)
            self.session.sessionPreset = .inputPriority
            let wantedWidth = args["width"] as? Int ?? 1920, wantedHeight = args["height"] as? Int ?? 1080
            if let format = device.formats.first(where: {
              let dim = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
              return Int(dim.width) == wantedWidth && Int(dim.height) == wantedHeight
            }) { try device.lockForConfiguration(); device.activeFormat = format; device.unlockForConfiguration() }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            guard self.session.canAddOutput(output) else { throw NSError(domain: "无法开启视频输出", code: 1) }
            self.session.addOutput(output)
          } catch { self.session.commitConfiguration(); throw error }
          self.canvasW = args["canvasW"] as? Int ?? 640; self.canvasH = args["canvasH"] as? Int ?? 480
          self.latest = nil; self.session.commitConfiguration(); self.session.startRunning(); self.reply(result, nil)
        case "close":
          if self.session.isRunning { self.session.stopRunning() }; self.latest = nil; self.reply(result, nil)
        case "capture", "captureRaw":
          guard let image = self.latest else { throw NSError(domain: "请等待摄像头画面", code: 1) }
          let processed: CIImage
          if call.method == "captureRaw" {
            let rotated = image.oriented(forExifOrientation: [1, 6, 3, 8][self.rotation % 4])
            processed = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
          } else {
            processed = try self.process(image, capture: true)
          }
          guard let cg = self.context.createCGImage(processed, from: processed.extent),
                let bytes = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw NSError(domain: "图像编码失败", code: 1) }
          self.reply(result, FlutterStandardTypedData(bytes: bytes))
        case "ocr":
          guard let path = args["path"] as? String else { throw NSError(domain: "缺少图片路径", code: 1) }
          let language = args["language"] as? String ?? "zh-Hans"
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
          let supported = try VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: request.revision)
          guard supported.contains(language) else { throw NSError(domain: "当前 macOS 不支持所选识别语言，请更新系统或选择 English", code: 1) }
          request.recognitionLanguages = language == "zh-Hans" ? ["zh-Hans", "en-US"] : [language]
          try VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]).perform([request])
          let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
          self.reply(result, text)
        case "barcode":
          guard let image = self.latest, let cg = self.context.createCGImage(image, from: image.extent) else { throw NSError(domain: "没有摄像头画面", code: 1) }
          let request = VNDetectBarcodesRequest()
          if args["qr"] as? Bool == true { request.symbologies = [.qr] }
          try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
          let matches = (request.results ?? []).filter { args["qr"] as? Bool == true || $0.symbology != .qr }
          self.reply(result, matches.first?.payloadStringValue ?? "")
        case "setting":
          let key = args["key"] as? String ?? "", value = args["value"]
          switch key {
          case "rotation": self.rotation = value as? Int ?? 0
          case "rotateDelta": self.rotation = (self.rotation + (value as? Int ?? 0) + 4) % 4
          case "colorMode": self.colorMode = value as? Int ?? 0
          case "cutMode": self.cutMode = value as? Int ?? 0
          case "cutRect": if let rect = value as? [Int], rect.count == 4 { self.cutRect = CGRect(x: CGFloat(rect[0]), y: CGFloat(rect[1]), width: CGFloat(rect[2]), height: CGFloat(rect[3])) }
          case "zoom": self.zoom = CGFloat(value as? Double ?? 1); self.pan = .zero
          case "zoomDelta": self.zoom = min(5, max(1, self.zoom + CGFloat(value as? Double ?? 0)))
          case "trueSize": if let image = self.latest { self.zoom = max(1, image.extent.width / CGFloat(self.canvasW)) }
          case "pan": if let values = value as? [Int], values.count == 2 { self.pan.x += CGFloat(values[0]); self.pan.y -= CGFloat(values[1]) }
          case "removeBg": self.removeBg = value as? Bool ?? false
          case "smartEdge": self.smartEdge = value as? Bool ?? false
          case "focus": if let input = self.session.inputs.first as? AVCaptureDeviceInput, input.device.isFocusModeSupported(.autoFocus) { try input.device.lockForConfiguration(); input.device.focusMode = .autoFocus; input.device.unlockForConfiguration() }
          default: break
          }; self.reply(result, nil)
        default: self.reply(result, FlutterMethodNotImplemented)
        }
      } catch { self.failure(result, error.localizedDescription) }
    }
  }
  private func process(_ original: CIImage, capture: Bool) throws -> CIImage {
    var image = original.oriented(forExifOrientation: [1, 6, 3, 8][rotation % 4])
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    if capture && cutMode == 2, let rect = cutRect {
      let scale = min(CGFloat(canvasW) / image.extent.width, CGFloat(canvasH) / image.extent.height)
      let left = (CGFloat(canvasW) - image.extent.width * scale) / 2, top = (CGFloat(canvasH) - image.extent.height * scale) / 2
      let area = CGRect(x: (rect.minX - left) / scale, y: image.extent.height - (rect.maxY - top) / scale, width: rect.width / scale, height: rect.height / scale).intersection(image.extent)
      if !area.isEmpty { image = image.cropped(to: area) }
    } else if capture && (cutMode == 1 || smartEdge), let cg = context.createCGImage(image, from: image.extent) {
      let request = VNDetectRectanglesRequest(); request.maximumObservations = 1; request.minimumConfidence = 0.6
      try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
      if let rect = request.results?.first {
        func point(_ p: CGPoint) -> CIVector { CIVector(x: image.extent.minX + p.x * image.extent.width, y: image.extent.minY + p.y * image.extent.height) }
        image = image.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": point(rect.topLeft), "inputTopRight": point(rect.topRight), "inputBottomLeft": point(rect.bottomLeft), "inputBottomRight": point(rect.bottomRight)])
      }
    }
    if colorMode == 1 || colorMode == 2 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: colorMode == 2 ? 3 : 1]) }
    if colorMode >= 3 || removeBg { image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.25, kCIInputBrightnessKey: 0.08]) }
    return image
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    latest = CIImage(cvPixelBuffer: buffer)
    let now = CFAbsoluteTimeGetCurrent()
    guard now - lastFrameTime > 1.0 / 12.0, let raw = latest else { return }; lastFrameTime = now
    do {
      let image = try process(raw, capture: false)
      let scale = min(CGFloat(canvasW) / image.extent.width, CGFloat(canvasH) / image.extent.height) * zoom
      let transformed = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: (CGFloat(canvasW) - image.extent.width * scale) / 2 + pan.x, y: (CGFloat(canvasH) - image.extent.height * scale) / 2 + pan.y))
      let canvas = CGRect(x: 0, y: 0, width: CGFloat(canvasW), height: CGFloat(canvasH))
      let area = transformed.extent.integral.intersection(canvas)
      guard !area.isEmpty else { return }
      let fw = Int(area.width), fh = Int(area.height)
      var rgba = [UInt8](repeating: 0, count: fw * fh * 4)
      rgba.withUnsafeMutableBytes { ptr in context.render(transformed, toBitmap: ptr.baseAddress!, rowBytes: fw * 4, bounds: area, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
      var rgb = Data(count: fw * fh * 3)
      rgb.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
        for y in 0..<fh { for x in 0..<fw {
          let src = ((fh - 1 - y) * fw + x) * 4, dst = (y * fw + x) * 3
          ptr[dst] = rgba[src]; ptr[dst + 1] = rgba[src + 1]; ptr[dst + 2] = rgba[src + 2]
        } }
      }
      let event: [String: Any] = ["x": Int(area.minX), "y": canvasH-Int(area.maxY), "width": fw, "height": fh, "rgb": FlutterStandardTypedData(bytes: rgb)]
      DispatchQueue.main.async { self.sink?(event) }
    } catch { /* The next valid frame will replace this frame. */ }
  }
}
