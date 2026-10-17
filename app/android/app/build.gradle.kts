import java.nio.file.Files
import java.security.MessageDigest
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

abstract class PrepareSpeechAssetsTask : DefaultTask() {
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty
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
            versionNameSuffix = "-qa-a7"
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

// Public model assets stay outside Git. An offline build must verify the exact
// approved files rather than quietly ship a microphone that cannot recognize.
val speechAssetsDirectory = layout.buildDirectory.dir("generated/speechAssets")
val speechModelSource = rootProject.projectDir.resolve("../build/speech_models/sensevoice")
val speechNotices = rootProject.projectDir.resolve("../resources/speech")
val speechFiles = mapOf(
    "model.int8.onnx" to (239233841L to "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
    "tokens.txt" to (315894L to "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
    "LICENSE" to (71L to "221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17"),
)
val prepareSpeechAssets = tasks.register<PrepareSpeechAssetsTask>("prepareSpeechAssets") {
    outputDirectory.set(speechAssetsDirectory)
    inputs.files(speechFiles.keys.map { speechModelSource.resolve(it) })
    inputs.dir(speechNotices)
    outputs.dir(speechAssetsDirectory)
    doLast {
        val destination = speechAssetsDirectory.get().asFile
        speechFiles.forEach { (name, expected) ->
            val source = speechModelSource.resolve(name)
            check(source.isFile && source.length() == expected.first &&
                !Files.isSymbolicLink(source.toPath())) {
                "Run tools/prepare-speech-assets.ps1; fixed speech asset missing."
            }
            val digest = MessageDigest.getInstance("SHA-256")
            source.inputStream().use { stream ->
                val buffer = ByteArray(65536)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            check(digest.digest().joinToString("") { "%02x".format(it) } == expected.second) {
                "Fixed speech asset checksum differs."
            }
            val target = destination.resolve("speech/sensevoice/$name")
            target.parentFile.mkdirs()
            source.copyTo(target, overwrite = true)
        }
        listOf("NOTICE.txt", "FUNASR-MODEL-LICENSE.txt", "RECORD-LICENSE.txt",
            "SHERPA-ONNX-LICENSE.txt", "ONNXRUNTIME-LICENSE.txt").forEach { name ->
            val target = destination.resolve("speech/licenses/$name")
            target.parentFile.mkdirs()
            speechNotices.resolve(name).copyTo(target, overwrite = true)
        }
    }
}
androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(prepareSpeechAssets) { it.outputDirectory }
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
        // A7 adds a forward-compatible pending-click field. A higher QA code
        // prevents accidentally reinstalling an older strict mirror reader.
        variant.outputs.forEach { it.versionCode.set(if (splitQa) 2 else 4002) }
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
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
