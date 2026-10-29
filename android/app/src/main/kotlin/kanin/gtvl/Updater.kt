package kanin.gtvl

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import java.io.File
import java.security.MessageDigest

/**
 * GTVL's own updates, which the Flutter side downloads from GTVL's GitHub
 * releases. Nothing is installed until [check] has found the APK to be the
 * size and SHA-256 its release names, GTVL itself, newer than this copy, and
 * signed with the same key; Android checks the key again as it installs.
 *
 * From Android 12, GTVL may update itself without asking; older Android
 * asks the user to confirm each update.
 */
class Updater(private val context: Context) {
    private val packages = context.packageManager

    /** This copy's version, what Android allows, and the room for a download. */
    fun about(): Map<String, Any> {
        val info = packages.getPackageInfo(context.packageName, 0)
        return mapOf(
            "version" to (info.versionName ?: ""),
            "build" to info.code,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "allowed" to packages.canRequestPackageInstalls(),
            "quiet" to (Build.VERSION.SDK_INT >= 31),
            "room" to StatFs(context.cacheDir.path).availableBytes,
        )
    }

    /**
     * Why the APK at [path] must not be installed: "size" or "checksum"
     * (not what its release names), "unreadable", "package" (not GTVL),
     * "older" (not newer than this copy), "android" (needs a newer one) or
     * "signer" (not GTVL's key). Null if it may.
     */
    @Suppress("DEPRECATION") // the flag-object forms need Android 13
    fun check(path: String, size: Long, sha256: String): String? {
        val apk = File(path)
        if (!apk.isFile || apk.length() != size) return "size"
        if (sha256Of(apk) != sha256.lowercase()) return "checksum"
        val archive = packages.getPackageArchiveInfo(path, withSigners) ?: return "unreadable"
        val installed = packages.getPackageInfo(context.packageName, withSigners)
        return when {
            archive.packageName != context.packageName -> "package"
            archive.code <= installed.code -> "older"
            (archive.applicationInfo?.minSdkVersion ?: 0) > Build.VERSION.SDK_INT -> "android"
            !sameKey(archive, installed) -> "signer"
            else -> null
        }
    }

    /** Signed with this copy's key, or with a later key this one passed on to. */
    private fun sameKey(archive: PackageInfo, installed: PackageInfo): Boolean {
        val ours = signers(installed, lineage = false)
        return ours.isNotEmpty() && signers(archive, lineage = true).containsAll(ours)
    }

    // Android 8 has neither the signing history nor the long version code:
    // there, the signatures themselves and the int code.
    @Suppress("DEPRECATION")
    private val withSigners = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    /** [info]'s signing certificates; with [lineage], also those its key took over from (Android 9 on). */
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo, lineage: Boolean): List<String> {
        if (Build.VERSION.SDK_INT < 28) return info.signatures?.map { it.toCharsString() }.orEmpty()
        val signing = info.signingInfo ?: return emptyList()
        val certificates = if (lineage && !signing.hasMultipleSigners()) signing.signingCertificateHistory else signing.apkContentsSigners
        return certificates?.map { it.toCharsString() }.orEmpty()
    }

    @Suppress("DEPRECATION")
    private val PackageInfo.code: Long
        get() = if (Build.VERSION.SDK_INT >= 28) longVersionCode else versionCode.toLong()

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Hands the checked APK at [path] to Android's installer. Its answer
     * comes to [UpdateReceiver]; on success Android ends GTVL's process, and
     * with [relaunch] GTVL comes back on screen. [quiet]: never ask the user
     * (an update at standby); one that would have to waits for them instead.
     */
    fun install(path: String, quiet: Boolean, relaunch: Boolean) {
        val apk = File(path)
        val installer = packages.packageInstaller
        // A session left from an earlier try would only hold space.
        for (session in installer.mySessions) runCatching { installer.abandonSession(session.sessionId) }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("gtvl.apk", 0, apk.length()).use { output ->
                    input.copyTo(output, 1 shl 16)
                    session.fsync(output)
                }
            }
            // Written now, not later: the process ends as the update goes in.
            prefs(context).edit().putLong(RELAUNCH, if (relaunch) System.currentTimeMillis() else 0).commit()
            val answer = Intent(context, UpdateReceiver::class.java).setAction(STATUS).putExtra(QUIET, quiet)
            // Mutable: the installer adds its answer to it.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            session.commit(PendingIntent.getBroadcast(context, id, answer, flags).intentSender)
        }
    }

    /**
     * Opens Android's switch that lets GTVL install apps: its own page where
     * the TV has one, else the list of apps, else security settings. TVs
     * send the pages they lack to a stub that only says so.
     */
    fun allow(): Boolean {
        val pages = listOf(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")),
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES),
            Intent(Settings.ACTION_SECURITY_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        val page = pages.firstOrNull { page ->
            packages.resolveActivity(page, 0)?.activityInfo?.packageName.let { it != null && it != MainActivity.STUBS }
        } ?: pages.last()
        return context.startNew(page)
    }

    companion object {
        const val STATUS = "kanin.gtvl.UPDATE_STATUS"
        const val QUIET = "quiet"

        /** When an update began with GTVL on screen; 0 if it didn't. */
        const val RELAUNCH = "relaunchAfterUpdate"

        fun prefs(context: Context): SharedPreferences = context.getSharedPreferences("gtvl", Context.MODE_PRIVATE)
    }
}

/**
 * Android's installer answering an update, and GTVL starting again after
 * one. Not exported: only Android and GTVL itself can reach it.
 */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> relaunch(context)
            Updater.STATUS -> answer(context, intent)
        }
    }

    /**
     * GTVL was on screen as its update began: back on screen, rather than
     * the app shown before it. Android lets the home app start itself.
     */
    private fun relaunch(context: Context) {
        val prefs = Updater.prefs(context)
        val began = prefs.getLong(Updater.RELAUNCH, 0)
        prefs.edit().remove(Updater.RELAUNCH).apply()
        if (began > 0 && System.currentTimeMillis() - began < 10 * 60_000) {
            context.startNew(Intent(context, MainActivity::class.java))
        }
    }

    private fun answer(context: Context, intent: Intent) {
        val quiet = intent.getBooleanExtra(Updater.QUIET, false)
        val what = when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Only Android and GTVL can reach this receiver, so this is the installer's own screen.
                val confirm = confirmation(intent)
                if (!quiet && confirm != null && context.startNew(confirm)) {
                    "confirm"
                } else {
                    // An update at standby must not ask: it waits for the user in About.
                    runCatching {
                        context.packageManager.packageInstaller.abandonSession(intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1))
                    }
                    "waiting"
                }
            }
            PackageInstaller.STATUS_SUCCESS -> "installed"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "cancelled"
            else -> "failed"
        }
        if (what != "confirm" && what != "installed") Updater.prefs(context).edit().remove(Updater.RELAUNCH).apply()
        onStatus?.invoke(mapOf("type" to "update", "what" to what, "message" to intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)))
    }

    @Suppress("DEPRECATION") // the typed form needs Android 13
    private fun confirmation(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_INTENT)

    companion object {
        /** Hears the installer's answers while GTVL runs, as {type: update, what, message}. */
        var onStatus: ((Map<String, Any?>) -> Unit)? = null
    }
}
