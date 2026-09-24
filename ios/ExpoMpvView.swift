import ExpoModulesCore
import Libmpv
import CoreText
import AVKit
import AVFoundation
import CoreVideo

class ExpoMpvView: ExpoView {
  private static var sessions: [String: ExpoMpvView] = [:]
  private var sessionId: String?
  private var sessionOwner: ExpoMpvView?
  private weak var sessionDisplayView: ExpoMpvView?
  var playerView: ExpoMpvView { sessionOwner ?? self }
  private var eventView: ExpoMpvView { sessionDisplayView ?? self }
  private var currentSource: String?
  private var isDisposed = false
  private func displayRetainedLayer(_ owner: ExpoMpvView) {
    owner.sessionDisplayView = self
    if owner.sampleHostView.superview !== self {
      owner.sampleHostView.removeFromSuperview()
      addSubview(owner.sampleHostView)
    }
    layoutSampleView(owner.sampleHostView)
    setNeedsLayout()
    // The new React view can still have its pre-rotation bounds when the
    // session prop arrives. Layout again after the modal has been measured.
    DispatchQueue.main.async { [weak self] in
      self?.setNeedsLayout()
      self?.layoutIfNeeded()
    }
  }

  func attachSession(_ id: String) {
    // A delayed prop update on the previous inline view must not steal the
    // retained layer back from the fullscreen view.
    if sessionId == id { return }
    sessionId = id
    if let owner = Self.sessions[id] {
      destroy() // This view's temporary mpv is replaced by the retained session.
      sessionOwner = owner
      displayRetainedLayer(owner)
    } else {
      Self.sessions[id] = self
      sessionDisplayView = self
    }
  }

  static func releaseSession(_ id: String) {
    guard let owner = sessions.removeValue(forKey: id) else { return }
    owner.destroy()
  }
  // MARK: - Shared sample-buffer output

  private let sampleHostView = SampleBufferHostView()
  private var displayLayer: AVSampleBufferDisplayLayer { sampleHostView.displayLayer }
  private var renderer: ExpoMpvSampleBufferRenderer?
  private var framesPresented = 0

  // MARK: - MPV

  private var mpv: OpaquePointer?
  private lazy var queue = DispatchQueue(label: "com.expo.mpv.event", qos: .userInitiated)

  // MARK: - State

  private var isInitialized = false
  private var pendingSource: String?
  private var pendingHwdec: String = "videotoolbox"
  private var progressTimer: Timer?
  // Updated from copied property events on main; progress must never block
  // UIKit while the mpv core is seeking, decoding or waiting for network I/O.
  private var progressValues: [String: Double] = [:]
  @available(iOS 15.0, *) private var pictureInPicture: ExpoMpvPictureInPicture?

  /// Whether a source has been requested (loadfile issued and not stopped).
  /// Distinguishes "idle" (no media) from "loading" (media coming up).
  private var hasSource = false
  /// Last emitted high-level playback state, to avoid duplicate events.
  private var currentState = "idle"

  // MARK: - Event Dispatchers

  let onPlaybackStateChange = EventDispatcher()
  let onProgress = EventDispatcher()
  let onLoad = EventDispatcher()
  let onError = EventDispatcher()
  let onEnd = EventDispatcher()
  let onBuffer = EventDispatcher()
  let onSeek = EventDispatcher()
  let onVolumeChange = EventDispatcher()
  let onHdrStateChange = EventDispatcher()
  let onPictureInPictureChange = EventDispatcher()

