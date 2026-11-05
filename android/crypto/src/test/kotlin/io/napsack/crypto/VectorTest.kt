package io.napsack.crypto

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory

/**
 * Every check in VectorChecks (shared/crypto/vector-checks.js in Kotlin)
 * against the pinned vectors, read from the repository: one test per check, by
 * its name.
 */
class VectorTest {
    companion object {
        val results: List<CheckResult> by lazy { VectorChecks.run(Format1(Vectors.load("format1"))) }

        // vector-checks.js's names, less its two browser-platform checks (WebCrypto,
        // TextEncoder). From: node, runVectorChecks(...).map((r) => r.name).
        val javaScript = listOf(
            "base64 round-trips",
            "password derives the vector's auth key",
            "username is case-insensitive",
            "unwrapped key decrypts the vector text",
            "a wrong password can't unwrap",
            "both friends derive the chat key",
            "recipient decrypts the vector text",
            "recipient decrypts the vector pic (format 1)",
            "a fresh text round-trips with a fresh IV",
            "swapped sender fails",
            "a text can't be read as a pic",
            "tampering fails",
            "recipient decrypts format 2 pic",
            "packs pic like the vector",
            "recipient decrypts format 2 pic_no_caption",
            "packs pic_no_caption like the vector",
            "format 2 can't be read as format 1",
            "a captioned pic round-trips",
            "a new identity wraps and unwraps",
            "format 2 text 1 decrypts like the vector",
            "format 2 text 2 decrypts like the vector",
            "format 1 texts still read, with no reply",
            "a format 2 text can't be read as format 1",
            "unknown envelope fields are ignored",
            "malformed envelopes are refused",
            "reaction decrypts like the vector",
            "a reaction can't move to another message",
            "a reaction round-trips",
            "group wrap keys for bob and alice",
            "group text decrypts like the vector",
            "the sender's own devices read it too",
            "group pic decrypts like the vector, caption and all",
            "one member's wrap doesn't open for another",
            "a group message can't move to another group",
            "or claim a different member list",
            "a group text can't be read as a pic",
            "changed content fails",
            "a new group message round-trips",
            "a format 4 video decrypts like the vector, caption and all",
            "a video can't be read as a pic",
            "a format 5 group video decrypts like the vector",
            "a group video can't be read as a group pic",
            "only video types travel in the envelope",
            "a video round-trips",
            "a format 6 photo decrypts like the vector, caption and place",
            "a photo can't be read as a video or a format 2 pic",
            "a format 7 group photo decrypts like the vector, with no place",
            "only JPEGs travel as photos",
            "a direct edit decrypts like the vector",
            "an edit can't be moved to another message",
            "an edit can't be read as a text",
            "a group edit decrypts like the vector",
            "recovery key displays like the vector",
            "recovery key reads back despite typos",
            "recovery key derives the vector's auth key",
            "recovery key unlocks the vector's private key",
            "a recovery copy round-trips",
            "the password-wrapped key can't pass as a recovery copy",
            "a wrong recovery key can't unlock",
            "malformed recovery keys are refused",
            "changing the password keeps the same key",
            "the passkey PRF input matches the vector",
            "a passkey's copy of the key opens like the vector",
            "a passkey copy round-trips",
            "another passkey, or the password's copy, can't pass as it",
            "safety code matches the vector",
            "safety code is symmetric",
            "new texts and pics are format 2",
        )

        /** The ones only format 1 needs, which this port makes so far. */
        val format1 = listOf(
            "base64 round-trips",
            "password derives the vector's auth key",
            "username is case-insensitive",
            "unwrapped key decrypts the vector text",
            "a wrong password can't unwrap",
            "both friends derive the chat key",
            "recipient decrypts the vector text",
            "recipient decrypts the vector pic (format 1)",
            "a fresh text round-trips with a fresh IV",
            "swapped sender fails",
            "a text can't be read as a pic",
            "tampering fails",
            "a new identity wraps and unwraps",
        )
    }

    @TestFactory
    fun checks() = results.map { r ->
        DynamicTest.dynamicTest(r.name) {
            assertTrue(r.ok, "${r.name}: ${r.error ?: "the check came out false"}")
        }
    }

    /**
     * The same checks as JavaScript's, in JavaScript's order, under its names.
     * When every format is ported this becomes `results == javaScript`, as the
     * iOS app's VectorTests has it.
     */
    @Test
    fun sameChecksAsJavaScript() {
        val names = results.map { it.name }
        assertEquals(format1, names)
        assertEquals(javaScript.filter { it in names }, names, "in JavaScript's order")
    }

    @Test
    fun refusesWhatIsntBase64() {
        assertThrows(IllegalArgumentException::class.java) { E2E.fromB64("not base64!") }
    }
}
