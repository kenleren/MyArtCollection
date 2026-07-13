package app.archivale

import java.io.File

internal object AttachmentViewerPolicy {
    fun isSupportingAttachmentPayload(
        sourceFile: File,
        applicationDocumentsDirectory: File,
    ): Boolean {
        return try {
            val attachmentRoot =
                File(applicationDocumentsDirectory, "attachments/artworks").canonicalFile
            val candidate = sourceFile.canonicalFile
            candidate.isFile &&
                candidate.path.startsWith(attachmentRoot.path + File.separator)
        } catch (_: Exception) {
            false
        }
    }

    fun launchSupportingAttachment(
        launch: () -> Unit,
        isActivityNotFound: (Throwable) -> Boolean,
    ): Boolean {
        return try {
            launch()
            true
        } catch (error: Throwable) {
            if (isActivityNotFound(error)) {
                false
            } else {
                throw error
            }
        }
    }
}
