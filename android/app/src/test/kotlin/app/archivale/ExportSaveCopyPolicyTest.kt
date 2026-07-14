package app.archivale

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.file.Files
import java.security.MessageDigest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ExportSaveCopyPolicyTest {
    private lateinit var privateDataDirectory: File
    private lateinit var applicationDocumentsDirectory: File
    private lateinit var exportRoot: File

    @Before
    fun setUp() {
        privateDataDirectory = Files.createTempDirectory("export-save-policy-").toFile()
        applicationDocumentsDirectory = File(privateDataDirectory, "app_flutter")
        exportRoot = File(applicationDocumentsDirectory, "generated_exports")
        assertTrue(exportRoot.mkdirs())
    }

    @After
    fun tearDown() {
        privateDataDirectory.deleteRecursively()
    }

    @Test
    fun acceptsOnlyExactCommittedArtifactGeometryAndMetadata() {
        val report = committedReport()
        validate(report)?.use { source ->
            assertTrue(source.metadata.kind == "report")
            assertTrue(source.metadata.mimeType == "application/pdf")
        } ?: throw AssertionError("Expected a validated report")

        val metadata = File("${report.path}.json")
        val original = metadata.readText()
        metadata.writeText(original.replace("\"state\":\"complete\"", "\"state\":\"partial\""))
        assertNull(validate(report))
        metadata.writeText(original)

        assertNull(validate(report, suggestedName = "other.pdf"))
        assertNull(validate(report, mimeType = "application/zip"))
        assertNull(validate(metadata, suggestedName = metadata.name))

        val wrongDirectory = File(exportRoot, "archives/${report.name}")
        assertTrue(requireNotNull(wrongDirectory.parentFile).mkdirs())
        report.copyTo(wrongDirectory)
        metadata.copyTo(File("${wrongDirectory.path}.json"))
        assertNull(validate(wrongDirectory))
    }

    @Test
    fun rejectsMissingCorruptExtraAndMismatchedMetadata() {
        val report = committedReport()
        val metadata = File("${report.path}.json")
        val original = metadata.readText()

        metadata.writeText("{}")
        assertNull(validate(report))
        metadata.writeText(original.dropLast(1) + ",\"extra\":true}")
        assertNull(validate(report))
        metadata.writeText(JSONObject(original).put("byte_size", "3").toString())
        assertNull(validate(report))
        metadata.writeText(JSONObject(original).put("created_at", 7).toString())
        assertNull(validate(report))
        metadata.writeText(JSONObject(original).put("warnings", "none").toString())
        assertNull(validate(report))
        metadata.writeText(original.replace(report.sha256(), "0".repeat(64)))
        assertNull(validate(report))
        metadata.writeText(original)
        report.writeBytes(byteArrayOf(9, 9, 9))
        assertNull(validate(report))
    }

    @Test
    fun rejectsInsideAndOutsideRootSymlinks() {
        val report = committedReport()
        val insideLink = File(report.parentFile, "${report.nameWithoutExtension}-link.pdf")
        Files.createSymbolicLink(insideLink.toPath(), report.toPath())
        File("${report.path}.json").copyTo(File("${insideLink.path}.json"))
        assertNull(validate(insideLink, suggestedName = insideLink.name))

        val outside = File(applicationDocumentsDirectory, "private.pdf").also {
            it.writeBytes(byteArrayOf(1, 2, 3))
        }
        val outsideLink = File(report.parentFile, "outside-link.pdf")
        Files.createSymbolicLink(outsideLink.toPath(), outside.toPath())
        File("${report.path}.json").copyTo(File("${outsideLink.path}.json"))
        assertNull(validate(outsideLink, suggestedName = outsideLink.name))
    }

    @Test
    fun heldDescriptorIgnoresPostPickerPathReplacement() {
        val originalBytes = ByteArray(200_000) { index -> (index % 251).toByte() }
        val report = committedReport(originalBytes)
        val source = validate(report)
        assertNotNull(source)

        val replacement = ByteArray(originalBytes.size) { 7 }
        assertTrue(report.delete())
        report.writeBytes(replacement)
        val output = ByteArrayOutputStream()

        source!!.use {
            assertTrue(it.revalidateAndCopy(output))
        }
        assertArrayEquals(originalBytes, output.toByteArray())
    }

    @Test
    fun sameInodeMutationAfterPickerFailsBeforeCopy() {
        val originalBytes = ByteArray(200_000) { index -> (index % 251).toByte() }
        val report = committedReport(originalBytes)
        val source = validate(report)
        assertNotNull(source)

        report.writeBytes(ByteArray(originalBytes.size) { 4 })
        source!!.use {
            assertFalse(it.revalidateAndCopy(ByteArrayOutputStream()))
        }
    }

    @Test
    fun allowsOnlySafeSuggestedNames() {
        assertTrue(ExportSaveCopyPolicy.isSafeSuggestedName("report-1.pdf"))
        assertFalse(ExportSaveCopyPolicy.isSafeSuggestedName("../private.pdf"))
        assertFalse(ExportSaveCopyPolicy.isSafeSuggestedName("archive/record.zip"))
    }

    private fun committedReport(bytes: ByteArray = byteArrayOf(1, 2, 3)): File {
        val subjectId = "artwork-1"
        val id = "report-${subjectId.sha256().take(24)}-1"
        val report = File(exportRoot, "reports/$id.pdf")
        assertTrue(requireNotNull(report.parentFile).mkdirs())
        report.writeBytes(bytes)
        val metadata = JSONObject()
            .put("metadata_version", 1)
            .put("state", "complete")
            .put("artifact_id", id)
            .put("kind", "report")
            .put("subject_id", subjectId)
            .put("file_name", report.name)
            .put("mime_type", "application/pdf")
            .put("byte_size", bytes.size)
            .put("checksum_sha256", bytes.sha256())
            .put("created_at", "2026-07-14T09:00:00.000Z")
            .put("warnings", emptyList<String>())
        File("${report.path}.json").writeText(metadata.toString())
        return report
    }

    private fun validate(
        file: File,
        suggestedName: String = file.name,
        mimeType: String = "application/pdf",
    ): ExportSaveCopyPolicy.ValidatedExportSource? {
        val payload = try {
            FileInputStream(file)
        } catch (_: Exception) {
            return null
        }
        val metadata = try {
            FileInputStream(File("${file.path}.json"))
        } catch (_: Exception) {
            payload.close()
            return null
        }
        val validated = metadata.use {
            ExportSaveCopyPolicy.openValidated(
                sourceFile = file,
                applicationDocumentsDirectory = applicationDocumentsDirectory,
                suggestedName = suggestedName,
                mimeType = mimeType,
                payload = payload,
                metadataPayload = it,
            )
        }
        if (validated == null) payload.close()
        return validated
    }
}

private fun ByteArray.sha256(): String =
    MessageDigest.getInstance("SHA-256").digest(this).joinToString("") { "%02x".format(it) }

private fun File.sha256(): String = readBytes().sha256()

private fun String.sha256(): String = toByteArray(Charsets.UTF_8).sha256()
