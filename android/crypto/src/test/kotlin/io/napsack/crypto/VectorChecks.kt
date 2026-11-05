package io.napsack.crypto

import java.security.PrivateKey
import javax.crypto.SecretKey

/** One check's outcome, as vector-checks.js reports it. */
data class CheckResult(val name: String, val ok: Boolean, val ms: Long, val error: String? = null)

/**
 * shared/crypto/vector-checks.js in Kotlin: the same checks, under the same
 * names, in the same order, against the pinned vectors. Format 1 so far; the
 * others join as each format is ported (VectorTest says which are left).
 */
object VectorChecks {
    fun run(v: Format1): List<CheckResult> {
        val results = mutableListOf<CheckResult>()
        fun check(name: String, fn: () -> Boolean) {
            val start = System.nanoTime()
            val outcome = runCatching(fn)
            val ms = (System.nanoTime() - start) / 1_000_000
            results += CheckResult(name, outcome.getOrDefault(false), ms, outcome.exceptionOrNull()?.let { it.message ?: it.toString() })
        }
        fun fails(fn: () -> Any?): Boolean = runCatching(fn).isFailure
        fun priv(p: Format1.Party): PrivateKey = E2E.privateKey(E2E.fromB64(p.pkcs8))

        lateinit var d: E2E.PasswordKeys
        lateinit var ka: SecretKey
        lateinit var kb: SecretKey

        check("base64 round-trips") { E2E.toB64(E2E.fromB64("AAEC/w==")) == "AAEC/w==" }

        // Password -> keys (the slow one: 600,000 rounds of PBKDF2)
        check("password derives the vector's auth key") {
            d = E2E.deriveFromPassword(v.username, v.password)
            d.authKey == v.authKey
        }
        check("username is case-insensitive") {
            E2E.deriveFromPassword(v.username.lowercase(), v.password).authKey == v.authKey
        }
        check("unwrapped key decrypts the vector text") {
            val unwrapped = E2E.unwrapIdentity(d.wrapKey, v.wrappedPrivateKey)
            val k = E2E.pairKey(unwrapped, v.bob.spki, v.alice.id, v.bob.id)
            E2E.decryptText(k, v.textCiphertext, v.textFrom, v.textTo) == v.textPlaintext
        }
        check("a wrong password can't unwrap") {
            val wrong = E2E.deriveFromPassword(v.username, "wrong password")
            fails { E2E.unwrapIdentity(wrong.wrapKey, v.wrappedPrivateKey) }
        }

        // Both sides derive the same chat key (ECDH + HKDF)
        check("both friends derive the chat key") {
            ka = E2E.pairKey(priv(v.alice), v.bob.spki, v.alice.id, v.bob.id)
            kb = E2E.pairKey(priv(v.bob), v.alice.spki, v.bob.id, v.alice.id)
            ka.encoded.contentEquals(kb.encoded)
        }
        check("recipient decrypts the vector text") {
            E2E.decryptText(kb, v.textCiphertext, v.textFrom, v.textTo) == v.textPlaintext
        }
        check("recipient decrypts the vector pic (format 1)") {
            E2E.toB64(E2E.decryptSnap(kb, E2E.fromB64(v.snapCiphertextB64), v.snapFrom, v.snapTo)) == v.snapPlaintextB64
        }
        check("a fresh text round-trips with a fresh IV") {
            val a = E2E.encryptText(ka, "round trip", v.alice.id, v.bob.id)
            val b = E2E.encryptText(ka, "round trip", v.alice.id, v.bob.id)
            a != b && E2E.decryptText(kb, a, v.alice.id, v.bob.id) == "round trip"
        }

        // Associated data binds sender, recipient, and kind
        check("swapped sender fails") { fails { E2E.decryptText(kb, v.textCiphertext, v.textTo, v.textFrom) } }
        check("a text can't be read as a pic") {
            fails { E2E.decryptSnap(kb, E2E.fromB64(v.textCiphertext), v.textFrom, v.textTo) }
        }
        check("tampering fails") {
            val t = E2E.fromB64(v.textCiphertext)
            t[20] = (t[20].toInt() xor 1).toByte()
            fails { E2E.decryptText(kb, E2E.toB64(t), v.textFrom, v.textTo) }
        }

        // A new account's keys, the way sign-up makes them
        check("a new identity wraps and unwraps") {
            val id = E2E.createIdentity(d.wrapKey)
            val back = E2E.unwrapIdentity(d.wrapKey, id.wrappedPrivateKey)
            val k1 = E2E.pairKey(back, v.bob.spki, 1, v.bob.id)
            val k2 = E2E.pairKey(priv(v.bob), id.publicKey, v.bob.id, 1)
            E2E.decryptText(k2, E2E.encryptText(k1, "new", 1, v.bob.id), 1, v.bob.id) == "new"
        }
        return results
    }
}
