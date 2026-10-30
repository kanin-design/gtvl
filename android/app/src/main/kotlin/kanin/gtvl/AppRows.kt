package kanin.gtvl

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.tv.TvContract
import android.media.tv.TvContract.Channels
import android.media.tv.TvContract.WatchNextPrograms
import android.net.Uri
import android.util.Log
import java.io.File
import kotlin.math.ceil

/** Reading other apps' rows takes this, which the user grants once. */
internal const val TV_LISTINGS = "android.permission.READ_TV_LISTINGS"

private const val TAG = "GTVL.rows"

/**
 * The rows other apps share with the home screen, as Android's TV listings
 * hold them: what is being watched in each app (its Watch Next programs),
 * and each app's own channels with their programs. Null until GTVL may read
 * TV listings; then Android hands over every row an app hasn't hidden.
 */
internal fun Context.appRows(): Map<String, Any>? {
    if (checkSelfPermission(TV_LISTINGS) != PackageManager.PERMISSION_GRANTED) return null
    fun shown(row: Map<String, Any?>) = row["browsable"] != 0L && row["package_name"] != packageName
    val watchNext = query(WatchNextPrograms.CONTENT_URI).filter(::shown).map(::item)
    val channels = query(Channels.CONTENT_URI)
        .filter { it[Channels.COLUMN_TYPE] == Channels.TYPE_PREVIEW && it[Channels.COLUMN_BROWSABLE] == 1L && shown(it) }
        .map { channel ->
            val pkg = channel[Channels.COLUMN_PACKAGE_NAME] as String
            mapOf(
                "app" to pkg,
                "appName" to appName(pkg),
                "name" to channel[Channels.COLUMN_DISPLAY_NAME],
                "programs" to query(TvContract.buildPreviewProgramsUriForChannel(channel["_id"] as Long))
                    .filter(::shown)
                    .sortedByDescending { it["weight"] as? Long ?: 0 }
                    .map(::item),
            )
        }
    Log.i(
        TAG,
        "watch next: ${watchNext.groupingBy { it["app"] }.eachCount()}; " +
            "channels: ${channels.map { "${it["app"]}/${it["name"]} (${(it["programs"] as List<*>).size})" }}; " +
            "pictures: ${(watchNext + channels.flatMap { it["programs"] as List<Map<String, Any?>> })
                .mapNotNull { (it["image"] as? String)?.substringBefore(':') }.groupingBy { it }.eachCount()}",
    )
    return mapOf("watchNext" to watchNext.map { it + ("appName" to appName(it["app"] as String)) }, "channels" to channels)
}

/**
 * One program, as a row's card shows it. The columns are TvContract's,
 * shared by Watch Next and preview programs.
 */
private fun item(p: Map<String, Any?>): Map<String, Any?> {
    fun text(column: String) = (p[column] as? String)?.takeIf(String::isNotBlank)
    val season = text("season_display_number")
    val episode = text("episode_display_number")
    val position = p["last_playback_position_millis"] as? Long ?: 0
    val duration = p["duration_millis"] as? Long ?: 0
    val started = duration > 0 && position > 0
    // A 16:9 poster (aspect ratio 0) fits the card as it is; otherwise the thumbnail, which is usually wide.
    val poster = text("poster_art_uri")
    return mapOf(
        "app" to p["package_name"],
        "title" to text("title"),
        "subtitle" to listOfNotNull(
            listOfNotNull(season?.let { "S$it" }, episode?.let { "E$it" }).joinToString(" ").ifEmpty { null },
            text("episode_title"),
        ).joinToString(" · ").ifEmpty { null },
        "summary" to text("short_description"),
        "image" to (if (p["poster_art_aspect_ratio"] == 0L) poster else text("thumbnail_uri") ?: poster),
        "link" to text("intent_uri"),
        "progress" to (if (started) position.toDouble() / duration else null),
        "minutesLeft" to (if (started) ceil((duration - position) / 60000.0).toLong() else null),
        "time" to (p[WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS] as? Long ?: 0),
    )
}

private fun Context.appName(pkg: String): String =
    runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }
        .getOrDefault(pkg)

/** Every row of [uri] Android lets GTVL read, as column name to value. */
private fun Context.query(uri: Uri): List<Map<String, Any?>> = runCatching {
    contentResolver.query(uri, null, null, null, null)?.use { c ->
        buildList {
            while (c.moveToNext()) {
                add(
                    (0 until c.columnCount).associate { i ->
                        c.getColumnName(i) to when (c.getType(i)) {
                            Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                            Cursor.FIELD_TYPE_STRING -> c.getString(i)
                            Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                            else -> null
                        }
                    },
                )
            }
        }
    }.orEmpty()
}.getOrElse {
    Log.w(TAG, "Could not read $uri", it)
    emptyList()
}

/**
 * Opens [address] in [pkg]: an app's own link to a program ("intent:"),
 * or a plain link. A link that names no app goes to [pkg], one that names
 * another app is refused (it could be the installer, which GTVL may now
 * use), and none may hand out access to files.
 */
internal fun Context.openLink(address: String, pkg: String?): Boolean {
    val intent = runCatching {
        if (address.startsWith("intent:") || address.contains("#Intent;")) {
            Intent.parseUri(address, Intent.URI_INTENT_SCHEME).apply {
                selector = null
                flags = flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()
                if (component == null && `package` == null) setPackage(pkg)
            }.takeIf { pkg == null || (it.component?.packageName ?: it.`package`) == pkg }
        } else {
            Intent(Intent.ACTION_VIEW, Uri.parse(address)).setPackage(pkg)
        }
    }.getOrNull()
    return intent != null && startNew(intent) || pkg != null && launchApp(pkg)
}

/**
 * A picture an app shares by its own address (content: or
 * android.resource:), as a small cached JPEG; Flutter loads web addresses
 * itself. Null when the app doesn't let GTVL read it.
 */
internal fun Context.picture(address: String): String? {
    val file = File(File(cacheDir, "pictures").apply { mkdirs() }, "${address.hashCode().toUInt()}.jpg")
    if (file.length() > 0) return file.path
    return runCatching {
        val bitmap = contentResolver.openInputStream(Uri.parse(address))?.use(BitmapFactory::decodeStream) ?: return null
        val small = Bitmap.createScaledBitmap(bitmap, 480, 480 * bitmap.height / bitmap.width, true)
        small.saveTo(file, Bitmap.CompressFormat.JPEG, 85)
        file.path
    }.getOrNull()
}

/**
 * Writes the picture to [file] whole or not at all: into a ".part" file,
 * onto the disk, then renamed into place, so power lost mid-write never
 * leaves an empty or broken picture for a cache to keep handing out.
 */
internal fun Bitmap.saveTo(file: File, format: Bitmap.CompressFormat, quality: Int) {
    val part = File(file.path + ".part")
    part.outputStream().use {
        compress(format, quality, it)
        it.fd.sync()
    }
    if (!part.renameTo(file)) part.delete()
}
