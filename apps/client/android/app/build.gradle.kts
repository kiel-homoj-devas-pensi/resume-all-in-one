import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置由本机显式指定；无配置时只生成未签名产物，不冒充发行包。
val signingPropertiesPath = providers.environmentVariable("RESUME_ANDROID_SIGNING_PROPERTIES")
    .orNull?.takeIf { it.isNotBlank() }
val releaseSigningProperties = signingPropertiesPath?.let { configuredPath ->
    val configurationFile = File(configuredPath)
    if (!configurationFile.isAbsolute || !configurationFile.isFile) {
        throw GradleException("Release signing requires an existing absolute configuration path.")
    }
    val properties = Properties()
    try {
        // 支持本机编辑器和 Windows PowerShell 写出的 UTF-8（含可选 BOM）。
        configurationFile.readText(Charsets.UTF_8).removePrefix("\uFEFF")
            .reader().use { properties.load(it) }
    } catch (_: Exception) {
        throw GradleException("Release signing configuration could not be read.")
    }
    if (listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .any { properties.getProperty(it).isNullOrBlank() }) {
        throw GradleException("Release signing configuration is incomplete.")
    }
    val keystoreFile = File(properties.getProperty("storeFile"))
    if (!keystoreFile.isAbsolute || !keystoreFile.isFile) {
        throw GradleException("Release signing requires an existing absolute keystore path.")
    }
    properties
}

android {
    useLibrary("android.test.runner", false)
    useLibrary("android.test.base", false)
    namespace = "com.resumeallinone.resume_all_in_one_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 既有安装的数据和升级身份依赖此 ID；发行前由负责人确认，不随文案改名。
        applicationId = "com.resumeallinone.resume_all_in_one_client"
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
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }

    signingConfigs {
        if (releaseSigningProperties != null) {
            create("release") {
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
                storeFile = File(releaseSigningProperties.getProperty("storeFile"))
                storePassword = releaseSigningProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            proguardFiles("proguard-rules.pro")
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
    // Local text extraction; Apache-2.0, Android API 19+. No optional image codecs.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
}
