package io.napsack.crypto

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * The pinned vectors, read from the repository's tests/vectors/ (never copied,
 * never regenerated). Gradle says where they are (crypto/build.gradle.kts);
 * run any other way, they're found by walking up from the working directory.
 */
object Vectors {
    val directory: File by lazy {
        System.getProperty("napsack.vectors")?.let(::File)?.takeIf { it.isDirectory }
            ?: generateSequence(File("").absoluteFile) { it.parentFile }
                .map { File(it, "tests/vectors") }
                .firstOrNull { File(it, "format1.json").isFile }
            ?: error("Can't find tests/vectors/ (the pinned vectors) above ${File("").absolutePath}")
    }

    fun load(name: String): JsonObject = Json.parseToJsonElement(File(directory, "$name.json").readText()).jsonObject
}

/** tests/vectors/format1.json: the original scheme. */
class Format1(json: JsonObject) {
    class Party(o: JsonObject) {
        val id = o.long("id")
        val pkcs8 = o.string("pkcs8")
        val spki = o.string("spki")
    }

    val username = json.obj("password").string("username")
    val password = json.obj("password").string("password")
    val authKey = json.obj("password").string("auth_key")
    val wrappedPrivateKey = json.obj("password").string("wrapped_private_key")
    val alice = Party(json.obj("alice"))
    val bob = Party(json.obj("bob"))
    val textFrom = json.obj("text").long("from")
    val textTo = json.obj("text").long("to")
    val textPlaintext = json.obj("text").string("plaintext")
    val textCiphertext = json.obj("text").string("ciphertext")
    val snapFrom = json.obj("snap").long("from")
    val snapTo = json.obj("snap").long("to")
    val snapPlaintextB64 = json.obj("snap").string("plaintext_b64")
    val snapCiphertextB64 = json.obj("snap").string("ciphertext_b64")
}

private fun JsonObject.obj(key: String) = getValue(key).jsonObject
private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content
private fun JsonObject.long(key: String) = getValue(key).jsonPrimitive.long
