import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun dartDefineEnabled(name: String): Boolean {
    val encodedDefines = providers.gradleProperty("dart-defines").orNull ?: return false
    return encodedDefines
        .split(",")
        .filter { it.isNotBlank() }
        .mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull()
        }
        .any { it == "$name=true" }
}

fun requestedReleaseArtifactTasks(): List<String> {
    val artifactPrefixes = listOf("assemble", "bundle", "package", "install")
    return gradle.startParameter.taskNames.filter { taskName ->
        val normalized = taskName.substringAfterLast(":")
        normalized.contains("release", ignoreCase = true) &&
            artifactPrefixes.any { normalized.startsWith(it, ignoreCase = true) }
    }
}

fun nonBlankOrNull(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() }

val keyProperties =
    Properties().apply {
        val keyPropertiesFile = rootProject.file("key.properties")
        if (keyPropertiesFile.isFile) {
            keyPropertiesFile.inputStream().use(::load)
        }
    }

fun releaseSigningValue(gradleOrEnvName: String, keyPropertiesName: String): String? =
    nonBlankOrNull(providers.gradleProperty(gradleOrEnvName).orNull)
        ?: nonBlankOrNull(providers.environmentVariable(gradleOrEnvName).orNull)
        ?: nonBlankOrNull(keyProperties.getProperty(keyPropertiesName))

val releaseSigningInputs =
    mapOf(
        "storeFile" to
            releaseSigningValue(
                "MY_ART_COLLECTION_ANDROID_RELEASE_STORE_FILE",
                "storeFile",
            ),
        "storePassword" to
            releaseSigningValue(
                "MY_ART_COLLECTION_ANDROID_RELEASE_STORE_PASSWORD",
                "storePassword",
            ),
        "keyAlias" to
            releaseSigningValue(
                "MY_ART_COLLECTION_ANDROID_RELEASE_KEY_ALIAS",
                "keyAlias",
            ),
        "keyPassword" to
            releaseSigningValue(
                "MY_ART_COLLECTION_ANDROID_RELEASE_KEY_PASSWORD",
                "keyPassword",
            ),
    )
val releaseSigningReady = releaseSigningInputs.values.all { it != null }
val releaseArtifactTasks = requestedReleaseArtifactTasks()
val releaseSigningFailureMessage =
    buildString {
        append("Android release signing is required for Play-ready release artifacts. ")
        append("Provide all release signing inputs through ignored android/key.properties ")
        append("or MY_ART_COLLECTION_ANDROID_RELEASE_* Gradle/environment properties ")
        append("before building release APK or AAB.")
    }

val enableFirebaseAndroid =
    providers.environmentVariable("MY_ART_COLLECTION_FIREBASE_ANDROID")
        .map { it.equals("true", ignoreCase = true) }
        .getOrElse(false)
val firebaseAndroidDartDefineEnabled = dartDefineEnabled("MY_ART_COLLECTION_FIREBASE_ANDROID")
val crashlyticsDartDefineEnabled =
    dartDefineEnabled("MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS")
val remoteConfigDartDefineEnabled = dartDefineEnabled("MY_ART_COLLECTION_REMOTE_CONFIG")
val googleServicesConfig = file("google-services.json")

if (crashlyticsDartDefineEnabled && !enableFirebaseAndroid) {
    throw GradleException(
        "MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true requires " +
            "MY_ART_COLLECTION_FIREBASE_ANDROID=true in the Gradle environment",
    )
}

if (crashlyticsDartDefineEnabled && !firebaseAndroidDartDefineEnabled) {
    throw GradleException(
        "MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true requires " +
            "--dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true",
    )
}

if (remoteConfigDartDefineEnabled && !enableFirebaseAndroid) {
    throw GradleException(
        "MY_ART_COLLECTION_REMOTE_CONFIG=true requires " +
            "MY_ART_COLLECTION_FIREBASE_ANDROID=true in the Gradle environment",
    )
}

if (remoteConfigDartDefineEnabled && !firebaseAndroidDartDefineEnabled) {
    throw GradleException(
        "MY_ART_COLLECTION_REMOTE_CONFIG=true requires " +
            "--dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true",
    )
}

if (enableFirebaseAndroid) {
    require(googleServicesConfig.isFile) {
        "MY_ART_COLLECTION_FIREBASE_ANDROID=true requires android/app/google-services.json"
    }
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

android {
    namespace = "app.archivale"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.archivale"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["crashlyticsCollectionEnabled"] = "false"
        buildConfigField(
            "boolean",
            "MY_ART_ON_DEVICE_AI_ENABLED",
            dartDefineEnabled("MY_ART_ON_DEVICE_AI_ENABLED").toString(),
        )
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        create("release") {
            if (releaseSigningReady) {
                storeFile = rootProject.file(releaseSigningInputs.getValue("storeFile")!!)
                storePassword = releaseSigningInputs.getValue("storePassword")
                keyAlias = releaseSigningInputs.getValue("keyAlias")
                keyPassword = releaseSigningInputs.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

gradle.taskGraph.whenReady {
    if (releaseArtifactTasks.isNotEmpty() && !releaseSigningReady) {
        throw GradleException(releaseSigningFailureMessage)
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
    implementation("com.google.mlkit:genai-prompt:1.0.0-beta2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
