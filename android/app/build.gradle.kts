import java.util.Base64

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Use the same compile-time flag as Dart so the Play artifact cannot retain
// the direct-download install permission while its updater is disabled.
val googlePlayBuild = providers.gradleProperty("dart-defines").orNull
    ?.split(",")
    ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
    ?.contains("TSUKUYOMI_GOOGLE_PLAY=true") == true

android {
    namespace = "space.tsukuyomi.tsukuyomi_space_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    if (googlePlayBuild) {
        sourceSets.getByName("release").manifest.srcFile("src/play/AndroidManifest.xml")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "space.tsukuyomi.tsukuyomi_space_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (googlePlayBuild) {
            // Media dependencies may ship additional ABIs even when Flutter's
            // target-platform flag builds only our supported 64-bit binaries.
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
            }
        }
    }

    signingConfigs {
        create("release") {
            val keyPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (keyPath != null) {
                storeFile = file(keyPath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "tsukuyomi"
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Release builds require the stable distribution key; never use a
            // runner's ephemeral debug key for downloadable packages.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/qq-open-sdk.jar"))
}
