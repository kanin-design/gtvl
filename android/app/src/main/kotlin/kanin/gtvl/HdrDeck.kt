package kanin.gtvl

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import java.io.File

/**
 * Plays HDR wallpaper films on a video layer of their own, underneath
 * GTVL's whole screen, which draws see-through where a film shows. Only a
 * video layer shows Dolby Vision right: drawn into Flutter's picture it comes
 * out green, and mixed into Flutter's screen as a platform view, every menu
 * over it flickers. Films follow one another without a gap, the next loading
 * while one plays; Flutter dips to black between them, as the TV blends no
 * two Dolby Vision films.
 *
 * [report] hears {type: hdr, what: frame | next | position | ended | error}.
 */
class HdrDeck(private val activity: Activity, private val report: (Map<String, Any?>) -> Unit) : Player.Listener {
    private var player: ExoPlayer? = null
    private var view: SurfaceView? = null
    private val main = Handler(Looper.getMainLooper())

    /** How far the film is, twice a second, for Flutter to time the next one. */
    private val ticker = object : Runnable {
        override fun run() {
            val p = player ?: return
            send(
                "position",
                "position" to p.currentPosition,
                "duration" to p.duration.takeIf { it != C.TIME_UNSET },
                "index" to p.currentMediaItemIndex,
            )
            main.postDelayed(this, 500)
        }
    }

    /** Plays [uri] from its start, replacing anything playing or queued. */
    fun play(uri: String, loop: Boolean, speed: Float) {
        val p = player ?: open()
        p.setMediaItem(item(uri))
        adjust(loop, speed)
        p.prepare()
        p.play()
        main.removeCallbacks(ticker)
        main.post(ticker)
    }

    /** Changes how the film playing, and any queued after it, play. */
    fun adjust(loop: Boolean, speed: Float) {
        val p = player ?: return
        p.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        p.setPlaybackSpeed(speed)
    }

    /** Loads [uri] to follow the film playing now, without a gap. */
    fun queue(uri: String) {
        player?.addMediaItem(item(uri))
    }

    fun skip() {
        player?.seekToNextMediaItem()
    }

    fun pause() {
        player?.pause()
    }

    fun resume() {
        player?.play()
    }

    /** Lets go of the decoder and the video layer. */
    fun stop() {
        main.removeCallbacks(ticker)
        player?.release()
        player = null
        view?.let { (it.parent as? ViewGroup)?.removeView(it) }
        view = null
    }

    // Media3 marks its video scaling mode unstable, though ExoPlayer has long had it.
    @OptIn(markerClass = [UnstableApi::class])
    private fun open(): ExoPlayer {
        // First in the content view, so behind the window and the Flutter screen above it.
        val surface = SurfaceView(activity)
        activity.findViewById<ViewGroup>(android.R.id.content).addView(surface, 0, ViewGroup.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        view = surface
        return ExoPlayer.Builder(activity).build().also {
            it.setVideoSurfaceView(surface)
            it.videoScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
            // A wallpaper is silent, and never takes the sound from what else plays.
            it.trackSelectionParameters = it.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                .build()
            it.volume = 0f
            it.addListener(this)
            player = it
        }
    }

    private fun item(uri: String) = MediaItem.fromUri(if (uri.startsWith("/")) Uri.fromFile(File(uri)) else Uri.parse(uri))

    private fun send(what: String, vararg values: Pair<String, Any?>) = report(mapOf("type" to "hdr", "what" to what, *values))

    override fun onRenderedFirstFrame() = send("frame")

    override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
        // A looping film starting over, or a new choice, is no next film.
        if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO || reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK) {
            send("next", "index" to player?.currentMediaItemIndex)
        }
    }

    override fun onPlaybackStateChanged(state: Int) {
        if (state == Player.STATE_ENDED) send("ended")
    }

    override fun onPlayerError(error: PlaybackException) = send("error", "message" to error.message)
}
