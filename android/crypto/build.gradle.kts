// NapsackCrypto for Android: the formats in plain Kotlin over the Java crypto
// APIs, with no Android in it, so its tests run on any JDK in seconds.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    // Only the tests read JSON (the pinned vectors); the library itself has no dependencies.
    testImplementation(libs.kotlinx.serialization.json)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

// The pinned vectors, read from the repository (never copied): tests/vectors/.
val vectors = rootProject.layout.projectDirectory.dir("../tests/vectors")

tasks.test {
    useJUnitPlatform()
    inputs.dir(vectors).withPropertyName("vectors").withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("napsack.vectors", vectors.asFile.absolutePath)
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
