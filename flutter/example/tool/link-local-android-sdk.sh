#!/usr/bin/env bash
# Builds the Android Treebars SDK beside this package and puts it where the example app resolves it.
#
# Why not a composite build, as the React Native sample uses: Flutter's Gradle plugin refuses an
# Android Gradle plugin older than its own minimum, and the Android SDK's build pins an older one,
# while a composite build refuses two versions in one tree. So the SDK is built by its own Gradle and
# handed over as an AAR and its POM, in a Maven layout under example/build/ (never committed). The
# example's build.gradle.kts reads that directory first when it exists, and only for com.treebars,
# so without it the published SDK of the same version is used.
#
# Run it again after any change to the Android SDK.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sdk="$(cd "$here/../../../android" && pwd)"
repo="$here/../build/local-android-sdk"

version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$sdk/build.gradle.kts")"
[ -n "$version" ] || { echo "could not read the Android SDK's version from $sdk/build.gradle.kts" >&2; exit 1; }

(cd "$sdk" && ./gradlew -q assembleRelease generatePomFileForMavenPublication)

dest="$repo/com/treebars/sdk-android/$version"
mkdir -p "$dest"
cp "$sdk/build/outputs/aar/treebars-sdk-android-release.aar" "$dest/sdk-android-$version.aar"
cp "$sdk/build/publications/maven/pom-default.xml" "$dest/sdk-android-$version.pom"
echo "com.treebars:sdk-android:$version -> $dest"
