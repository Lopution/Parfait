plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle Plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.lopution.pixivfunc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    flavorDimensions += "distribution"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.lopution.pixivfunc"
        // minSdk = 29 (Android 10): MediaStoreChannel throws on <29 so the
        // download feature never worked there; exposing Android 7-9 devices
        // to an app whose downloads always fail is worse than excluding
        // them. API 29 is in the acceptance matrix (R4).
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    productFlavors {
        create("github") {
            dimension = "distribution"
            buildConfigField("boolean", "UPDATE_SELF_UPDATER_ENABLED", "true")
            val publicKey = providers.gradleProperty("PIXIV_UPDATE_PUBLIC_KEY_DER_B64")
                .orNull
                ?.trim()
                ?.replace("\\", "\\\\")
                ?.replace("\"", "\\\"")
                ?: ""
            buildConfigField("String", "UPDATE_PUBLIC_KEY_DER_B64", "\"$publicKey\"")
        }
        create("fdroid") {
            dimension = "distribution"
            buildConfigField("boolean", "UPDATE_SELF_UPDATER_ENABLED", "false")
            buildConfigField("String", "UPDATE_PUBLIC_KEY_DER_B64", "\"\"")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
    implementation("androidx.core:core:1.15.0")
    // Home widget background maintenance (08-26-android-home-widgets).
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    // Plain JVM tests for widget budget math.
    testImplementation("junit:junit:4.13.2")
}
