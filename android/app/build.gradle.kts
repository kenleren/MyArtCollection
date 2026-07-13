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

fun nonBlankOrNull(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() }

enum class ReleaseSigningSource {
    GRADLE_PROPERTY,
    ENVIRONMENT_VARIABLE,
    KEY_PROPERTIES,
}

data class ReleaseSigningInput(
    val value: String,
    val source: ReleaseSigningSource,
)

fun isReleaseArtifactOrSigningTask(taskName: String): Boolean {
    val normalized = taskName.substringAfterLast(":")
    val guardedPrefixes = listOf("assemble", "bundle", "package", "sign", "install")
    return normalized.contains("release", ignoreCase = true) &&
        guardedPrefixes.any { normalized.startsWith(it, ignoreCase = true) }
}

val keyProperties =
    Properties().apply {
        val keyPropertiesFile = rootProject.file("key.properties")
        if (keyPropertiesFile.isFile) {
            keyPropertiesFile.inputStream().use(::load)
        }
    }

fun releaseSigningValue(
    gradleOrEnvName: String,
    keyPropertiesName: String,
): Pair<ReleaseSigningInput?, String?> {
    val gradlePropertyValue = nonBlankOrNull(providers.gradleProperty(gradleOrEnvName).orNull)
    val environmentValue = nonBlankOrNull(providers.environmentVariable(gradleOrEnvName).orNull)
    val keyPropertiesValue = nonBlankOrNull(keyProperties.getProperty(keyPropertiesName))

    if (
        gradlePropertyValue != null &&
        environmentValue != null &&
        gradlePropertyValue != environmentValue
    ) {
        return null to
            "Conflicting Android release signing inputs were provided for $gradleOrEnvName. " +
            "Use exactly one signing-input source contract for a release build."
    }

    return when {
        gradlePropertyValue != null ->
            ReleaseSigningInput(gradlePropertyValue, ReleaseSigningSource.GRADLE_PROPERTY) to null
        environmentValue != null ->
            ReleaseSigningInput(environmentValue, ReleaseSigningSource.ENVIRONMENT_VARIABLE) to null
        keyPropertiesValue != null ->
            ReleaseSigningInput(keyPropertiesValue, ReleaseSigningSource.KEY_PROPERTIES) to null
        else -> null to null
    }
}

fun releaseSigningConfigurationIssue(
    inputs: Map<String, ReleaseSigningInput>,
    perInputError: String?,
): String? {
    if (perInputError != null) {
        return perInputError
    }

    val configuredSources = inputs.values.map { it.source }.toSet()
    if (configuredSources.size > 1) {
        return "Android release signing inputs must come from exactly one source contract: " +
            "ignored android/key.properties, MY_ART_COLLECTION_ANDROID_RELEASE_* Gradle properties, " +
            "or MY_ART_COLLECTION_ANDROID_RELEASE_* environment variables. Do not mix them."
    }

    val missingKeys =
        listOf("storeFile", "storePassword", "keyAlias", "keyPassword").filterNot(inputs::containsKey)
    if (missingKeys.isNotEmpty()) {
        return "Android release signing is incomplete. Provide storeFile, storePassword, keyAlias, " +
            "and keyPassword through one supported source contract before building release APK or AAB."
    }

    return null
}

fun releaseSigningFailureMessage(detail: String): String =
    buildString {
        append("Android release signing is required for Play-ready release artifacts. ")
        append(detail)
    }

fun ensureReleaseSigningReady() {
    releaseSigningConfigurationIssue?.let { throw GradleException(releaseSigningFailureMessage(it)) }
}

val releaseSigningInputKeys =
    mapOf(
        "storeFile" to "MY_ART_COLLECTION_ANDROID_RELEASE_STORE_FILE",
        "storePassword" to "MY_ART_COLLECTION_ANDROID_RELEASE_STORE_PASSWORD",
        "keyAlias" to "MY_ART_COLLECTION_ANDROID_RELEASE_KEY_ALIAS",
        "keyPassword" to "MY_ART_COLLECTION_ANDROID_RELEASE_KEY_PASSWORD",
    )
val releaseSigningResults =
    releaseSigningInputKeys.mapValues { (inputName, gradleOrEnvName) ->
        releaseSigningValue(gradleOrEnvName, inputName)
    }
val releaseSigningInputs =
    releaseSigningResults.mapNotNull { (name, result) ->
        result.first?.let { name to it }
    }.toMap()
val releaseSigningConfigurationIssue =
    releaseSigningConfigurationIssue(
        releaseSigningInputs,
        releaseSigningResults.values.mapNotNull { it.second }.firstOrNull(),
    )
val releaseSigningReady = releaseSigningConfigurationIssue == null

val enableFirebaseAndroid =
    providers.environmentVariable("MY_ART_COLLECTION_FIREBASE_ANDROID")
        .map { it.equals("true", ignoreCase = true) }
        .getOrElse(false)
val firebaseAndroidDartDefineEnabled = dartDefineEnabled("MY_ART_COLLECTION_FIREBASE_ANDROID")
val brokerClientDartDefineEnabled = dartDefineEnabled("MY_ART_COLLECTION_BROKER_CLIENT")
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

if (brokerClientDartDefineEnabled && crashlyticsDartDefineEnabled) {
    throw GradleException(
        "MY_ART_COLLECTION_BROKER_CLIENT=true cannot be combined with " +
            "MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true. " +
            "Broker-capable artifacts disable startup Crashlytics independently of research consent.",
    )
}

if (brokerClientDartDefineEnabled && !enableFirebaseAndroid) {
    throw GradleException(
        "MY_ART_COLLECTION_BROKER_CLIENT=true requires " +
            "MY_ART_COLLECTION_FIREBASE_ANDROID=true in the Gradle environment",
    )
}

if (brokerClientDartDefineEnabled && !firebaseAndroidDartDefineEnabled) {
    throw GradleException(
        "MY_ART_COLLECTION_BROKER_CLIENT=true requires " +
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
    if (!brokerClientDartDefineEnabled) {
        apply(plugin = "com.google.firebase.crashlytics")
    }
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
                storeFile = rootProject.file(releaseSigningInputs.getValue("storeFile").value)
                storePassword = releaseSigningInputs.getValue("storePassword").value
                keyAlias = releaseSigningInputs.getValue("keyAlias").value
                keyPassword = releaseSigningInputs.getValue("keyPassword").value
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

dependencies {
    testImplementation("junit:junit:4.13.2")
}

gradle.taskGraph.whenReady {
    if (allTasks.any { isReleaseArtifactOrSigningTask(it.name) }) {
        ensureReleaseSigningReady()
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
