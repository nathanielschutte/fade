package io.napsack.app

import android.os.Build
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The development screen on the emulator, live against a real local server.
 * scripts/test-android.sh starts a fresh one and passes its address (as the
 * emulator sees it) and its version as instrumentation arguments; without
 * them, these skip.
 */
@RunWith(AndroidJUnit4::class)
class ServerScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val args = InstrumentationRegistry.getArguments()
    private val server: String? = args.getString("napsackServer")
    private val serverVersion: String? = args.getString("napsackServerVersion")

    @Test
    fun showsTheServersVersion() {
        assumeTrue("no napsackServer argument (scripts/test-android.sh passes one)", server != null && serverVersion != null)
        // The question the screen would ask (Android 17: reaching this computer is local network access), answered yes.
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (Build.VERSION.SDK_INT >= LocalNetwork.FIRST_SDK) {
            instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, LocalNetwork.PERMISSION)
        }
        compose.setContent { NapsackTheme { ServerScreen() } }

        compose.onNodeWithTag("address").performTextReplacement(server!!)
        compose.onNodeWithTag("check").performClick()
        // Whichever comes first: the server's version, or the problem the screen shows.
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasTestTag("serverVersion")).fetchSemanticsNodes().isNotEmpty() ||
                compose.onAllNodes(hasTestTag("problem")).fetchSemanticsNodes().isNotEmpty()
        }
        val problem = compose.onAllNodes(hasTestTag("problem")).fetchSemanticsNodes().firstOrNull()
        assertNull("the screen says: ${problem?.config?.getOrNull(SemanticsProperties.Text)?.joinToString()}", problem)
        compose.onNodeWithTag("serverVersion").assertTextEquals(serverVersion!!)
        // The test server needs no particular Android version (scripts/test-android.sh).
        compose.onNodeWithTag("updateNeeded").assertDoesNotExist()
    }

    @Test
    fun timesTheKeyDerivationOnTheDevice() {
        compose.setContent { NapsackTheme { ServerScreen() } }
        compose.onNodeWithTag("derive").performClick()
        // 600,000 rounds: about a second on a phone, slower on an emulator.
        compose.waitUntil(60_000) { compose.onAllNodes(hasTestTag("derivation")).fetchSemanticsNodes().isNotEmpty() }
    }
}
