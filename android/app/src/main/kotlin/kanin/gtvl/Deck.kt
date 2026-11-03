package kanin.gtvl

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.SurfaceControl
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.animation.AccelerateDecelerateInterpolator
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import java.io.File

/**
 * Plays wallpaper films on a video layer of their own, underneath GTVL's whole
 * screen, which draws see-through where a film shows. Drawn into Flutter's
 * picture instead, a film costs several times the CPU and memory; Dolby Vision
 * comes out green that way, and mixed into Flutter's screen as a platform view,
 * every menu over it flickers.
 *
 * One film fades into the next on a second layer, both decoding meanwhile.
 * HDR films can't: they follow one another without a gap, the next loading
 * while one plays, and Flutter dips to black between them, as the TV blends no
 * two Dolby Vision films. Nor can Android before 10, which has no way to fade a
 * layer: its films go the same way.
 *
 * [report] hears {type: deck, what: frame | next | missed | position | ended | error}.
 */
class Deck(private val activity: Activity, private val report: (Map<String, Any?>) -> Unit) {
    private var film: Film? = null

    /** Opened on the other layer, paused, to fade in over [film]. */
    private var coming: Film? = null

    /** The fade asked for, in ms, for when [coming] is ready. */
    private var fadeWanted: Long? = null
    private var fading: ValueAnimator? = null
    private var speed = 1f
    private val main = Handler(Looper.getMainLooper())

    /** How far the film is, twice a second, for Flutter to time the next one. */
    private val ticker = object : Runnable {
        override fun run() {
            val p = film?.player ?: return
            send(
                "position",
                "position" to p.currentPosition,
                "duration" to p.duration.takeIf { it != C.TIME_UNSET },
            )
            main.postDelayed(this, 500)
        }
    }

    /** Plays [uri] from its start, replacing anything playing or coming; says whether films can fade here. */
    fun play(uri: String, loop: Boolean, speed: Float): Boolean {
        settle()
        val now = film ?: Film(upper = false).also { film = it }
        now.player.setMediaItem(item(uri))
        adjust(loop, speed)
        now.player.prepare()
        now.player.play()
        main.removeCallbacks(ticker)
        main.post(ticker)
        return blends
    }

    /** Changes how the film playing plays, and how fast any coming will. */
    fun adjust(loop: Boolean, speed: Float) {
        this.speed = speed
        film?.player?.let {
            it.repeatMode = repeat(loop)
            it.setPlaybackSpeed(speed)
        }
        coming?.player?.setPlaybackSpeed(speed)
    }

    /** Loads [uri] to follow the film playing: to fade in with [blend], or else without a gap. */
    fun queue(uri: String, loop: Boolean, blend: Boolean) {
        val now = film ?: return
        if (!blend || !blends) {
            now.player.addMediaItem(item(uri))
            return
        }
        coming?.release()
        fadeWanted = null
        coming = Film(upper = !now.upper).also {
            it.player.setMediaItem(item(uri))
            it.player.repeatMode = repeat(loop)
            it.player.setPlaybackSpeed(speed)
            it.player.prepare()
        }
    }

    /** Moves on to the next film: fades over [fade] ms to one loaded to fade in, as soon as it is ready. */
    fun skip(fade: Long) {
        val next = coming
        if (next == null) {
            if (fading == null) film?.player?.seekToNextMediaItem()
            return
        }
        fadeWanted = fade
        if (next.player.playbackState == Player.STATE_READY) fade()
    }

    fun pause() {
        film?.player?.pause()
    }

    fun resume() {
        film?.player?.play()
    }

    /** Lets go of the decoders and the video layers. */
    fun stop() {
        main.removeCallbacks(ticker)
        settle()
        film?.release()
        film = null
    }

    /** Ends any fade, and drops the film coming. */
    private fun settle() {
        fading?.end()
        coming?.release()
        coming = null
        fadeWanted = null
    }

    /**
     * Only the upper layer's see-through changes: the new film fades in on it,
     * or the old one fades off it to show the new one beneath, which looks the
     * same. So the two films can take turns on the layers.
     */
    private fun fade() {
        val old = film ?: return
        val new = coming ?: return
        val ms = fadeWanted ?: return
        fadeWanted = null
        fading?.end()
        coming = null
        film = new
        new.player.play()
        send("next")
        val upper = if (new.upper) new else old
        fading = ValueAnimator.ofFloat(if (new.upper) 0f else 1f, if (new.upper) 1f else 0f).apply {
            duration = ms
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { upper.see(it.animatedValue as Float) }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    upper.see(if (new.upper) 1f else 0f)
                    old.release()
                    fading = null
                }
            })
            start()
        }
    }

    private fun repeat(loop: Boolean) = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF

    private fun item(uri: String) = MediaItem.fromUri(if (uri.startsWith("/")) Uri.fromFile(File(uri)) else Uri.parse(uri))

    private fun send(what: String, vararg values: Pair<String, Any?>) = report(mapOf("type" to "deck", "what" to what, *values))

    /** A player on a video layer behind the window and the Flutter screen above it; the [upper] layer lies over the other. */
    // Media3 marks its video scaling mode unstable, though ExoPlayer has long had it.
    @OptIn(markerClass = [UnstableApi::class])
    private inner class Film(val upper: Boolean) : Player.Listener {
        val view = SurfaceView(activity)
        val player = ExoPlayer.Builder(activity).build()

        init {
            view.setZOrderMediaOverlay(upper)
            // Unseen until it fades in, if a film is playing beneath it.
            if (upper) {
                view.holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) = see(0f)
                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
                    override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
                })
            }
            activity.findViewById<ViewGroup>(android.R.id.content).addView(view, 0, ViewGroup.LayoutParams(MATCH_PARENT, MATCH_PARENT))
            player.setVideoSurfaceView(view)
            player.videoScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING
            // A wallpaper is silent, and never takes the sound from what else plays.
            player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                .build()
            player.volume = 0f
            player.addListener(this)
        }

        /** How much of this layer shows, from 0 to 1. */
        fun see(amount: Float) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
            val layer = view.surfaceControl?.takeIf { it.isValid } ?: return
            SurfaceControl.Transaction().use { it.setAlpha(layer, amount).apply() }
        }

        fun release() {
            player.release()
            (view.parent as? ViewGroup)?.removeView(view)
        }

        override fun onRenderedFirstFrame() {
            if (this === film) send("frame")
        }

        override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
            // A looping film starting over, or a new choice, is no next film.
            if (this === film && (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO || reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK)) {
                send("next", "index" to player.currentMediaItemIndex)
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            when {
                this === coming && state == Player.STATE_READY -> fade()
                // With a film coming, this one holds its last frame until that is ready.
                this === film && state == Player.STATE_ENDED && coming == null -> send("ended")
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            when {
                // The film playing goes on until another will open.
                this === coming -> {
                    release()
                    coming = null
                    fadeWanted = null
                    film?.player?.repeatMode = Player.REPEAT_MODE_ONE
                    send("missed", "message" to error.message)
                }
                this === film -> send("error", "message" to error.message)
            }
        }
    }

    private companion object {
        val blends = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }
}
