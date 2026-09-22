import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit
import Libmpv

/// Small sample-buffer bridge used by system PiP. The normal view continues to
/// use mpv's Metal output; this second render context copies frames only while
/// PiP is active.
@available(iOS 15.0, *)
final class ExpoMpvPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
  private let handle: OpaquePointer
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var renderContext: OpaquePointer?
  private var controller: AVPictureInPictureController?
  private var timer: Timer?
  private var size = CGSize(width: 640, height: 360)
  private var playing = false
  private var active = false
  private let onPlaybackChange: (Bool) -> Void

  init(handle: OpaquePointer, onPlaybackChange: @escaping (Bool) -> Void) {
    self.handle = handle
    self.onPlaybackChange = onPlaybackChange
    super.init()
    displayLayer.videoGravity = .resizeAspect
  }

  deinit { stop() }

  var isActive: Bool { active }

  func start(playing: Bool, sourceRect: CGRect?, width: Int64, height: Int64) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    self.playing = playing
    if width > 0, height > 0 { size = CGSize(width: width, height: height) }
    guard makeRenderContext(), let context = controller else { return false }
    if let sourceRect { context.sourceRectHint = sourceRect }
    renderFrame()
    active = true
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.renderFrame()
    }
    context.startPictureInPicture()
    return true
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    controller?.stopPictureInPicture()
    active = false
    if let renderContext {
      mpv_render_context_free(renderContext)
      self.renderContext = nil
    }
  }

  func setPlaying(_ value: Bool) {
    playing = value
    onPlaybackChange(value)
    controller?.invalidatePlaybackState()
  }

  private func makeRenderContext() -> Bool {
    if renderContext != nil { return controller != nil }
    let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String)
    var params = [
      mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]
    guard mpv_render_context_create(&renderContext, handle, &params) >= 0 else { return false }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    controller = AVPictureInPictureController(contentSource: source)
    return controller != nil
  }

  private func renderFrame() {
    guard let renderContext, size.width > 0, size.height > 0 else { return }
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { return }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    var wh = [Int32(size.width), Int32(size.height)]
    let format = UnsafeMutablePointer(mutating: ("bgr0" as NSString).utf8String)
    var stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let rendered = wh.withUnsafeMutableBytes { whBytes in
      withUnsafeMutablePointer(to: &stride) { stridePtr in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: whBytes.baseAddress),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: format),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePtr),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        return mpv_render_context_render(renderContext, &params)
      }
    }
    guard rendered >= 0 else { return }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: nil, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
          let sample else { return }
    displayLayer.enqueue(sample)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    setPlaying(playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !playing }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) {
    // Seeking remains owned by mpv; the host can expose seek controls through JS.
  }
}