  // MARK: - Init

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black
    setupSampleLayer()
    setupNotifications()
    // Expo applies view props after init. Waiting one main-queue turn lets a
    // replacement view adopt its existing session without creating and then
    // destroying a second libmpv instance during the fullscreen transition.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isDisposed, self.sessionOwner == nil else { return }
      self.setupMpv()
    }
  }

  deinit {
    stopProgressTimer()
    NotificationCenter.default.removeObserver(self)
    destroy()
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let owner = playerView
    // The original view stays alive as the session owner. Its queued layout
    // must not shrink the layer after a fullscreen view has adopted it.
    if let displayView = owner.sessionDisplayView, displayView !== self { return }
    layoutSampleView(owner.sampleHostView)
  }

  private func layoutSampleView(_ renderView: SampleBufferHostView) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    renderView.frame = bounds
    CATransaction.commit()
  }

  private func setupSampleLayer() {
    sampleHostView.isUserInteractionEnabled = false
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
    addSubview(sampleHostView)
  }

  private func present(_ sample: CMSampleBuffer) {
    guard !isDisposed, hasSource else { return }
    if displayLayer.status == .failed { displayLayer.flush() }
    guard displayLayer.isReadyForMoreMediaData else { return }
    displayLayer.enqueue(sample)
    framesPresented += 1
    if #available(iOS 15.0, *) { pictureInPicture?.didEnqueueFrame() }
  }

  // MARK: - MPV Setup

  private func setupMpv() {
    guard !isDisposed, mpv == nil else { return }
    log("Creating mpv instance...")

    mpv = mpv_create()
    guard let mpv = mpv else {
      let msg = "Failed to create mpv instance"
      log("ERROR: \(msg)")
      DispatchQueue.main.async { self.eventView.onError(["error": msg]) }
      return
    }

    checkError(mpv_request_log_messages(mpv, "warn"), label: "request_log_messages")
    setOptionString("vo", "libmpv")
    // The sample-buffer renderer accepts CPU-addressable frames. Decode with
    // VideoToolbox and copy back; never silently force a second software decoder.
    setOptionString("hwdec", pendingHwdec == "videotoolbox" ? "videotoolbox-copy" : pendingHwdec)
    setOptionString("keepaspect", "yes")

    // General options
    setOptionString("keep-open", "yes")
    setOptionString("idle", "yes")
    setOptionString("input-default-bindings", "no")
    setOptionString("input-vo-keyboard", "no")

    // Subtitle font configuration
    // iOS has no fontconfig, so libass can't discover system fonts.
    // We use CoreText to find a CJK font file and point libass to it.
    configureFonts(mpv)

    // Initialize mpv
    log("Initializing mpv...")
    let initResult = mpv_initialize(mpv)
    guard initResult == 0 else {
      let errStr = String(cString: mpv_error_string(initResult))
      let msg = "mpv_initialize failed: \(errStr) (\(initResult))"
      log("ERROR: \(msg)")
      DispatchQueue.main.async { self.eventView.onError(["error": msg]) }
      mpv_destroy(mpv)
      self.mpv = nil
      return
    }

    if #available(iOS 15.0, *) {
      pictureInPicture = ExpoMpvPictureInPicture(
        displayLayer: displayLayer,
        onPlaybackChange: { [weak self] playing in
          guard let self else { return }
          if playing { self.play() } else { self.pause() }
        },
        onSeek: { [weak self] seconds in self?.seekBy(seconds) },
        onActiveChange: { [weak self] active in
          guard let self else { return }
          self.eventView.onPictureInPictureChange(["active": active])
          if !active && UIApplication.shared.applicationState == .background {
            self.setPropertyString("vid", "no")
          }
        },
        onFailure: { [weak self] message in
          self?.eventView.onPictureInPictureChange(["active": false, "error": message])
        }
      )
    }
    log("mpv initialized successfully")

    // Observe properties
    mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 2, "time-pos", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 4, "eof-reached", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 5, "volume", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 6, "mute", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 7, "speed", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 8, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 11, "core-idle", MPV_FORMAT_FLAG)
    mpv_observe_property(mpv, 12, "video-params/sig-peak", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 14, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 15, "cache-speed", MPV_FORMAT_DOUBLE)
    mpv_observe_property(mpv, 16, "cache-buffering-state", MPV_FORMAT_DOUBLE)

    // Set wakeup callback for the event loop
    let rawSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    mpv_set_wakeup_callback(mpv, { ctx in
      guard let ctx = ctx else { return }
      let view = Unmanaged<ExpoMpvView>.fromOpaque(ctx).takeUnretainedValue()
      view.readEvents()
    }, rawSelf)

    let renderer = ExpoMpvSampleBufferRenderer(
      onFrame: { [weak self] sample in self?.present(sample) },
      onError: { [weak self] message in
        self?.eventView.onError(["error": "[shared-frame-v1] \(message)"])
      })
    self.renderer = renderer
    renderer.start(handle: mpv) { [weak self] error in
      guard let self, !self.isDisposed else { return }
      if let error {
        self.eventView.onError(["error": "[shared-frame-v1] Renderer init: \(error)"])
        return
      }
      self.isInitialized = true
      if let source = self.pendingSource {
        self.pendingSource = nil
        self.loadFile(source)
      }
    }
  }

  // MARK: - App Lifecycle

  private func setupNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  @objc private func appDidEnterBackground() {
    guard mpv != nil else { return }
    if #available(iOS 15.0, *), pictureInPicture?.isActive == true || pictureInPicture?.isStarting == true { return }
    setPropertyString("vid", "no")
  }

  @objc private func appWillEnterForeground() {
    guard mpv != nil else { return }
    if #available(iOS 15.0, *), pictureInPicture?.isActive == true { return }
    setPropertyString("vid", "auto")
  }

  // MARK: - Progress Timer

  /// Start the progress timer if it isn't already running. Idempotent so it can
  /// be driven repeatedly from the state machine without tearing down/recreating.
  private func startProgressTimer() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.progressTimer == nil else { return }
      self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        self?.emitProgressEvent()
      }
    }
  }

  private func stopProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = nil
  }

  private func emitProgressEvent() {
    guard mpv != nil else { return }
    let position = progressValues["time-pos"] ?? 0
    let duration = progressValues["duration"] ?? 0
    let cachedDuration = progressValues["demuxer-cache-duration"] ?? 0
    let cacheTime = progressValues["demuxer-cache-time"] ?? 0
    let bufferRate = progressValues["cache-speed"] ?? 0
    let bufferingPercent = progressValues["paused-for-cache"] == 1
      ? (progressValues["cache-buffering-state"] ?? 0) : 100

    guard position.isFinite && duration.isFinite else { return }

    eventView.onProgress([
      "position": position,
      "duration": duration,
      "bufferedDuration": cachedDuration.isFinite ? cachedDuration : 0,
      "bufferedPosition": cacheTime.isFinite ? cacheTime : 0,
      "bufferRate": bufferRate,
      "bufferingPercent": bufferingPercent.isFinite ? bufferingPercent : 0,
    ])
  }

  // MARK: - Playback State Machine

  /// Derive the high-level playback state from mpv's orthogonal status flags.
  /// Order matters: cache stalls and EOF take precedence over the pause flag.
  private func computeState() -> String {
    guard mpv != nil, hasSource else { return "idle" }
    if progressValues["eof-reached"] == 1 { return "ended" }
    if progressValues["paused-for-cache"] == 1 { return "buffering" }
    if progressValues["pause"] == 1 { return "paused" }
    // Not paused and not stalled, but the core isn't rendering yet -> still
    // loading the first frame (or re-buffering after a seek).
    if progressValues["core-idle"] == 1 { return "loading" }
    return "playing"
  }

  /// Recompute state, drive the progress timer accordingly, and emit an event
  /// only when the state actually changes. Must run on the main thread.
  private func emitStateChange() {
    let state = computeState()

    switch state {
    case "playing", "loading", "buffering":
      startProgressTimer()
    default:
      stopProgressTimer()
    }

    guard state != currentState else { return }
    currentState = state
    eventView.onPlaybackStateChange([
      "state": state,
      "isPlaying": progressValues["pause"] != 1,
    ])
  }

  // MARK: - Event Loop

  private func readEvents() {
    queue.async { [weak self] in
      guard let self = self, self.mpv != nil else { return }

      while true {
        let event = mpv_wait_event(self.mpv, 0)
        guard let event = event else { break }

        if event.pointee.event_id == MPV_EVENT_NONE {
          break
        }

        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
          self.handlePropertyChange(event)

        case MPV_EVENT_SET_PROPERTY_REPLY:
          if event.pointee.error < 0 {
            let message = String(cString: mpv_error_string(event.pointee.error))
            DispatchQueue.main.async { self.eventView.onError(["error": "mpv property: \(message)"]) }
          }

        case MPV_EVENT_LOG_MESSAGE:
          if let data = event.pointee.data {
            let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if let text = msg.text {
              let logText = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
              let prefix = msg.prefix.map { String(cString: $0) } ?? "?"
              let level = msg.level.map { String(cString: $0) } ?? "?"
              self.log("[\(prefix)] [\(level)] \(logText)")
            }
          }

        case MPV_EVENT_VIDEO_RECONFIG:
          // Read the pair together on the client event queue, never on the
          // renderer or main thread and never half old/half new dimensions.
          let width = Int(self.getInt("video-out-params/dw"))
          let height = Int(self.getInt("video-out-params/dh"))
          DispatchQueue.main.async {
            self.renderer?.setVideoSize(width: width, height: height)
          }

        case MPV_EVENT_FILE_LOADED:
          self.log("EVENT: file-loaded")
          DispatchQueue.main.async {
            let duration = self.getDouble("duration")
            let width = self.getInt("video-params/w")
            let height = self.getInt("video-params/h")
            self.log("Media loaded: duration=\(duration) size=\(width)x\(height)")
            self.eventView.onLoad([
              "duration": duration.isFinite ? duration : 0,
              "width": width,
              "height": height,
            ])
            // File is demuxed and tracks are known, but the first frame may not
            // be rendered yet — let the state machine decide loading vs playing.
            self.emitStateChange()
          }

        case MPV_EVENT_START_FILE:
          self.log("EVENT: start-file")

        case MPV_EVENT_END_FILE:
          if let data = event.pointee.data {
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            self.log("EVENT: end-file reason=\(endFile.reason) error=\(endFile.error)")
            DispatchQueue.main.async {
              // NOTE: do NOT clear hasSource here. END_FILE also fires for the
              // previous file when switching via `loadfile replace` (reason=stop),
              // which would otherwise flip the state to "idle" right after the new
              // load. Only the explicit stop() method clears hasSource.
              let reason: String
              switch endFile.reason {
              case MPV_END_FILE_REASON_EOF:
                reason = "ended"
              case MPV_END_FILE_REASON_ERROR:
                reason = "error"
                let errStr = String(cString: mpv_error_string(endFile.error))
                let msg = "Playback error: \(errStr) (code \(endFile.error))"
                self.log("ERROR: \(msg)")
                self.eventView.onError(["error": msg])
              case MPV_END_FILE_REASON_STOP:
                reason = "stopped"
              default:
                reason = "unknown"
              }
              self.eventView.onEnd(["reason": reason])
              if reason == "ended" {
                // EOF with keep-open=yes: emit "ended" directly to avoid relying
                // on eof-reached property timing.
                self.currentState = "ended"
                self.eventView.onPlaybackStateChange(["state": "ended", "isPlaying": false])
                self.stopProgressTimer()
              } else {
                self.emitStateChange()
              }
            }
          }

        case MPV_EVENT_SHUTDOWN:
          self.log("EVENT: shutdown")
          self.mpv = nil
          return

        case MPV_EVENT_SEEK:
          DispatchQueue.main.async {
            self.eventView.onSeek([:])
          }

        default:
          let eventName = mpv_event_name(event.pointee.event_id)
          if let eventName = eventName {
            self.log("EVENT: \(String(cString: eventName))")
          }
        }
      }
    }
  }

  private func handlePropertyChange(_ event: UnsafePointer<mpv_event>) {
    guard let data = event.pointee.data else { return }
    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee

    guard let cName = prop.name else { return }
    let name = String(cString: cName)

    let progressKeys: Set<String> = ["time-pos", "duration", "demuxer-cache-duration",
      "demuxer-cache-time", "cache-speed", "cache-buffering-state", "paused-for-cache", "pause", "eof-reached", "core-idle", "volume", "mute", "speed"]
    if progressKeys.contains(name) {
      var value: Double = 0
      if let data = prop.data {
        if prop.format == MPV_FORMAT_DOUBLE { value = data.assumingMemoryBound(to: Double.self).pointee }
        else if prop.format == MPV_FORMAT_FLAG { value = Double(data.assumingMemoryBound(to: Int32.self).pointee) }
      }
      let snapshot = value.isFinite ? value : 0
      DispatchQueue.main.async {
        self.progressValues[name] = snapshot
        self.updatePictureInPicturePlayback()
      }
    }

    switch name {
    // These flags all feed the unified state machine; let computeState() decide.
    case "pause", "core-idle", "eof-reached":
      DispatchQueue.main.async {
        self.emitStateChange()
      }

    case "paused-for-cache":
      let buffering: Bool = {
        guard prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data else { return false }
        return flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
      }()
      DispatchQueue.main.async {
        // Keep the dedicated buffering event for backwards compatibility, and
        // recompute the high-level state (buffering vs playing).
        self.eventView.onBuffer(["isBuffering": buffering])
        self.emitStateChange()
      }

    case "volume":
      if prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data {
        let volume = dataPtr.assumingMemoryBound(to: Double.self).pointee
        DispatchQueue.main.async {
          self.eventView.onVolumeChange(["volume": volume, "muted": self.progressValues["mute"] == 1])
        }
      }

    case "mute":
      if prop.format == MPV_FORMAT_FLAG, let flagPtr = prop.data {
        let muted = flagPtr.assumingMemoryBound(to: Int32.self).pointee != 0
        DispatchQueue.main.async {
          self.eventView.onVolumeChange(["volume": self.progressValues["volume"] ?? 100, "muted": muted])
        }
      }

    case "video-params/sig-peak":
      let sigPeak: Double = {
        guard prop.format == MPV_FORMAT_DOUBLE, let dataPtr = prop.data else { return 0 }
        return dataPtr.assumingMemoryBound(to: Double.self).pointee
      }()
      DispatchQueue.main.async {
        self.emitHdrStateChange(sigPeak: sigPeak)
      }

    default:
      break
    }
  }

  /// Report HDR state to JS. `sigPeak` > 1 means the media is HDR; combined with
  /// the screen's EDR headroom it tells whether HDR is actually being displayed.
  /// Must run on the main thread (reads UIScreen).
  private func emitHdrStateChange(sigPeak: Double) {
    let peak = sigPeak.isFinite ? sigPeak : 0
    let isHdr = peak > 1.0
    let hdrActive = false // The shared BGRA output does not carry EDR metadata.
    let gamma = getString("video-params/gamma") ?? ""
    eventView.onHdrStateChange([
      "isHdr": isHdr,
      "hdrActive": hdrActive,
      "sigPeak": peak,
      "hdrFormat": isHdr ? gamma : "",
    ])
  }

  // MARK: - Public API

  func loadFile(_ url: String) {
    if currentSource == url && hasSource { return }
    currentSource = url
    guard isInitialized, mpv != nil else {
      log("loadFile deferred (not initialized yet): \(url)")
      pendingSource = url
      return
    }
    log("loadFile: \(url)")
    hasSource = true
    commandAsync("loadfile", args: [url, "replace"])
    // Enter "loading" immediately. We force it here (rather than via
    // computeState) because right after loadfile mpv may still report the
    // previous file's flags (e.g. eof-reached), which would misfire "ended".
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.currentState = "loading"
      self.eventView.onPlaybackStateChange(["state": "loading", "isPlaying": self.progressValues["pause"] != 1])
      self.startProgressTimer()
    }
  }

  func play() {
    setFlag("pause", false)
  }

  func pause() {
    setFlag("pause", true)
  }

  func togglePlay() {
    let isPaused = getFlag("pause")
    setFlag("pause", !isPaused)
  }

  func stop() {
    stopPictureInPicture()
    displayLayer.flushAndRemoveImage()
    pendingSource = nil
    commandAsync("stop")
    hasSource = false
    currentSource = nil
    DispatchQueue.main.async { [weak self] in
      self?.emitStateChange() // -> idle
    }
  }

  func seekTo(_ position: Double) {
    commandAsync("seek", args: [String(position), "absolute"])
  }

  func seekBy(_ offset: Double) {
    commandAsync("seek", args: [String(offset), "relative"])
  }

  func setSpeed(_ speed: Double) {
    setDouble("speed", speed)
  }

  func setVolume(_ volume: Double) {
    setDouble("volume", volume)
  }

  func setMuted(_ muted: Bool) {
    setFlag("mute", muted)
  }

  func isPictureInPictureSupported() -> Bool {
    if #available(iOS 15.0, *) { return AVPictureInPictureController.isPictureInPictureSupported() }
    return false
  }

  func isPictureInPictureActive() -> Bool {
    if #available(iOS 15.0, *) { return pictureInPicture?.isActive == true }
    return false
  }

  func startPictureInPicture(sourceRect: [String: Double]?,
                             completion: @escaping (Bool, String?) -> Void) {
    guard #available(iOS 15.0, *) else {
      eventView.onPictureInPictureChange(["active": false, "error": "PiP requires iOS 15 or newer"])
      completion(false, "PiP requires iOS 15 or newer")
      return
    }
    guard mpv != nil, currentSource != nil, let pictureInPicture else {
      completion(false, "[shared-frame-v1] PiP requires a loaded video")
      return
    }
    updatePictureInPicturePlayback()
    pictureInPicture.start(hostView: sampleHostView, completion: completion)
  }

  private func updatePictureInPicturePlayback() {
    if #available(iOS 15.0, *) {
      pictureInPicture?.updatePlayback(playing: progressValues["pause"] != 1,
                                      duration: progressValues["duration"] ?? 0)
    }
  }

  func stopPictureInPicture() {
    guard #available(iOS 15.0, *) else { return }
    pictureInPicture?.stop()
  }

  func setLooping(_ loop: Bool) {
    guard mpv != nil else { return }
    setPropertyString("loop-file", loop ? "inf" : "no")
  }

  func setHwdec(_ mode: String) {
    pendingHwdec = mode
    if isInitialized, mpv != nil {
      setPropertyString("hwdec", mode == "videotoolbox" ? "videotoolbox-copy" : mode)
    }
  }

  func setSubtitleTrack(_ trackId: Int) {
    setInt("sid", Int64(trackId))
  }

  func setAudioTrack(_ trackId: Int) {
    setInt("aid", Int64(trackId))
  }

  /// Build args for sub-add / audio-add: <url> [<flags> [<title> [<lang>]]].
  private func trackAddArgs(_ path: String, flag: String, title: String?, lang: String?) -> [String] {
    var args = [path, flag]
    if let title = title { args.append(title) }
    if let lang = lang {
      if args.count == 2 { args.append("") } // placeholder for title
      args.append(lang)
    }
    return args
  }

  /// Load an external subtitle file (local path or URL).
  /// `flag` defaults to "select" (mpv's own default) so the subtitle is shown
  /// immediately. Pass "auto" to add without selecting (then use setSubtitleTrack).
  func addSubtitle(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil) {
    guard mpv != nil else { return }
    log("addSubtitle: \(path) flags=\(flag)")
    commandAsync("sub-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang))
  }

  /// Remove a subtitle track by id.
  func removeSubtitle(_ trackId: Int) {
    commandAsync("sub-remove", args: [String(trackId)])
  }

  /// Reload current subtitles (useful after font changes).
  func reloadSubtitles() {
    commandAsync("sub-reload")
  }

  /// Load an external audio file (local path or URL). `flag` defaults to
  /// "select" so it becomes the active audio track. Pass "auto" to add without
  /// selecting (then use setAudioTrack).
  func addAudio(_ path: String, flag: String = "select", title: String? = nil, lang: String? = nil) {
    guard mpv != nil else { return }
    log("addAudio: \(path) flags=\(flag)")
    commandAsync("audio-add", args: trackAddArgs(path, flag: flag, title: title, lang: lang))
  }

  /// Remove an audio track by id.
  func removeAudio(_ trackId: Int) {
    commandAsync("audio-remove", args: [String(trackId)])
  }

  func setSubtitleDelay(_ seconds: Double) {
    setDouble("sub-delay", seconds)
  }

  func setPropertyString(_ name: String, _ value: String) {
    guard mpv != nil else { return }
    let result = value.withCString { text in
      var pointer = text
      return mpv_set_property_async(mpv, 0, name, MPV_FORMAT_STRING, &pointer)
    }
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property string '\(name)'='\(value)' failed: \(errStr)")
    }
  }

  func getPlaybackInfo() -> [String: Any] {
    let position = progressValues["time-pos"] ?? 0
    let duration = progressValues["duration"] ?? 0
    let isPaused = progressValues["pause"] == 1
    let speed = progressValues["speed"] ?? 1
    let volume = progressValues["volume"] ?? 100
    let muted = progressValues["mute"] == 1

    return [
      "rendererRevision": "shared-frame-v1",
      "framesPresented": framesPresented,
      "position": position.isFinite ? position : 0,
      "duration": duration.isFinite ? duration : 0,
      "isPlaying": !isPaused,
      "speed": speed,
      "volume": volume,
      "muted": muted,
    ]
  }

  func getTrackList() -> [[String: Any]] {
    guard mpv != nil else { return [] }

    let count = getInt("track-list/count")
    var tracks: [[String: Any]] = []

    for i in 0..<count {
      let prefix = "track-list/\(i)"
      var track: [String: Any] = [:]

      track["id"] = Int(getInt("\(prefix)/id"))
      track["type"] = getString("\(prefix)/type") ?? "unknown"
      track["title"] = getString("\(prefix)/title") ?? ""
      track["lang"] = getString("\(prefix)/lang") ?? ""
      track["codec"] = getString("\(prefix)/codec") ?? ""
      track["selected"] = getFlag("\(prefix)/selected")
      track["isDefault"] = getFlag("\(prefix)/default")
      track["isExternal"] = getFlag("\(prefix)/external")

      // Extra info based on track type
      let trackType = track["type"] as? String ?? ""
      if trackType == "audio" {
        track["channelCount"] = Int(getInt("\(prefix)/demux-channel-count"))
        track["sampleRate"] = Int(getInt("\(prefix)/demux-samplerate"))
      } else if trackType == "video" {
        track["width"] = Int(getInt("\(prefix)/demux-w"))
        track["height"] = Int(getInt("\(prefix)/demux-h"))
        track["fps"] = getDouble("\(prefix)/demux-fps")
      }

      tracks.append(track)
    }

    log("getTrackList: \(tracks.count) tracks found")
    return tracks
  }

  func getCurrentTrackIds() -> [String: Int] {
    guard mpv != nil else { return [:] }
    return [
      "vid": Int(getInt("vid")),
      "aid": Int(getInt("aid")),
      "sid": Int(getInt("sid")),
    ]
  }

  func getMediaInfo() -> [String: Any] {
    guard mpv != nil else { return [:] }

    let hwdec = getString("hwdec") ?? ""
    let hwdecCurrent = getString("hwdec-current") ?? ""
    let videoCodec = getString("video-codec") ?? ""
    let audioCodec = getString("audio-codec-name") ?? ""
    let width = getInt("video-params/w")
    let height = getInt("video-params/h")
    let fps = getDouble("container-fps")
    let videoBitrate = getDouble("video-bitrate")
    let audioBitrate = getDouble("audio-bitrate")
    let pixelFormat = getString("video-params/pixelformat") ?? ""
    let colorspace = getString("video-params/colormatrix") ?? ""
    // Transfer function: "pq" = HDR10/Dolby Vision, "hlg" = HLG, else SDR.
    let gamma = getString("video-params/gamma") ?? ""
    let isHdr = gamma == "pq" || gamma == "hlg" || getDouble("video-params/sig-peak") > 1.0

    return [
      "hwdec": hwdec,
      "hwdecCurrent": hwdecCurrent,
      "videoCodec": videoCodec,
      "audioCodec": audioCodec,
      "width": Int(width),
      "height": Int(height),
      "fps": fps.isFinite ? fps : 0,
      "videoBitrate": videoBitrate.isFinite ? videoBitrate : 0,
      "audioBitrate": audioBitrate.isFinite ? audioBitrate : 0,
      "pixelFormat": pixelFormat,
      "colorspace": colorspace,
      "isHdr": isHdr,
      "hdrFormat": gamma,
    ]
  }

  func destroy() {
    guard !isDisposed else { return }
    isDisposed = true
    isInitialized = false
    stopProgressTimer()
    if #available(iOS 15.0, *) { pictureInPicture?.dispose(); pictureInPicture = nil }
    displayLayer.flushAndRemoveImage()
    guard let handle = mpv else { return }
    mpv_set_wakeup_callback(handle, nil, nil)
    queue.sync { self.mpv = nil }
    let renderer = self.renderer
    self.renderer = nil
    // Disable/finish rendering before freeing its core. Teardown does not
    // block UIKit, and both the old handle and renderer remain owned here.
    if let renderer {
      renderer.dispose { mpv_terminate_destroy(handle) }
    } else {
      DispatchQueue.global(qos: .utility).async { mpv_terminate_destroy(handle) }
    }
  }

  // MARK: - Font Configuration

  /// Configure fonts for subtitle rendering.
  ///
  /// iOS 18+ changed system fonts (PingFang etc.) to Apple's HVGL variable font format,
  /// which FreeType (used by libass) cannot parse. This means system CJK fonts are
  /// unusable by libass even if CoreText can find them.
  ///
  /// Solution: bundle a standard OTF/TTF CJK font (Noto Sans CJK SC) that FreeType
  /// can read, and point libass to it via sub-fonts-dir.
  /// See: https://github.com/libass/libass/issues/912
  ///      https://github.com/mpv-player/mpv/issues/14878
  private func configureFonts(_ mpv: OpaquePointer) {
    // Locate the bundled Noto Sans CJK SC font in the module's bundle
    let fontFileName = "NotoSansCJKsc-Regular"
    let fontFileExt = "otf"

    // Search in all bundles (the font is in the ExpoMpv pod bundle)
    var fontPath: String?
    for bundle in Bundle.allBundles {
      if let path = bundle.path(forResource: fontFileName, ofType: fontFileExt) {
        fontPath = path
        break
      }
    }

    // Also check the main bundle's Frameworks
    if fontPath == nil {
      let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
      if let contents = try? FileManager.default.contentsOfDirectory(atPath: frameworksPath) {
        for item in contents where item.hasSuffix(".framework") {
          let bundlePath = frameworksPath + "/" + item
          if let bundle = Bundle(path: bundlePath),
             let path = bundle.path(forResource: fontFileName, ofType: fontFileExt) {
            fontPath = path
            break
          }
        }
      }
    }

    guard let resolvedFontPath = fontPath else {
      log("WARNING: Bundled font \(fontFileName).\(fontFileExt) not found in any bundle")
      // Fallback: try auto font provider without bundled font
      setOptionString("sub-font-provider", "auto")
      setOptionString("sub-font", "sans-serif")
      return
    }

    let fontsDir = (resolvedFontPath as NSString).deletingLastPathComponent
    log("Font: \(resolvedFontPath)")

    // Point libass to the directory containing our bundled font
    setOptionString("sub-fonts-dir", fontsDir)

    // auto = CoreText on Apple platforms (handles font name matching + fallback)
    setOptionString("sub-font-provider", "auto")

    // Default font for SRT / plain text subtitles
    setOptionString("sub-font", "Noto Sans CJK SC")
    setOptionString("sub-font-size", "40")
    setOptionString("sub-codepage", "auto")

    // ASS subtitles: don't force-override styles.
    // When ASS references fonts like "Microsoft YaHei" that don't exist on iOS,
    // CoreText + our bundled font provide fallback.
    setOptionString("sub-ass-override", "no")
    setOptionString("sub-ass-shaper", "simple")

    // Auto-load external subtitles from same directory as video
    setOptionString("sub-auto", "fuzzy")
  }

  // MARK: - MPV Helpers

  private func commandAsync(_ command: String, args: [String] = []) {
    guard mpv != nil else {
      log("commandAsync ignored (mpv is nil): \(command)")
      return
    }

    // Build null-terminated args string for mpv_command_string is simplest,
    // but mpv_command_string doesn't exist. Use mpv_command with proper memory management.
    let allArgs = [command] + args
    // Create C strings that live long enough
    var cStrings = allArgs.map { strdup($0) }
    cStrings.append(nil) // null-terminate

    // Create array of const pointers
    let result = cStrings.withUnsafeMutableBufferPointer { buffer -> Int32 in
      // Build an array of UnsafePointer<CChar>? from UnsafeMutablePointer<CChar>?
      var constPtrs = buffer.map { UnsafePointer($0) }
      return constPtrs.withUnsafeMutableBufferPointer { constBuffer in
        mpv_command(mpv, constBuffer.baseAddress)
      }
    }

    // Free strdup'd strings
    for ptr in cStrings {
      if let ptr = ptr { free(ptr) }
    }

    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: command '\(command) \(args.joined(separator: " "))' failed: \(errStr) (\(result))")
      DispatchQueue.main.async {
        self.eventView.onError(["error": "Command '\(command)' failed: \(errStr)"])
      }
    } else {
      log("Command OK: \(command) \(args.joined(separator: " "))")
    }
  }

  private func setOptionString(_ name: String, _ value: String) {
    guard let mpv = mpv else { return }
    let result = mpv_set_option_string(mpv, name, value)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set option '\(name)'='\(value)' failed: \(errStr)")
    } else {
      log("Option: \(name) = \(value)")
    }
  }

  private func getDouble(_ name: String) -> Double {
    guard mpv != nil else { return 0 }
    var data: Double = 0
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    return data
  }

  private func getString(_ name: String) -> String? {
    guard mpv != nil else { return nil }
    let cstr = mpv_get_property_string(mpv, name)
    defer { mpv_free(cstr) }
    guard let cstr = cstr else { return nil }
    return String(cString: cstr)
  }

  private func getInt(_ name: String) -> Int64 {
    guard mpv != nil else { return 0 }
    var data: Int64 = 0
    mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
    return data
  }

  private func getFlag(_ name: String) -> Bool {
    guard mpv != nil else { return false }
    var data: Int32 = 0
    mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
    return data != 0
  }

  /// mpv exposes this value directly; avoid decoding the entire cache-state
  /// node on the UI thread for every progress event.
  private func getCacheRawInputRate() -> Double {
    return Double(getInt("cache-speed"))
  }

  private func setDouble(_ name: String, _ value: Double) {
    guard mpv != nil else { return }
    var data = value
    let result = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property '\(name)'=\(value) failed: \(errStr)")
    }
  }

  private func setInt(_ name: String, _ value: Int64) {
    guard mpv != nil else { return }
    var data = value
    let result = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set property '\(name)'=\(value) failed: \(errStr)")
    }
  }

  private func setFlag(_ name: String, _ flag: Bool) {
    guard mpv != nil else { return }
    var data: Int32 = flag ? 1 : 0
    let result = mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &data)
    if result < 0 {
      let errStr = String(cString: mpv_error_string(result))
      log("ERROR: set flag '\(name)'=\(flag) failed: \(errStr)")
    }
  }

  @discardableResult
  private func checkError(_ status: Int32, label: String = "") -> Bool {
    if status < 0 {
      let errStr = String(cString: mpv_error_string(status))
      log("ERROR [\(label)]: \(errStr) (\(status))")
      return false
    }
    return true
  }

  private func log(_ message: String) {
    NSLog("[ExpoMpv] %@", message)
  }
}

