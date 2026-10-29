package kanin.gtvl

import android.content.Context
import android.content.Intent

/** Starts [intent] in a task of its own; false if nothing could. */
internal fun Context.startNew(intent: Intent): Boolean = try {
    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    true
} catch (e: Exception) {
    false
}

/** Opens the app [pkg], at its TV entry when it has one. */
internal fun Context.launchApp(pkg: String): Boolean {
    val intent = packageManager.getLeanbackLaunchIntentForPackage(pkg)
        ?: packageManager.getLaunchIntentForPackage(pkg)
        ?: return false
    return startNew(intent)
}
