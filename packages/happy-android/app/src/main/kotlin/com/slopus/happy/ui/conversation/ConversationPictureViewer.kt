package com.slopus.happy.ui.conversation

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import com.slopus.happy.R
import com.slopus.happy.conversation.PictureDismissal
import com.slopus.happy.ui.components.MaterialSymbols
import com.slopus.happy.ui.components.RemoteImage
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

object PictureViewerTags {
    const val VIEWER = "conversation.picture.viewer"
    const val IMAGE = "conversation.picture.viewer.image"
    const val CLOSE = "conversation.picture.viewer.close"
}

/** The viewer's motion, iOS's PictureViewController. */
object PictureViewerSpec {
    /** The cross-dissolve it comes and goes with. */
    const val FADE_MS = 250
    /** Let go short of closing, it springs back (UIKit's 0.35 s, damping 0.85). */
    const val SPRING_DAMPING = 0.85f
    const val SPRING_STIFFNESS = 322f
    /** Flung away, it carries on off the screen in 0.15 to 0.3 s. */
    const val LEAVE_MIN_MS = 150
    const val LEAVE_MAX_MS = 300
    const val MAX_ZOOM = 5f
    /** A double tap zooms a whole picture to this. */
    const val DOUBLE_TAP_ZOOM = 2.5f
}

/**
 * One picture of the conversation, filling the window over black, as iOS's
 * viewer holds it: the whole picture at once, pinched to 1–5 times and
 * dragged while it is larger than the window, double-tapped in and out.
 * Pinching back to whole resets the position. A whole picture dragged up
 * or down follows the finger, shrinking to 0.8 as the black fades over
 * half the screen ([PictureDismissal]); let go past 100 dp or flung, it
 * carries on off the screen and the viewer goes, otherwise it springs
 * back. It comes and goes with a 250 ms fade; Back, a tap or the close
 * button leaves.
 */
