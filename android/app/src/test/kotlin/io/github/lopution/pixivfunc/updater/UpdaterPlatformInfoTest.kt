package io.github.lopution.pixivfunc.updater

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM coverage for the hex helper. `platformInfo` / `packageInfo` /
 * `signerSha256` need [android.content.pm.PackageInfo] and are not
 * exercised here (no Robolectric).
 */
class UpdaterPlatformInfoTest {
    @Test
    fun `sha256Hex of empty bytes is the empty SHA-256 digest`() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            UpdaterPlatformInfo.sha256Hex(ByteArray(0)),
        )
    }

    @Test
    fun `sha256Hex formats a fake signature as lowercase hex`() {
        assertEquals(
            "26a66b061e8f48f39927c312f25293959729eee95978e2892d49d3512a5cc092",
            UpdaterPlatformInfo.sha256Hex(byteArrayOf(0x00, 0x01, 0xff.toByte())),
        )
    }
}
