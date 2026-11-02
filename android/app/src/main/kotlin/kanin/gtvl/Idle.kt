package kanin.gtvl

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.KeyEvent

/**
 * Says when no button has been pressed for a while, for GTVL's screensaver,
 * and when one is again. The press that ends the screensaver does nothing
 * else, so OK on the way back doesn't open the app in focus; volume and media
 * buttons still do what they do.
 *
 * Android's own screensaver would start over GTVL at its own time, so where it
 * comes before the TV sleeps, this holds it off until the TV's sleep time.
 *
 * [report] hears {type: saver, on}.
 */
class Idle(private val activity: Activity, private val report: (Map<String, Any?>) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val start = Runnable { show(true) }

    /**
     * A wake lock, not FLAG_KEEP_SCREEN_ON: when that flag goes, Android counts
     * it as a button press and waits a whole sleep time again before sleeping.
     */
    @Suppress("DEPRECATION")
    private val awake by lazy {
        activity.getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK, "gtvl:screensaver")
            .apply { setReferenceCounted(false) }
    }

    /** How long without a button before the screensaver shows; 0 never. */
    private var after = 0L

    private var inFront = false
    private var showing = false

    /** The button that ended the screensaver: its repeats and release go nowhere too. */
    private var waking: Int? = null

    fun set(minutes: Int) {
        after = minutes * 60_000L
        touch()
    }

    fun resume() {
        inFront = true
        touch()
    }

    fun pause() {
        inFront = false
        waking = null
        touch()
    }

    /** A button was pressed, or GTVL came or went: the wait starts over. */
    fun touch() {
        show(false)
        main.removeCallbacks(start)
        if (!inFront || after <= 0) {
            if (awake.isHeld) awake.release()
            return
        }
        main.postDelayed(start, after)
        holdOff()
    }

    /** Whether [event] ends the screensaver and goes no further. */
    fun swallow(event: KeyEvent): Boolean {
        if (event.keyCode == waking) {
            if (event.action == KeyEvent.ACTION_UP) waking = null
            return true
        }
        if (!showing || event.action != KeyEvent.ACTION_DOWN) return false
        touch()
        if (event.keyCode in passing) return false
        waking = event.keyCode
        return true
    }

    /** How long this TV stays awake with no button pressed, in ms; null when never, or when that can't be read. */
    fun sleepAfter(): Long? = secure("sleep_timeout")?.takeIf { it > 0 }

    private fun holdOff() {
        val sleep = secure("sleep_timeout")
        val own = runCatching { Settings.System.getLong(activity.contentResolver, Settings.System.SCREEN_OFF_TIMEOUT) }.getOrNull()
        val ownFirst = own != null && sleep != null && secure("screensaver_enabled") != 0L && (sleep <= 0 || own < sleep)
        when {
            !ownFirst -> if (awake.isHeld) awake.release()
            sleep!! > 0 -> awake.acquire(sleep)
            else -> awake.acquire()
        }
    }

    /** A setting Android keeps to itself, which it may not let GTVL read. */
    private fun secure(name: String): Long? = runCatching { Settings.Secure.getLong(activity.contentResolver, name) }.getOrNull()

    private fun show(on: Boolean) {
        if (showing == on) return
        showing = on
        report(mapOf("type" to "saver", "on" to on))
    }

    private companion object {
        val passing = setOf(
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_STOP, KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_REWIND, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
        )
    }
}
