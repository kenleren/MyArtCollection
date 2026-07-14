package app.archivale

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AttachmentCustodyNativeAccessTest {
    @Test
    fun firstAndSubsequentMissingLibraryAttemptsStayUnavailable() {
        var loadAttempts = 0
        val bindings = RecordingBindings()
        val access = AttachmentCustodyNativeAccess(
            loadLibrary = {
                loadAttempts += 1
                if (loadAttempts == 1) {
                    throw UnsatisfiedLinkError("injected missing library")
                }
                throw NoClassDefFoundError("injected poisoned loader")
            },
            bindings = bindings,
        )
        var destinationActions = 0

        repeat(3) {
            assertEquals(
                "unavailable",
                attemptSave(access) { destinationActions += 1 },
            )
            assertNull(attemptCustody(access))
        }

        assertEquals(1, loadAttempts)
        assertEquals(0, bindings.calls)
        assertEquals(0, bindings.liveDescriptors)
        assertEquals(0, destinationActions)
    }

    @Test
    fun linkageFailureAtEitherNativeEntryIsCachedUnavailable() {
        val openBindings = PoisonedBindings()
        val openAccess = AttachmentCustodyNativeAccess(
            loadLibrary = {},
            bindings = openBindings,
        )
        var destinationActions = 0

        repeat(3) {
            assertEquals(
                "unavailable",
                attemptSave(openAccess) { destinationActions += 1 },
            )
            assertNull(attemptCustody(openAccess))
        }
        assertEquals(1, openBindings.openCalls)
        assertEquals(0, openBindings.executeCalls)

        val executeBindings = PoisonedBindings()
        val executeAccess = AttachmentCustodyNativeAccess(
            loadLibrary = {},
            bindings = executeBindings,
        )
        repeat(3) {
            assertNull(attemptCustody(executeAccess))
            assertEquals(
                "unavailable",
                attemptSave(executeAccess) { destinationActions += 1 },
            )
        }

        assertEquals(0, executeBindings.openCalls)
        assertEquals(1, executeBindings.executeCalls)
        assertEquals(0, destinationActions)
    }

    private fun attemptSave(
        access: AttachmentCustodyNativeAccess,
        destinationAction: () -> Unit,
    ): String {
        val descriptors = access.openExportPair("private-root", "committed-export")
        if (descriptors.size != 2) return "unavailable"
        destinationAction()
        return "ready"
    }

    private fun attemptCustody(access: AttachmentCustodyNativeAccess): String? =
        access.execute(
            flutterRoot = "private-root",
            operation = "capabilities",
            sourcePath = "",
            operationId = "",
            artworkId = "",
            attachmentId = "",
            canonicalName = "",
        )

    private class RecordingBindings : AttachmentCustodyNativeBindings {
        var calls = 0
        var liveDescriptors = 0

        override fun execute(
            flutterRoot: String,
            operation: String,
            sourcePath: String,
            operationId: String,
            artworkId: String,
            attachmentId: String,
            canonicalName: String,
        ): String {
            calls += 1
            return "{}"
        }

        override fun openExportPair(flutterRoot: String, sourcePath: String): IntArray {
            calls += 1
            liveDescriptors += 2
            return intArrayOf(10, 11)
        }
    }

    private class PoisonedBindings : AttachmentCustodyNativeBindings {
        var executeCalls = 0
        var openCalls = 0

        override fun execute(
            flutterRoot: String,
            operation: String,
            sourcePath: String,
            operationId: String,
            artworkId: String,
            attachmentId: String,
            canonicalName: String,
        ): String {
            executeCalls += 1
            throw NoClassDefFoundError("injected poisoned custody binding")
        }

        override fun openExportPair(flutterRoot: String, sourcePath: String): IntArray {
            openCalls += 1
            throw NoClassDefFoundError("injected poisoned export binding")
        }
    }
}
