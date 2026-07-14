package app.archivale

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
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
    fun acceptsOnlyGeneratedExportPayloads() {
        val report = File(exportRoot, "reports/report-1.pdf").also {
            assertTrue(requireNotNull(it.parentFile).mkdirs())
            it.writeBytes(byteArrayOf(1, 2, 3))
        }
        val outside = File(applicationDocumentsDirectory, "attachments/private.pdf").also {
            assertTrue(requireNotNull(it.parentFile).mkdirs())
            it.writeBytes(byteArrayOf(4, 5, 6))
        }

        assertTrue(
            ExportSaveCopyPolicy.isGeneratedExport(report, applicationDocumentsDirectory),
        )
        assertFalse(
            ExportSaveCopyPolicy.isGeneratedExport(outside, applicationDocumentsDirectory),
        )
    }

    @Test
    fun rejectsSymlinkThatResolvesOutsideExportRoot() {
        val outside = File(applicationDocumentsDirectory, "outside.pdf").also {
            it.writeBytes(byteArrayOf(1))
        }
        val link = File(exportRoot, "reports/report-link.pdf")
        assertTrue(requireNotNull(link.parentFile).mkdirs())
        Files.createSymbolicLink(link.toPath(), outside.toPath())

        assertFalse(
            ExportSaveCopyPolicy.isGeneratedExport(link, applicationDocumentsDirectory),
        )
    }

    @Test
    fun allowsOnlyArchiveAndReportMimeTypesAndSafeNames() {
        assertTrue(ExportSaveCopyPolicy.isAllowedMimeType("application/pdf"))
        assertTrue(ExportSaveCopyPolicy.isAllowedMimeType("application/zip"))
        assertFalse(ExportSaveCopyPolicy.isAllowedMimeType("text/plain"))
        assertTrue(ExportSaveCopyPolicy.isSafeSuggestedName("report-1.pdf"))
        assertFalse(ExportSaveCopyPolicy.isSafeSuggestedName("../private.pdf"))
        assertFalse(ExportSaveCopyPolicy.isSafeSuggestedName("archive/record.zip"))
    }

    @Test
    fun copiesExactBytesToTheUserSelectedDestination() {
        val bytes = ByteArray(200_000) { index -> (index % 251).toByte() }
        val output = ByteArrayOutputStream()

        ExportSaveCopyPolicy.copy(ByteArrayInputStream(bytes), output)

        assertArrayEquals(bytes, output.toByteArray())
    }
}
