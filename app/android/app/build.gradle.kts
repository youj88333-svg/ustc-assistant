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
            versionNameSuffix = "-qa-a2"
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

// Split ABI output codes must not turn a later non-split integration build
// into a downgrade that Flutter handles by uninstalling the QA application.
// Production codes/signing remain under the separately approved release flow.
androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        // The pinned Flutter plugin adds 4000 to the x86_64 split's base code.
        // A1's isolated emulator builds use that ABI; non-split integration
        // builds need the same final code to preserve their synthetic data.
        val splitQa = project.findProperty("split-per-abi") == "true"
        variant.outputs.forEach { it.versionCode.set(if (splitQa) 1 else 4001) }
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.17.1")
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
