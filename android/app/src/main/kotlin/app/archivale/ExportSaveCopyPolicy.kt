package app.archivale

import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

internal object ExportSaveCopyPolicy {
    private val safeId = Regex("^[A-Za-z0-9_-]{1,128}$")
    private val sha256 = Regex("^[a-f0-9]{64}$")
    private val canonicalUtc =
        Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}(?:\\d{3})?Z$")
    private val metadataKeys =
        setOf(
            "metadata_version",
            "state",
            "artifact_id",
            "kind",
            "subject_id",
            "file_name",
            "mime_type",
            "byte_size",
            "checksum_sha256",
            "created_at",
            "warnings",
        )

    fun openValidated(
        sourceFile: File,
        applicationDocumentsDirectory: File,
        suggestedName: String,
        mimeType: String,
        payload: FileInputStream,
        metadataPayload: InputStream,
    ): ValidatedExportSource? {
        return try {
            val exportRoot = File(applicationDocumentsDirectory.absoluteFile, "generated_exports")
            val absoluteSource = sourceFile.absoluteFile.toPath().normalize().toFile()
            val canonicalSource = sourceFile.canonicalFile
            if (Files.isSymbolicLink(sourceFile.toPath()) || !canonicalSource.isFile) {
                return null
            }
            val metadata = parseMetadata(metadataPayload) ?: return null
            val extension = if (metadata.kind == "report") "pdf" else "zip"
            val directory = if (metadata.kind == "report") "reports" else "archives"
            val expected = File(exportRoot, "$directory/${metadata.artifactId}.$extension")
                .absoluteFile
                .toPath()
                .normalize()
                .toFile()
            if (
                absoluteSource != expected ||
                canonicalSource != expected.canonicalFile ||
                metadata.fileName != expected.name ||
                suggestedName != metadata.fileName ||
                mimeType != metadata.mimeType ||
                (metadata.kind == "report" && metadata.subjectId == null) ||
                (metadata.kind == "archive" && metadata.subjectId != null)
            ) {
                return null
            }
            val initial = digest(payload)
            if (initial.byteSize != metadata.byteSize || initial.checksum != metadata.checksum) {
                return null
            }
            payload.channel.position(0)
            ValidatedExportSource(payload, metadata)
        } catch (_: Exception) {
            null
        }
    }

    fun isSafeSuggestedName(name: String): Boolean =
        name.isNotBlank() &&
            name.length <= 160 &&
            !name.contains('/') &&
            !name.contains('\\') &&
            name.none { it.code < 0x20 || it.code == 0x7f }

    private fun parseMetadata(input: InputStream): CommittedExportMetadata? {
        val bytes = input.readBytes()
        if (bytes.isEmpty() || bytes.size > 64 * 1024) return null
        val value = JSONObject(bytes.toString(Charsets.UTF_8))
        val keys = value.keys().asSequence().toSet()
        if (keys != metadataKeys || value.opt("metadata_version") != 1 || value.opt("state") != "complete") {
            return null
        }
        val artifactId = value.opt("artifact_id") as? String ?: return null
        val kind = value.opt("kind") as? String ?: return null
        val fileName = value.opt("file_name") as? String ?: return null
        val mimeType = value.opt("mime_type") as? String ?: return null
        val byteSizeValue = value.opt("byte_size")
        if (byteSizeValue !is Int && byteSizeValue !is Long) return null
        val byteSize = (byteSizeValue as Number).toLong()
        val checksum = value.opt("checksum_sha256") as? String ?: return null
        val createdAt = value.opt("created_at") as? String ?: return null
        val warnings = value.opt("warnings") as? JSONArray ?: return null
        if (!canonicalUtc.matches(createdAt) || (0 until warnings.length()).any { warnings.opt(it) !is String }) {
            return null
        }
        val subjectValue = value.opt("subject_id")
        val subjectId = when (subjectValue) {
            JSONObject.NULL -> null
            is String -> subjectValue
            else -> return null
        }
        val expectedMime = if (kind == "report") "application/pdf" else "application/zip"
        val expectedExtension = if (kind == "report") ".pdf" else ".zip"
        if (
            !safeId.matches(artifactId) ||
            kind !in setOf("report", "archive") ||
            !isSafeSuggestedName(fileName) ||
            !fileName.endsWith(expectedExtension) ||
            mimeType != expectedMime ||
            byteSize < 1 ||
            !sha256.matches(checksum) ||
            (subjectId != null && !safeId.matches(subjectId))
        ) {
            return null
        }
        if (
            (kind == "report" &&
                (subjectId == null ||
                    !artifactId.startsWith("report-${subjectId.sha256().take(24)}-"))) ||
            (kind == "archive" && !artifactId.startsWith("archive-"))
        ) {
            return null
        }
        return CommittedExportMetadata(
            artifactId = artifactId,
            kind = kind,
            subjectId = subjectId,
            fileName = fileName,
            mimeType = mimeType,
            byteSize = byteSize,
            checksum = checksum,
        )
    }

    private fun digest(input: InputStream): CopyDigest {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var byteSize = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
            byteSize += count
        }
        return CopyDigest(byteSize, digest.digest().toHex())
    }

    internal data class CommittedExportMetadata(
        val artifactId: String,
        val kind: String,
        val subjectId: String?,
        val fileName: String,
        val mimeType: String,
        val byteSize: Long,
        val checksum: String,
    )

    internal class ValidatedExportSource(
        private val payload: FileInputStream,
        val metadata: CommittedExportMetadata,
    ) : AutoCloseable {
        fun revalidateAndCopy(destination: OutputStream): Boolean {
            return try {
                payload.channel.position(0)
                val beforeCopy = digest(payload)
                if (
                    beforeCopy.byteSize != metadata.byteSize ||
                    beforeCopy.checksum != metadata.checksum
                ) {
                    return false
                }
                payload.channel.position(0)
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                var byteSize = 0L
                while (true) {
                    val count = payload.read(buffer)
                    if (count < 0) break
                    destination.write(buffer, 0, count)
                    digest.update(buffer, 0, count)
                    byteSize += count
                }
                destination.flush()
                byteSize == metadata.byteSize && digest.digest().toHex() == metadata.checksum
            } catch (_: Exception) {
                false
            }
        }

        override fun close() {
            payload.close()
        }
    }

    private data class CopyDigest(val byteSize: Long, val checksum: String)
}

private fun ByteArray.toHex(): String = joinToString("") { byte -> "%02x".format(byte) }

private fun String.sha256(): String =
    MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8)).toHex()
