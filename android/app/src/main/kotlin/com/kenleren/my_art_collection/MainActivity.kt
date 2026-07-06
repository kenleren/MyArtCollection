package com.kenleren.my_art_collection

import android.graphics.BitmapFactory
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val onDeviceAiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var onDeviceAiProvider: MlKitPromptOnDeviceAiProvider? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kenleren.my_art_collection/on_device_ai",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAvailability" -> {
                    if (!BuildConfig.MY_ART_ON_DEVICE_AI_ENABLED) {
                        result.success(disabledCapability())
                        return@setMethodCallHandler
                    }
                    onDeviceAiScope.launch {
                        try {
                            result.success(nativeOnDeviceAiProvider().checkAvailability())
                        } catch (error: Exception) {
                            result.success(unavailableCapability("On-device AI status check failed."))
                        }
                    }
                }
                "downloadModel" -> {
                    if (!BuildConfig.MY_ART_ON_DEVICE_AI_ENABLED) {
                        result.success(disabledCapability())
                        return@setMethodCallHandler
                    }
                    onDeviceAiScope.launch {
                        try {
                            result.success(nativeOnDeviceAiProvider().downloadModel())
                        } catch (error: Exception) {
                            result.success(downloadFailedCapability())
                        }
                    }
                }
                "createDraft" -> {
                    if (!BuildConfig.MY_ART_ON_DEVICE_AI_ENABLED) {
                        result.error(
                            "ON_DEVICE_AI_DISABLED",
                            "On-device AI is disabled for this build.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    val primaryImagePath = call.argument<String>("primaryImagePath")
                    if (primaryImagePath.isNullOrBlank()) {
                        result.error(
                            "ON_DEVICE_AI_BAD_REQUEST",
                            "On-device AI needs a local primary image path.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    onDeviceAiScope.launch {
                        try {
                            result.success(nativeOnDeviceAiProvider().createDraft(primaryImagePath))
                        } catch (error: OnDeviceAiNotReadyException) {
                            result.error(
                                "ON_DEVICE_AI_NOT_READY",
                                "On-device AI is not ready yet.",
                                null,
                            )
                        } catch (error: Exception) {
                            result.error(
                                "ON_DEVICE_AI_FAILED",
                                "On-device AI draft failed.",
                                null,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        onDeviceAiProvider?.close()
        onDeviceAiScope.cancel()
        super.onDestroy()
    }

    private fun nativeOnDeviceAiProvider(): MlKitPromptOnDeviceAiProvider {
        return onDeviceAiProvider ?: MlKitPromptOnDeviceAiProvider(onDeviceAiScope).also {
            onDeviceAiProvider = it
        }
    }
}

private class MlKitPromptOnDeviceAiProvider(
    private val scope: CoroutineScope,
) {
    private var generativeModel: GenerativeModel? = null
    private var downloadJob: Job? = null
    private var lastDownloadFailed = false

    suspend fun checkAvailability(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return unavailableCapability("On-device AI requires Android API level 26 or newer.")
        }

        val model = model()
        return when (model.checkStatus()) {
            FeatureStatus.AVAILABLE -> {
                lastDownloadFailed = false
                availableCapability(model)
            }
            FeatureStatus.DOWNLOADABLE -> if (lastDownloadFailed) {
                downloadFailedCapability()
            } else {
                downloadableCapability()
            }
            FeatureStatus.DOWNLOADING -> downloadingCapability()
            else -> unavailableCapability(
                "Gemini Nano is not supported on this device or AICore is not ready.",
            )
        }
    }

    suspend fun downloadModel(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return unavailableCapability("On-device AI requires Android API level 26 or newer.")
        }

        val model = model()
        return when (model.checkStatus()) {
            FeatureStatus.AVAILABLE -> {
                lastDownloadFailed = false
                availableCapability(model)
            }
            FeatureStatus.DOWNLOADABLE -> beginDownload(model)
            FeatureStatus.DOWNLOADING -> downloadingCapability()
            else -> unavailableCapability(
                "Gemini Nano is not supported on this device or AICore is not ready.",
            )
        }
    }

    suspend fun createDraft(primaryImagePath: String): Map<String, Any?> {
        val capability = checkAvailability()
        if (capability["availability"] != "available") {
            throw OnDeviceAiNotReadyException(capability["message"]?.toString() ?: "On-device AI is not ready.")
        }

        val bitmap = BitmapFactory.decodeFile(primaryImagePath)
            ?: throw IllegalArgumentException("The local primary image could not be decoded.")
        val response = model().generateContent(
            generateContentRequest(
                ImagePart(bitmap),
                TextPart(artworkDraftPrompt),
            ) {
                temperature = 0.2f
                topK = 10
                candidateCount = 1
                maxOutputTokens = 256
            },
        )
        val outputText = response.candidates.firstOrNull()?.text.orEmpty()
        if (outputText.isBlank()) {
            throw IllegalStateException("The on-device model returned an empty draft.")
        }
        return parseDraftResponse(outputText)
    }

    fun close() {
        downloadJob?.cancel()
        generativeModel?.close()
        generativeModel = null
    }

    private fun model(): GenerativeModel {
        return generativeModel ?: Generation.getClient().also {
            generativeModel = it
        }
    }

    private suspend fun beginDownload(model: GenerativeModel): Map<String, Any?> {
        if (downloadJob?.isActive == true) {
            return downloadingCapability()
        }

        lastDownloadFailed = false
        val firstUpdate = CompletableDeferred<Map<String, Any?>>()
        downloadJob = scope.launch {
            try {
                model.download().collect { status ->
                    val capability = when (status) {
                        is DownloadStatus.DownloadStarted -> downloadingCapability()
                        is DownloadStatus.DownloadProgress -> downloadingCapability()
                        is DownloadStatus.DownloadCompleted -> {
                            lastDownloadFailed = false
                            availableCapability(model)
                        }
                        is DownloadStatus.DownloadFailed -> {
                            lastDownloadFailed = true
                            downloadFailedCapability()
                        }
                    }
                    if (!firstUpdate.isCompleted) {
                        firstUpdate.complete(capability)
                    }
                }
                if (!firstUpdate.isCompleted) {
                    firstUpdate.complete(checkAvailability())
                }
            } catch (_: Exception) {
                lastDownloadFailed = true
                if (!firstUpdate.isCompleted) {
                    firstUpdate.complete(downloadFailedCapability())
                }
            } finally {
                downloadJob = null
            }
        }
        return firstUpdate.await()
    }
}

private class OnDeviceAiNotReadyException(message: String) : Exception(message)

private fun disabledCapability(): Map<String, Any?> =
    capability(
        availability = "disabled",
        message = "On-device AI is disabled for this build.",
    )

private fun unavailableCapability(message: String): Map<String, Any?> =
    capability(
        availability = "unavailable",
        message = message,
    )

private fun downloadableCapability(): Map<String, Any?> =
    capability(
        availability = "downloadable",
        message = "Gemini Nano support is downloadable but not ready yet.",
    )

private fun downloadingCapability(): Map<String, Any?> =
    capability(
        availability = "downloading",
        message = "Gemini Nano support is still downloading. Try again after it finishes.",
    )

private fun downloadFailedCapability(): Map<String, Any?> =
    capability(
        availability = "download_failed",
        message = "On-device AI download could not finish yet. Try again after checking AICore.",
    )

private suspend fun availableCapability(model: GenerativeModel): Map<String, Any?> =
    capability(
        availability = "available",
        message = "On-device AI is available on this device.",
        baseModelName = runCatching { model.getBaseModelName() }.getOrNull(),
    )

private fun capability(
    availability: String,
    message: String,
    baseModelName: String? = null,
): Map<String, Any?> =
    mapOf(
        "availability" to availability,
        "deviceModel" to listOfNotNull(Build.MANUFACTURER, Build.MODEL).joinToString(" ").trim(),
        "message" to listOfNotNull(message, baseModelName?.let { "Model: $it." }).joinToString(" "),
    )

private val artworkDraftPrompt = """
Analyze this artwork photo locally on the device. Return compact JSON only with these optional string keys:
visualSummary, signatureNotes, subjectMatter, mediumHint, stylePeriodHint, conditionNotes.
Also include searchTerms as an array of up to 5 short strings.
Use cautious wording. Do not claim attribution, authenticity, appraisal, or market value.
Use null or omit a field when the photo does not support it.
""".trimIndent()

private fun parseDraftResponse(outputText: String): Map<String, Any?> {
    val jsonText = outputText
        .replace(Regex("^```(?:json)?\\s*", RegexOption.IGNORE_CASE), "")
        .replace(Regex("\\s*```$"), "")
        .trim()
    val json = JSONObject(jsonText)
    return mapOf(
        "visualSummary" to json.optionalString("visualSummary"),
        "signatureNotes" to json.optionalString("signatureNotes"),
        "subjectMatter" to json.optionalString("subjectMatter"),
        "mediumHint" to json.optionalString("mediumHint"),
        "stylePeriodHint" to json.optionalString("stylePeriodHint"),
        "conditionNotes" to json.optionalString("conditionNotes"),
        "searchTerms" to json.optionalStringArray("searchTerms"),
    )
}

private fun JSONObject.optionalString(name: String): String? =
    opt(name)
        ?.takeUnless { it == JSONObject.NULL }
        ?.toString()
        ?.trim()
        ?.takeIf { it.isNotBlank() && !it.equals("null", ignoreCase = true) }

private fun JSONObject.optionalStringArray(name: String): List<String> {
    val array = optJSONArray(name) ?: JSONArray()
    return (0 until array.length())
        .mapNotNull { index -> array.optString(index).trim().takeIf { it.isNotBlank() } }
        .take(5)
}
