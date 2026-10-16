plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cn.ustcassistant.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "cn.ustcassistant.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".qa"
            versionNameSuffix = "-qa-a0"
        }
        release {
            // A8 supplies the privately managed production signature.
            // Never silently sign production with the QA/debug identity.
            signingConfig = null
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
    debugImplementation("androidx.webkit:webkit:1.13.0")
    // Flutter's integration_test plugin contributes an older runner to debugRuntimeClasspath.
    // AGP applies consistent resolution to the instrumentation APK: keep both sides aligned.
    debugImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
}

// Lint reads this generated file, but AGP does not invalidate cached property-file findings on edits.
tasks.matching { it.name.startsWith("lintAnalyze") }.configureEach {
    inputs.file(rootProject.file("local.properties"))
}
