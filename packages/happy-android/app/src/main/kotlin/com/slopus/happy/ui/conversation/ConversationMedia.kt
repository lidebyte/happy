package com.slopus.happy.ui.conversation

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.exifinterface.media.ExifInterface
import com.slopus.happy.conversation.MediaFlow
import com.slopus.happy.conversation.MediaItem
import com.slopus.happy.ui.components.Icon
import com.slopus.happy.ui.components.Ionicon
import com.slopus.happy.ui.components.RemoteImage
import com.slopus.happy.ui.components.ThumbHash
import com.slopus.happy.ui.theme.HappyTheme
import java.io.ByteArrayInputStream
import kotlin.math.roundToInt

/** A picture tile's look: iOS's `ChatMediaView`. */
object ConversationMediaSpec {
    val radius = 8.dp
    val outline = 1.dp
    val failedIcon = 20.dp
}

object ConversationMediaTags {
    /** Every picture tile; the flow they sit in is [FLOW]. */
    const val TILE = "conversation.media.tile"
    const val FLOW = "conversation.media.flow"
}

/**
 * Pictures shown together, as iOS lays a conversation's out ([MediaFlow]):
 * planned from their shapes before any bytes arrive, then placed at the
 * width this is given. [measure] turns that width (dp) into the flow's own;
 * with [alignEnd] the flow is pushed against the right edge, the rest
 * left clear, as a person's photos hug the right as their bubble does.
 * Otherwise the flow takes the width its tiles use, from the left.
 *
 * Every tile is measured at exactly its frame, so a tile is its picture's
 * own shape before, while and after it loads, and nothing moves when it
 * lands.
 */
@Composable
fun MediaFlowLayout(
    images: List<MediaFlow.Image>,
    modifier: Modifier = Modifier,
    columns: Int = 0,
    limits: MediaFlow.Limits = MediaFlow.tool,
    alignEnd: Boolean = false,
    measure: (Float) -> Float = { it },
    tile: @Composable (index: Int) -> Unit,
) {
    Layout(
        content = { images.indices.forEach { index -> key(index) { tile(index) } } },
        modifier = modifier.testTag(ConversationMediaTags.FLOW),
    ) { measurables, constraints ->
        val available = if (constraints.hasBoundedWidth) constraints.maxWidth / density else FALLBACK_WIDTH
        val room = measure(available).coerceAtLeast(0f)
        val flow = MediaFlow.layout(images, room, columns, limits, alignEnd)
        val shift = if (alignEnd) available - room else 0f
        fun px(dp: Float) = (dp * density).roundToInt()
        val placeables = measurables.mapIndexed { index, measurable ->
            val frame = flow.frames.getOrNull(index) ?: MediaFlow.Frame(0f, 0f, 0f, 0f)
            // Each edge rounded on its own, so neighbours never overlap or open a gap.
            val width = (px(frame.right + shift) - px(frame.x + shift)).coerceAtLeast(0)
            val height = (px(frame.bottom) - px(frame.y)).coerceAtLeast(0)
            measurable.measure(Constraints.fixed(width, height))
        }
        val width = if (alignEnd) px(available) else px(flow.width)
        layout(width.coerceIn(constraints.minWidth, constraints.maxWidth), px(flow.height).coerceAtLeast(constraints.minHeight)) {
            placeables.forEachIndexed { index, placeable ->
                val frame = flow.frames.getOrNull(index) ?: return@forEachIndexed
                placeable.place(px(frame.x + shift), px(frame.y))
            }
        }
    }
}

/** Only where a flow is given no width to fill (never in the transcript). */
private const val FALLBACK_WIDTH = 360f

/**
 * One picture of a conversation's, as iOS's `ChatMediaView` draws it: the
 * picture whole in a tile of its own shape, on surfacePressed until it
 * lands, a 1 dp divider hairline over the whole tile and corners rounded
 * 8. [placeholder] (a thumbhash) shows until then. A picture that couldn't
 * be had keeps its ground under a quiet image glyph.
 */
@Composable
fun MediaTile(
    bytes: ByteArray?,
    cacheKey: String,
    contentDescription: String?,
    failed: Boolean,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    placeholder: ImageBitmap? = null,
) {
    val colors = HappyTheme.colors
    val shape = RoundedCornerShape(ConversationMediaSpec.radius)
    Box(
        modifier
            .testTag(ConversationMediaTags.TILE)
            .clip(shape)
            .background(colors.surfacePressed)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .border(ConversationMediaSpec.outline, colors.divider, shape),
        contentAlignment = Alignment.Center,
    ) {
        if (bytes != null && !failed) {
            RemoteImage(
                model = bytes,
                cacheKey = cacheKey,
                contentDescription = contentDescription,
                // The tile is the picture's shape: fitted, it fills it.
                contentScale = ContentScale.Fit,
                placeholder = placeholder,
                modifier = Modifier.matchParentSize(),
            )
        } else if (placeholder != null && !failed) {
            androidx.compose.foundation.Image(placeholder, null, Modifier.matchParentSize(), contentScale = ContentScale.FillBounds)
        }
        if (failed) Icon(Ionicon.ImageOutline, ConversationMediaSpec.failedIcon, colors.textSecondary)
    }
}

/** What the flow knows of a presented picture before its bytes arrive: as stated, else its thumbhash's shape. */
internal fun MediaItem.flowImage(): MediaFlow.Image = MediaFlow.Image(
    width = width?.toFloat(),
    height = height?.toFloat(),
    scale = scale?.toFloat(),
    hashedRatio = hashedRatio(thumbhash),
)

/** The width over height a ThumbHash's header carries; null for no hash or one too short. */
internal fun hashedRatio(thumbhash: String?): Float? {
    if (thumbhash.isNullOrEmpty()) return null
    return try {
        val hash = Base64.decode(thumbhash.replace('-', '+').replace('_', '/'), Base64.DEFAULT)
        if (hash.size < 5) null else ThumbHash.approximateAspectRatio(hash).takeIf { it > 0f && it.isFinite() }
    } catch (_: IllegalArgumentException) {
        null
    }
}

/**
 * A picture's upright pixel size, read from its header alone (iOS's
 * `ChatPlanner.pictureSize`): EXIF orientations 5 to 8 turn it on its side,
 * as the image loader will. An unreadable header knows nothing, and the
 * flow falls back to 4:3.
 */
internal fun pictureSize(bytes: ByteArray): MediaFlow.Image {
    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    val width = options.outWidth
    val height = options.outHeight
    if (width <= 0 || height <= 0) return MediaFlow.Image()
    val orientation = try {
        ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } catch (_: Exception) {
        ExifInterface.ORIENTATION_NORMAL
    }
    val turned = orientation in ExifInterface.ORIENTATION_TRANSPOSE..ExifInterface.ORIENTATION_ROTATE_270
    return if (turned) MediaFlow.Image(height.toFloat(), width.toFloat()) else MediaFlow.Image(width.toFloat(), height.toFloat())
}
