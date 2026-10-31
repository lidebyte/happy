package com.slopus.happy.ui.artifacts

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.slopus.happy.R
import com.slopus.happy.artifacts.ArtifactMedia
import com.slopus.happy.artifacts.ArtifactMediaItem
import com.slopus.happy.artifacts.formatDuration
import com.slopus.happy.conversation.MediaFiles
import com.slopus.happy.ui.components.MaterialSymbols
import com.slopus.happy.ui.components.RemoteImage
import com.slopus.happy.ui.theme.happyTextStyle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

object ArtifactViewerTags {
    const val VIEWER = "artifact.viewer"
    const val CLOSE = "artifact.viewer.close"
    const val SHARE = "artifact.viewer.share"
    const val VIDEO = "artifact.viewer.video"
    const val PLAY = "artifact.viewer.play"
}

/**
 * The artifact's pictures and recordings whole on black (iOS's
 * `PictureViewController` over `ArtifactMedia`), swiped between in their
 * order: a picture pinched to 1–5 times and dragged while larger, a double
 * tap toggling 2×; a recording playing in its page with play, pause and a
 * scrubber, read a range at a time. Close top right, Share top left: the
 * item as a file named as the artifact names it, so the share sheet can
 * save it. Back or Close leaves.
 */
@Composable
fun ArtifactViewer(items: List<ArtifactMediaItem>, index: Int, media: ArtifactMedia, onClose: () -> Unit) {
    if (items.isEmpty()) return
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val pager = rememberPagerState(initialPage = index.coerceIn(0, items.lastIndex)) { items.size }
        val context = LocalContext.current
        val scope = rememberCoroutineScope()
        var sharing by remember { mutableStateOf(false) }
        Box(Modifier.fillMaxSize().background(Color.Black).testTag(ArtifactViewerTags.VIEWER)) {
            HorizontalPager(pager, Modifier.fillMaxSize(), key = { items[it].key }) { page ->
                val item = items[page]
                if (item.isVideo) VideoPage(item, media, active = pager.currentPage == page) else PicturePage(item, media)
            }
            Row(
                Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                IconButton(
                    onClick = {
                        if (sharing) return@IconButton
                        sharing = true
                        val item = items[pager.currentPage]
                        scope.launch {
                            try {
                                val file = media.shareable(item.key, File(context.cacheDir, MediaFiles.DIRECTORY)) ?: return@launch
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.conversation.media", file)
                                val type = context.contentResolver.getType(uri) ?: if (item.isVideo) "video/*" else "image/*"
                                val send = Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            } catch (_: ActivityNotFoundException) {
                            } catch (_: IllegalArgumentException) {
                            } finally {
                                sharing = false
                            }
                        }
                    },
                    colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
                    modifier = Modifier.size(44.dp).testTag(ArtifactViewerTags.SHARE),
                ) {
                    if (sharing) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                    else Icon(MaterialSymbols.Share, stringResource(R.string.artifact_share))
                }
                IconButton(
                    onClick = onClose,
                    colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
                    modifier = Modifier.size(44.dp).testTag(ArtifactViewerTags.CLOSE),
                ) {
                    Icon(MaterialSymbols.Close, stringResource(R.string.conversation_picture_close))
                }
            }
        }
    }
}

@Composable
private fun PicturePage(item: ArtifactMediaItem, media: ArtifactMedia) {
    val bytes by produceState<ByteArray?>(null, item.key) { value = media.data(item.key) }
    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val shown = bytes
        if (shown == null) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
        } else {
            RemoteImage(
                model = shown,
                cacheKey = "artifact/${media.artifactId}/${media.version}/${item.key}/full",
                contentDescription = item.label,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offsetX, translationY = offsetY)
                    .pointerInput(Unit) {
                        detectTapGestures(onDoubleTap = {
                            scale = if (scale > 1f) 1f else 2f
                            offsetX = 0f
                            offsetY = 0f
                        })
                    }
                    .pointerInput(Unit) {
                        // Only while zoomed does a drag move the picture; at 1× it pages.
                        detectTransformGestures(panZoomLock = true) { _, pan, zoom, _ ->
                            scale = (scale * zoom).coerceIn(1f, 5f)
                            if (scale > 1f) {
                                offsetX += pan.x
                                offsetY += pan.y
                            } else {
                                offsetX = 0f
                                offsetY = 0f
                            }
                        }
                    },
            )
        }
    }
}

