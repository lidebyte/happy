package com.slopus.happy.journeys

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.ui.HappyApp
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.chat.ComposeChatTags
import com.slopus.happy.ui.chat.ComposerTags
import com.slopus.happy.ui.components.HeaderTags
import com.slopus.happy.ui.home.FlatRowTags
import com.slopus.happy.ui.home.HomeServices
import com.slopus.happy.ui.home.HomeTags
import com.slopus.happy.ui.node
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Compose's empty chat when the computer is slow: Back before it has
 * answered stops the start, and the text stays in the draft for the next
 * compose.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ComposeJourneyTest {
    @get:Rule val rule = createComposeRule()

    private val journey = Journey()
    private val server = journey.server

    @After
    fun tearDown() = journey.close()

    @Test
    fun leavingBeforeTheComputerAnswersStopsTheStartAndKeepsTheText() {
        journey.machine()
        journey.session("s0", updatedAt = 100, title = "Existing chat")
        // The computer never answers.
        server.silentRpc += "${Journey.MACHINE}:spawn-happy-session"
        val graph = journey.graph()
        journey.signIn(graph)
        val newSession = HomeServices.of(graph).newSession(ApplicationProvider.getApplicationContext())
        rule.setContent { HappyApp(graph) }
        rule.waitFor(FlatRowTags.ROW)

        rule.node(HomeTags.COMPOSE).performClick()
        rule.waitFor(ComposeChatTags.TARGET)
        rule.node(ComposerTags.INPUT).performTextInput("Plan the release")
        rule.node(ComposerTags.PRIMARY).performClick()
        rule.waitUntil(10_000) { newSession.starter.phase.value != null }

        rule.node(HeaderTags.LEFT).performClick()
        rule.waitUntilDoesNotExist(hasTestTag(ComposeChatTags.TARGET), 5_000)
        rule.waitFor(HomeTags.COMPOSE)
        rule.waitUntil(5_000) { newSession.starter.phase.value == null }
        assertEquals("Plan the release", newSession.draft.value.input)

        rule.node(HomeTags.COMPOSE).performClick()
        rule.waitFor(ComposeChatTags.TARGET)
        rule.node(ComposerTags.INPUT).assertTextEquals("Plan the release")
    }
}
