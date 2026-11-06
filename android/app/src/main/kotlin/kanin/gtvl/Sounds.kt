package kanin.gtvl

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.util.Log
import io.flutter.FlutterInjector
import java.io.IOException

/**
 * The sounds of moving focus and pressing OK, by set. "android" plays the
 * TV's own sound effects, as its home screen does, and like there only while
 * Android's System sounds switch is on. "off" plays none. Any other name is
 * one of GTVL's sets, files in its assets (assets/sounds/<set>/move.wav and
 * press.wav), played on the system sounds' volume as Android plays its own.
 *
 * Any set can play, not only the one in use, so settings can play a theme
 * as focus moves over it. Each set's files load the first time it is asked
 * for, and stay.
 */
class Sounds(private val context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private var set = "off"
    private var pool: SoundPool? = null

    /** GTVL's files by set and event ("pop/move"), as SoundPool numbers them; 0 for one missing. */
    private val samples = mutableMapOf<String, Int>()
    private val loaded = mutableSetOf<Int>()

    /** A file asked for while it was still loading: it plays once loaded. */
    private var waiting: Int? = null

    /** Uses the set [name] from now on, loading its files so the first plays at once. */
    fun use(name: String) {
        set = name
        load(name)
    }

    /** Plays the set in use's sound for [event]: up, down, left or right (focus moved that way), or press (OK). */
    fun play(event: String) = play(set, event)

    /** Plays [event] in the set [name], whether it is in use or not. */
    fun play(name: String, event: String) {
        when (name) {
            "off" -> {}
            "android" -> audio.playSoundEffect(
                when (event) {
                    "up" -> AudioManager.FX_FOCUS_NAVIGATION_UP
                    "down" -> AudioManager.FX_FOCUS_NAVIGATION_DOWN
                    "left" -> AudioManager.FX_FOCUS_NAVIGATION_LEFT
                    "right" -> AudioManager.FX_FOCUS_NAVIGATION_RIGHT
                    else -> AudioManager.FX_KEY_CLICK
                },
            )
            else -> {
                load(name)
                val sample = samples["$name/${if (event == "press") "press" else "move"}"] ?: return
                when {
                    sample == 0 -> {}
                    sample in loaded -> pool?.play(sample, 1f, 1f, 1, 0, 1f)
                    else -> waiting = sample
                }
            }
        }
    }

    private fun load(name: String) {
        if (name == "android" || name == "off") return
        val pool = pool()
        val flutter = FlutterInjector.instance().flutterLoader()
        for (event in listOf("move", "press")) {
            val key = "$name/$event"
            if (key in samples) continue
            samples[key] = try {
                context.assets.openFd(flutter.getLookupKeyForAsset("assets/sounds/$key.wav")).use { pool.load(it, 1) }
            } catch (e: IOException) {
                Log.w("GTVL", "Set $name has no $event sound", e)
                0
            }
        }
    }

    private fun pool(): SoundPool = pool ?: SoundPool.Builder()
        .setMaxStreams(4)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        .build()
        .also { made ->
            made.setOnLoadCompleteListener { _, sample, status ->
                if (status != 0) return@setOnLoadCompleteListener
                loaded += sample
                if (sample == waiting) {
                    waiting = null
                    made.play(sample, 1f, 1f, 1, 0, 1f)
                }
            }
            pool = made
        }

    fun release() {
        pool?.release()
        pool = null
        samples.clear()
        loaded.clear()
        waiting = null
    }
}
