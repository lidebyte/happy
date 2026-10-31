package com.slopus.happy.ui.conversation

import android.util.Base64
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.slopus.happy.R
import com.slopus.happy.chat.ChatMessage
import com.slopus.happy.chat.ChatRow
import com.slopus.happy.chat.MessageMeta
import com.slopus.happy.chat.ToolCall
import com.slopus.happy.chat.ToolState
import com.slopus.happy.chat.UserDisplay
import com.slopus.happy.conversation.Block
import com.slopus.happy.conversation.ConversationRow
import com.slopus.happy.conversation.Delivery
import com.slopus.happy.conversation.MediaFlow
import com.slopus.happy.conversation.MediaRef
import com.slopus.happy.conversation.NoticeKind
import com.slopus.happy.ui.chat.AgentMessage
import com.slopus.happy.ui.chat.BubblePalette
import com.slopus.happy.ui.chat.MarkdownView
import com.slopus.happy.ui.chat.MessageCallbacks
import com.slopus.happy.ui.chat.ToolView
import com.slopus.happy.ui.chat.UserMessage
import com.slopus.happy.ui.components.Icon
import com.slopus.happy.ui.components.Ionicon
import com.slopus.happy.ui.components.rememberThumbHash
import com.slopus.happy.ui.layout.LocalWindowLayout
import com.slopus.happy.ui.layout.contentMaxWidth
import com.slopus.happy.ui.theme.HappyTheme
import com.slopus.happy.ui.theme.happyTextStyle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

object ConversationRowTags {
    const val REASONING = "conversation.reasoning"
    const val PICTURE = "conversation.picture"
    const val MEDIA = "conversation.media"
    const val MEDIA_FILE = "conversation.media.file"
    const val ARTIFACT = "conversation.artifact"
    const val COLLABORATOR = "conversation.collaborator"
    const val FAILURE = "conversation.failure"
    const val FAILURE_RETRY = "conversation.failure.retry"
    const val NOTICE = "conversation.notice"
}

/** The rows' own measures; text, tools and user bubbles are the legacy chat's (MessageSpec, ToolSpec). */
object ConversationRowSpec {
    val marginHorizontal = 16.dp
    val marginVertical = 6.dp
    val cardRadius = 12.dp
    val cardPadding = 12.dp
    /** Under a bubble's own 4: its photos 8 under it, as iOS. */
    val photosGap = 4.dp
    val label = happyTextStyle(fontSize = 13, lineHeight = 18, weight = FontWeight.SemiBold)
    val body = happyTextStyle(fontSize = 14, lineHeight = 20)
    val notice = happyTextStyle(fontSize = 13, lineHeight = 18)
    val icon = 16.dp
}

/** What the rows ask of the screen. */
class ConversationRowActions(
    val legacy: MessageCallbacks,
    val onRetryFailure: (String) -> Unit,
    /** A presented item's bytes. */
    val loadMedia: suspend (MediaRef) -> ByteArray,
    /** Opens an artifact; null where this build has no viewer, and its card says where it opens. */
    val onOpenArtifact: ((artifactId: String) -> Unit)? = null,
    /** Shows one picture full screen. */
    val onOpenPicture: (bytes: ByteArray, cacheKey: String, name: String?) -> Unit = { _, _, _ -> },
    /** Opens a presented video or file in whatever on the phone reads it. */
    val onOpenMedia: ((MediaRef) -> Unit)? = null,
    /** What that is doing: reading, or why it could not open. */
    val mediaOpening: (MediaRef) -> MediaOpening? = { null },
)

