plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.tour_guide"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.tour_guide"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("ciRelease") {
            val ksFile = file(System.getenv("CI_KEYSTORE_PATH") ?: "/dev/null")
            if (ksFile.exists()) {
                storeFile = ksFile
                storePassword = System.getenv("CI_KEYSTORE_PASSWORD") ?: ""
                keyAlias = System.getenv("CI_KEY_ALIAS") ?: ""
                keyPassword = System.getenv("CI_KEY_PASSWORD") ?: ""
            }
        }
    }

    buildTypes {
        release {
            val ciKs = file(System.getenv("CI_KEYSTORE_PATH") ?: "/dev/null")
            signingConfig = if (ciKs.exists()) {
                signingConfigs.getByName("ciRelease")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
