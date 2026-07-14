package app.archivale

import java.util.concurrent.atomic.AtomicBoolean

internal interface AttachmentCustodyNativeBindings {
    fun execute(
        flutterRoot: String,
        operation: String,
        sourcePath: String,
        operationId: String,
        artworkId: String,
        attachmentId: String,
        canonicalName: String,
    ): String

    fun openExportPair(
        flutterRoot: String,
        sourcePath: String,
    ): IntArray
}

internal class AttachmentCustodyNativeAccess(
    private val loadLibrary: () -> Unit,
    private val bindings: AttachmentCustodyNativeBindings,
) {
    private val linkageUnavailable = AtomicBoolean(false)
    private val libraryAvailable: Boolean by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        try {
            loadLibrary()
            true
        } catch (_: LinkageError) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    fun execute(
        flutterRoot: String,
        operation: String,
        sourcePath: String,
        operationId: String,
        artworkId: String,
        attachmentId: String,
        canonicalName: String,
    ): String? {
        if (linkageUnavailable.get() || !libraryAvailable) return null
        return try {
            bindings.execute(
                flutterRoot,
                operation,
                sourcePath,
                operationId,
                artworkId,
                attachmentId,
                canonicalName,
            )
        } catch (_: LinkageError) {
            linkageUnavailable.set(true)
            null
        }
    }

    fun openExportPair(
        flutterRoot: String,
        sourcePath: String,
    ): IntArray {
        if (linkageUnavailable.get() || !libraryAvailable) return IntArray(0)
        return try {
            bindings.openExportPair(flutterRoot, sourcePath)
        } catch (_: LinkageError) {
            linkageUnavailable.set(true)
            IntArray(0)
        }
    }
}

private object AttachmentCustodyJni : AttachmentCustodyNativeBindings {
    external override fun execute(
        flutterRoot: String,
        operation: String,
        sourcePath: String,
        operationId: String,
        artworkId: String,
        attachmentId: String,
        canonicalName: String,
    ): String

    external override fun openExportPair(
        flutterRoot: String,
        sourcePath: String,
    ): IntArray
}

internal object AttachmentCustodyNative {
    private val access = AttachmentCustodyNativeAccess(
        loadLibrary = { System.loadLibrary("attachment_custody") },
        bindings = AttachmentCustodyJni,
    )

    fun execute(
        flutterRoot: String,
        operation: String,
        sourcePath: String,
        operationId: String,
        artworkId: String,
        attachmentId: String,
        canonicalName: String,
    ): String? = access.execute(
        flutterRoot,
        operation,
        sourcePath,
        operationId,
        artworkId,
        attachmentId,
        canonicalName,
    )

    fun openExportPair(
        flutterRoot: String,
        sourcePath: String,
    ): IntArray = access.openExportPair(flutterRoot, sourcePath)
}