/**
 * One conversation row. User bubbles, agent text and tool rows are the
 * legacy chat's own components (MessageView, ToolView in compact form, so
 * tool output stays hidden); the rest are drawn here. Spec: every row here
 * is 16 in from the sides and 6 above and below. Reasoning: an 13/18
 * semibold "Thinking" line with a 16 chevron in textSecondary, opening to
 * the 14/20 text in textSecondary. Pictures are laid out as iOS lays them
 * ([MediaFlow], [MediaFlowLayout]), each whole in a tile of its own shape
 * ([MediaTile]: radius 8, a divider hairline), 8 apart, planned from their
 * sizes before the bytes come. A person's photos go 8 under their bubble
 * against the right edge, in at most the bubble's width (36 clear at the
 * left, never past 560): one alone up to 360 high, several justified up
 * to 280 high. An agent's, and what a tool presented, from the left edge
 * at the column's measure: one alone up to 640 high, never past its own
 * size; several justified up to 480 high, or in the 1 or 2 columns the
 * tool asked for. Media is read on demand; videos and files are a
 * surfaceHigh card (radius 12, padding 12) naming the file and saying
 * where it opens. Artifacts the same card, with the artifact's title.
 * Another agent's message: "From another agent" (13/18 semibold,
 * textSecondary) over its Markdown. A failure: a
 * surfaceHigh card with the reason in textDestructive and Retry (13/18
 * semibold, link colour) while it can help, "Retried" once acted on. A
 * notice: 13/18 textSecondary, centred.
 */
@Composable
fun ConversationRowView(row: ConversationRow, bubble: BubblePalette, actions: ConversationRowActions) {
    val content = Modifier.contentMaxWidth(LocalWindowLayout.current)
    Box(Modifier.fillMaxWidth()) {
        when (row) {
            is ConversationRow.User -> UserRow(row, bubble, actions, content)
            is ConversationRow.Text -> AgentMessage(
                ChatRow.AgentText(ChatMessage.AgentText(row.key, 0, row.text), row.blocks),
                actions.legacy,
                content,
            )
            is ConversationRow.Tool -> ToolView(
                ChatMessage.ToolCallMessage(
                    id = row.key,
                    createdAt = row.createdAt,
                    tool = ToolCall(
                        callId = row.callId,
                        name = row.name,
                        state = when (row.status) {
                            "completed" -> ToolState.Completed
                            "failed" -> ToolState.Error
                            else -> ToolState.Running
                        },
                        input = row.input,
                        createdAt = row.createdAt,
                    ),
                ),
                actions.legacy,
                content,
            )
            is ConversationRow.Reasoning -> ReasoningRow(row, content)
            is ConversationRow.Picture -> Box(content.fillMaxWidth().padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical)) {
                InlinePictures(row.key, listOf(row.image), actions, MediaFlow.tool, alignEnd = false)
            }
            is ConversationRow.Media -> MediaRow(row, actions, content)
            is ConversationRow.Artifact -> InfoCard(
                icon = Ionicon.LayersOutline,
                title = row.title.ifEmpty { stringResource(R.string.conversation_artifact) },
                detail = stringResource(R.string.conversation_artifact_unavailable).takeIf { actions.onOpenArtifact == null },
                onClick = actions.onOpenArtifact?.let { open -> { open(row.artifactId) } },
                modifier = content.testTag(ConversationRowTags.ARTIFACT),
            )
            is ConversationRow.Collaborator -> CollaboratorRow(row, content)
            is ConversationRow.Failure -> FailureRow(row, actions, content)
            is ConversationRow.Notice -> Text(
                stringResource(
                    when (row.kind) {
                        NoticeKind.Compacting -> R.string.conversation_compacting
                        NoticeKind.Compacted -> R.string.conversation_compacted
                        NoticeKind.CompactionFailed -> R.string.conversation_compaction_failed
                    },
                ),
                style = ConversationRowSpec.notice,
                color = HappyTheme.colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = content
                    .fillMaxWidth()
                    .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical)
                    .testTag(ConversationRowTags.NOTICE),
            )
        }
    }
}

@Composable
private fun UserRow(row: ConversationRow.User, bubble: BubblePalette, actions: ConversationRowActions, modifier: Modifier) {
    val failed = row.delivery as? Delivery.Failed
    // A send waiting behind a running turn reads "Sends after this turn"; one on its way, "Sending…".
    val message = remember(row) {
        ChatMessage.UserText(
            id = row.key,
            localId = row.messageId,
            createdAt = if (row.delivery == Delivery.Sending) System.currentTimeMillis() else 0,
            text = row.text,
            meta = if (row.delivery == Delivery.Pending) MessageMeta(buildJsonObject { put("queuedWhileBusy", JsonPrimitive(true)) }) else null,
            pending = row.delivery == Delivery.Sending || row.delivery == Delivery.Pending,
            sendError = failed?.reason,
        )
    }
    // The photos go under the words, against the right edge as the bubble is.
    val photos = @Composable {
        InlinePictures(row.key, row.pictures, actions, MediaFlow.message, alignEnd = true, measure = MediaFlow::messageMeasure)
    }
    if (row.text.isNotEmpty() || failed != null) {
        UserMessage(
            ChatRow.User(message, UserDisplay.Text(row.text, row.blocks), failedLocalId = row.messageId.takeIf { failed != null }),
            bubble,
            actions.legacy,
            modifier.fillMaxWidth(),
            attachments = if (row.pictures.isEmpty()) null else {
                { Box(Modifier.padding(top = ConversationRowSpec.photosGap)) { photos() } }
            },
        )
    } else if (row.pictures.isNotEmpty()) {
        Box(
            modifier
                .fillMaxWidth()
                .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical),
        ) { photos() }
    }
}

