import AVFoundation
import AVKit
import UIKit

/// AVKit consumes the SAME layer/frames as inline playback. No second mpv core,
/// hidden 2x2 view, polling renderer, URL reload or playback synchronization.
@available(iOS 15.0, *)
final class ExpoMpvPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  static let revision = "shared-frame-v1"
  private let displayLayer: AVSampleBufferDisplayLayer
  private var controller: AVPictureInPictureController?
  private var watchdog: Timer?
  private var deadline: Date?
  private var requested = false
  private var startCompletion: ((Bool, String?) -> Void)?
  private var playing = false
  private var duration: Double = 0
  private var hasFrame = false
  private var active = false
  private var disposed = false
  private let onPlaybackChange: (Bool) -> Void
  private let onSeek: (Double) -> Void
  private let onActiveChange: (Bool) -> Void
  private let onFailure: (String) -> Void

  init(displayLayer: AVSampleBufferDisplayLayer, onPlaybackChange: @escaping (Bool) -> Void,
       onSeek: @escaping (Double) -> Void, onActiveChange: @escaping (Bool) -> Void,
       onFailure: @escaping (String) -> Void) {
    self.displayLayer = displayLayer
    self.onPlaybackChange = onPlaybackChange
    self.onSeek = onSeek
    self.onActiveChange = onActiveChange
    self.onFailure = onFailure
    super.init()
  }

  var isActive: Bool { active || controller?.isPictureInPictureActive == true }
  var isStarting: Bool { startCompletion != nil }

  /// Prewarm AVKit once the primary renderer has supplied a real video frame.
  func didEnqueueFrame() {
    guard !disposed else { return }
    hasFrame = true
    if controller == nil && AVPictureInPictureController.isPictureInPictureSupported() {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      self.controller = controller
    }
    attemptStart()
  }

  func updatePlayback(playing: Bool, duration: Double) {
    let changed = self.playing != playing || self.duration != duration
    self.playing = playing
    self.duration = duration.isFinite ? max(0, duration) : 0
    if changed { controller?.invalidatePlaybackState() }
  }

  func start(hostView: UIView, completion: @escaping (Bool, String?) -> Void) {
    guard !disposed else { completion(false, "PiP player was disposed"); return }
    if isActive { completion(true, nil); return }
    guard startCompletion == nil else { completion(false, "PiP is already starting"); return }
    startCompletion = completion
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      fail("PiP is not supported"); return
    }
    guard hostView.window != nil else {
      fail("Player is not attached to a window"); return
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .moviePlayback)
      try audio.setActive(true)
    } catch {
      fail("Audio session: \(error)"); return
    }
    deadline = Date().addingTimeInterval(8)
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.attemptStart() }
    watchdog = timer
    RunLoop.main.add(timer, forMode: .common)
    attemptStart()
  }

  private func attemptStart() {
    guard startCompletion != nil else { return }
    if let controller, controller.isPictureInPictureActive {
      pictureInPictureControllerDidStartPictureInPicture(controller)
      return
    }
    if let deadline, Date() >= deadline {
      fail("Timed out; requested=\(requested), frame=\(hasFrame), possible=\(controller?.isPictureInPicturePossible == true), layer=\(displayLayer.status.rawValue), error=\(String(describing: displayLayer.error))")
      controller?.stopPictureInPicture()
      return
    }
    guard !requested, hasFrame, let controller, controller.isPictureInPicturePossible else { return }
    requested = true
    controller.invalidatePlaybackState()
    controller.startPictureInPicture()
  }

  private func finish(_ success: Bool, error: String? = nil) {
    watchdog?.invalidate(); watchdog = nil
    deadline = nil
    requested = false
    let completion = startCompletion
    startCompletion = nil
    completion?(success, error)
  }

  private func fail(_ message: String) {
    let detail = "[\(Self.revision)] \(message)"
    onFailure(detail)
    finish(false, error: detail)
  }

  func stop() {
    if isStarting { finish(false, error: "[\(Self.revision)] PiP start cancelled") }
    controller?.stopPictureInPicture()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    stop()
    controller?.delegate = nil
    controller = nil
    active = false
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard self.controller === controller else { return }
    active = true
    onActiveChange(true)
    finish(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    guard self.controller === controller else { return }
    active = false
    onActiveChange(false)
    if isStarting { finish(false, error: "[\(Self.revision)] PiP stopped before didStart") }
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    guard self.controller === controller else { return }
    active = false
    fail(String(describing: error as NSError))
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    self.playing = playing
    onPlaybackChange(playing)
    controller.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: duration > 0
      ? CMTime(seconds: duration, preferredTimescale: 600) : .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { !playing }

  func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime, completion: @escaping @Sendable () -> Void) {
    if interval.seconds.isFinite { onSeek(interval.seconds) }
    completion()
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
    completion(displayLayer.superlayer != nil)
  }
}
