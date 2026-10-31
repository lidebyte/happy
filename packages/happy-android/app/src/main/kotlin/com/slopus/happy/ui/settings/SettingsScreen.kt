package com.slopus.happy.ui.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.slopus.happy.R
import com.slopus.happy.model.Profile
import com.slopus.happy.ui.components.Avatar
import com.slopus.happy.ui.components.Icon
import com.slopus.happy.ui.components.Ionicon
import com.slopus.happy.ui.components.Item
import com.slopus.happy.ui.components.ItemGroup
import com.slopus.happy.ui.components.ItemList
import com.slopus.happy.ui.components.Screen
import com.slopus.happy.ui.components.StackHeader
import com.slopus.happy.ui.home.AccountMenu
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

object SettingsTags {
    const val ACCOUNT = "settings.row.account"
    const val BACKUP = "settings.row.backup"
    const val APPEARANCE = "settings.row.appearance"
    const val LANGUAGE = "settings.row.language"
    const val VOICE = "settings.row.voice"
    const val AGENTS = "settings.row.agents"
    const val SCAN_TERMINAL = "settings.row.scanTerminal"
    const val ENTER_TERMINAL = "settings.row.enterTerminal"
    const val VERSION = "settings.version"
    const val SUPPORT = "settings.support"
}

/** SettingsView.tsx, Android: the links and the icon colours the older pages still use. */
object SettingsSpec {
    /** Item icons are 29 Ionicons in the 32 icon slot. */
    val itemIcon = 29.dp

    val blue = Color(0xFF007AFF)
    val indigo = Color(0xFF5856D6)
    val red = Color(0xFFFF3B30)
    val orange = Color(0xFFFF9500)
    val teal = Color(0xFF5AC8FA)

    const val GITHUB_URL = "https://github.com/slopus/happy"
    const val ISSUES_URL = "https://github.com/slopus/happy/issues"
    const val PRIVACY_URL = "https://happy.engineering/privacy/"
    const val TERMS_URL = "https://happy.engineering/terms/"
}

/** A settings row icon: a 29 Ionicon in [color]. */
@Composable
fun ItemIcon(icon: Ionicon, color: Color) {
    Icon(icon = icon, size = SettingsSpec.itemIcon, color = color)
}

/** The profile avatar: the uploaded or GitHub picture when there is one, else generated from the account id. */
@Composable
fun ProfileAvatar(profile: Profile, size: Dp) {
    Avatar(id = profile.id, size = size, imageUri = profile.avatarUrl, thumbhash = profile.avatar?.thumbhash)
}

/**
 * formatBuildSubtitle: "Commit 2026-10-16 03:12 UTC / abc1234" from the
 * build's commit, either part optional; null without both.
 */
