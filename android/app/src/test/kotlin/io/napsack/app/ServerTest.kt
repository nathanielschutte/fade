package io.napsack.app

import java.io.File
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ServerTest {
    /** A real answer from GET /api/config (staging, 0.42.0). */
    private val staging = """
        {"api_version":1,"build":"aa3aa6a","environment":"staging","group_message_formats":[0,3,5,7],"invite_required":true,
        "message_formats":[1,2,4,6],"min_client_versions":{},"server_version":"0.42.0","snap_max_bytes":524288,
        "snap_ttl_hours":720,"started_at":1793304049,"vapid_public_key":"BCTu","video_max_bytes":4194304,"video_max_seconds":10}
    """.trimIndent()

    @Test
    fun readsTheServersConfig() {
        val config = ServerConfig.decode(staging)
        assertEquals("0.42.0", config.serverVersion)
        assertEquals("staging", config.environment)
        assertEquals(listOf(1, 2, 4, 6), config.messageFormats)
        assertEquals(listOf(0, 3, 5, 7), config.groupMessageFormats)
        assertNull(config.minimumAndroid)
        assertNull(config.updateNeeded("0.1.0"))
        // What the screen keeps across a rotation reads back the same.
        assertEquals(config, ServerConfig.decode(config.encode()))
    }

    @Test
    fun readsAnOlderServerAndProduction() {
        // Before 0.42.0 there were no group formats; production's environment is null.
        val json = staging
            .replace("\"group_message_formats\":[0,3,5,7],", "")
            .replace("\"staging\"", "null")
            .replace("{}", "{\"ios\":\"1.2.0\",\"android\":\"1.2.0\"}")
        val config = ServerConfig.decode(json)
        assertNull(config.groupMessageFormats)
        assertNull(config.environment)
        assertEquals("1.2.0", config.minimumAndroid)
        assertEquals("1.2.0", config.updateNeeded("1.1.9"))
        assertNull(config.updateNeeded("1.2.0"))
    }

    @Test
    fun onlyTheAndroidMinimumCounts() {
        val config = ServerConfig.decode(staging.replace("{}", "{\"ios\":\"9.0.0\"}"))
        assertNull(config.updateNeeded("0.1.0"))
    }

    @Test
    fun comparesVersionsLikeTheServer() {
        assertTrue(ClientVersion.isOlder("1.1.99", than = "1.2.0"))
        assertFalse(ClientVersion.isOlder("1.2.0", than = "1.2.0"))
        assertFalse(ClientVersion.isOlder("1.10.0", than = "1.9.0"))
        assertTrue(ClientVersion.isOlder("0.1.0+7", than = "1"))
        assertFalse(ClientVersion.isOlder("1.2.0-beta", than = "1.2"))
        // What the server can't read (version.rs, Semver::parse), it doesn't turn away.
        assertEquals(null, ClientVersion.parse("1.2.3.4"))
        assertEquals(null, ClientVersion.parse("one"))
        assertFalse(ClientVersion.isOlder("one", than = "1.0.0"))
    }

    @Test
    fun acceptsOnlyWebAddresses() {
        assertEquals("https://staging.napsack.io/api/config", Server("https://staging.napsack.io").request("config").url.toString())
        assertEquals("http://10.0.2.2:8080/api/config", Server(" http://10.0.2.2:8080 ").request("config").url.toString())
        assertThrows(ServerError.BadAddress::class.java) { Server("staging.napsack.io") }
        assertThrows(ServerError.BadAddress::class.java) { Server("ftp://example.com") }
    }

    @Test
    fun knowsWhichAddressesAreTheLocalNetwork() {
        // What Android 17 asks about first: the emulator's name for this computer, home networks, .local names.
        for (host in listOf("10.0.2.2", "192.168.1.20", "172.20.0.5", "169.254.1.1", "nates-mac.local", "fd12::1", "fe80::1")) {
            assertTrue(LocalNetwork.includes(host), host)
        }
        for (host in listOf("api.napsack.io", "staging.napsack.io", "localhost", "127.0.0.1", "172.32.0.1", "8.8.8.8", "10.0.2.2.example.com")) {
            assertFalse(LocalNetwork.includes(host), host)
        }
    }

    @Test
    fun saysWhichAppItIs() {
        val request = Server("https://staging.napsack.io").request("config")
        assertEquals("android/${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}", request.header("X-Napsack-Client"))
    }

    @Test
    fun releaseBuildsUseHttpsOnly() {
        // The network rules every build starts from: plain http is allowed only by the debug
        // build's own copy (src/debug/res/xml). scripts/test-android.sh checks the release APK itself.
        val main = File("src/main/res/xml/network_security_config.xml").readText()
        assertFalse(main.contains("cleartextTrafficPermitted=\"true\""), "src/main's network_security_config allows plain http")
        assertTrue(main.contains("cleartextTrafficPermitted=\"false\""))
    }
}
