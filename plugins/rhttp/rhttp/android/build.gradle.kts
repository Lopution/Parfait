import org.jetbrains.kotlin.gradle.dsl.JvmTarget

group = "com.flutter_rust_bridge.rhttp"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// AGP 9 built-in Kotlin: do NOT apply org.jetbrains.kotlin.android here.
// Kotlin sources are compiled by AGP's built-in support; jvmTarget is
// configured via the `kotlin` extension below. (Upstream 0.18.0 predates
// this.)

android {
    namespace = "com.flutter_rust_bridge.rhttp"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

apply(from = "../cargokit/gradle/plugin.gradle")

extensions.getByName("cargokit").withGroovyBuilder {
    setProperty("manifestDir", "../rust")
    setProperty("libname", "rhttp")
}