// A real UIKit-owned layer, retained with the playback session across views.
private final class SampleBufferHostView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

// MARK: - Sample-buffer renderer

/// One render context on the playback core, shared by the inline view and PiP.
/// VideoToolbox decodes; mpv converts the decoded frame into a pooled BGRA
/// buffer on this queue. No second loadfile/decoder and no GPU calls in background.
private final class ExpoMpvSampleBufferRenderer {
  private let queue = DispatchQueue(label: "com.expo.mpv.frames", qos: .userInitiated)
  private let lock = NSLock()
  private var acceptingUpdates = true
  private var updateScheduled = false
  private var deliveryScheduled = false
  private var latestSample: CMSampleBuffer?
  // The following fields belong exclusively to queue.
  private var context: OpaquePointer?
  private var pool: CVPixelBufferPool?
  private var size = CGSize.zero
  private var disposed = false
  private var reportedError = false
  private let onFrame: (CMSampleBuffer) -> Void
  private let onError: (String) -> Void

  init(onFrame: @escaping (CMSampleBuffer) -> Void, onError: @escaping (String) -> Void) {
    self.onFrame = onFrame
    self.onError = onError
  }

  func start(handle: OpaquePointer, completion: @escaping (String?) -> Void) {
    queue.async { [self] in
      guard !disposed else { return }
      let status = MPV_RENDER_API_TYPE_SW.withCString { api in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        return mpv_render_context_create(&context, handle, &params)
      }
      if status >= 0, let context {
        mpv_render_context_set_update_callback(context, { raw in
          guard let raw else { return }
          Unmanaged<ExpoMpvSampleBufferRenderer>.fromOpaque(raw)
            .takeUnretainedValue().scheduleUpdate()
        }, Unmanaged.passUnretained(self).toOpaque())
      }
      let error = status < 0 ? String(cString: mpv_error_string(status)) : nil
      DispatchQueue.main.async { completion(error) }
    }
  }