fun buildSubtitle(commitSha: String?, commitTimestamp: String?): String? {
    val time = commitTimestamp?.takeIf { it.isNotEmpty() }?.let { value ->
        try {
            OffsetDateTime.parse(value).withOffsetSameInstant(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm 'UTC'"))
        } catch (_: DateTimeParseException) {
            value
        }
    }
    val sha = commitSha?.takeIf { it.isNotEmpty() }?.take(7)
    if (time == null && sha == null) return null
    return listOfNotNull(if (time != null) "Commit $time" else "Commit", sha).joinToString(" / ")
}

/** Everything a Happy account's Settings asks of the app. */
@Immutable
class HappySettingsActions(
    val onBack: () -> Unit = {},
    val onAccount: () -> Unit = {},
    val onBackup: () -> Unit = {},
    val onAppearance: () -> Unit = {},
    val onLanguage: () -> Unit = {},
    val onVoice: () -> Unit = {},
    val onAgents: () -> Unit = {},
    val onScanTerminal: () -> Unit = {},
    val onEnterTerminal: () -> Unit = {},
    /** Signs this account out, once confirmed. */
    val onSignOut: () -> Unit = {},
)

/**
 * A Happy account's Settings, as iOS's SettingsViewController lays out a
 * Happy account's page: its picture, name and "@username" (or "Happy
 * account") at the top ([SettingsHeader]); every account on the phone with
 * Add Agent ([AccountsCard]); Account and Backup & Restore; Appearance,
 * Language, Voice Assistant and Agents; the terminal's Scan QR code and
 * Enter URL; Support us; About; and Logout. Rows carry iOS's coloured
 * tiles ([SettingsTile]). happy-app's Connected Accounts (Claude Code,
 * GitHub) are gone from here, as from iOS.
 *
 * The Version detail is "versionName (versionCode)": happy-app shows
 * "version / runtime N", its OTA runtime, and a native build has none; the
 * version code is what identifies this build instead.
 */
@Composable
fun SettingsScreen(
    profile: SettingsProfile,
    about: AboutInfo,
    accounts: AccountMenu = AccountMenu(),
    accountActions: AccountsCardActions = AccountsCardActions({}, {}),
    actions: HappySettingsActions = HappySettingsActions(),
    aboutActions: AboutActions = AboutActions(),
    connectingTerminal: Boolean = false,
) {
    Screen(header = { StackHeader(stringResource(R.string.settings_title), actions.onBack) }) {
        ItemList {
            SettingsHeader(profile)
            AccountsCard(accounts, accountActions)
            ItemGroup {
                Item(
                    title = stringResource(R.string.settings_account),
                    icon = { SettingsTile(Ionicon.PersonCircleOutline, SettingsTiles.blue) },
                    onClick = actions.onAccount,
                    modifier = Modifier.testTag(SettingsTags.ACCOUNT),
                )
                Item(
                    title = stringResource(R.string.settings_backup_restore),
                    icon = { SettingsTile(Ionicon.KeyOutline, SettingsTiles.green) },
                    onClick = actions.onBackup,
                    modifier = Modifier.testTag(SettingsTags.BACKUP),
                )
            }
            ItemGroup {
                Item(
                    title = stringResource(R.string.settings_appearance),
                    icon = { SettingsTile(Ionicon.ColorPaletteOutline, SettingsTiles.purple) },
                    onClick = actions.onAppearance,
                    modifier = Modifier.testTag(SettingsTags.APPEARANCE),
                )
                Item(
                    title = stringResource(R.string.settings_language_title),
                    icon = { SettingsTile(Ionicon.LanguageOutline, SettingsTiles.green) },
                    onClick = actions.onLanguage,
                    modifier = Modifier.testTag(SettingsTags.LANGUAGE),
                )
                Item(
                    title = stringResource(R.string.settings_voice_assistant),
                    icon = { SettingsTile(Ionicon.MicOutline, SettingsTiles.orange) },
                    onClick = actions.onVoice,
                    modifier = Modifier.testTag(SettingsTags.VOICE),
                )
                Item(
                    title = stringResource(R.string.settings_agents),
                    icon = { SettingsTile(Ionicon.OptionsOutline, SettingsTiles.teal) },
                    onClick = actions.onAgents,
                    modifier = Modifier.testTag(SettingsTags.AGENTS),
                )
            }
            ItemGroup {
                Item(
                    title = stringResource(R.string.settings_scan_qr_code_to_authenticate),
                    icon = { SettingsTile(Ionicon.QrCodeOutline, SettingsTiles.indigo) },
                    onClick = actions.onScanTerminal,
                    loading = connectingTerminal,
                    showChevron = false,
                    modifier = Modifier.testTag(SettingsTags.SCAN_TERMINAL),
                )
                Item(
                    title = stringResource(R.string.connect_enter_url_manually),
                    icon = { SettingsTile(Ionicon.LinkOutline, SettingsTiles.indigo) },
                    onClick = actions.onEnterTerminal,
                    showChevron = false,
                    modifier = Modifier.testTag(SettingsTags.ENTER_TERMINAL),
                )
            }
            SupportCard(about, aboutActions)
            AboutCard(about, aboutActions)
            RemoveCard(agent = false, name = profile.name, onRemove = actions.onSignOut)
        }
    }
}
