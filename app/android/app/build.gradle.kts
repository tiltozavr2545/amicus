import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing config lives outside the repo (android/key.properties is
// gitignored) — the keystore itself is a secret that can never be replaced
// or recovered if lost or leaked, so it stays out of source control entirely.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.github.tiltozavr2545.amicus"
    // Pinned above flutter.compileSdkVersion (35 in Flutter 3.32.8): Google Play
    // requires targetSdk 36 from 2026-08-31, and targetSdk can't exceed compileSdk.
    // Flutter itself only defaults to 36 from 3.35, which needs macOS 14+.
    compileSdk = 36
    // Pinned above flutter.ndkVersion (26.x): several plugins (app_links,
    // image_picker_android, etc.) require 27.0.12077973.
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.github.tiltozavr2545.amicus"
        // Pinned above flutter.minSdkVersion (21): firebase_messaging's
        // manifest declares minSdk 23 (Android 6.0, 2015) and the merge fails
        // below that — confirmed by trying flutter.minSdkVersion first.
        minSdk = 23
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Falls back to debug signing (so `flutter run --release` still
            // works, and so CI can compile-check an AAB without holding the
            // keystore) when key.properties isn't present, e.g. a fresh clone.
            //
            // The fallback is announced, loudly, because it used to be silent:
            // the output was named like any other release artifact, gave no
            // hint in the build log, and was signed with the world-known
            // Android debug key. Handed to a tester as "the release build" it
            // cannot be installed over — or later upgraded by — a Play build,
            // and an upload attempt burns a version code on a rejection.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "\n" +
                        "**********************************************************************\n" +
                        "WARNING: android/key.properties not found.\n" +
                        "This RELEASE build is signed with the DEBUG key. It is not\n" +
                        "distributable: it cannot be uploaded to Play, and it cannot be\n" +
                        "installed over or upgraded by a Play build.\n" +
                        "**********************************************************************\n"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
