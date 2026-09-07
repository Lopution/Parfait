plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle Plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.lopution.pixivfunc"
    // Flutter 3.47.2 defaults compileSdkVersion to 36; 37 is required by
    // androidx.core 1.19 and flutter_secure_storage 11. Revisit when flutter.compileSdkVersion reaches 37.
    compileSdk = 37
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
        // Split APK versionCodes use Flutter ABI_VERSION offsets
        // (io.flutter.FlutterPluginConstants):
        //   armeabi-v7a ABI_VERSION=1 → 1000+n
        //   arm64-v8a   ABI_VERSION=2 → 2000+n
        // x86_64 (ABI_VERSION=4) is not built. Do not pass
        // -Pforce-version-code-ignoring-abi: F-Droid multi-APK same-version
        // releases require distinct versionCodes, and the updater compares
        // versionCode % 1000.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Resolve release signing material once, but defer the missing-material
    // error until the GitHub release variant is requested. F-Droid's release
    // artifact is intentionally store-managed and must remain buildable
    // without the project's private keystore.
    val releaseKeystorePath = providers.gradleProperty("PIXIV_RELEASE_KEYSTORE").orNull
    val releaseStorePassword =
        providers.gradleProperty("PIXIV_RELEASE_KEYSTORE_PASSWORD").orNull
    val releaseKeyAlias = providers.gradleProperty("PIXIV_RELEASE_KEY_ALIAS").orNull
    val releaseKeyPassword = providers.gradleProperty("PIXIV_RELEASE_KEY_PASSWORD").orNull
    val hasOfficialReleaseMaterial = releaseKeystorePath != null &&
        releaseStorePassword != null &&
        releaseKeyAlias != null &&
        releaseKeyPassword != null &&
        releaseKeystorePath.isNotEmpty() &&
        releaseStorePassword.isNotEmpty() &&
        releaseKeyAlias.isNotEmpty() &&
        releaseKeyPassword.isNotEmpty()
    val allowDebugReleaseSigning = providers.gradleProperty(
        "PIXIV_ALLOW_DEBUG_RELEASE_SIGNING",
    ).orNull?.equals("true", ignoreCase = true) == true
    val pixivReleaseSigningConfig = if (hasOfficialReleaseMaterial) {
        signingConfigs.create("pixivRelease").apply {
            storeFile = file(releaseKeystorePath!!)
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias!!
            keyPassword = releaseKeyPassword
        }
    } else {
        null
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

            // Only the distributable GitHub variant consumes the project's
            // release keystore. A local debug flag is explicitly non-
            // publishable and is useful for compile/package smoke tests.
            if (pixivReleaseSigningConfig != null) {
                signingConfig = pixivReleaseSigningConfig
                buildConfigField("boolean", "RELEASE_SIGNED_OFFICIALLY", "true")
                println("release signing: official keystore (${releaseKeyAlias})")
            } else if (allowDebugReleaseSigning) {
                signingConfig = signingConfigs.getByName("debug")
                buildConfigField("boolean", "RELEASE_SIGNED_OFFICIALLY", "false")
                println(
                    "!!! RELEASE SIGNING: DEBUG KEYS (explicitly allowed via " +
                        "PIXIV_ALLOW_DEBUG_RELEASE_SIGNING=true) — this build is NOT " +
                        "publishable and cannot be overwritten-installed over an " +
                        "officially signed release.",
                )
            } else {
                // The task-level check below emits the actionable error only when
                // the githubRelease variant is actually requested.
                buildConfigField("boolean", "RELEASE_SIGNED_OFFICIALLY", "false")
            }
        }
        create("fdroid") {
            dimension = "distribution"
            buildConfigField("boolean", "UPDATE_SELF_UPDATER_ENABLED", "false")
            buildConfigField("String", "UPDATE_PUBLIC_KEY_DER_B64", "\"\"")
            buildConfigField("boolean", "RELEASE_SIGNED_OFFICIALLY", "false")
        }
    }

    buildTypes {
        release {
            // Signing is selected by the flavor above. GitHub requires the
            // project key; F-Droid deliberately remains store-managed.
        }
    }

    // Android history uses platform SQLite (`sqflite.databaseFactory`).
    // `sqflite_common_ffi` stays a main dependency for desktop/tests (D-4)
    // and would otherwise ship `libsqlite3.so` (~1.73 MB/ABI) as a native
    // asset that the production factory never loads.
    packaging {
        jniLibs {
            excludes += "**/libsqlite3.so"
        }
    }

}

// Keep the failure scoped to an actual GitHub package task. AGP configures
// every flavor while resolving many unrelated tasks (including F-Droid's
// Kotlin compile), so a configuration-time throw would incorrectly block the
// store-managed flavor too.
val verifyGithubReleaseSigning = tasks.register("verifyGithubReleaseSigning") {
    doLast {
        val hasOfficialMaterial = providers.gradleProperty("PIXIV_RELEASE_KEYSTORE")
            .orNull?.isNotEmpty() == true &&
            providers.gradleProperty("PIXIV_RELEASE_KEYSTORE_PASSWORD")
                .orNull?.isNotEmpty() == true &&
            providers.gradleProperty("PIXIV_RELEASE_KEY_ALIAS")
                .orNull?.isNotEmpty() == true &&
            providers.gradleProperty("PIXIV_RELEASE_KEY_PASSWORD")
                .orNull?.isNotEmpty() == true
        val allowDebug = providers.gradleProperty("PIXIV_ALLOW_DEBUG_RELEASE_SIGNING")
            .orNull?.equals("true", ignoreCase = true) == true
        if (!hasOfficialMaterial && !allowDebug) {
            throw GradleException(
                "GitHub release signing material is missing. Provide " +
                    "PIXIV_RELEASE_KEYSTORE, PIXIV_RELEASE_KEYSTORE_PASSWORD, " +
                    "PIXIV_RELEASE_KEY_ALIAS and PIXIV_RELEASE_KEY_PASSWORD " +
                    "as Gradle properties, or explicitly opt into a " +
                    "non-publishable debug test build with " +
                    "-PPIXIV_ALLOW_DEBUG_RELEASE_SIGNING=true.",
            )
        }
    }
}

tasks.configureEach {
    if (name == "assembleGithubRelease" ||
        name == "bundleGithubRelease" ||
        name == "packageGithubRelease") {
        dependsOn(verifyGithubReleaseSigning)
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
    implementation("androidx.core:core:1.19.0")
    // Home widget background maintenance (08-26-android-home-widgets).
    // work-runtime-ktx is an empty shell since 2.8; Kotlin APIs live here.
    implementation("androidx.work:work-runtime:2.11.2")
    // Plain JVM tests for widget budget math.
    testImplementation("junit:junit:4.13.2")
}
