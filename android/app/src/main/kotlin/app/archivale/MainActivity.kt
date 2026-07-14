package app.archivale

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
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
import java.io.File

private object AttachmentCustodyNative {
    init {
        System.loadLibrary("attachment_custody")
    }

    external fun execute(
        flutterRoot: String,
        operation: String,
        sourcePath: String,
        operationId: String,
        artworkId: String,
        attachmentId: String,
        canonicalName: String,
    ): String

    external fun openExportPair(
        flutterRoot: String,
        sourcePath: String,
    ): IntArray
}

class MainActivity : FlutterActivity() {
    private companion object {
        const val CREATE_EXPORT_DOCUMENT_REQUEST = 47178
    }

    private val onDeviceAiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var onDeviceAiProvider: MlKitPromptOnDeviceAiProvider? = null
    private var pendingExportSave: PendingExportSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.archivale/on_device_ai",
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.archivale/attachment_viewer",
        ).setMethodCallHandler { call, result ->
            if (call.method != "openSupportingAttachment") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val uri = call.argument<String>("uri")
            val mimeType = call.argument<String>("mimeType")
            result.success(
                uri != null && mimeType != null && openSupportingAttachment(uri, mimeType),
            )
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.archivale/export_destination",
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveCopy") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val sourcePath = call.argument<String>("sourcePath")
            val suggestedName = call.argument<String>("suggestedName")
            val mimeType = call.argument<String>("mimeType")
            if (
                sourcePath == null ||
                suggestedName == null ||
                mimeType == null ||
                !ExportSaveCopyPolicy.isSafeSuggestedName(suggestedName)
            ) {
                result.success("unavailable")
                return@setMethodCallHandler
            }
            val sourceFile = File(sourcePath)
            val applicationDocumentsDirectory = getDir("flutter", Context.MODE_PRIVATE)
            if (pendingExportSave != null) {
                result.success("unavailable")
                return@setMethodCallHandler
            }
            val source = openValidatedExportSource(
                sourceFile = sourceFile,
                applicationDocumentsDirectory = applicationDocumentsDirectory,
                suggestedName = suggestedName,
                mimeType = mimeType,
            )
            if (source == null) {
                result.success("unavailable")
                return@setMethodCallHandler
            }
            val createIntent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = source.metadata.mimeType
                putExtra(Intent.EXTRA_TITLE, source.metadata.fileName)
            }
            try {
                pendingExportSave = PendingExportSave(source) { outcome -> result.success(outcome) }
                startActivityForResult(createIntent, CREATE_EXPORT_DOCUMENT_REQUEST)
            } catch (_: ActivityNotFoundException) {
                pendingExportSave?.finish("unavailable")
                pendingExportSave = null
            } catch (_: SecurityException) {
                pendingExportSave?.finish("unavailable")
                pendingExportSave = null
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.archivale/attachment_custody_v1",
        ).setMethodCallHandler { call, result ->
            val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
            val response = try {
                AttachmentCustodyNative.execute(
                    getDir("flutter", Context.MODE_PRIVATE).absolutePath,
                    call.method,
                    arguments["sourcePath"] as? String ?: "",
                    arguments["operationId"] as? String ?: "",
                    arguments["artworkId"] as? String ?: "",
                    arguments["attachmentId"] as? String ?: "",
                    arguments["canonicalName"] as? String ?: "",
                )
            } catch (_: UnsatisfiedLinkError) {
                "{\"outcome\":\"unsupported\",\"detail\":\"Native attachment custody is unavailable.\"}"
            } catch (_: Exception) {
                "{\"outcome\":\"ioFailure\",\"detail\":\"Native attachment custody failed.\"}"
            }
            try {
                result.success(JSONObject(response).toMethodChannelMap())
            } catch (_: Exception) {
                result.success(mapOf("outcome" to "ioFailure", "detail" to "Invalid native custody response."))
            }
        }
    }

    @Deprecated("Activity result callback is required for ACTION_CREATE_DOCUMENT.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != CREATE_EXPORT_DOCUMENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingExportSave
        pendingExportSave = null
        if (pending == null) return
        val destination = data?.data
        ExportSaveCallbackPolicy.complete(
            pending = pending,
            accepted = resultCode == Activity.RESULT_OK && destination != null,
            copy = {
                val output = contentResolver.openOutputStream(requireNotNull(destination), "w")
                if (output == null) {
                    false
                } else {
                    output.use { pending.source.revalidateAndCopy(it) }
                }
            },
            cleanup = {
                if (contentResolver.delete(requireNotNull(destination), null, null) == 0) {
                    contentResolver.openOutputStream(destination, "wt")?.close()
                }
            },
        )
    }

    override fun onDestroy() {
        pendingExportSave?.finish("unavailable")
        pendingExportSave = null
        onDeviceAiProvider?.close()
        onDeviceAiScope.cancel()
        super.onDestroy()
    }

    private fun nativeOnDeviceAiProvider(): MlKitPromptOnDeviceAiProvider {
        return onDeviceAiProvider ?: MlKitPromptOnDeviceAiProvider(onDeviceAiScope).also {
            onDeviceAiProvider = it
        }
    }

    private fun openSupportingAttachment(uriString: String, mimeType: String): Boolean {
        val sourceUri = Uri.parse(uriString)
        if (sourceUri.scheme != "file") {
            return false
        }
        val sourceFile = try {
            File(sourceUri.path ?: return false)
        } catch (_: IllegalArgumentException) {
            return false
        }
        if (!isSupportingAttachmentPayload(sourceFile)) {
            return false
        }

        val scopedUri = try {
            FileProvider.getUriForFile(
                this,
                "${BuildConfig.APPLICATION_ID}.fileProvider",
                sourceFile,
            )
        } catch (_: IllegalArgumentException) {
            return false
        }
        val openIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(scopedUri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return AttachmentViewerPolicy.launchSupportingAttachment(
            launch = { startActivity(openIntent) },
            isActivityNotFound = { error -> error is ActivityNotFoundException },
        )
    }

    private fun isSupportingAttachmentPayload(sourceFile: File): Boolean {
        val applicationDocumentsDirectory = getDir("flutter", Context.MODE_PRIVATE)
        return AttachmentViewerPolicy.isSupportingAttachmentPayload(
            sourceFile,
            applicationDocumentsDirectory,
        )
    }

    private fun openValidatedExportSource(
        sourceFile: File,
        applicationDocumentsDirectory: File,
        suggestedName: String,
        mimeType: String,
    ): ExportSaveCopyPolicy.ValidatedExportSource? {
        var payload: ParcelFileDescriptor.AutoCloseInputStream? = null
        var metadata: ParcelFileDescriptor.AutoCloseInputStream? = null
        return try {
            val descriptors = AttachmentCustodyNative.openExportPair(
                applicationDocumentsDirectory.absolutePath,
                sourceFile.absolutePath,
            )
            if (descriptors.size != 2) return null
            payload = ParcelFileDescriptor.AutoCloseInputStream(
                ParcelFileDescriptor.adoptFd(descriptors[0]),
            )
            metadata = ParcelFileDescriptor.AutoCloseInputStream(
                ParcelFileDescriptor.adoptFd(descriptors[1]),
            )
            metadata.use { metadataPayload ->
                ExportSaveCopyPolicy.openValidated(
                    sourceFile = sourceFile,
                    applicationDocumentsDirectory = applicationDocumentsDirectory,
                    suggestedName = suggestedName,
                    mimeType = mimeType,
                    payload = requireNotNull(payload),
                    metadataPayload = metadataPayload,
                )
            }.also { validated ->
                if (validated == null) payload.close()
            }
        } catch (_: UnsatisfiedLinkError) {
            try {
                payload?.close()
            } catch (_: Exception) {
                // The native linkage failure wins.
            }
            null
        } catch (_: Exception) {
            try {
                payload?.close()
            } catch (_: Exception) {
                // The original validation failure wins.
            }
            null
        }
    }
}

