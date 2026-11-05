// napsack for Android (docs/design/android.md, docs/android-onboarding.md).
// Open this folder (android/) in Android Studio.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    // Fetches JDK 21 for the build when the JDK running Gradle is another one
    // (Android Studio runs Gradle on its own, newer JDK).
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "napsack"
include(":app", ":crypto")
