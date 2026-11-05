package io.napsack.app

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Who this app is to a server. Every request says `X-Napsack-Client:
 * android/<version>+<build>`, so the server can turn away an app older than it
 * supports (docs/operations/releasing.md, rule 4).
 */
object AppInfo {
    const val VERSION = BuildConfig.VERSION_NAME
    const val BUILD = BuildConfig.VERSION_CODE
    const val CLIENT_HEADER = "android/$VERSION+$BUILD"

    /** The server this build starts on (app/build.gradle.kts); the app can be pointed elsewhere. */
    const val DEFAULT_SERVER = BuildConfig.SERVER_URL
}

/** GET /api/config: what a client needs before signing in (docs/spec/api.md). */
@Serializable
data class ServerConfig(
    @SerialName("server_version") val serverVersion: String,
    val build: String,
    @SerialName("api_version") val apiVersion: Int,
    /** "staging" on non-production copies; null in production. */
    val environment: String? = null,
    @SerialName("invite_required") val inviteRequired: Boolean,
    @SerialName("message_formats") val messageFormats: List<Int>,
    /** Servers before 0.42.0 don't say. */
    @SerialName("group_message_formats") val groupMessageFormats: List<Int>? = null,
    @SerialName("min_client_versions") val minClientVersions: Map<String, String>,
) {
    /** The oldest Android app this server still serves, if it has a minimum. */
    val minimumAndroid: String? get() = minClientVersions["android"]

    /** The newer app this server needs, or null if this one will do. */
    fun updateNeeded(version: String = AppInfo.VERSION): String? =
        minimumAndroid?.takeIf { ClientVersion.isOlder(version, than = it) }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun decode(text: String): ServerConfig = json.decodeFromString(serializer(), text)
    }

    fun encode(): String = Json.encodeToString(serializer(), this)
}

/** What went wrong talking to a server, in words for the screen. */
sealed class ServerError(message: String) : Exception(message) {
    class BadAddress : ServerError("That isn't a server address. Try one like https://staging.napsack.io.")
    class Status(val code: Int) : ServerError("The server answered $code.")
    class NotNapsack : ServerError("That server answered, but not like a napsack server. Check the address.")
    class Unreachable(cause: IOException) :
        ServerError("Couldn't reach that server (${cause.message ?: cause.javaClass.simpleName}). Check the address, and that it's running.")
}

class Server(address: String) {
    val base: HttpUrl = address.trim().toHttpUrlOrNull()?.takeIf { it.host.isNotEmpty() } ?: throw ServerError.BadAddress()

    fun request(path: String): Request = Request.Builder()
        .url(base.newBuilder().addPathSegment("api").addPathSegments(path).build())
        .header("X-Napsack-Client", AppInfo.CLIENT_HEADER)
        .build()

    suspend fun config(): ServerConfig = withContext(Dispatchers.IO) {
        try {
            http.newCall(request("config")).execute().use { response ->
                if (response.code != 200) throw ServerError.Status(response.code)
                val body = response.body.string()
                try {
                    ServerConfig.decode(body)
                } catch (_: IllegalArgumentException) {
                    // kotlinx.serialization's errors are IllegalArgumentExceptions: not JSON, or not this JSON.
                    throw ServerError.NotNapsack()
                }
            }
        } catch (e: IOException) {
            throw ServerError.Unreachable(e)
        }
    }

    companion object {
        /** One client for the app, as OkHttp wants: it shares connections and threads. */
        val http: OkHttpClient = OkHttpClient.Builder()
            .callTimeout(15, TimeUnit.SECONDS)
            .build()
    }
}

/**
 * Android 17 asks the person before an app targeting it reaches the local
 * network, which includes a development server (the emulator's 10.0.2.2 is a
 * private address). Debug builds declare it (src/debug/AndroidManifest.xml);
 * release builds never need it.
 */
object LocalNetwork {
    const val PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    const val FIRST_SDK = 37

    /** Private and link-local addresses, and `.local` names. Loopback (`adb reverse`) isn't the network. */
    fun includes(host: String): Boolean {
        val h = host.lowercase().trimEnd('.')
        if (h.endsWith(".local")) return true
        val v4 = h.split('.').mapNotNull { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
        if (v4.size == 4 && h.count { it == '.' } == 3) {
            val (a, b) = v4
            return a == 10 || (a == 172 && b in 16..31) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        // IPv6 unique local (fc00::/7) and link-local (fe80::/10).
        return h.contains(':') && (h.startsWith("fc") || h.startsWith("fd") || h.matches(Regex("^fe[89ab].*")))
    }
}

/**
 * App versions compared the way the server compares them (server/src/version.rs,
 * `Semver`): up to three numbers, dot by dot (1.10.0 is newer than 1.9.0); a
 * "-pre" or "+build" suffix doesn't count. A version the server couldn't read
 * isn't checked there, so it isn't older here either.
 */
object ClientVersion {
    fun parse(version: String): Triple<Long, Long, Long>? {
        val core = version.trim().split('+', '-').first()
        val parts = core.split('.')
        if (parts.size > 3) return null
        val numbers = parts.map { it.toLongOrNull()?.takeIf { n -> n >= 0 } ?: return null }
        return Triple(numbers[0], numbers.getOrElse(1) { 0 }, numbers.getOrElse(2) { 0 })
    }

    fun isOlder(version: String, than: String): Boolean {
        val a = parse(version) ?: return false
        val b = parse(than) ?: return false
        return compareValuesBy(a, b, { it.first }, { it.second }, { it.third }) < 0
    }
}
