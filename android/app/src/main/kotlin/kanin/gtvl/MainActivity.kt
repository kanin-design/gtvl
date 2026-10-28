package kanin.gtvl

import android.Manifest
import android.content.Intent
import android.content.pm.LauncherApps
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.UserHandle
import android.os.storage.StorageManager
import android.provider.Settings
import android.util.DisplayMetrics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
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
                "storage" -> storage(result)
                "launch" -> result.success(launch(arg!!))
                "appInfo" -> result.success(start(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$arg"))))
                "uninstall" -> result.success(start(Intent(Intent.ACTION_DELETE, Uri.parse("package:$arg"))))
                "settings" -> result.success(start(Intent(arg ?: Settings.ACTION_SETTINGS)))
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "gtvl/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                launcherApps.registerCallback(appsCallback, mainThread)
                connectivity.registerDefaultNetworkCallback(networkCallback, mainThread)
            }

            override fun onCancel(arguments: Any?) {
                launcherApps.unregisterCallback(appsCallback)
                connectivity.unregisterNetworkCallback(networkCallback)
                events = null
            }
        })
    }

    /** Home pressed while the launcher is already open: go back to the dock. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) events?.success(mapOf("type" to "home"))
    }

    override fun onDestroy() {
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

    /** Reading pictures, a permission Android 13 renamed. */
    private val readPictures =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
    private var storageAnswer: MethodChannel.Result? = null

    /** Answers with [volumes] once reading pictures is allowed, asking the user if needed; null if refused. */
    private fun storage(result: MethodChannel.Result) {
        if (checkSelfPermission(readPictures) == PackageManager.PERMISSION_GRANTED) return result.success(volumes())
        storageAnswer?.success(null)
        storageAnswer = result
        requestPermissions(arrayOf(readPictures), STORAGE_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_REQUEST) return
        val allowed = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        storageAnswer?.success(if (allowed) volumes() else null)
        storageAnswer = null
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

    private fun launch(pkg: String): Boolean {
        val intent = packageManager.getLeanbackLaunchIntentForPackage(pkg)
            ?: packageManager.getLaunchIntentForPackage(pkg)
            ?: return false
        return start(intent)
    }

    private fun start(intent: Intent): Boolean = try {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
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
        override fun onPackageRemoved(pkg: String, user: UserHandle) = appsChanged()
        override fun onPackageChanged(pkg: String, user: UserHandle) = appsChanged()
        override fun onPackagesAvailable(pkgs: Array<out String>, user: UserHandle, replacing: Boolean) = appsChanged()
        override fun onPackagesUnavailable(pkgs: Array<out String>, user: UserHandle, replacing: Boolean) = appsChanged()
    }

    private fun appsChanged() {
        events?.success(mapOf("type" to "apps"))
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

    private companion object {
        const val STORAGE_REQUEST = 1
    }
}
