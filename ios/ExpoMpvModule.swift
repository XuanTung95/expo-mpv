import ExpoModulesCore

public class ExpoMpvModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoMpv")

    AsyncFunction("releaseSession") { (sessionId: String) in
      ExpoMpvView.releaseSession(sessionId)
    }.runOnQueue(.main)

    // MARK: - View

    View(ExpoMpvView.self) {
      // Events emitted by the native view
      Events(
        "onPlaybackStateChange",
        "onProgress",
        "onLoad",
        "onError",
        "onEnd",
        "onBuffer",
        "onSeek",
        "onVolumeChange",
        "onHdrStateChange",
        "onPictureInPictureChange"
      )

      // MARK: - Props
      Prop("sessionId") { (view: ExpoMpvView, sessionId: String?) in
        if let sessionId { view.attachSession(sessionId) }
      }


      Prop("source") { (view: ExpoMpvView, source: String?) in
        if let source = source {
          view.playerView.loadFile(source)
        }
      }

      Prop("paused") { (view: ExpoMpvView, paused: Bool) in
        if paused {
          view.playerView.pause()
        } else {
          view.playerView.play()
        }
      }

      Prop("speed") { (view: ExpoMpvView, speed: Double) in
        view.playerView.setSpeed(speed)
      }

      Prop("volume") { (view: ExpoMpvView, volume: Double) in
        view.playerView.setVolume(volume)
      }

      Prop("muted") { (view: ExpoMpvView, muted: Bool) in
        view.playerView.setMuted(muted)
      }

      Prop("loop") { (view: ExpoMpvView, loop: Bool) in
        view.playerView.setLooping(loop)
      }

      Prop("hwdec") { (view: ExpoMpvView, hwdec: String?) in
        if let hwdec = hwdec {
          view.playerView.setHwdec(hwdec)
        }
      }

      // MARK: - Imperative Functions (called via ref)

      AsyncFunction("play") { (view: ExpoMpvView) in
        view.playerView.play()
      }.runOnQueue(.main)

      AsyncFunction("pause") { (view: ExpoMpvView) in
        view.playerView.pause()
      }.runOnQueue(.main)

      AsyncFunction("togglePlay") { (view: ExpoMpvView) in
        view.playerView.togglePlay()
      }.runOnQueue(.main)

      AsyncFunction("stop") { (view: ExpoMpvView) in
        view.playerView.stop()
      }.runOnQueue(.main)

      AsyncFunction("seekTo") { (view: ExpoMpvView, position: Double) in
        view.playerView.seekTo(position)
      }.runOnQueue(.main)

      AsyncFunction("seekBy") { (view: ExpoMpvView, offset: Double) in
        view.playerView.seekBy(offset)
      }.runOnQueue(.main)

      AsyncFunction("setSpeed") { (view: ExpoMpvView, speed: Double) in
        view.playerView.setSpeed(speed)
      }.runOnQueue(.main)

      AsyncFunction("setVolume") { (view: ExpoMpvView, volume: Double) in
        view.playerView.setVolume(volume)
      }.runOnQueue(.main)

      AsyncFunction("setMuted") { (view: ExpoMpvView, muted: Bool) in
        view.playerView.setMuted(muted)
      }.runOnQueue(.main)

      AsyncFunction("isPictureInPictureSupported") { (view: ExpoMpvView) -> Bool in
        view.playerView.isPictureInPictureSupported()
      }.runOnQueue(.main)

      AsyncFunction("isPictureInPictureActive") { (view: ExpoMpvView) -> Bool in
        view.playerView.isPictureInPictureActive()
      }.runOnQueue(.main)

      AsyncFunction("startPictureInPicture") { (view: ExpoMpvView, sourceRect: [String: Double]?, promise: Promise) in
        view.playerView.startPictureInPicture(sourceRect: sourceRect) { started, error in
          if started { promise.resolve(true) }
          else { promise.reject("ERR_MPV_PIP_START", error ?? "PiP failed to start") }
        }
      }.runOnQueue(.main)

      AsyncFunction("stopPictureInPicture") { (view: ExpoMpvView) in
        view.playerView.stopPictureInPicture()
      }.runOnQueue(.main)

      AsyncFunction("setSubtitleTrack") { (view: ExpoMpvView, trackId: Int) in
        view.playerView.setSubtitleTrack(trackId)
      }.runOnQueue(.main)

      AsyncFunction("setAudioTrack") { (view: ExpoMpvView, trackId: Int) in
        view.playerView.setAudioTrack(trackId)
      }.runOnQueue(.main)

      AsyncFunction("addSubtitle") { (view: ExpoMpvView, path: String, flag: String?, title: String?, lang: String?) in
        view.playerView.addSubtitle(path, flag: flag ?? "select", title: title, lang: lang)
      }.runOnQueue(.main)

      AsyncFunction("removeSubtitle") { (view: ExpoMpvView, trackId: Int) in
        view.playerView.removeSubtitle(trackId)
      }.runOnQueue(.main)

      AsyncFunction("reloadSubtitles") { (view: ExpoMpvView) in
        view.playerView.reloadSubtitles()
      }.runOnQueue(.main)

      AsyncFunction("addAudio") { (view: ExpoMpvView, path: String, flag: String?, title: String?, lang: String?) in
        view.playerView.addAudio(path, flag: flag ?? "select", title: title, lang: lang)
      }.runOnQueue(.main)

      AsyncFunction("removeAudio") { (view: ExpoMpvView, trackId: Int) in
        view.playerView.removeAudio(trackId)
      }.runOnQueue(.main)

      AsyncFunction("setSubtitleDelay") { (view: ExpoMpvView, seconds: Double) in
        view.playerView.setSubtitleDelay(seconds)
      }.runOnQueue(.main)

      AsyncFunction("setPropertyString") { (view: ExpoMpvView, name: String, value: String) in
        view.playerView.setPropertyString(name, value)
      }.runOnQueue(.main)

      AsyncFunction("getPlaybackInfo") { (view: ExpoMpvView) -> [String: Any] in
        return view.playerView.getPlaybackInfo()
      }.runOnQueue(.main)

      AsyncFunction("getTrackList") { (view: ExpoMpvView) -> [[String: Any]] in
        return view.playerView.getTrackList()
      }.runOnQueue(.main)

      AsyncFunction("getCurrentTrackIds") { (view: ExpoMpvView) -> [String: Int] in
        return view.playerView.getCurrentTrackIds()
      }.runOnQueue(.main)

      AsyncFunction("getMediaInfo") { (view: ExpoMpvView) -> [String: Any] in
        return view.playerView.getMediaInfo()
      }.runOnQueue(.main)
    }
  }
}
