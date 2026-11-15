import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing comes from key.properties written by CI from GitHub secrets. Never committed.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

// A release must never silently fall back to Android's debug signing identity.
val releaseRequested = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
if (releaseRequested) {
    check(listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all { !keyProps.getProperty(it).isNullOrBlank() }) {
        "Puffle release signing is missing. Configure the dedicated Puffle upload keystore before building a release."
    }
    check(file(keyProps.getProperty("storeFile")).isFile) { "Puffle release keystore file is missing." }
}

android {
    namespace = "com.pufflecloud.app"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    defaultConfig {
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keyProps.containsKey("storeFile")) {
                storeFile = file(keyProps["storeFile"] as String)
                storePassword = keyProps["storePassword"] as String
                keyAlias = keyProps["keyAlias"] as String
                keyPassword = keyProps["keyPassword"] as String
            }
        }
    }

    flavorDimensions += "dist"
    productFlavors {
        create("direct") {
            dimension = "dist"
            applicationId = "com.pufflecloud.app"
            manifestPlaceholders["authScheme"] = "com.pufflecloud.app"
        }
        create("play") {
            dimension = "dist"
            applicationId = "com.pufflecloud.app"
            manifestPlaceholders["authScheme"] = "com.pufflecloud.app"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

flutter { source = "../.." }