internal class PendingExportSave(
    val source: ExportSaveSource,
    private val result: (String) -> Unit,
) {
    private var finished = false

    fun finish(outcome: String) {
        if (finished) return
        finished = true
        try {
            result(outcome)
        } catch (_: Exception) {
            // Flutter completion errors must not retain the private source descriptor.
        } finally {
            try {
                source.close()
            } catch (_: Exception) {
                // Terminal cleanup is best effort after the descriptor close was attempted.
            }
        }
    }
}

internal object ExportSaveCallbackPolicy {
    fun complete(
        pending: PendingExportSave,
        accepted: Boolean,
        copy: () -> Boolean,
        cleanup: () -> Unit,
    ) {
        if (!accepted) {
            pending.finish("dismissed")
            return
        }
        val completed = try {
            copy()
        } catch (_: Exception) {
            false
        }
        if (!completed) {
            try {
                cleanup()
            } catch (_: Exception) {
                // The provider may not allow cleanup. The operation still fails closed.
            }
        }
        pending.finish(if (completed) "completed" else "unavailable")
    }
}

private fun JSONObject.toMethodChannelMap(): Map<String, Any?> =
    keys().asSequence().associateWith { key -> get(key).toMethodChannelValue() }

private fun Any?.toMethodChannelValue(): Any? =
    when (this) {
        JSONObject.NULL -> null
        is JSONObject -> toMethodChannelMap()
        is JSONArray -> List(length()) { index -> get(index).toMethodChannelValue() }
        else -> this
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
