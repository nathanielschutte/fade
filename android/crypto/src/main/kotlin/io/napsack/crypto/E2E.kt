// End-to-end encryption for the Android app: the formats shared/crypto/crypto.js
// defines (the reference implementation), byte for byte. The pinned vectors in
// tests/vectors/ are the contract; when this disagrees with one, this is wrong.
//
// Password -> PBKDF2 (salted with the username) -> master secret, split by HKDF into:
//   auth key: sent to the server in place of the password
//   wrap key: never leaves the device; encrypts the private key the server stores
// Each account has a P-256 key pair. Two friends' keys give them a shared
// AES-GCM key (ECDH + HKDF) that encrypts every text and pic between them.
//
// Only the Java crypto APIs, which Android ships too: no third-party crypto.
// Format 1 so far (the password, the identity, chat keys, texts and pics); the
// other formats follow as the iOS app took them (docs/design/android.md).

package io.napsack.crypto

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

object E2E {
    const val PBKDF2_ITERATIONS = 600_000

    /** Message formats (server/src/version.rs, docs/how-napsack-works.md). Format 1 stays readable forever. */
    const val FORMAT = 1

    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private val random = SecureRandom()

    /** What a password gives: the auth key (base64) the server checks instead of the password, and the wrap key, which never leaves the device. */
    class PasswordKeys(val authKey: String, val wrapKey: SecretKey)

    // ---------- encoding ----------

    /** Throws IllegalArgumentException if it isn't base64. */
    fun fromB64(b64: String): ByteArray = Base64.getDecoder().decode(b64)

    fun toB64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    // ---------- AES-GCM ----------
    // Sealed bytes are IV || ciphertext || tag, as crypto.js writes them. `aad`
    // binds the ciphertext to its context, so the server can't move it to
    // another chat, sender, or kind of message.

    fun seal(key: SecretKey, plaintext: ByteArray, aad: String): ByteArray {
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(aad.toByteArray())
        return iv + cipher.doFinal(plaintext)
    }

    /** Throws (AEADBadTagException) if the key, the associated data, or any byte is wrong. */
    fun open(key: SecretKey, sealed: ByteArray, aad: String): ByteArray {
        require(sealed.size >= IV_BYTES) { "too short to be sealed" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES))
        cipher.updateAAD(aad.toByteArray())
        return cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
    }

    // ---------- password ----------

    /**
     * Slow on purpose (600,000 rounds of PBKDF2; near a second on a phone).
     * Usernames are case-insensitive, so the salt is too. The password reaches
     * PBKDF2 as UTF-8, as TextEncoder gives it to WebCrypto.
     */
    fun deriveFromPassword(username: String, password: String): PasswordKeys {
        val salt = "napsack/v1/user/${username.trim().lowercase()}".toByteArray()
        val spec = PBEKeySpec(password.toCharArray(), salt, PBKDF2_ITERATIONS, 256)
        val master = try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
        try {
            return PasswordKeys(
                authKey = toB64(hkdf(master, ByteArray(0), "napsack/v1/auth")),
                wrapKey = aesKey(hkdf(master, ByteArray(0), "napsack/v1/wrap")),
            )
        } finally {
            master.fill(0)
        }
    }

    /**
     * HKDF-SHA256 (RFC 5869) for 32 bytes, as WebCrypto's HKDF derives them.
     * An empty salt is HashLen zero bytes, which is the same HMAC key (HMAC pads
     * keys with zeros) and one the Java API accepts.
     */
    internal fun hkdf(input: ByteArray, salt: ByteArray, info: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(input)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        prk.fill(0)
        // One block of output is all 32 bytes need: T(1) = HMAC(PRK, info || 0x01).
        mac.update(info.toByteArray())
        mac.update(1.toByte())
        return mac.doFinal()
    }

    private fun aesKey(bytes: ByteArray): SecretKey = SecretKeySpec(bytes, "AES")

    // ---------- identity ----------

    private const val WRAP_AAD = "napsack/v1/identity"

    /** A new account's key pair: the public key (SPKI, base64) for the server, and the private key (PKCS#8) going there only wrapped. */
    class NewIdentity(val publicKey: String, val wrappedPrivateKey: String, val privateKey: PrivateKey)

    fun createIdentity(wrapKey: SecretKey): NewIdentity {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        val pair = generator.generateKeyPair()
        val pkcs8 = pair.private.encoded
        try {
            return NewIdentity(
                publicKey = toB64(pair.public.encoded),
                wrappedPrivateKey = toB64(seal(wrapKey, pkcs8, WRAP_AAD)),
                privateKey = pair.private,
            )
        } finally {
            pkcs8.fill(0)
        }
    }

    /** Throws if the wrap key is wrong (wrong password, or the server swapped the blob). */
    fun unwrapIdentity(wrapKey: SecretKey, wrapped: String): PrivateKey {
        val pkcs8 = open(wrapKey, fromB64(wrapped), WRAP_AAD)
        try {
            return privateKey(pkcs8)
        } finally {
            pkcs8.fill(0)
        }
    }

    /** A P-256 private key as WebCrypto exports it (PKCS#8 DER). */
    fun privateKey(pkcs8: ByteArray): PrivateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    // ---------- a friend's chat key ----------

    /** Both friends derive the same key: ECDH, then HKDF salted with both ids in order. */
    fun pairKey(mine: PrivateKey, theirs: String, myId: Long, theirId: Long): SecretKey {
        val theirKey = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(fromB64(theirs)))
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(mine)
        agreement.doPhase(theirKey, true)
        // The shared point's x coordinate, 32 bytes: what WebCrypto's deriveBits(256) gives.
        val shared = agreement.generateSecret()
        try {
            val (lo, hi) = minOf(myId, theirId) to maxOf(myId, theirId)
            return aesKey(hkdf(shared, "napsack/v1/pair/$lo/$hi".toByteArray(), "napsack/v1/messages"))
        } finally {
            shared.fill(0)
        }
    }

    // ---------- format 1: texts and pics ----------

    fun messageAad(kind: String, sender: Long, recipient: Long): String = "napsack/v1/$kind/$sender/$recipient"

    fun encryptText(key: SecretKey, text: String, sender: Long, recipient: Long): String =
        toB64(seal(key, text.toByteArray(), messageAad("text", sender, recipient)))

    /** Bad UTF-8 becomes U+FFFD, as TextDecoder does. */
    fun decryptText(key: SecretKey, b64: String, sender: Long, recipient: Long): String =
        String(open(key, fromB64(b64), messageAad("text", sender, recipient)))

    fun encryptSnap(key: SecretKey, bytes: ByteArray, sender: Long, recipient: Long): ByteArray =
        seal(key, bytes, messageAad("snap", sender, recipient))

    fun decryptSnap(key: SecretKey, sealed: ByteArray, sender: Long, recipient: Long): ByteArray =
        open(key, sealed, messageAad("snap", sender, recipient))
}