/**
 * A recording in its page: the platform's player reading the artifact's
 * file a range at a time ([ArtifactMedia.videoSource]), started when the
 * page is in view and paused when it isn't, with play/pause, a scrubber and
 * the time under it.
 */
@Composable
private fun VideoPage(item: ArtifactMediaItem, media: ArtifactMedia, active: Boolean) {
    val source = remember(item.key) { media.videoSource(item.key) }
    val player = remember(item.key) { MediaPlayer() }
    var prepared by remember { mutableStateOf(false) }
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableIntStateOf(0) }
    var duration by remember { mutableIntStateOf(0) }
    var ratio by remember { mutableFloatStateOf(16f / 9f) }
    var failed by remember { mutableStateOf(false) }
    DisposableEffect(player) {
        try {
            source?.let(player::setDataSource) ?: run { failed = true }
            player.setOnPreparedListener {
                prepared = true
                duration = it.duration.coerceAtLeast(0)
            }
            player.setOnVideoSizeChangedListener { _, w, h -> if (w > 0 && h > 0) ratio = w.toFloat() / h }
            player.setOnCompletionListener { playing = false }
            player.setOnErrorListener { _, _, _ ->
                failed = true
                playing = false
                true
            }
            if (source != null) player.prepareAsync()
        } catch (_: Exception) {
            failed = true
        }
        onDispose {
            runCatching { player.release() }
            source?.close()
        }
    }
    LaunchedEffect(prepared, active) {
        if (!prepared) return@LaunchedEffect
        if (active) {
            player.start()
            playing = true
        } else if (player.isPlaying) {
            player.pause()
            playing = false
        }
    }
    LaunchedEffect(playing) {
        while (playing) {
            position = runCatching { player.currentPosition }.getOrDefault(position)
            delay(250)
        }
    }
    Box(Modifier.fillMaxSize().testTag(ArtifactViewerTags.VIDEO), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { ctx ->
                TextureView(ctx).apply {
                    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                        private var surface: Surface? = null
                        override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
                            surface = Surface(texture).also { runCatching { player.setSurface(it) } }
                        }

                        override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) = Unit

                        override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                            runCatching { player.setSurface(null) }
                            surface?.release()
                            surface = null
                            return true
                        }

                        override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                    }
                }
            },
            modifier = Modifier.fillMaxWidth().aspectRatio(ratio),
        )
        if (!prepared && !failed) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(24.dp))
        if (failed) Text(stringResource(R.string.artifact_file_unavailable), color = Color.White, style = happyTextStyle(fontSize = 15, lineHeight = 20))
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            IconButton(
                onClick = {
                    if (!prepared) return@IconButton
                    if (player.isPlaying) {
                        player.pause()
                        playing = false
                    } else {
                        player.start()
                        playing = true
                    }
                },
                modifier = Modifier.size(48.dp).clip(CircleShape).background(PlayFill).testTag(ArtifactViewerTags.PLAY),
                colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
            ) {
                Icon(
                    if (playing) MaterialSymbols.Pause else MaterialSymbols.PlayArrow,
                    stringResource(if (playing) R.string.artifact_pause else R.string.artifact_play),
                )
            }
            Slider(
                value = if (duration > 0) position.toFloat() / duration else 0f,
                onValueChange = { fraction ->
                    if (prepared && duration > 0) {
                        position = (fraction * duration).toInt()
                        player.seekTo(position)
                    }
                },
                enabled = prepared && duration > 0,
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.3f)),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(formatDuration(position / 1000.0), color = Color.White, style = happyTextStyle(fontSize = 12, lineHeight = 16))
                Text(formatDuration(duration / 1000.0), color = Color.White, style = happyTextStyle(fontSize = 12, lineHeight = 16))
            }
        }
    }
}
