plugins {
    // Pinned to the AGP and Kotlin versions React Native's Gradle plugin names, so this module can
    // sit in the same build tree as a React Native app: AGP refuses to run as two versions of
    // itself in one build.
    id("com.android.library") version "8.12.0"
    id("org.jetbrains.kotlin.android") version "2.1.20"
    // 0.35.0 and not later: 0.36 and up refuse to apply below AGP 8.13, and AGP is pinned above.
    id("com.vanniktech.maven.publish") version "0.35.0"
}

// A coordinate, so the React Native wrapper can name this module rather than duplicate it.
// `version` tracks the SDK version the events themselves carry.
group = "com.treebars"
version = "0.4.0"

android {
    namespace = "com.treebars.sdk"
    compileSdk = 36

    defaultConfig {
        // 24: `DeviceInfo.kt` calls `areNotificationsEnabled()`, an API 24 method, without a
        // version check. The React Native wrapper defaults to 24 as well.
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests {
            // Robolectric supplies the real thing for the classes that need one; this keeps an
            // unstubbed `android.*` static from throwing "not mocked" in the ones that do not.
            isReturnDefaultValues = true
            isIncludeAndroidResources = true
        }
    }

}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.4")
    // The Play Install Referrer client, and the whole of deterministic Android acquisition: Play
    // keeps the `referrer` a tracker link put on the store URL and hands it back through this.
    // Google's own library rather than a hand-rolled AIDL bind — the service's contract is theirs
    // to change, and this is the artefact they version it through. See `Acquisition.kt`.
    implementation("com.android.installreferrer:installreferrer:2.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    // SessionManager, InAppStore and NotificationStore all take a SharedPreferences. Robolectric
    // is what supplies one without an emulator, which lets these tests run on a plain JVM rather
    // than needing a device.
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("androidx.test:core:1.7.0")
}

// Maven Central, through the Central Portal. The artifact id is set explicitly: the default is
// `rootProject.name`, `treebars-sdk-android`, which stutters against a `com.treebars` group, and
// `sdk-android` is the name the React Native package's build.gradle depends on.
//
// `automaticRelease = false`: an upload waits on central.sonatype.com as a deployment that somebody
// looks at and presses Publish on, because a release there cannot be withdrawn. Credentials and the
// signing key come from ~/.gradle/gradle.properties (`mavenCentralUsername`, `mavenCentralPassword`,
// `signingInMemoryKey…`), never from this file. `./gradlew publishToMavenCentral`.
mavenPublishing {
    configure(com.vanniktech.maven.publish.AndroidSingleVariantLibrary())
    coordinates("com.treebars", "sdk-android", version.toString())
    pom {
        name.set("Treebars Android SDK")
        description.set("Events, sessions, in-app messages, push and the notification centre for Treebars.")
        inceptionYear.set("2026")
        url.set("https://github.com/treebars/sdks")
        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
                distribution.set("https://opensource.org/licenses/MIT")
            }
        }
        developers {
            developer {
                id.set("treebars")
                name.set("Treebars")
                url.set("https://treebars.com")
            }
        }
        scm {
            url.set("https://github.com/treebars/sdks")
            connection.set("scm:git:git://github.com/treebars/sdks.git")
            developerConnection.set("scm:git:ssh://git@github.com/treebars/sdks.git")
        }
    }
    signAllPublications()
    publishToMavenCentral(automaticRelease = false)
}
