package com.slopus.happy.ui.conversation

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.width
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.assertDp
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File

/** The full-screen picture: dragged away up or down, springing back when let go short, and never while zoomed. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PictureViewerTest {
    @get:Rule
    val rule = createComposeRule()

    private var closed = 0

    private fun show() {
        val png = ByteArrayOutputStream().also {
            Bitmap.createBitmap(40, 30, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.GREEN) }.compress(Bitmap.CompressFormat.PNG, 100, it)
        }.toByteArray()
        rule.setHappyContent { PictureViewer(png, "viewer-test", "a picture") { closed++ } }
        rule.waitForIdle()
        rule.node(PictureViewerTags.IMAGE).assertExists()
    }

    @Test fun `a long drag down puts it away`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeDown(startY = centerY, endY = centerY + 600f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `a fling up puts it away too`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeUp(startY = centerY, endY = centerY - 200f, durationMillis = 60) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `let go short and slow it springs back`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput {
            down(center)
            // 60 dp over half a second: past the slop, short of 100 dp, too slow to fling.
            repeat(10) {
                advanceEventTime(50)
                moveBy(Offset(0f, 18f))
            }
            advanceEventTime(200)
            up()
        }
        rule.waitForIdle()
        assertEquals(0, closed)
        assertDp("back in place", 0, rule.node(PictureViewerTags.IMAGE).getBoundsInRoot().top)
        rule.node(PictureViewerTags.VIEWER).assertExists()
    }

    @Test fun `held halfway, the picture follows the finger and the black is half gone`() {
        show()
        val start = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        rule.node(PictureViewerTags.IMAGE).performTouchInput {
            down(center)
            // 891 tall: the black is gone 445.5 down; this is about half of that.
            repeat(12) {
                advanceEventTime(40)
                moveBy(Offset(0f, 18.5f * 3))
            }
        }
        rule.waitForIdle()
        val moved = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        // Carried about 222 down (less the touch slop) and shrunk around its middle.
        assertTrue("followed the finger: ${moved.top}", moved.top > start.top + 150.dp)
        assertTrue("shrank", moved.width < start.width)
        val viewer = rule.node(PictureViewerTags.VIEWER).captureToImage().asAndroidBitmap()
        val ground = viewer.getPixel(6, 6)
        assertTrue("the black fades: ${Integer.toHexString(ground)}", android.graphics.Color.alpha(ground) in 100..170)
        val dir = File("build/conversation-screens").apply { mkdirs() }
        File(dir, "picture-viewer-dragging.png").outputStream().use { viewer.compress(Bitmap.CompressFormat.PNG, 100, it) }
        rule.node(PictureViewerTags.IMAGE).performTouchInput { up() }
        rule.waitForIdle()
        assertEquals("let go past 100 dp, it goes", 1, closed)
    }

    @Test fun `zoomed in, a drag pans instead of closing`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { doubleClick(center) }
        rule.waitForIdle()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeDown(startY = centerY, endY = centerY + 600f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(0, closed)
    }

    @Test fun `its button closes it after the fade`() {
        show()
        rule.node(PictureViewerTags.CLOSE).performClickSafely()
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    private fun androidx.compose.ui.test.SemanticsNodeInteraction.performClickSafely() = performTouchInput { click(center) }
}
