// Makes sdks/android a standalone Gradle build: Gradle refuses to configure a project with no
// settings file.
//
// Build and test it with the `assembleRelease` and `testDebugUnitTest` tasks.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "treebars-sdk-android"
