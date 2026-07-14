package app.archivale

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.os.Bundle
import android.system.Os
import android.system.OsConstants
import org.json.JSONObject
import java.io.File
import java.lang.reflect.Method
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

private object AttachmentCustodyTestNative {
    external fun crashAt(point: String)

    external fun resetHooks()
}

class AttachmentCustodyInstrumentation : Instrumentation() {
    private data class Fingerprint(
        val device: Long,
        val inode: Long,
        val bytes: ByteArray,
        val sha256: String,
    ) {
        override fun equals(other: Any?): Boolean =
            other is Fingerprint &&
                device == other.device &&
                inode == other.inode &&
                bytes.contentEquals(other.bytes) &&
                sha256 == other.sha256

        override fun hashCode(): Int {
            var result = device.hashCode()
            result = 31 * result + inode.hashCode()
            result = 31 * result + bytes.contentHashCode()
            return 31 * result + sha256.hashCode()
        }
    }

    private lateinit var context: Context
    private lateinit var nativeInstance: Any
    private lateinit var nativeExecute: Method

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val results = Bundle()
        val resultCode =
            try {
                setUpHarness()
                testCapabilitiesAndCrashRecoveryUseShippingJni()
                testConcurrencyAndCollisionPreserveWinnerThroughShippingJni()
                testRepeatedLeafAndIntermediateSwapRacesPreserveSentinelThroughShippingJni()
                results.putString(
                    "stream",
                    "PASS capabilities/crash/concurrency/collision; leaf=40x20; intermediate=40x20; sentinel identity/bytes/SHA-256 unchanged\n",
                )
                Activity.RESULT_OK
            } catch (error: Throwable) {
                results.putString("stream", "FAIL ${error.message ?: error.javaClass.simpleName}\n")
                Activity.RESULT_CANCELED
            } finally {
                runCatching { AttachmentCustodyTestNative.resetHooks() }
            }
        finish(resultCode, results)
    }

    private fun testConcurrencyAndCollisionPreserveWinnerThroughShippingJni() {
        withTestDirectory { parent ->
            val root = File(parent, "concurrency-root").apply { mkdirs() }
            val pdf = File(parent, "concurrency.pdf").apply { writeText("%PDF-1.4\npdf-winner\n%%EOF\n") }
            val jpg = File(parent, "concurrency.jpg").apply { writeText("jpeg-winner") }
            var left: JSONObject? = null
            var right: JSONObject? = null
            val first = Thread {
                left = call(root, "publish", pdf, "intent-pdf", "artwork-001", "attachment-001", "payload.pdf")
            }
            val second = Thread {
                right = call(root, "publish", jpg, "intent-jpg", "artwork-001", "attachment-001", "payload.jpg")
            }
            first.start()
            second.start()
            first.join()
            second.join()
            val outcomes = listOf(left!!.getString("outcome"), right!!.getString("outcome"))
            check(outcomes.count { it == "published" } == 1) { "concurrent publication had no unique winner: $outcomes" }
            check(outcomes.all { it == "published" || it == "alreadyExists" || it == "publicationConflict" }) {
                "concurrent publication returned unexpected outcome: $outcomes"
            }
            val payloadDirectory = File(root, "attachments/artworks/artwork-001/attachments/attachment-001")
            val winner = payloadDirectory.listFiles()!!.single { it.name.startsWith("payload.") }
            val before = fingerprint(winner)
            val retrySource = if (winner.name == "payload.pdf") jpg else pdf
            val retryName = if (winner.name == "payload.pdf") "payload.jpg" else "payload.pdf"
            val collision = call(
                root,
                "publish",
                retrySource,
                "intent-collision",
                "artwork-001",
                "attachment-001",
                retryName,
            )
            check(collision.getString("outcome") in setOf("alreadyExists", "publicationConflict")) {
                "collision did not fail closed: ${collision.getString("outcome")}"
            }
            requireEquals(before, fingerprint(winner), "collision overwrote or changed the winning payload")

            val erasureRoot = File(parent, "erasure-concurrency-root").apply { mkdirs() }
            var eraseLeft: JSONObject? = null
            var eraseRight: JSONObject? = null
            val eraseFirst = Thread { eraseLeft = call(erasureRoot, "writeErasureControl", operationId = "erase-left") }
            val eraseSecond = Thread { eraseRight = call(erasureRoot, "writeErasureControl", operationId = "erase-right") }
            eraseFirst.start()
            eraseSecond.start()
            eraseFirst.join()
            eraseSecond.join()
            val erasureOutcomes = listOf(eraseLeft!!.getString("outcome"), eraseRight!!.getString("outcome"))
            check(erasureOutcomes.count { it == "erasureOwned" } == 1 &&
                erasureOutcomes.count { it == "erasureConflict" } == 1
            ) { "erasure owners were not exclusive: $erasureOutcomes" }
        }
    }

    private fun setUpHarness() {
        context = targetContext
        val nativeClass = Class.forName("app.archivale.AttachmentCustodyNative")
        nativeInstance =
            checkNotNull(nativeClass.getDeclaredField("INSTANCE").apply { isAccessible = true }.get(null))
        nativeExecute =
            nativeClass
                .getDeclaredMethod(
                    "execute",
                    String::class.java,
                    String::class.java,
                    String::class.java,
                    String::class.java,
                    String::class.java,
                    String::class.java,
                    String::class.java,
                ).apply { isAccessible = true }
    }

    private fun testCapabilitiesAndCrashRecoveryUseShippingJni() {
        withTestDirectory { parent ->
            val root = File(parent, "root").apply { mkdirs() }
            assertOutcome(call(root, "capabilities"), "available")
            assertOutcome(call(root, "selfTest"), "available")

            val source = File(parent, "source.pdf").apply {
                writeText("%PDF-1.4\nphysical-android-crash-recovery\n%%EOF\n")
            }
            AttachmentCustodyTestNative.crashAt("publish.afterIntentFileFsync")
            try {
                assertOutcome(
                    call(
                        root,
                        "publish",
                        source,
                        "intent-crash",
                        "artwork-001",
                        "attachment-001",
                        "payload.pdf",
                    ),
                    "ioFailure",
                )
            } finally {
                AttachmentCustodyTestNative.resetHooks()
            }
            assertOutcome(
                call(
                    root,
                    "recoverPublication",
                    operationId = "intent-crash",
                    artworkId = "artwork-001",
                    attachmentId = "attachment-001",
                    canonicalName = "payload.pdf",
                ),
                "publicationRecovered",
            )
        }
    }

    private fun testRepeatedLeafAndIntermediateSwapRacesPreserveSentinelThroughShippingJni() {
        withTestDirectory { parent ->
            val sentinel = File(parent, "outside-sentinel").apply {
                writeText("outside-root-sentinel-with-stable-identity")
            }
            val expected = fingerprint(sentinel)
            repeat(RACE_REPETITIONS) { iteration ->
                runLeafRace(parent, sentinel, expected, iteration)
            }
            repeat(RACE_REPETITIONS) { iteration ->
                runIntermediateRace(parent, sentinel, expected, iteration)
            }
        }
    }

    private fun runLeafRace(
        parent: File,
        sentinel: File,
        expected: Fingerprint,
        iteration: Int,
    ) {
        val root = File(parent, "leaf-root-$iteration").apply { mkdirs() }
        val source = File(parent, "leaf-source-$iteration.pdf").apply {
            writeText("%PDF-1.4\nleaf-race-$iteration\n%%EOF\n")
        }
        assertOutcome(
            call(
                root,
                "publish",
                source,
                "leaf-intent-$iteration",
                "artwork-001",
                "attachment-001",
                "payload.pdf",
            ),
            "published",
        )
        val directory =
            File(root, "attachments/artworks/artwork-001/attachments/attachment-001")
        val leaf = File(directory, "payload.pdf")
        val held = File(directory, ".held")
        val stop = AtomicBoolean(false)
        val attacker = Thread {
            while (!stop.get()) {
                ignoreFailure { Os.rename(leaf.path, held.path) }
                ignoreFailure { Os.symlink(sentinel.path, leaf.path) }
                ignoreFailure { Os.remove(leaf.path) }
                ignoreFailure { leaf.writeText("foreign-replacement-$iteration") }
                ignoreFailure { Os.remove(leaf.path) }
                ignoreFailure { Os.rename(held.path, leaf.path) }
            }
        }
        attacker.start()
        try {
            repeat(RACE_ATTEMPTS) { attempt ->
                call(
                    root,
                    "remove",
                    artworkId = "artwork-001",
                    attachmentId = "attachment-001",
                    canonicalName = "payload.pdf",
                )
                requireEquals(
                    expected,
                    fingerprint(sentinel),
                    "leaf iteration=$iteration attempt=$attempt changed sentinel",
                )
            }
        } finally {
            stop.set(true)
            attacker.join()
        }
        requireEquals(expected, fingerprint(sentinel), "leaf iteration=$iteration changed sentinel after join")
        removeTree(root)
        source.delete()
    }

    private fun runIntermediateRace(
        parent: File,
        sentinel: File,
        expected: Fingerprint,
        iteration: Int,
    ) {
        val root = File(parent, "intermediate-root-$iteration").apply { mkdirs() }
        val source = File(parent, "intermediate-source-$iteration.pdf").apply {
            writeText("%PDF-1.4\nintermediate-race-$iteration\n%%EOF\n")
        }
        assertOutcome(
            call(
                root,
                "publish",
                source,
                "intermediate-intent-$iteration",
                "artwork-001",
                "attachment-001",
                "payload.pdf",
            ),
            "published",
        )
        val attachmentParent = File(root, "attachments/artworks/artwork-001/attachments")
        val attachment = File(attachmentParent, "attachment-001")
        val held = File(attachmentParent, "attachment-held")
        val outside = File(parent, "outside-directory-$iteration").apply { mkdirs() }
        File(outside, "payload.pdf").writeText("outside-replacement-$iteration")
        val stop = AtomicBoolean(false)
        val attacker = Thread {
            while (!stop.get()) {
                ignoreFailure { Os.rename(attachment.path, held.path) }
                ignoreFailure { Os.symlink(outside.path, attachment.path) }
                ignoreFailure { Os.remove(attachment.path) }
                ignoreFailure { Os.rename(held.path, attachment.path) }
            }
        }
        attacker.start()
        try {
            repeat(RACE_ATTEMPTS) { attempt ->
                call(
                    root,
                    "remove",
                    artworkId = "artwork-001",
                    attachmentId = "attachment-001",
                    canonicalName = "payload.pdf",
                )
                requireEquals(
                    expected,
                    fingerprint(sentinel),
                    "intermediate iteration=$iteration attempt=$attempt changed sentinel",
                )
            }
        } finally {
            stop.set(true)
            attacker.join()
        }
        requireEquals(
            expected,
            fingerprint(sentinel),
            "intermediate iteration=$iteration changed sentinel after join",
        )
        removeTree(root)
        source.delete()
        removeTree(outside)
    }

    private fun call(
        root: File,
        operation: String,
        source: File? = null,
        operationId: String = "",
        artworkId: String = "",
        attachmentId: String = "",
        canonicalName: String = "",
    ): JSONObject =
        JSONObject(
            nativeExecute.invoke(
                nativeInstance,
                root.path,
                operation,
                source?.path.orEmpty(),
                operationId,
                artworkId,
                attachmentId,
                canonicalName,
            ) as String,
        )

    private fun assertOutcome(result: JSONObject, expected: String) {
        check(result.getString("outcome") == expected) {
            "expected $expected but received ${result.getString("outcome")}: ${result.optString("detail")}"
        }
    }

    private fun requireEquals(expected: Fingerprint, actual: Fingerprint, message: String) {
        check(expected == actual) { message }
    }

    private fun fingerprint(file: File): Fingerprint {
        val status = Os.lstat(file.path)
        val bytes = file.readBytes()
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return Fingerprint(
            status.st_dev,
            status.st_ino,
            bytes,
            digest.joinToString("") { "%02x".format(it) },
        )
    }

    private fun withTestDirectory(block: (File) -> Unit) {
        val parent = File(context.cacheDir, "attachment-custody-${System.nanoTime()}")
        check(parent.mkdirs()) { "could not create instrumentation fixture" }
        try {
            block(parent)
        } finally {
            removeTree(parent)
        }
    }

    private fun removeTree(file: File) {
        val status = runCatching { Os.lstat(file.path) }.getOrNull() ?: return
        if (OsConstants.S_ISDIR(status.st_mode)) {
            file.listFiles()?.forEach(::removeTree)
            ignoreFailure { Os.remove(file.path) }
        } else {
            ignoreFailure { Os.remove(file.path) }
        }
    }

    private fun ignoreFailure(action: () -> Unit) {
        runCatching(action)
    }

    companion object {
        private const val RACE_REPETITIONS = 40
        private const val RACE_ATTEMPTS = 20
    }
}
