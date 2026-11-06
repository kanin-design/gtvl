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
 */
class Sounds(private val context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private var set = "off"
    private var pool: SoundPool? = null

    /** The set's files by event ("move", "press"), and those loaded so far. */
    private val samples = mutableMapOf<String, Int>()
    private val loaded = mutableSetOf<Int>()

    /** A file asked for while it was still loading: it plays once loaded. */
    private var waiting: Int? = null

    /** Changes to the set [name], loading its files now so the first plays at once. */
    fun use(name: String) {
        if (name == set) return
        release()
        set = name
        if (name == "android" || name == "off") return
        val pool = SoundPool.Builder()
            .setMaxStreams(4)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .build()
        pool.setOnLoadCompleteListener { _, sample, status ->
            if (status != 0) return@setOnLoadCompleteListener
            loaded += sample
            if (sample == waiting) {
                waiting = null
                pool.play(sample, 1f, 1f, 1, 0, 1f)
            }
        }
        val flutter = FlutterInjector.instance().flutterLoader()
        for (event in listOf("move", "press")) {
            try {
                context.assets.openFd(flutter.getLookupKeyForAsset("assets/sounds/$name/$event.wav")).use {
                    samples[event] = pool.load(it, 1)
                }
            } catch (e: IOException) {
                Log.w("GTVL", "Set $name has no $event sound", e)
            }
        }
        this.pool = pool
    }

    /** Plays the sound for [event]: up, down, left or right (focus moved that way), or press (OK). */
    fun play(event: String) {
        when (set) {
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
                val pool = pool ?: return
                val sample = samples[if (event == "press") "press" else "move"] ?: return
                if (sample in loaded) pool.play(sample, 1f, 1f, 1, 0, 1f) else waiting = sample
            }
        }
    }

    fun release() {
        pool?.release()
        pool = null
        samples.clear()
        loaded.clear()
        waiting = null
    }
}