/** A message's own pictures, read from the bytes it carries: their shapes from their headers, before they decode. */
@Composable
private fun InlinePictures(
    key: String,
    pictures: List<Block.Image>,
    actions: ConversationRowActions,
    limits: MediaFlow.Limits,
    alignEnd: Boolean,
    measure: (Float) -> Float = { it },
) {
    val decoded = remember(key, pictures) {
        pictures.map { picture ->
            val bytes = try {
                Base64.decode(picture.data, Base64.DEFAULT)
            } catch (_: IllegalArgumentException) {
                null
            }
            bytes to (bytes?.let(::pictureSize) ?: MediaFlow.Image())
        }
    }
    val label = stringResource(R.string.conversation_picture)
    MediaFlowLayout(
        images = decoded.map { it.second },
        limits = limits,
        alignEnd = alignEnd,
        measure = measure,
        modifier = Modifier.testTag(ConversationRowTags.PICTURE),
    ) { index ->
        val bytes = decoded[index].first
        val cacheKey = "conversation/$key:$index"
        MediaTile(
            bytes = bytes,
            cacheKey = cacheKey,
            contentDescription = label,
            failed = bytes == null,
            onClick = bytes?.let { { actions.onOpenPicture(it, cacheKey, null) } },
        )
    }
}

@Composable
private fun ReasoningRow(row: ConversationRow.Reasoning, modifier: Modifier) {
    val colors = HappyTheme.colors
    var open by rememberSaveable(row.key) { mutableStateOf(false) }
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical)
            .testTag(ConversationRowTags.REASONING),
    ) {
        Row(
            modifier = Modifier.clickable(role = Role.Button) { open = !open },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(stringResource(R.string.conversation_thinking), style = ConversationRowSpec.label, color = colors.textSecondary)
            Icon(if (open) Ionicon.ChevronUp else Ionicon.ChevronDown, ConversationRowSpec.icon, colors.textSecondary)
        }
        if (open) Text(row.text, style = ConversationRowSpec.body, color = colors.textSecondary, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun MediaRow(row: ConversationRow.Media, actions: ConversationRowActions, modifier: Modifier) {
    val visual = row.items.filter { it.item.kind == "image" }
    val other = row.items.filter { it.item.kind != "image" }
    Column(
        modifier.fillMaxWidth().padding(vertical = ConversationRowSpec.marginVertical).testTag(ConversationRowTags.MEDIA),
        verticalArrangement = Arrangement.spacedBy(MediaFlow.GAP.dp),
    ) {
        if (visual.isNotEmpty()) {
            val loads = visual.map { ref -> key(ref.key) { rememberMediaBytes(ref, actions.loadMedia) } }
            // As stated, else the hash's shape; a picture that stated no size takes its own once read.
            val images = visual.mapIndexed { index, ref ->
                val stated = ref.item.flowImage()
                val read = loads[index]?.getOrNull()
                if (MediaFlow.pointSize(stated) == null && read?.size?.width != null) read.size else stated
            }
            MediaFlowLayout(
                images = images,
                columns = row.columns,
                limits = MediaFlow.tool,
                modifier = Modifier.padding(horizontal = ConversationRowSpec.marginHorizontal),
            ) { index ->
                val ref = visual[index]
                val load = loads[index]
                val bytes = load?.getOrNull()?.bytes
                val cacheKey = "conversation/media/${ref.key}"
                MediaTile(
                    bytes = bytes,
                    cacheKey = cacheKey,
                    contentDescription = ref.item.name.ifEmpty { stringResource(R.string.conversation_picture) },
                    failed = load?.isFailure == true,
                    onClick = bytes?.let { { actions.onOpenPicture(it, cacheKey, ref.item.name) } },
                    placeholder = rememberThumbHash(ref.item.thumbhash),
                )
            }
        }
        other.forEach { ref ->
            val opening = actions.mediaOpening(ref)
            val open = actions.onOpenMedia
            InfoCard(
                icon = if (ref.item.kind == "video") Ionicon.PlayCircleOutline else Ionicon.DocumentTextOutline,
                title = ref.item.name,
                detail = when {
                    opening is MediaOpening.Failed -> opening.reason
                    opening is MediaOpening.Reading -> stringResource(R.string.conversation_media_reading)
                    open == null -> stringResource(if (ref.item.kind == "video") R.string.conversation_video_unavailable else R.string.conversation_file_unavailable)
                    else -> null
                },
                onClick = open?.let { { it(ref) } },
                modifier = Modifier.testTag(ConversationRowTags.MEDIA_FILE),
                vertical = 0.dp,
            )
        }
    }
}

/** A presented picture's bytes and the size its header gives. */
private class MediaBytes(val bytes: ByteArray, val size: MediaFlow.Image)

/** A presented picture's bytes, read once per item while it is shown; null until they come. */
@Composable
private fun rememberMediaBytes(ref: MediaRef, load: suspend (MediaRef) -> ByteArray): Result<MediaBytes>? {
    val bytes by produceState<Result<MediaBytes>?>(null, ref.key) {
        value = try {
            val bytes = load(ref)
            Result.success(MediaBytes(bytes, withContext(Dispatchers.Default) { pictureSize(bytes) }))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
    return bytes
}

@Composable
private fun InfoCard(
    icon: Ionicon,
    title: String,
    detail: String?,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    vertical: androidx.compose.ui.unit.Dp = ConversationRowSpec.marginVertical,
) {
    val colors = HappyTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = vertical)
            .clip(RoundedCornerShape(ConversationRowSpec.cardRadius))
            .background(colors.surfaceHigh)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(ConversationRowSpec.cardPadding),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, 22.dp, colors.textSecondary)
        Column(Modifier.weight(1f)) {
            Text(title, style = ConversationRowSpec.label, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (detail != null) Text(detail, style = ConversationRowSpec.notice, color = colors.textSecondary)
        }
        if (onClick != null) Icon(Ionicon.ChevronForward, ConversationRowSpec.icon, colors.textSecondary)
    }
}

@Composable
private fun CollaboratorRow(row: ConversationRow.Collaborator, modifier: Modifier) {
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical)
            .testTag(ConversationRowTags.COLLABORATOR),
    ) {
        Text(stringResource(R.string.conversation_from_agent), style = ConversationRowSpec.label, color = HappyTheme.colors.textSecondary)
        if (row.blocks.isNotEmpty()) MarkdownView(row.blocks)
    }
}

@Composable
private fun FailureRow(row: ConversationRow.Failure, actions: ConversationRowActions, modifier: Modifier) {
    val colors = HappyTheme.colors
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = ConversationRowSpec.marginHorizontal, vertical = ConversationRowSpec.marginVertical)
            .clip(RoundedCornerShape(ConversationRowSpec.cardRadius))
            .background(colors.surfaceHigh)
            .padding(ConversationRowSpec.cardPadding)
            .testTag(ConversationRowTags.FAILURE),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Ionicon.AlertCircleOutline, 18.dp, colors.textDestructive)
            Text(row.reason, style = ConversationRowSpec.body, color = colors.textDestructive, modifier = Modifier.weight(1f))
        }
        when {
            row.resolved -> Text(stringResource(R.string.conversation_failure_resolved), style = ConversationRowSpec.label, color = colors.textSecondary)
            row.retryable -> Text(
                stringResource(R.string.common_retry),
                style = ConversationRowSpec.label,
                color = colors.textLink,
                modifier = Modifier
                    .testTag(ConversationRowTags.FAILURE_RETRY)
                    .clickable(role = Role.Button) { actions.onRetryFailure(row.messageId) }
                    .padding(vertical = 4.dp),
            )
        }
    }
}
