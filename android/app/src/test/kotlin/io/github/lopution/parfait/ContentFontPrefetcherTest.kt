package io.github.lopution.parfait

import org.junit.Assert.assertEquals
import org.junit.Test

class ContentFontPrefetcherTest {
    // Trimmed from a ColorOS fonts.xml: whitespace around file names, axis
    // children, comma-separated langs, an `ignore`d emoji family.
    private val config =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <familyset>
            <family name="sans-serif">
                <font weight="400" style="normal">Roboto-Regular.ttf
                  <axis tag="wght" stylevalue="400" />
                </font>
            </family>
            <family-list name="google-sans">
                <family><font weight="400" style="normal">GoogleSans.ttf</font></family>
            </family-list>
            <family lang="und-Thai">
                <font weight="400" style="normal">NotoSansThai-Regular.ttf</font>
            </family>
            <family lang="und-Khmr">
                <font weight="400" style="normal">NotoSansKhmer-VF.ttf</font>
            </family>
            <family lang="zh-Hans">
                <font weight="400" style="normal">SysSans-Hans-Regular.ttf
                </font>
                <font weight="400" style="normal" index="2" fallbackFor="serif">NotoSerifCJK-Regular.ttc
                </font>
            </family>
            <family lang="zh-Hant,zh-Bopo">
                <font weight="400" style="normal">SysSans-Hant-Regular.ttf</font>
            </family>
            <family lang="ja">
                <font weight="400" style="normal" index="0">
                    NotoSansCJK-Regular.ttc
                </font>
            </family>
            <family lang="ko">
                <font weight="400" style="normal" index="1">NotoSansCJK-Regular.ttc</font>
            </family>
            <family lang="und-Zsye" ignore="true">
                <font weight="400" style="normal">NotoColorEmojiLegacy.ttf</font>
            </family>
            <family lang="und-Zsye">
                <font weight="400" style="normal">NotoColorEmoji.ttf</font>
            </family>
        </familyset>
        """.trimIndent()

    private val sizes =
        mapOf(
            "NotoSansThai-Regular.ttf" to 40_000L,
            "NotoSansKhmer-VF.ttf" to 3_000_000L,
        )

    @Test
    fun `CJK and emoji fallbacks in full, other fallbacks only when small`() {
        val files =
            contentFontFiles(config.byteInputStream()) { sizes[it] ?: 30_000_000L }
        assertEquals(
            listOf(
                "NotoSansThai-Regular.ttf",
                "SysSans-Hans-Regular.ttf",
                "SysSans-Hant-Regular.ttf",
                "NotoSansCJK-Regular.ttc",
                "NotoColorEmojiLegacy.ttf",
                "NotoColorEmoji.ttf",
            ),
            files,
        )
    }
}
