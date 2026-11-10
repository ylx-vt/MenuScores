# MenuScores

An independently maintained native macOS menu-bar scoreboard and sports-data tracker, derived from [Daniyal Master’s MenuScores](https://github.com/daniyalmaster693/MenuScores). This fork currently exposes NBA games; future league support is a product choice, not an architectural restriction.

## Current app

The current local release is [2.5.14 (40)](docs/releases/2.5.14.md), recorded by Git tag `v2.5.14`.

- Click the basketball menu-bar icon for today’s NBA games and history. Dates and times use Beijing time; tomorrow appears from noon.
- Select a game to reserve/pin its score. Manual selection survives restarts and takes priority over automatic favorite-team selection. Click its menu-bar score to open the box score.
- Restored compact match details keep the 620pt two-score-card team switcher, seven-column player table and player drilldown. The match opens with scores, one cached recap line and the complete statistics together. Team switching, quarter scores, team totals and the seven-column player table stay on the first screen; detailed recap, real play-by-play evidence and follow-up questions expand in place and return to the preserved team and scroll position. Public-source search is used only when an external fact needs checking; local match judgments do not depend on external links. Settings → 通用 controls the feature and its project-external plaintext private credential file. Recaps use a draft and an independent editorial pass. The existing app lifecycle can prepare missing content serially with a shared automatic/manual cap of $5.00 per Beijing calendar day; identical input is cached and failed requests are not automatically retried. Ready articles open from the document icon beside each match, and completed recaps support a separate notification preference. See [Terra behavior and validation](docs/terra-summary-demo.md).
- Chinese team/player names, bundled team logos, persistent headshots, player details and v3 season-performance estimates. Missing or failed data keeps an explicit unavailable/cache state.
- Pregame comparison, on-demand history, priority-ordered favorites and login launch. Existing favorites, including legacy non-NBA entries, remain readable.
- Opt-in local system notifications for followed/manual games: pregame, start, halftime, close finish, overtime and final. Sound defaults off. App/network availability and system permission are required; sleep or exit delivery is not guaranteed.
- The existing four-page first-launch guide remains.

Optional notch scores follow the pinned match. Hover to expand; screens without a hardware notch use a small top floating panel. Enable it in Settings → 通用. “关键时刻展开” uses the same milestone switches as Settings → 比赛提醒. It can work without system notification permission. An available floating alert takes priority over system notifications; temporary followed-game alerts return to the unchanged pin. Both new switches default off.

The retired multi-sport UI, old refresh/notification chain and global notch shortcut have been removed. The current NBA adapter shares schedule observations and persistent milestone deduplication; it adds no networking timer or daemon. Legacy favorites and stored values remain readable.

## Development

Requires macOS, full Xcode supporting the project’s synchronized groups and `.icon` assets, and Swift 6 for the retained local package. The app target declares macOS 13.0; unit tests declare 15.1. Deployment support requires separate OS testing.

Open `MenuScores.xcodeproj`, scheme `MenuScores`. Resolve the checked-in Swift package revisions. The packages are LaunchAtLogin-Modern, TourKit and the locally maintained DynamicNotchKit window/animation foundation. KeyboardShortcuts and the local package’s documentation-only dependencies were removed. No web server is required.

Use one derived-data directory and run commands serially:

```sh
xcodebuild -project MenuScores.xcodeproj -scheme MenuScores -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/MenuScores-build -jobs 2 -only-testing:MenuScoresTests -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
xcodebuild -project MenuScores.xcodeproj -scheme MenuScores -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/MenuScores-build -jobs 2 build CODE_SIGNING_ALLOWED=NO
```

Hosted unit tests suppress production startup, schedule polling, avatar preloading and notification work. Test fixtures and temporary store paths are used instead.

For isolated visual QA, stop the installed app first, then run the Debug executable with `--notch-preview`. This developer-only fixture exports compact/expanded views into the fixed build directory, suppresses networking and notification work, and never writes pins or defaults. Stop it before reopening the installed app; fixture scores are not live results.

The shared `MenuScores` scheme runs unit tests by default. `MenuScores-UI-Optional` retains the upstream launch/screenshot/performance templates separately; these are not meaningful product interaction coverage and may launch the app repeatedly. They are not part of routine validation.

These commands produce unsigned local builds, not a public distribution. Installation, signing and release channels are separate steps. Do not install an upstream Homebrew/release build over this customized app expecting local features. This repository does not yet document a fork-specific public release or support channel.

The scripts named `install-terra-*-local.py` record earlier, version-specific local upgrades. They assert particular source/installed versions and validation receipts; they are not a generic installer for the current version.

## Code map

- `MenuScoresApp.swift`: menu-bar scenes and persistent schedule refresh.
- `Services/NBASchedule*`, `NBAPinnedSelection.swift`: Beijing schedule windows, cache and selection.
- `Views/BoxScore/`, `Services/NBABoxScore*`: details, history and presentation.
- `Services/NBAReviewGameQuery.swift`, `NBAReviewResearch.swift`: bounded in-match fact tools, bounded Terra questions and public-source search fallback; shared daily budget and cached answers.
- `Services/NBAReviewConversationStore.swift`: local per-game dialogue, drafts and interrupted states; bounded historical context for follow-ups. `NBAOpenAIPrivateConfiguration.swift` reads the user-approved owner-only plaintext file in Application Support. Legacy Keychain access is migration-only; missing or invalid files never fall back to Keychain.
- `Services/NBAAnswerMarkdown.swift`, `Views/BoxScore/NBAAnswerMarkdownView.swift`: native safe answer formatting and citation links, without HTML or remote images.
- `Services/NBAAvatar*`, `NBALocalization.swift`: portrait preparation and Chinese names.
- `Services/NBASeason*`, `NBALeaguePercentiles.swift`: player statistics and v3 estimates.
- `Notifications/NBAGameReminder*`: timestamped milestone rules, durable deduplication and output routing.
- `Managers/NBANotchController.swift`, `Views/Notch/`, `NBANotchSession.swift`: optional presentation, display identity and transient event recovery.
- `Favorites/`, `Views/Settings Views/`: favorites compatibility and current settings.

See [data and reminder behavior](docs/NBA-data-and-reminders.md) for cache rules, v3 methodology/limitations and sources. Keep all test fixtures and provenance. [LEAGUES.md](LEAGUES.md) states the current scope and extension boundary.

## License and attribution

The project retains its [GPLv3 license](LICENSE), original copyright notices and [third-party attribution](ThirdPartyNotices/README.md). The upstream source/release channels describe the original app. ESPN endpoints, marks and portraits are external dependencies and may change.

## Local housekeeping

Keep generated validation output in the single derived-data directory. `.local-backups/` is ignored and contains the verified pre-cleanup source recovery ZIP and manifest/hash record. It is not an app backup. Do not commit personal Xcode state, caches, builds or recovery archives. Preserve user defaults, selected games, notification permissions and avatar caches during development.
