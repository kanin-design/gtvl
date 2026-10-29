package kanin.gtvl

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import org.json.JSONObject
import java.io.File

/** Remote, then button, then press, hold or double: what it does instead. */
typealias Remaps = Map<String, Map<String, Map<String, String>>>

/**
 * Remaps the remote's buttons. Android shows an accessibility service each
 * button press before apps get it (Power aside), and lets it keep the press.
 *
 * A button can do something else when pressed, held or pressed twice. One
 * with a hold or double press is held back until it is clear which it was;
 * its own press is then passed on where Android lets an app do that
 * ([replay]). OK and the arrows always pass untouched, and typed characters
 * are never looked at.
 */
class ButtonService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private val audio by lazy { getSystemService(AudioManager::class.java) }
    private val holdTime = ViewConfiguration.getLongPressTimeout().toLong()
    private val doubleTime = ViewConfiguration.getDoubleTapTimeout().toLong()

    /** The remapped button down now, or waiting to see if a second press follows. */
    private var press: Press? = null

    /** A button caught while finding one, by [keyName]: its release is kept too. */
    private var swallow: String? = null

    private var finding: ((Map<String, String>?) -> Unit)? = null
    private val giveUp = Runnable { reply(null) }

    override fun onServiceConnected() {
        instance = this
        if (remaps == null) remaps = readConfig()
        onChange?.invoke()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        gone()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        gone()
        super.onDestroy()
    }

    private fun gone() {
        if (instance != this) return
        instance = null
        reply(null)
        onChange?.invoke()
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.isPrintingKey || event.keyCode in untouchable) return false
        val key = keyName(event)
        if (key == swallow) {
            if (event.action == KeyEvent.ACTION_UP) swallow = null
            return true
        }
        val device = event.device ?: return false
        val remote = remoteId(device)
        val down = event.action == KeyEvent.ACTION_DOWN
        if (down && event.repeatCount == 0) Log.d(TAG, "$key on $remote")
        if (finding != null && down) {
            // Back gives up, and goes back as usual.
            if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                reply(null)
                return false
            }
            swallow = key
            reply(mapOf("remote" to remote, "name" to device.name, "key" to key))
            return true
        }
        val waiting = press
        if (waiting != null && waiting.second && (waiting.remote != remote || waiting.key != key)) {
            // Another button while one waits for its second press: that one was a single press.
            main.removeCallbacks(waiting.single)
            waiting.single.run()
        }
        val remap = remaps?.get(remote)?.get(key)
        if (remap.isNullOrEmpty()) return false
        val current = press?.takeIf { it.remote == remote && it.key == key }
        if (down) {
            if (event.repeatCount > 0) return true
            if (current != null && current.second) {
                main.removeCallbacks(current.single)
                current.done = true
                run(remap["double"], current)
            } else {
                press?.let { held ->
                    // Another remapped button while that one is still down: it was a press.
                    main.removeCallbacks(held.hold)
                    if (!held.done) run(held.slot("press"), held)
                }
                press = Press(remote, key, event.keyCode, event.deviceId).also {
                    if (remap["hold"] != null) main.postDelayed(it.hold, holdTime)
                }
            }
        } else if (current == null) {
            // Its press went on to the app (or was settled already): so does its release.
            return false
        } else {
            main.removeCallbacks(current.hold)
            when {
                current.done -> press = null
                remap["double"] != null && !current.second -> {
                    current.second = true
                    main.postDelayed(current.single, doubleTime)
                }
                else -> {
                    press = null
                    run(remap["press"], current)
                }
            }
        }
        return true
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {}

    override fun onInterrupt() {}

    /** One remapped button's press, held back until it is clear what it was. */
    private inner class Press(val remote: String, val key: String, val code: Int, val deviceId: Int) {
        /** Released once, and waiting to see if a second press follows. */
        var second = false

        /** Its hold or double press has run. */
        var done = false

        val hold = Runnable {
            done = true
            run(slot("hold"), this)
        }
        val single = Runnable {
            if (press == this) press = null
            run(slot("press"), this)
        }

        fun slot(name: String) = remaps?.get(remote)?.get(key)?.get(name)
    }

    /** Does [action], or with none, the button's own press. */
    private fun run(action: String?, press: Press) {
        if (action == null) replay(press) else perform(action, press.deviceId)
    }

    /** The button's own press, for buttons whose press Android lets an app make. */
    private fun replay(press: Press) {
        when (press.code) {
            KeyEvent.KEYCODE_HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            KeyEvent.KEYCODE_BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            KeyEvent.KEYCODE_APP_SWITCH -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            KeyEvent.KEYCODE_VOLUME_UP -> volume(AudioManager.ADJUST_RAISE)
            KeyEvent.KEYCODE_VOLUME_DOWN -> volume(AudioManager.ADJUST_LOWER)
            KeyEvent.KEYCODE_VOLUME_MUTE -> volume(AudioManager.ADJUST_TOGGLE_MUTE)
            KeyEvent.KEYCODE_ASSIST, KeyEvent.KEYCODE_SEARCH, KeyEvent.KEYCODE_VOICE_ASSIST -> assist(press.deviceId)
            KeyEvent.KEYCODE_SETTINGS -> startNew(Intent(Settings.ACTION_SETTINGS))
            KeyEvent.KEYCODE_BUTTON_12 -> if (press.remote == SHIELD_REMOTE) launchApp(NETFLIX)
            in mediaKeys.values -> media(press.code)
        }
    }

    /** Does [action], as config.json names it, e.g. "app:com.plexapp.android" or "system:sleep". */
    private fun perform(action: String, deviceId: Int) {
        val what = action.substringAfter(':')
        when (action.substringBefore(':')) {
            "app" -> launchApp(what)
            "gtvl" -> startNew(Intent(this, MainActivity::class.java).putExtra(MainActivity.OPEN, what))
            "media" -> mediaKeys[what]?.let(::media)
            "volume" -> volumes[what]?.let(::volume)
            "system" -> when (what) {
                "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
                "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
                "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
                "power" -> performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
                "sleep" -> if (Build.VERSION.SDK_INT >= 28) performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
                "screenshot" -> if (Build.VERSION.SDK_INT >= 28) performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)
                "settings" -> startNew(Intent(Settings.ACTION_SETTINGS))
                "assistant" -> assist(deviceId)
            }
            // "nothing": the press is just kept.
        }
    }

    private fun media(code: Int) {
        val now = SystemClock.uptimeMillis()
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
        audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
    }

    private fun volume(direction: Int) =
        audio.adjustSuggestedStreamVolume(direction, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI)

    /** The Assistant, listening through the remote the button was on. */
    private fun assist(deviceId: Int) =
        startNew(Intent(Intent.ACTION_ASSIST).putExtra(Intent.EXTRA_ASSIST_INPUT_DEVICE_ID, deviceId))

    /** Hands [answer] the next button pressed, as {remote, name, key}; null after a while, or if stopped. */
    fun find(answer: (Map<String, String>?) -> Unit) {
        reply(null)
        finding = answer
        main.postDelayed(giveUp, 20_000)
    }

    fun stopFinding() = reply(null)

    private fun reply(found: Map<String, String>?) {
        main.removeCallbacks(giveUp)
        val answer = finding ?: return
        finding = null
        answer(found)
    }

    private fun readConfig(): Remaps = try {
        parse(JSONObject(File(filesDir, "config.json").readText()).optJSONObject("remotes"))
    } catch (e: Exception) {
        emptyMap()
    }

    companion object {
        private const val TAG = "GTVL.buttons"

        /** The SHIELD Remote (2019): its Netflix button sends BUTTON_12. */
        private const val SHIELD_REMOTE = "0955:7217"
        private const val NETFLIX = "com.netflix.ninja"

        /** OK, the arrows and Power are never remapped, so the TV always works. */
        private val untouchable = setOf(
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_POWER,
            KeyEvent.KEYCODE_SLEEP, KeyEvent.KEYCODE_WAKEUP,
        )
        private val mediaKeys = mapOf(
            "play_pause" to KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            "play" to KeyEvent.KEYCODE_MEDIA_PLAY,
            "pause" to KeyEvent.KEYCODE_MEDIA_PAUSE,
            "stop" to KeyEvent.KEYCODE_MEDIA_STOP,
            "next" to KeyEvent.KEYCODE_MEDIA_NEXT,
            "previous" to KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            "rewind" to KeyEvent.KEYCODE_MEDIA_REWIND,
            "fast_forward" to KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            "record" to KeyEvent.KEYCODE_MEDIA_RECORD,
        )
        private val volumes = mapOf(
            "up" to AudioManager.ADJUST_RAISE,
            "down" to AudioManager.ADJUST_LOWER,
            "mute" to AudioManager.ADJUST_TOGGLE_MUTE,
        )
        private val slotNames = setOf("press", "hold", "double")

        /** The service, while Android has it on. */
        var instance: ButtonService? = null
            private set

        /** Told when the service turns on or off. */
        var onChange: (() -> Unit)? = null

        /** The remaps in use: config.json's at first, then each new set GTVL hands over. */
        var remaps: Remaps? = null

        /** A remote's vendor and product, so every remote of a model shares remaps. */
        fun remoteId(device: InputDevice): String =
            if (device.vendorId == 0 && device.productId == 0) {
                "name:${device.name}"
            } else {
                "%04x:%04x".format(device.vendorId, device.productId)
            }

        /** Android's name for the button, or its scan code where it has none. */
        fun keyName(event: KeyEvent): String =
            if (event.keyCode == KeyEvent.KEYCODE_UNKNOWN) {
                "SCAN_${event.scanCode}"
            } else {
                KeyEvent.keyCodeToString(event.keyCode).removePrefix("KEYCODE_")
            }

        /** Config.remotes, keeping only the presses, holds and double presses that do something else. */
        fun parse(json: JSONObject?): Remaps {
            json ?: return emptyMap()
            return json.keys().asSequence().associateWith { remote ->
                val buttons = json.optJSONObject(remote)?.optJSONObject("buttons") ?: JSONObject()
                buttons.keys().asSequence().associateWith { key ->
                    val slots = buttons.optJSONObject(key) ?: JSONObject()
                    slots.keys().asSequence()
                        .filter { it in slotNames }
                        .associateWith { slots.optString(it) }
                        .filterValues { it.isNotEmpty() && it != "default" }
                }
            }
        }
    }
}
