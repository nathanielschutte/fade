package io.napsack.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import io.napsack.crypto.E2E
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.measureTime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The development screen, until the real app has screens: which server this
 * app talks to and what it says about itself, and how long a sign-in's key
 * derivation takes on this phone (it has to stay near a second; mobile.md).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerScreen() {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("development", Context.MODE_PRIVATE) }
    var address by rememberSaveable { mutableStateOf(prefs.getString("server", null) ?: AppInfo.DEFAULT_SERVER) }
    // Kept across a rotation or a change of text size, which start the screen again.
    var config by rememberSaveable(stateSaver = configSaver) { mutableStateOf<ServerConfig?>(null) }
    var problem by rememberSaveable { mutableStateOf<String?>(null) }
    var checking by remember { mutableStateOf(false) }
    // Which check is current: an answer for an older one (or an address since changed) is dropped.
    var attempt by remember { mutableIntStateOf(0) }
    var derivation by rememberSaveable(stateSaver = durationSaver) { mutableStateOf<Duration?>(null) }
    var deriving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun check() {
        val mine = ++attempt
        checking = true
        prefs.edit().putString("server", address.trim()).apply()
        scope.launch {
            val outcome = try {
                Result.success(Server(address).config())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
            if (mine != attempt) return@launch
            checking = false
            config = outcome.getOrNull()
            problem = outcome.exceptionOrNull()?.let { it.message ?: "That didn't work: ${it.javaClass.simpleName}." }
        }
    }

    // A development server on this computer or the network: Android 17 asks first (LocalNetwork).
    fun needsLocalNetwork(): Boolean {
        val host = runCatching { Server(address).base.host }.getOrNull() ?: return false
        return BuildConfig.DEBUG && Build.VERSION.SDK_INT >= LocalNetwork.FIRST_SDK && LocalNetwork.includes(host) &&
            context.checkSelfPermission(LocalNetwork.PERMISSION) != PackageManager.PERMISSION_GRANTED
    }
    val askLocalNetwork = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if (allowed) {
            check()
        } else {
            config = null
            problem = "napsack isn't allowed to reach your network, so it can't reach that server. Allow Nearby devices in its app settings (Permissions), then check again."
        }
    }
    fun checkOrAsk() = if (needsLocalNetwork()) askLocalNetwork.launch(LocalNetwork.PERMISSION) else check()

    fun timeDerivation() {
        deriving = true
        scope.launch {
            // Off the main thread: it's slow on purpose.
            derivation = withContext(Dispatchers.Default) {
                measureTime { E2E.deriveFromPassword("timing", "correct horse battery") }
            }
            deriving = false
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("napsack") }) },
        contentWindowInsets = WindowInsets.safeDrawing,
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Section("Server") {
                OutlinedTextField(
                    value = address,
                    onValueChange = {
                        address = it
                        // What's shown was for the old address.
                        attempt++
                        checking = false
                        config = null
                        problem = null
                    },
                    placeholder = { Text("https://staging.napsack.io") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrectEnabled = false,
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Go,
                    ),
                    keyboardActions = KeyboardActions(onGo = { if (!checking) checkOrAsk() }),
                    modifier = Modifier.fillMaxWidth().testTag("address"),
                )
                Button(onClick = ::checkOrAsk, enabled = !checking, modifier = Modifier.testTag("check")) {
                    Text(if (checking) "Checking…" else "Check")
                }
                problem?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("problem")) }
                config?.let { c ->
                    Labeled("Version", c.serverVersion, "serverVersion")
                    Labeled("Build", c.build, "serverBuild")
                    Labeled("Environment", c.environment ?: "none (production or development)")
                    Labeled("Message formats", c.messageFormats.joinToString(", "))
                    Labeled("Group formats", c.groupMessageFormats?.joinToString(", ") ?: "not listed")
                    c.updateNeeded()?.let { minimum ->
                        Text(
                            "This server needs napsack $minimum or newer. Update the app to use it.",
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("updateNeeded"),
                        )
                    }
                }
            }
            Section("This app") {
                Labeled("Version", "${AppInfo.VERSION} (${AppInfo.BUILD})")
                Labeled("Says it is", AppInfo.CLIENT_HEADER)
            }
            Section("Encryption", footer = "Made up credentials; nothing is sent anywhere.") {
                Button(onClick = ::timeDerivation, enabled = !deriving, modifier = Modifier.testTag("derive")) {
                    Text(if (deriving) "Deriving…" else "Time a sign-in's key derivation")
                }
                derivation?.let { Labeled("600,000 rounds of PBKDF2", formatDuration(it), "derivation") }
            }
        }
    }
}

/** A group of rows on a raised panel, under a small heading. */
@Composable
private fun Section(title: String, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(color = Palette.deep, shape = RoundedCornerShape(14.dp), modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(PaddingValues(16.dp)), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
        }
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

/**
 * A label and its value: on one line, the value at the end, when they fit;
 * otherwise the value goes under the label, with the whole width to wrap in
 * (large text never breaks a word).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Labeled(label: String, value: String, tag: String? = null) {
    FlowRow(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 12.dp))
        Text(value, modifier = if (tag != null) Modifier.testTag(tag) else Modifier)
    }
}

private val configSaver = Saver<ServerConfig?, String>(save = { it?.encode() }, restore = { ServerConfig.decode(it) })
private val durationSaver = Saver<Duration?, Long>(save = { it?.inWholeMilliseconds }, restore = { it.milliseconds })

private fun formatDuration(d: Duration): String {
    val ms = d.inWholeMilliseconds
    return if (ms < 1000) "$ms ms" else String.format(Locale.ROOT, "%.2f s", ms / 1000.0)
}

@Preview
@Composable
private fun ServerScreenPreview() {
    NapsackTheme { ServerScreen() }
}
