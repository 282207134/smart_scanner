import AVFoundation
import Foundation

// Read-only capability query; does not open or reconfigure any camera.
for device in AVCaptureDevice.devices(for: .video) {
  var sizes = Set<String>()
  var photos = Set<String>()
  var formats: [String] = []
  for format in device.formats {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let size = "\(dimensions.width)x\(dimensions.height)"
    sizes.insert(size)
    let code = CMFormatDescriptionGetMediaSubType(format.formatDescription)
    let subtype = String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? "\(code)"
    let rates = format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)fps" }.joined(separator: ",")
    formats.append("  \(size) \(subtype) \(rates)")
    if #available(macOS 13.0, *) {
      for photo in format.supportedMaxPhotoDimensions {
        photos.insert("\(photo.width)x\(photo.height)")
      }
    }
  }
  print("\(device.localizedName) [\(device.uniqueID)]")
  print("video sizes: \(sizes.sorted().joined(separator: ", "))")
  print("photo sizes: \(photos.sorted().joined(separator: ", "))")
  print(formats.joined(separator: "\n"))
}
