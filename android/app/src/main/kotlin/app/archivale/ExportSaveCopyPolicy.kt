package app.archivale

import java.io.File
import java.io.InputStream
import java.io.OutputStream

internal object ExportSaveCopyPolicy {
    private val allowedMimeTypes = setOf("application/pdf", "application/zip")

    fun isGeneratedExport(
        sourceFile: File,
        applicationDocumentsDirectory: File,
    ): Boolean {
        return try {
            val exportRoot =
                File(applicationDocumentsDirectory, "generated_exports").canonicalFile
            val candidate = sourceFile.canonicalFile
            candidate.isFile &&
                candidate.path.startsWith(exportRoot.path + File.separator)
        } catch (_: Exception) {
            false
        }
    }

    fun isAllowedMimeType(mimeType: String): Boolean = mimeType in allowedMimeTypes

    fun isSafeSuggestedName(name: String): Boolean =
        name.isNotBlank() &&
            name.length <= 160 &&
            !name.contains('/') &&
            !name.contains('\\') &&
            name.none { it.code < 0x20 || it.code == 0x7f }

    fun copy(source: InputStream, destination: OutputStream) {
        source.copyTo(destination, bufferSize = 64 * 1024)
        destination.flush()
    }
}
