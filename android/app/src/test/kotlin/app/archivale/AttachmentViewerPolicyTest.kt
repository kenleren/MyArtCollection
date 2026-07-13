package app.archivale

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test

class AttachmentViewerPolicyTest {
    private lateinit var privateDataDirectory: File
    private lateinit var applicationDocumentsDirectory: File
    private lateinit var attachmentRoot: File

    @Before
    fun setUp() {
        privateDataDirectory = Files.createTempDirectory("attachment-viewer-policy-").toFile()
        applicationDocumentsDirectory = File(privateDataDirectory, "app_flutter")
        attachmentRoot = File(applicationDocumentsDirectory, "attachments/artworks")
        assertTrue(attachmentRoot.mkdirs())
    }

    @After
    fun tearDown() {
        privateDataDirectory.deleteRecursively()
    }

    @Test
    fun acceptsPayloadUnderPathProviderApplicationDocumentsRoot() {
        val payload = payloadAt(File(attachmentRoot, "artwork-001/attachment-001/payload.pdf"))

        assertTrue(
            AttachmentViewerPolicy.isSupportingAttachmentPayload(
                payload,
                applicationDocumentsDirectory,
            ),
        )
    }

    @Test
    fun rejectsLegacyFilesDirRoot() {
        val payload = payloadAt(
            File(privateDataDirectory, "files/attachments/artworks/artwork-001/payload.pdf"),
        )

        assertFalse(
            AttachmentViewerPolicy.isSupportingAttachmentPayload(
                payload,
                applicationDocumentsDirectory,
            ),
        )
    }

    @Test
    fun rejectsSiblingWithAttachmentRootPrefix() {
        val payload = payloadAt(
            File(applicationDocumentsDirectory, "attachments/artworks-copy/payload.pdf"),
        )

        assertFalse(
            AttachmentViewerPolicy.isSupportingAttachmentPayload(
                payload,
                applicationDocumentsDirectory,
            ),
        )
    }

    @Test
    fun rejectsSymlinkThatResolvesOutsideAttachmentRoot() {
        val outsidePayload = payloadAt(File(applicationDocumentsDirectory, "outside/payload.pdf"))
        val link = File(attachmentRoot, "artwork-001/attachment-001/payload.pdf")
        assertTrue(requireNotNull(link.parentFile).mkdirs())
        Files.createSymbolicLink(link.toPath(), outsidePayload.toPath())

        assertFalse(
            AttachmentViewerPolicy.isSupportingAttachmentPayload(
                link,
                applicationDocumentsDirectory,
            ),
        )
    }

    @Test
    fun rejectsMissingPayloadInsideAttachmentRoot() {
        val missing = File(attachmentRoot, "artwork-001/attachment-001/payload.pdf")

        assertFalse(
            AttachmentViewerPolicy.isSupportingAttachmentPayload(
                missing,
                applicationDocumentsDirectory,
            ),
        )
    }

    @Test
    fun launchesWithoutPackageVisibilityPreflight() {
        var launchCount = 0

        val launched = AttachmentViewerPolicy.launchSupportingAttachment(
            launch = { launchCount += 1 },
            isActivityNotFound = { false },
        )

        assertTrue(launched)
        assertTrue(launchCount == 1)
    }

    @Test
    fun returnsFalseWhenNoViewerHandlesTheIntent() {
        val noHandler = NoAttachmentViewerException()

        val launched = AttachmentViewerPolicy.launchSupportingAttachment(
            launch = { throw noHandler },
            isActivityNotFound = { error -> error === noHandler },
        )

        assertFalse(launched)
    }

    @Test
    fun doesNotHideUnexpectedLaunchFailures() {
        val unexpected = IllegalStateException("synthetic unexpected failure")

        assertThrows(IllegalStateException::class.java) {
            AttachmentViewerPolicy.launchSupportingAttachment(
                launch = { throw unexpected },
                isActivityNotFound = { false },
            )
        }
    }

    private fun payloadAt(file: File): File {
        assertTrue(requireNotNull(file.parentFile).mkdirs())
        file.writeText("synthetic attachment fixture")
        return file
    }

    private class NoAttachmentViewerException : RuntimeException()
}
