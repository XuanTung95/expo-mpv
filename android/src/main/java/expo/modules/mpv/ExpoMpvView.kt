package expo.modules.mpv

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class ExpoMpvView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
    private val onPlaybackStateChange by EventDispatcher()
    private val onProgress by EventDispatcher()
    private val onLoad by EventDispatcher()
    private val onError by EventDispatcher()
    private val onEnd by EventDispatcher()
    private val onBuffer by EventDispatcher()
    private val onSeek by EventDispatcher()
    private val onVolumeChange by EventDispatcher()
    private val onPictureInPictureChange by EventDispatcher()
    private val onHdrStateChange by EventDispatcher()
    private val appContextRef = appContext

    private var isDestroyed = false

    private val surfaceView = SurfaceView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }

    private val listener = object : MpvPlayer.Listener {
            override fun onPlaybackStateChange(state: String, isPlaying: Boolean) {
                onPlaybackStateChange(
                    mapOf(
                        "state" to state,
                        "isPlaying" to isPlaying,
                    )
                )
            }

            override fun onProgress(position: Double, duration: Double, bufferedDuration: Double, bufferedPosition: Double, bufferRate: Double, bufferingPercent: Double) {
                onProgress(
                    mapOf(
                        "position" to position,
                        "duration" to duration,
                        "bufferedDuration" to bufferedDuration,
                        "bufferedPosition" to bufferedPosition,
                        "bufferRate" to bufferRate,
                        "bufferingPercent" to bufferingPercent,
                    )
                )
            }

            override fun onLoad(duration: Double, width: Int, height: Int) {
                onLoad(
                    mapOf(
                        "duration" to duration,
                        "width" to width,
                        "height" to height,
                    )
                )
            }

            override fun onError(message: String) {
                onError(mapOf("error" to message))
            }

            override fun onEnd(reason: String) {
                onEnd(mapOf("reason" to reason))
            }

            override fun onBuffer(isBuffering: Boolean) {
                onBuffer(mapOf("isBuffering" to isBuffering))
            }

            override fun onSeek() {
                onSeek(emptyMap<String, Any>())
            }

            override fun onVolumeChange(volume: Double, muted: Boolean) {
                onVolumeChange(
                    mapOf(
                        "volume" to volume,
                        "muted" to muted,
                    )
                )
            }

            override fun onHdrStateChange(isHdr: Boolean, sigPeak: Double, hdrFormat: String) {
                onHdrStateChange(
                    mapOf(
                        "isHdr" to isHdr,
                        "hdrActive" to isHdr,
                        "sigPeak" to sigPeak,
                        "hdrFormat" to hdrFormat,
                    )
                )
            }
    }
    private var player = MpvPlayer(context, listener)
    private var sessionId: String? = null
    private var lastSource: String? = null

    companion object {
        private data class Session(val player: MpvPlayer, var view: ExpoMpvView, var source: String? = null)
        private val sessions = mutableMapOf<String, Session>()

        fun releaseSession(id: String) {
            sessions.remove(id)?.player?.release()
        }
    }

    fun attachSession(id: String) {
        if (sessionId == id) return
        sessionId = id
        val existing = sessions[id]
        if (existing == null) {
            sessions[id] = Session(player, this, lastSource)
        } else {
            player.release() // Dispose this view's temporary player.
            player = existing.player
            existing.view = this
            player.setListener(listener)
            surfaceView.holder.surface?.takeIf { it.isValid }?.let(player::setSurface)
        }
    }

    private fun ownsSurface(): Boolean = sessionId?.let { sessions[it]?.view === this } ?: true

    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            if (ownsSurface()) player.setSurface(holder.surface)
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            if (ownsSurface()) player.setSurface(null)
        }
    }

    init {
        addView(surfaceView)
        setBackgroundColor(0xFF000000.toInt())
        surfaceView.holder.addCallback(surfaceCallback)
    }

    override fun onDetachedFromWindow() {
        if (sessionId == null) destroy()
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (!ownsSurface()) return
        if (visibility == View.GONE || visibility == View.INVISIBLE) {
            player.setPropertyString("vid", "no")
        } else {
            player.setPropertyString("vid", "auto")
        }
    }

    fun destroy() {
        if (isDestroyed) return
        isDestroyed = true
        surfaceView.holder.removeCallback(surfaceCallback)
        player.setSurface(null)
        if (sessionId == null) player.release()
    }

    fun loadFile(url: String) {
        lastSource = url
        val session = sessionId?.let(sessions::get)
        if (session?.source == url) return
        if (session != null) session.source = url
        player.loadFile(url)
    }

    fun play() {
        player.play()
    }

    fun pause() {
        player.pause()
    }

    fun togglePlay() {
        player.togglePlay()
    }

    fun stop() {
        sessionId?.let { sessions[it]?.source = null }
        player.stop()
    }

    fun seekTo(position: Double) {
        player.seekTo(position)
    }

    fun seekBy(offset: Double) {
        player.seekBy(offset)
    }

    fun setSpeed(speed: Double) {
        player.setSpeed(speed)
    }

    fun setVolume(volume: Double) {
        player.setVolume(volume)
    }

    fun setMuted(muted: Boolean) {
        player.setMuted(muted)
    }

    fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            appContextRef.currentActivity?.packageManager?.hasSystemFeature("android.software.picture_in_picture") == true

    fun isPictureInPictureActive(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            appContextRef.currentActivity?.isInPictureInPictureMode == true

    fun startPictureInPicture(sourceRect: Map<String, Double>?): Boolean {
        if (!isPictureInPictureSupported() || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val activity = appContextRef.currentActivity ?: return false
        val width = sourceRect?.get("width")?.toInt()?.coerceAtLeast(1) ?: this.width.coerceAtLeast(1)
        val height = sourceRect?.get("height")?.toInt()?.coerceAtLeast(1) ?: this.height.coerceAtLeast(1)
        val started = activity.enterPictureInPictureMode(
            PictureInPictureParams.Builder().setAspectRatio(Rational(width, height)).build()
        )
        if (started) onPictureInPictureChange(mapOf("active" to true))
        return started
    }

    fun stopPictureInPicture() {
        // Android does not expose a programmatic PiP exit API.
    }

    fun setLooping(loop: Boolean) {
        player.setLooping(loop)
    }

    fun setHwdec(mode: String) {
        player.setHwdec(mode)
    }

    fun setSubtitleTrack(trackId: Int) {
        player.setSubtitleTrack(trackId)
    }

    fun setAudioTrack(trackId: Int) {
        player.setAudioTrack(trackId)
    }

    fun addSubtitle(path: String, flag: String, title: String?, lang: String?) {
        player.addSubtitle(path, flag, title, lang)
    }

    fun removeSubtitle(trackId: Int) {
        player.removeSubtitle(trackId)
    }

    fun reloadSubtitles() {
        player.reloadSubtitles()
    }

    fun setSubtitleDelay(seconds: Double) {
        player.setSubtitleDelay(seconds)
    }

    fun setPropertyString(name: String, value: String) {
        player.setPropertyString(name, value)
    }

    fun getPlaybackInfo(): Map<String, Any> {
        return player.getPlaybackInfo()
    }

    fun getTrackList(): List<Map<String, Any>> {
        return player.getTrackList()
    }

    fun getCurrentTrackIds(): Map<String, Int> {
        return player.getCurrentTrackIds()
    }

    fun getMediaInfo(): Map<String, Any> {
        return player.getMediaInfo()
    }
}
