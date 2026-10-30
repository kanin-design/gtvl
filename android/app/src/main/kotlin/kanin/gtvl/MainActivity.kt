package kanin.gtvl

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.os.UserHandle
import android.os.storage.StorageManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.InputDevice
import android.view.KeyEvent
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The launcher's Android side: one method channel for questions and actions,
 * one event channel for app, network and Home-key changes.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())
    private val connectivity by lazy { getSystemService(ConnectivityManager::class.java) }
    private val launcherApps by lazy { getSystemService(LauncherApps::class.java) }
    private var events: EventChannel.EventSink? = null

    /** HDR wallpaper films, on a video layer beneath GTVL's screen. */
    private val deck by lazy { HdrDeck(this) { events?.success(it) } }

    private val updater by lazy { Updater(this) }
    private val prefs by lazy { Updater.prefs(this) }

    /** A checked update to install as the TV goes to standby, without asking (Android 12 on, once allowed). */
    private var standbyUpdate: String? = null

    // GTVL's screen draws see-through where an HDR film shows beneath it
    // (HdrDeck), still on a surface of its own: Flutter's texture mode would
    // cost a copy of every frame.
    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun getRenderMode() = RenderMode.surface

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "gtvl/main").setMethodCallHandler { call, result ->
            val arg = call.arguments as? String
            when (call.method) {
                "paths" -> result.success(mapOf("files" to filesDir.path, "cache" to cacheDir.path))
                "apps" -> inBackground(result) { apps() }
                "tile" -> inBackground(result) { tile(arg!!) }
                "icon" -> inBackground(result) { tile(arg!!, square = true) }
                "vpnApps" -> inBackground(result) { vpnApps() }
                "storage" -> storage(result, videos = arg == "videos")
                "hdr" -> inBackground(result) { hdrQualities() }
                "videoFrame" -> inBackground(result) { videoFrame(arg!!) }
                "isHdr" -> inBackground(result) { isHdr(arg!!) }
                "canPlay" -> inBackground(result) { canPlay(arg!!) }
                "launch" -> result.success(launchApp(arg!!))
                "open" -> result.success(openLink(call.argument<String>("uri")!!, call.argument<String>("package")))
                "appRows" -> inBackground(result) { appRows() }
                "picture" -> inBackground(result) { picture(arg!!) }
                "allowTvListings" -> allowTvListings(result)
                "appInfo" -> result.success(startNew(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$arg"))))
                "uninstall" -> result.success(startNew(Intent(Intent.ACTION_DELETE, Uri.parse("package:$arg"))))
                "settings" -> result.success(startNew(Intent(arg ?: Settings.ACTION_SETTINGS)))
                "buttons" -> result.success(mapOf(
                    "on" to (ButtonService.instance != null),
                    "remotes" to remotes((call.arguments as? List<*>)?.filterIsInstance<String>().orEmpty()),
                ))
                "remap" -> {
                    ButtonService.remaps = ButtonService.parse(JSONObject(arg ?: "{}"))
                    result.success(null)
                }
                "findButton" -> ButtonService.instance?.find(result::success) ?: result.success(null)
                "stopFinding" -> {
                    ButtonService.instance?.stopFinding()
                    result.success(null)
                }
                "buttonSettings" -> result.success(buttonSettings())
                "hdrPlay" -> {
                    deck.play(call.argument("uri")!!, call.argument("loop") ?: false, (call.argument<Double>("speed") ?: 1.0).toFloat())
                    result.success(null)
                }
                "hdrAdjust" -> {
                    deck.adjust(call.argument("loop") ?: false, (call.argument<Double>("speed") ?: 1.0).toFloat())
                    result.success(null)
                }
                "hdrQueue" -> {
                    deck.queue(arg!!)
                    result.success(null)
                }
                "hdrSkip" -> {
                    deck.skip()
                    result.success(null)
                }
                "hdrPause" -> {
                    deck.pause()
                    result.success(null)
                }
                "hdrResume" -> {
                    deck.resume()
                    result.success(null)
                }
                "hdrStop" -> {
                    deck.stop()
                    result.success(null)
                }
                "updateInfo" -> result.success(updater.about())
                "checkUpdate" -> inBackground(result) {
                    updater.check(call.argument("path")!!, call.argument<Number>("size")!!.toLong(), call.argument("sha256")!!)
                }
                "installUpdate" -> {
                    // GTVL is on screen as the user asks: it comes back after.
                    val relaunch = showing
                    inBackground(result) {
                        updater.install(arg!!, quiet = false, relaunch = relaunch)
                        null
                    }
                }
                "updateAtStandby" -> {
                    standbyUpdate = arg
                    result.success(null)
                }
                "allowUpdates" -> result.success(updater.allow())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "gtvl/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                ButtonService.onChange = buttonsChanged
                UpdateReceiver.onStatus = updateStatus
                launcherApps.registerCallback(appsCallback, mainThread)
                connectivity.registerDefaultNetworkCallback(networkCallback, mainThread)
            }

            override fun onCancel(arguments: Any?) = stopEvents()
        })
    }

    private val buttonsChanged: () -> Unit = { events?.success(mapOf("type" to "buttons")) }
    private val updateStatus: (Map<String, Any?>) -> Unit = { events?.success(it) }

    /** Also when the activity goes, as Flutter then never cancels the events. */
    private fun stopEvents() {
        if (events == null) return
        launcherApps.unregisterCallback(appsCallback)
        connectivity.unregisterNetworkCallback(networkCallback)
        if (ButtonService.onChange === buttonsChanged) ButtonService.onChange = null
        if (UpdateReceiver.onStatus === updateStatus) UpdateReceiver.onStatus = null
        events = null
    }

    /** GTVL is on screen; when it last stopped being. */
    private var showing = false
    private var hiddenAt = 0L

    /**
     * Something else was on screen at standby (an HDMI input, an app), so
     * the Home some TVs send on waking (TCL's) must give it back to that.
     */
    private var giveBack = false
    private val stopGivingBack = Runnable { keepGiveBack(false) }

    /**
     * Sets [giveBack]. A yes is kept beyond GTVL's process only by an update
     * at standby, which ends it ([updateAtStandby]); the TV's Home on waking
     * then starts GTVL afresh. Every no clears what was kept.
     */
    private fun keepGiveBack(value: Boolean) {
        giveBack = value
        if (!value) storeGiveBack(this, false)
    }

    /** A screensaver started over GTVL, which pauses it like another app would. */
    private var underScreensaver = false

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_DREAMING_STARTED ->
                    underScreensaver = showing || SystemClock.elapsedRealtime() - hiddenAt < 3000
                // GTVL pauses as the screen goes off; paused long before, something else showed.
                Intent.ACTION_SCREEN_OFF -> {
                    keepGiveBack(!showing && !underScreensaver && SystemClock.elapsedRealtime() - hiddenAt > 3000)
                    mainThread.removeCallbacks(stopGivingBack)
                    standbyUpdate?.let(::updateAtStandby)
                }
                // That Home comes within moments of waking, if at all; a later one is the user's.
                Intent.ACTION_SCREEN_ON -> mainThread.postDelayed(stopGivingBack, 5000)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_DREAMING_STARTED)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, RECEIVER_NOT_EXPORTED) else registerReceiver(screen, filter)
        // Started afresh by the Home a TV sends on waking, GTVL's process
        // having ended at standby (an update): give the screen back all the same.
        if (intent.hasCategory(Intent.CATEGORY_HOME) && prefs.getBoolean(GIVE_BACK, false) &&
            prefs.getInt(GIVE_BACK_BOOT, -1) == bootCount(this)
        ) {
            keepGiveBack(false)
            if (openTvInput()) Log.i(TAG, "Woken to Home over another screen, started afresh: giving it back")
        }
    }

    /** Installs the update at [path] as the TV goes to standby, keeping it awake till done. */
    private fun updateAtStandby(path: String) {
        standbyUpdate = null
        // The update ends GTVL's process: the Home on waking finds this instead.
        if (giveBack) storeGiveBack(this, true)
        getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gtvl:update").acquire(2 * 60_000L)
        Log.i(TAG, "Installing an update at standby")
        worker.execute {
            runCatching { updater.install(path, quiet = true, relaunch = false) }.onFailure { Log.w(TAG, "Update at standby failed", it) }
        }
    }

    override fun onResume() {
        super.onResume()
        showing = true
        underScreensaver = false
    }

    override fun onPause() {
        super.onPause()
        showing = false
        hiddenAt = SystemClock.elapsedRealtime()
    }

    /**
     * Home pressed while the launcher is already open: go back to the dock.
     * The Home a TV sends on waking, over the input or app that was showing
     * at standby, gives that back instead. A remapped button can also ask
     * for settings or all apps ([OPEN]).
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            if (giveBack) {
                keepGiveBack(false)
                Log.i(TAG, "Woken to Home over another screen: giving it back")
                if (moveTaskToBack(true) || openTvInput()) return
            }
            events?.success(mapOf("type" to "home"))
        }
        intent.getStringExtra(OPEN)?.let { events?.success(mapOf("type" to "open", "what" to it)) }
    }

    /** The TV's own input screen, which opens on the input last used. */
    private fun openTvInput(): Boolean {
        val launch = Intent("com.android.tv.action.FORCE_LAUNCH_ON_BOOT")
        val tv = packageManager.queryIntentActivities(launch, 0).firstOrNull()?.activityInfo ?: return false
        return startNew(launch.setClassName(tv.packageName, tv.name))
    }

    override fun onDestroy() {
        unregisterReceiver(screen)
        stopEvents()
        deck.stop()
        worker.shutdown()
        super.onDestroy()
    }

    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) = worker.execute {
        val outcome = runCatching(work)
        mainThread.post { outcome.fold(result::success) { result.error("native", it.message, null) } }
    }

    /** Launchable apps; an app's TV entry wins over its phone entry. */
    private fun apps(): List<Map<String, Any>> {
        val found = LinkedHashMap<String, Map<String, Any>>()
        for ((category, tv) in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER to true, Intent.CATEGORY_LAUNCHER to false)) {
            for (info in packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)) {
                val pkg = info.activityInfo.packageName
                if (pkg == packageName || pkg in found) continue
                found[pkg] = mapOf(
                    "package" to pkg,
                    "label" to info.loadLabel(packageManager).toString(),
                    "tv" to tv,
                    "version" to updated(pkg),
                    // Built into the TV: Android won't uninstall it.
                    "system" to ((info.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
        }
        return found.values.toList()
    }

    /**
     * A PNG of the app's tile, cached until the app or this launcher updates
     * (a new launcher may draw tiles differently): its TV banner
     * (".b.png") when it has one, else its icon (".i.png"); or, for
     * rounded-square tiles, its icon filling a square (".s.png"). Only the
     * path crosses to Flutter, which decodes it at display size.
     */
    private fun tile(pkg: String, square: Boolean = false): String? {
        val dir = File(cacheDir, "tiles").apply { mkdirs() }
        val stem = "${pkg}_${updated(pkg)}_$launcherUpdated"
        val kinds = if (square) listOf("s") else listOf("b", "i")
        for (kind in kinds) File(dir, "$stem.$kind.png").takeIf { it.exists() }?.let { return it.path }
        // Tiles of older versions. The digits keep those of an app named like "${pkg}_tv".
        dir.listFiles { f ->
            f.name.startsWith("${pkg}_") && !f.name.startsWith("$stem.") &&
                f.name.removePrefix("${pkg}_").substringBefore('.').all { it.isDigit() || it == '_' }
        }?.forEach(File::delete)

        val tv = resolve(packageManager.getLeanbackLaunchIntentForPackage(pkg))
        val banner = if (square) null else tv?.activityInfo?.loadBanner(packageManager)
        val (bitmap, kind) = if (banner != null) render(banner, 640, 360) to "b" else {
            val entry = resolve(packageManager.getLaunchIntentForPackage(pkg)) ?: tv ?: return null
            if (square) squareIcon(sharpIcon(entry), 256) to "s" else render(entry.loadIcon(packageManager), 192, 192) to "i"
        }
        val file = File(dir, "$stem.$kind.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        return file.path
    }

    /** The entry's icon at the highest density the app has, sharp on a big tile. */
    private fun sharpIcon(entry: ResolveInfo): Drawable {
        val info = entry.activityInfo
        return runCatching {
            packageManager.getResourcesForApplication(info.applicationInfo)
                .getDrawableForDensity(info.iconResource, DisplayMetrics.DENSITY_XXXHIGH, null)
        }.getOrNull() ?: entry.loadIcon(packageManager)
    }

    /**
     * [icon] filling a [size] square: an adaptive icon's layers without the
     * system's mask, an older square icon enlarged to fill, or any other older
     * icon centred on a dark plate.
     */
    private fun squareIcon(icon: Drawable, size: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (icon is AdaptiveIconDrawable) {
            // The layers are 108 units across, and an icon shows the middle 72.
            val bleed = size / 4
            for (layer in listOfNotNull(icon.background, icon.foreground)) {
                layer.setBounds(-bleed, -bleed, size + bleed, size + bleed)
                layer.draw(canvas)
            }
            return bitmap
        }
        icon.setBounds(0, 0, size, size)
        icon.draw(canvas)
        val box = solidSquare(bitmap)
        if (box == null) {
            bitmap.eraseColor(0xFF2A2C31.toInt())
            val inset = size / 6
            icon.setBounds(inset, inset, size - inset, size - inset)
        } else {
            // A little past the edges, so its own corners fall outside the tile's rounder ones.
            bitmap.eraseColor(0)
            val bleed = size * 0.03f
            val sx = (size + 2 * bleed) / box.width()
            val sy = (size + 2 * bleed) / box.height()
            val x = -bleed - box.left * sx
            val y = -bleed - box.top * sy
            icon.setBounds(x.roundToInt(), y.roundToInt(), (x + size * sx).roundToInt(), (y + size * sy).roundToInt())
        }
        icon.draw(canvas)
        return bitmap
    }

    /** Where [bitmap]'s solid part is, when that part is a square, maybe with rounded corners. */
    private fun solidSquare(bitmap: Bitmap): Rect? {
        val size = bitmap.width
        val pixels = IntArray(size * size).also { bitmap.getPixels(it, 0, size, 0, 0, size, size) }
        fun solid(x: Int, y: Int) = Color.alpha(pixels[y * size + x]) > 200
        var left = size
        var top = size
        var right = -1
        var bottom = -1
        for (y in 0 until size) for (x in 0 until size) if (solid(x, y)) {
            left = minOf(left, x)
            top = minOf(top, y)
            right = maxOf(right, x)
            bottom = maxOf(bottom, y)
        }
        val w = right - left + 1
        val h = bottom - top + 1
        if (right < 0 || w < size / 3 || abs(w - h) > w / 10) return null
        // Solid by each side's middle and in from each corner, where a circle is not.
        val square = listOf(0.5f to 0.03f, 0.5f to 0.97f, 0.03f to 0.5f, 0.97f to 0.5f)
            .plus(listOf(0.12f to 0.12f, 0.88f to 0.12f, 0.12f to 0.88f, 0.88f to 0.88f))
            .all { (fx, fy) -> solid(left + (fx * (w - 1)).toInt(), top + (fy * (h - 1)).toInt()) }
        return if (square) Rect(left, top, right + 1, bottom + 1) else null
    }

    /**
     * The HDR aerial qualities this TV can show. The films are Dolby Vision
     * profile 5 at 30 fps, which needs a decoder for it at 1080p or 4K and a
     * screen that takes Dolby Vision.
     */
    private fun hdrQualities(): List<String> {
        @Suppress("DEPRECATION")
        val types = windowManager.defaultDisplay.hdrCapabilities?.supportedHdrTypes ?: intArrayOf()
        if (Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION !in types) return emptyList()
        val level = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION in it.supportedTypes }
            .flatMap { it.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION).profileLevels.asList() }
            .filter { it.profile == CodecProfileLevel.DolbyVisionProfileDvheStn }
            .maxOfOrNull { it.level } ?: 0
        return buildList {
            if (level >= CodecProfileLevel.DolbyVisionLevelFhd30) add("1080p_hdr")
            if (level >= CodecProfileLevel.DolbyVisionLevelUhd30) add("4k_hdr")
        }
    }

    /**
     * A JPEG of a frame from the video at [path], a little way in since many
     * videos open on black, cached until the file changes. Null if the video
     * can't be read.
     */
    private fun videoFrame(path: String): String? {
        val video = File(path)
        if (!video.canRead()) return null
        val file = File(File(cacheDir, "frames").apply { mkdirs() }, "${path.hashCode().toUInt()}_${video.lastModified()}.jpg")
        if (file.exists()) return file.path
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val length = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
            val at = minOf(length / 10, 2000) * 1000
            val frame = if (Build.VERSION.SDK_INT >= 27) {
                retriever.getScaledFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 270)
            } else {
                retriever.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?.let { Bitmap.createScaledBitmap(it, 480, 480 * it.height / it.width, true) }
            } ?: return null
            file.outputStream().use { frame.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            frame.recycle()
            file.path
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    /** Whether the video at [path] is Dolby Vision, HDR10 or HLG. */
    private fun isHdr(path: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount).map(extractor::getTrackFormat).any { format ->
                format.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION ||
                    format.containsKey(MediaFormat.KEY_COLOR_TRANSFER) &&
                    format.getInteger(MediaFormat.KEY_COLOR_TRANSFER) in
                    listOf(MediaFormat.COLOR_TRANSFER_ST2084, MediaFormat.COLOR_TRANSFER_HLG)
            }
        } catch (e: Exception) {
            false
        } finally {
            extractor.release()
        }
    }

    /** Whether this TV has a decoder for the video at [path]; true when that can't be told. */
    private fun canPlay(path: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            (0 until extractor.trackCount).map(extractor::getTrackFormat)
                .filter { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                .all { codecs.findDecoderForFormat(it) != null }
        } catch (e: Exception) {
            true
        } finally {
            extractor.release()
        }
    }

    /** Reading pictures or videos: one permission until Android 13 split and renamed it. */
    private fun readPermission(videos: Boolean) = when {
        Build.VERSION.SDK_INT < 33 -> Manifest.permission.READ_EXTERNAL_STORAGE
        videos -> Manifest.permission.READ_MEDIA_VIDEO
        else -> Manifest.permission.READ_MEDIA_IMAGES
    }
    private var storageAnswer: MethodChannel.Result? = null

    /** Answers with [volumes] once reading pictures or [videos] is allowed, asking the user if needed; null if refused. */
    private fun storage(result: MethodChannel.Result, videos: Boolean) {
        val permission = readPermission(videos)
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return result.success(volumes())
        storageAnswer?.success(null)
        storageAnswer = result
        requestPermissions(arrayOf(permission), STORAGE_REQUEST)
    }

    private var tvAnswer: MethodChannel.Result? = null

    /** Answers true once GTVL may read TV listings, asking the user if needed. */
    private fun allowTvListings(result: MethodChannel.Result) {
        if (checkSelfPermission(TV_LISTINGS) == PackageManager.PERMISSION_GRANTED) return result.success(true)
        tvAnswer?.success(false)
        tvAnswer = result
        requestPermissions(arrayOf(TV_LISTINGS), TV_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val allowed = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        when (requestCode) {
            STORAGE_REQUEST -> {
                storageAnswer?.success(if (allowed) volumes() else null)
                storageAnswer = null
            }
            TV_REQUEST -> {
                tvAnswer?.success(allowed)
                tvAnswer = null
            }
        }
    }

    /** Mounted storage, the TV's own and any USB drives, as {path, name}. */
    private fun volumes(): List<Map<String, String>> =
        getSystemService(StorageManager::class.java).storageVolumes.mapNotNull { volume ->
            val dir = when {
                Build.VERSION.SDK_INT >= 30 -> volume.directory
                volume.isPrimary && volume.state == Environment.MEDIA_MOUNTED -> Environment.getExternalStorageDirectory()
                else -> null
            }
            dir?.let { mapOf("path" to it.path, "name" to volume.getDescription(this)) }
        }

    private fun resolve(intent: Intent?): ResolveInfo? = intent?.let { packageManager.resolveActivity(it, 0) }

    private fun updated(pkg: String): Long = packageManager.getPackageInfo(pkg, 0).lastUpdateTime

    private val launcherUpdated by lazy { updated(packageName) }

    /** Draws [drawable] at its own size, shrunk to fit [maxW] x [maxH]. */
    private fun render(drawable: Drawable, maxW: Int, maxH: Int): Bitmap {
        val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: maxW
        val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: maxH
        val scale = minOf(1f, maxW.toFloat() / w, maxH.toFloat() / h)
        val bitmap = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, bitmap.width, bitmap.height)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }

    /**
     * Remotes that have sent GTVL a key, by [ButtonService.remoteId]: the ones
     * in use, where a TV also lists devices that are no remote to hold.
     */
    private val usedRemotes by lazy { prefs.getStringSet(USED_REMOTES, null).orEmpty().toMutableSet() }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        event.device?.let { device ->
            if (usedRemotes.add(ButtonService.remoteId(device))) {
                prefs.edit().putStringSet(USED_REMOTES, usedRemotes.toSet()).apply()
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * Remotes connected now, as {id, name, keys, used}: which of [keys]
     * (Android's names for them) each one has, and whether it has sent GTVL a
     * key. The TV's own buttons and virtual devices are left out.
     */
    private fun remotes(keys: List<String>): List<Map<String, Any>> {
        val codes = keys.map { KeyEvent.keyCodeFromString("KEYCODE_$it") }.toIntArray()
        return InputDevice.getDeviceIds().toList().mapNotNull(InputDevice::getDevice)
            .filter {
                !it.isVirtual && (Build.VERSION.SDK_INT < 29 || it.isExternal) &&
                    it.supportsSource(InputDevice.SOURCE_KEYBOARD)
            }
            .distinctBy(ButtonService::remoteId)
            .map { device ->
                val has = device.hasKeys(*codes)
                val id = ButtonService.remoteId(device)
                mapOf(
                    "id" to id,
                    "name" to device.name,
                    "keys" to keys.filterIndexed { i, _ -> codes[i] != KeyEvent.KEYCODE_UNKNOWN && has[i] },
                    "used" to (id in usedRemotes),
                )
            }
    }

    /**
     * Android's switch for GTVL buttons: its own page where the TV has one,
     * else accessibility settings, else all settings. TVs send the pages they
     * lack to a stub that only says so.
     */
    private fun buttonSettings(): Boolean {
        val service = ComponentName(this, ButtonService::class.java).flattenToString()
        val pages = listOf(
            Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").putExtra(Intent.EXTRA_COMPONENT_NAME, service),
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        val page = pages.firstOrNull { resolve(it)?.activityInfo?.packageName.let { pkg -> pkg != null && pkg != STUBS } }
            ?: pages.last()
        if (!startNew(page)) return false
        // Short of the switch itself, the way to it stays on screen a while (two toasts, about 7 s).
        if (page != pages.first()) {
            val path = if (Build.VERSION.SDK_INT >= 31) R.string.buttons_path_system else R.string.buttons_path
            repeat(2) { Toast.makeText(this, path, Toast.LENGTH_LONG).show() }
        }
        return true
    }

    /** Launchable apps that provide a VPN service. */
    private fun vpnApps(): List<Map<String, String>> {
        val found = LinkedHashMap<String, Map<String, String>>()
        for (info in packageManager.queryIntentServices(Intent(VpnService.SERVICE_INTERFACE), 0)) {
            val service = info.serviceInfo ?: continue
            // Only real VPN services are guarded by this permission.
            if (service.permission != android.Manifest.permission.BIND_VPN_SERVICE) continue
            val pkg = service.packageName
            val launchable = packageManager.getLeanbackLaunchIntentForPackage(pkg) != null ||
                packageManager.getLaunchIntentForPackage(pkg) != null
            if (launchable && pkg !in found) {
                found[pkg] = mapOf("package" to pkg, "name" to service.applicationInfo.loadLabel(packageManager).toString())
            }
        }
        return found.values.toList()
    }

    private val appsCallback = object : LauncherApps.Callback() {
        override fun onPackageAdded(pkg: String, user: UserHandle) = appsChanged()
        override fun onPackageRemoved(pkg: String, user: UserHandle) = appsChanged(removed = pkg)
        override fun onPackageChanged(pkg: String, user: UserHandle) = appsChanged()
        override fun onPackagesAvailable(pkgs: Array<out String>, user: UserHandle, replacing: Boolean) = appsChanged()
        override fun onPackagesUnavailable(pkgs: Array<out String>, user: UserHandle, replacing: Boolean) = appsChanged()
    }

    /** [removed]: an app uninstalled (not one being updated), which leaves the dock for good. */
    private fun appsChanged(removed: String? = null) {
        events?.success(mapOf("type" to "apps", "removed" to removed))
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = networkChanged(caps)
        override fun onLost(network: Network) = networkChanged(null)
    }

    /**
     * Reports the network's kind, Wi-Fi strength and whether a VPN is on. A VPN
     * rides on another network, so kind and strength come from that one.
     */
    @Suppress("DEPRECATION") // allNetworks: still the simplest way to find the network under a VPN
    private fun networkChanged(caps: NetworkCapabilities?) {
        val vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        val physical = if (!vpn) caps else connectivity.allNetworks
            .mapNotNull(connectivity::getNetworkCapabilities)
            .firstOrNull { !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
            ?: caps
        val kind = when {
            physical == null -> "none"
            physical.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            physical.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            physical.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
        val signal = if (Build.VERSION.SDK_INT >= 29) physical?.signalStrength else null
        events?.success(mapOf(
            "type" to "network",
            "kind" to kind,
            "online" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            "vpn" to vpn,
            "signal" to (signal ?: Int.MIN_VALUE),
        ))
    }

    companion object {
        private const val TAG = "GTVL"

        /** An extra asking the launcher to open "settings" or "apps". */
        const val OPEN = "kanin.gtvl.OPEN"
        private const val STORAGE_REQUEST = 1
        private const val TV_REQUEST = 2
        /** Where TVs send the settings pages they lack: a stub that only says so. */
        internal const val STUBS = "com.google.android.tv.frameworkpackagestubs"

        /** Kept in [Updater.prefs]: the remotes that have sent GTVL a key. */
        private const val USED_REMOTES = "usedRemotes"

        // Kept in [Updater.prefs]: give the screen back on the next Home, as of which boot.
        private const val GIVE_BACK = "giveBack"
        private const val GIVE_BACK_BOOT = "giveBackBoot"

        /** [giveBack] where a fresh process finds it, with the boot it holds for. */
        private fun storeGiveBack(context: Context, value: Boolean) {
            Updater.prefs(context).edit().putBoolean(GIVE_BACK, value).putInt(GIVE_BACK_BOOT, bootCount(context)).apply()
        }

        private fun bootCount(context: Context) = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, 0)
    }
}
