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

// Signing material is supplied only by the local release helper/secure CI job.
// Nothing falls back to the QA certificate or a checked-in password.
val releaseSigningEnvironment = mapOf(
    "store" to System.getenv("USTC_ANDROID_KEYSTORE"),
    "alias" to System.getenv("USTC_ANDROID_KEY_ALIAS"),
    "storePassword" to System.getenv("USTC_ANDROID_STORE_PASSWORD"),
    "keyPassword" to System.getenv("USTC_ANDROID_KEY_PASSWORD"),
)
val hasReleaseSigning = releaseSigningEnvironment.values.all { !it.isNullOrBlank() }

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

    signingConfigs {
        if (hasReleaseSigning) {
            create("publicRelease") {
                storeFile = file(releaseSigningEnvironment.getValue("store")!!)
                storeType = "PKCS12"
                keyAlias = releaseSigningEnvironment.getValue("alias")
                storePassword = releaseSigningEnvironment.getValue("storePassword")
                keyPassword = releaseSigningEnvironment.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".qa"
            versionNameSuffix = "-qa-a8-setup"
        }
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("publicRelease") else null
        }
    }
}

// Manifest/lint/debug verification may run without a production key. Producing
// a release APK/AAB may not: AGP otherwise permits an unsigned output.
gradle.taskGraph.whenReady {
    val producingRelease = allTasks.any {
        it.project == project &&
            Regex("^(assemble|bundle|package|sign|validateSigning)Release(?:$|Bundle|UniversalApk)").containsMatchIn(it.name)
    }
    if (producingRelease) {
        check(hasReleaseSigning) {
            "Release signing is required. Use tools/build-public-release.ps1 with a local signing configuration."
        }
        check(!releaseSigningEnvironment.getValue("alias").equals("androiddebugkey", ignoreCase = true)) {
            "The QA/debug signing alias is not allowed for a public release."
        }
        val keyStore = file(releaseSigningEnvironment.getValue("store")!!)
        check(keyStore.isFile && !Files.isSymbolicLink(keyStore.toPath())) {
            "The release keystore must be a regular local file."
        }
        val definitions = (project.findProperty("dart-defines") as? String).orEmpty()
            .split(',').filter { it.isNotBlank() }.map {
                String(java.util.Base64.getDecoder().decode(it), Charsets.UTF_8)
            }
        check(definitions.none {
            it == "USTC_DIAGNOSTICS=true" || it == "USTC_M3_VALIDATION=true"
        }) { "Development panels cannot be enabled in a public release." }
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
val projectSourceRoot = rootProject.projectDir.resolve("../..")
val projectNoticeFiles = mapOf(
    "LICENSE" to projectSourceRoot.resolve("LICENSE"),
    "NOTICE" to projectSourceRoot.resolve("NOTICE"),
    "THIRD_PARTY_NOTICES.md" to projectSourceRoot.resolve("THIRD_PARTY_NOTICES.md"),
    "public-1.0.0.md" to projectSourceRoot.resolve("docs/releases/public-1.0.0.md"),
    "known-issues.md" to projectSourceRoot.resolve("docs/releases/known-issues.md"),
)
val androidNativeNotice = rootProject.projectDir.resolve("../resources/android/NOTICE.txt")
val speechFiles = mapOf(
    "model.int8.onnx" to (239233841L to "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
    "tokens.txt" to (315894L to "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
    "LICENSE" to (71L to "221c6df10b0931a5629adad671ea48fb7747e034c414b6d2bfa275bc3dd4ea17"),
)
val prepareSpeechAssets = tasks.register<PrepareSpeechAssetsTask>("prepareSpeechAssets") {
    outputDirectory.set(speechAssetsDirectory)
    inputs.files(speechFiles.keys.map { speechModelSource.resolve(it) })
    inputs.dir(speechNotices)
    inputs.files(projectNoticeFiles.values)
    inputs.file(androidNativeNotice)
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
        projectNoticeFiles.forEach { (name, source) ->
            check(source.isFile && source.length() > 0 && !Files.isSymbolicLink(source.toPath())) {
                "Required project release notice is missing or unsafe."
            }
            val target = destination.resolve("licenses/project/$name")
            target.parentFile.mkdirs()
            source.copyTo(target, overwrite = true)
        }
        check(androidNativeNotice.isFile && androidNativeNotice.length() > 0) {
            "Required Android native component notice is missing."
        }
        val androidNoticeTarget = destination.resolve("licenses/android/NOTICE.txt")
        androidNoticeTarget.parentFile.mkdirs()
        androidNativeNotice.copyTo(androidNoticeTarget, overwrite = true)
        projectNoticeFiles.getValue("LICENSE")
            .copyTo(destination.resolve("licenses/android/APACHE-2.0.txt"), overwrite = true)
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
        // Keep compatibility and UI QA upgrades monotonic so the test runner
        // cannot reinstall an older reader over the retained synthetic owner.
        variant.outputs.forEach { it.versionCode.set(if (splitQa) 24 else 4024) }
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
