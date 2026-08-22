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
            // Without key.properties a release build would be signed with the
            // world-known Android debug key: not uploadable to Play, not
            // installable over a Play build, and named `app-release.aab` like
            // any other. That used to happen silently.
            //
            // It now FAILS rather than warns. A warning was tried first and is
            // the wrong instrument twice over: it scrolls past in a build log
            // nobody reads, and on the machine that has key.properties — every
            // machine that matters — it is unreachable, so there is no way to
            // tell a working warning from a broken one without deliberately
            // hiding the keystore. A failure cannot be missed, Flutter always
            // surfaces it (verified: the banner below appears in full through
            // `flutter build appbundle`), and it is the right default anyway —
            // an unsigned release is never what someone actually wanted.
            //
            // Compile-checking without the keystore is still legitimate (CI, a
            // fresh clone, `flutter run --release`), so it is available — just
            // never by accident. Pass `-PallowDebugSigning=true`, which
            // `make build-android` and the CI workflow do explicitly. The
            // deploy workflow deliberately does not, so a keystore that failed
            // to materialise there stops the build instead of shipping a
            // debug-signed bundle to the alpha track.
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                if (project.findProperty("allowDebugSigning") != "true") {
                    throw GradleException(
                        "\n" +
                            "**********************************************************************\n" +
                            "android/key.properties not found, so this RELEASE build would be\n" +
                            "signed with the DEBUG key. Such a build cannot be uploaded to Play\n" +
                            "and cannot be installed over or upgraded by a Play build, which\n" +
                            "makes it useless — and dangerous — to hand to a tester.\n" +
                            "\n" +
                            "To compile-check on purpose, opt in:\n" +
                            "  flutter build appbundle --release -PallowDebugSigning=true\n" +
                            "  (or just `make build-android`, which passes it)\n" +
                            "\n" +
                            "To produce a real release, put the upload keystore at\n" +
                            "android/key.properties.\n" +
                            "**********************************************************************\n"
                    )
                }
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