  /// Media dimensions, never the widget dimensions. AVSampleBufferDisplayLayer
  /// handles aspect-fit/rotation layouts without reconfiguring the mpv core.
  func setVideoSize(width: Int, height: Int) {
    guard width > 0, height > 0 else { return }
    queue.async { [self] in
      guard !disposed else { return }
      let next = CGSize(width: width, height: height)
      guard next != size else { return }
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferBytesPerRowAlignmentKey: 64,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      var nextPool: CVPixelBufferPool?
      let result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
        attributes as CFDictionary, &nextPool)
      guard result == kCVReturnSuccess else {
        reportError("CVPixelBufferPoolCreate: \(result)")
        return
      }
      size = next
      pool = nextPool
      render(force: true)
    }
  }

  private func scheduleUpdate() {
    lock.lock()
    guard acceptingUpdates, !updateScheduled else { lock.unlock(); return }
    updateScheduled = true
    lock.unlock()
    queue.async { [self] in
      lock.lock()
      updateScheduled = false
      lock.unlock()
      render(force: false)
    }
  }

  private func render(force: Bool) {
    guard !disposed, let context else { return }
    let flags = mpv_render_context_update(context)
    guard force || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
    guard let pool else { skipFrame(context); return }
    var buffer: CVPixelBuffer?
    // Buffers held by AVKit are never overwritten. Bound memory if delivery
    // stalls; a new render callback will provide the next frame.
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
      pool, [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer)
    guard status != kCVReturnWouldExceedAllocationThreshold else {
      skipFrame(context)
      return
    }
    guard status == kCVReturnSuccess, let buffer else {
      reportError("CVPixelBuffer allocation: \(status)"); return
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
    var locked = true
    defer { if locked { CVPixelBufferUnlockBaseAddress(buffer, []) } }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    var dimensions = [Int32(size.width), Int32(size.height)]
    var stride = CVPixelBufferGetBytesPerRow(buffer)
    // BGRA is supported by the bundled libmpv software backend. Unlike bgr0,
    // it supplies valid alpha without an extra per-pixel Swift loop.
    let result = "bgra".withCString { format in
      dimensions.withUnsafeMutableBytes { dimensions in
        withUnsafeMutablePointer(to: &stride) { stride in
          var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: dimensions.baseAddress),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stride),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
          ]
          // Waiting for frame presentation time is safe on this dedicated
          // queue; it never calls synchronous player/property commands.
          return mpv_render_context_render(context, &params)
        }
      }
    }
    guard result >= 0 else {
      reportError("mpv render: \(String(cString: mpv_error_string(result)))"); return
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    locked = false
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescriptionOut: &description) == noErr,
      let description else { return }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescription: description, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
      attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    deliver(sample)
  }

  private func skipFrame(_ context: OpaquePointer) {
    // Acknowledge a frame even when AVKit still owns every pool buffer;
    // otherwise mpv can wait for rendering and stall playback.
    var skip: Int32 = 1
    withUnsafeMutablePointer(to: &skip) { pointer in
      var params = [
        mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: pointer),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      _ = mpv_render_context_render(context, &params)
    }
  }

  private func deliver(_ sample: CMSampleBuffer) {
    lock.lock()
    guard acceptingUpdates else { lock.unlock(); return }
    latestSample = sample
    guard !deliveryScheduled else { lock.unlock(); return }
    deliveryScheduled = true
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let sample = self.acceptingUpdates ? self.latestSample : nil
      self.latestSample = nil
      self.deliveryScheduled = false
      self.lock.unlock()
      if let sample { self.onFrame(sample) }
    }
  }

  private func reportError(_ message: String) {
    guard !reportedError else { return }
    reportedError = true
    DispatchQueue.main.async { [onError] in onError(message) }
  }

  /// The owner must keep the mpv core alive until completion. No queue.sync:
  /// main, the event queue and the renderer never wait on each other.
  func dispose(completion: @escaping () -> Void) {
    lock.lock()
    acceptingUpdates = false
    latestSample = nil
    lock.unlock()
    queue.async { [self] in
      if !disposed {
        disposed = true
        if let context {
          mpv_render_context_set_update_callback(context, nil, nil)
          mpv_render_context_free(context)
          self.context = nil
        }
        pool = nil
      }
      completion()
    }
  }
}