@Composable
fun PictureViewer(bytes: ByteArray, cacheKey: String, name: String?, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val shown = remember { Animatable(0f) }
    var leaving by remember { mutableStateOf(false) }
    val close: () -> Unit = {
        if (!leaving) {
            leaving = true
            scope.launch {
                shown.animateTo(0f, tween(PictureViewerSpec.FADE_MS, easing = FastOutSlowInEasing))
                onClose()
            }
        }
    }
    LaunchedEffect(Unit) { shown.animateTo(1f, tween(PictureViewerSpec.FADE_MS, easing = LinearOutSlowInEasing)) }

    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        // Its own black fades; the window's dim would stay behind it. Light status icons over the black.
        val window = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect {
            window?.setDimAmount(0f)
            window?.let { WindowCompat.getInsetsController(it, it.decorView).isAppearanceLightStatusBars = false }
        }

        val density = LocalDensity.current
        var size by remember { mutableStateOf(IntSize.Zero) }
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        // The dismissal drag, in px; animated back or away once let go.
        var drag by remember { mutableStateOf(Offset.Zero) }
        var settling by remember { mutableStateOf<Job?>(null) }
        val heightDp = with(density) { size.height.toDp().value }
        // Read while drawing, so a drag redraws without recomposing.
        fun dismissal() = PictureDismissal.of(with(density) { drag.y.toDp().value }, 0f, heightDp)

        fun clamp(next: Offset, at: Float): Offset {
            val maxX = size.width * (at - 1) / 2
            val maxY = size.height * (at - 1) / 2
            return Offset(next.x.coerceIn(-maxX, maxX), next.y.coerceIn(-maxY, maxY))
        }

        fun settle(velocityY: Float) {
            val finger = with(density) { drag.y.toDp().value }
            val speed = with(density) { velocityY.toDp().value }
            val outcome = PictureDismissal.of(finger, speed, heightDp)
            settling = scope.launch {
                if (outcome.closes) {
                    // On off the screen the way it was going, as the rest of the black goes.
                    leaving = true
                    val down = if (velocityY == 0f) drag.y >= 0 else velocityY > 0
                    val distance = size.height.toFloat()
                    val remaining = max(1f, distance - abs(drag.y))
                    val ms = (remaining / max(abs(velocityY), 1f) * 1000).toInt()
                        .coerceIn(PictureViewerSpec.LEAVE_MIN_MS, PictureViewerSpec.LEAVE_MAX_MS)
                    animate(Offset.VectorConverter, drag, Offset(drag.x, if (down) distance else -distance), animationSpec = tween(ms, easing = LinearOutSlowInEasing)) { value, _ ->
                        drag = value
                    }
                    onClose()
                } else {
                    animate(
                        Offset.VectorConverter,
                        drag,
                        Offset.Zero,
                        animationSpec = spring(PictureViewerSpec.SPRING_DAMPING, PictureViewerSpec.SPRING_STIFFNESS),
                    ) { value, _ -> drag = value }
                }
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                .onSizeChanged { size = it }
                .drawBehind { drawRect(Color.Black.copy(alpha = shown.value * dismissal().groundAlpha)) }
                .testTag(PictureViewerTags.VIEWER)
                // On the window, not the moving picture: the finger is read where it is on the screen.
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { close() },
                        onDoubleTap = { point ->
                            val from = scale
                            val to = if (from > 1f) 1f else PictureViewerSpec.DOUBLE_TAP_ZOOM
                            val center = Offset(size.width / 2f, size.height / 2f)
                            val start = offset
                            // The tapped point stays under the finger.
                            val end = if (to == 1f) Offset.Zero else clamp((center - point) * (to - 1), to)
                            scope.launch {
                                animate(0f, 1f, animationSpec = tween(PictureViewerSpec.FADE_MS)) { t, _ ->
                                    scale = from + (to - from) * t
                                    offset = start + (end - start) * t
                                }
                            }
                        },
                    )
                }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val first = awaitFirstDown(requireUnconsumed = false)
                        settling?.cancel()
                        val tracker = VelocityTracker()
                        tracker.addPosition(first.uptimeMillis, first.position)
                        var moved = Offset.Zero
                        // Undecided until past the touch slop: a dismissal drag, or pinching and panning.
                        var dismissing: Boolean? = null
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.changes.any { it.isConsumed }) break
                            val fingers = event.changes.count { it.pressed }
                            if (fingers == 0) break
                            val zoom = event.calculateZoom()
                            val pan = event.calculatePan()
                            event.changes.firstOrNull { it.id == first.id }?.let { tracker.addPosition(it.uptimeMillis, it.position) }
                            if (dismissing == null) {
                                moved += pan
                                if (fingers > 1 || zoom != 1f) {
                                    dismissing = false
                                } else if (moved.getDistance() > viewConfiguration.touchSlop) {
                                    // Mostly up or down, on a whole picture, with nothing animating.
                                    dismissing = scale <= 1f && !leaving && abs(moved.y) > abs(moved.x)
                                }
                            }
                            when (dismissing) {
                                true -> drag += pan
                                false -> {
                                    scale = (scale * zoom).coerceIn(1f, PictureViewerSpec.MAX_ZOOM)
                                    offset = if (scale > 1f) clamp(offset + pan, scale) else Offset.Zero
                                }
                                null -> Unit
                            }
                            if (dismissing != null) event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                        if (dismissing == true) settle(tracker.calculateVelocity().y)
                    }
                },
        ) {
            RemoteImage(
                model = bytes,
                cacheKey = cacheKey,
                contentDescription = name,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val shrink = dismissal().scale
                        scaleX = scale * shrink
                        scaleY = scale * shrink
                        translationX = offset.x + drag.x
                        translationY = offset.y + drag.y
                        alpha = shown.value
                    }
                    // Inside the layer: its bounds are where the picture is drawn.
                    .testTag(PictureViewerTags.IMAGE),
            )
            IconButton(
                onClick = close,
                colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .padding(8.dp)
                    .graphicsLayer { alpha = min(shown.value, dismissal().groundAlpha) }
                    .testTag(PictureViewerTags.CLOSE),
            ) {
                Icon(MaterialSymbols.Close, stringResource(R.string.conversation_picture_close))
            }
        }
    }
}

/** The picture a row asked to show full screen, if any. */
@Composable
internal fun rememberPictureViewer(): PictureViewerState = remember { PictureViewerState() }

class PictureViewerState {
    internal var showing by mutableStateOf<Triple<ByteArray, String, String?>?>(null)

    fun show(bytes: ByteArray, cacheKey: String, name: String?) {
        showing = Triple(bytes, cacheKey, name)
    }

    fun close() {
        showing = null
    }
}

/** Draws the picture the conversation asked to show, over everything. */
@Composable
internal fun PictureViewerHost(state: PictureViewerState) {
    val showing = state.showing ?: return
    PictureViewer(showing.first, showing.second, showing.third, state::close)
}
