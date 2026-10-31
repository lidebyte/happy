package com.slopus.happy.ui.artifacts

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.slopus.happy.R
import com.slopus.happy.ui.components.MaterialSymbols
import com.slopus.happy.ui.conversation.ConversationScreenTags
import com.slopus.happy.ui.theme.HappyTheme
import com.slopus.happy.ui.theme.happyTextStyle
import kotlinx.coroutines.delay

object PlaceTags {
    const val LOADER = "place.loader"
    const val MESSAGE = "place.message"
}

/**
 * The bar of an agent's place (artifacts, an artifact, a Surface, a page):
 * back, the title on one line, and [actions]; on the page's own surface, as
 * iOS pushes these screens over home.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PlaceScaffold(
    title: String,
    onBack: () -> Unit,
    tag: String,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable () -> Unit,
) {
    val colors = HappyTheme.colors
    Column(Modifier.fillMaxSize().background(colors.surface).testTag(tag)) {
        TopAppBar(
            title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = {
                IconButton(onClick = onBack, modifier = Modifier.testTag(ConversationScreenTags.BACK)) {
                    Icon(MaterialSymbols.ArrowBack, stringResource(R.string.conversation_back))
                }
            },
            actions = actions,
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = colors.surface,
                scrolledContainerColor = colors.surface,
                titleContentColor = colors.text,
                navigationIconContentColor = colors.text,
                actionIconContentColor = colors.text,
            ),
        )
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) { content() }
    }
}

/**
 * The loading state of these screens: a plain spinner in the middle that
 * fades in once the wait is long enough to notice, so a quick read shows
 * nothing at all. One line to swap for the app's shared loader when it lands.
 */
@Composable
internal fun PlaceLoader(modifier: Modifier = Modifier) {
    val alpha = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(LOADER_DELAY)
        alpha.animateTo(1f, tween(LOADER_FADE))
    }
    Box(modifier.fillMaxSize().testTag(PlaceTags.LOADER), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = HappyTheme.colors.textSecondary,
            strokeWidth = 2.dp,
            modifier = Modifier.size(24.dp).graphicsLayer { this.alpha = alpha.value },
        )
    }
}

private const val LOADER_DELAY = 400L
private const val LOADER_FADE = 250

/** iOS's message label on these screens: 15pt in the row grey, centred, 16 in from the sides, 8 down. */
@Composable
internal fun PlaceMessage(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = happyTextStyle(fontSize = 15, lineHeight = 20),
        color = HappyTheme.colors.textSecondary,
        textAlign = TextAlign.Center,
        modifier = modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp).testTag(PlaceTags.MESSAGE),
    )
}
