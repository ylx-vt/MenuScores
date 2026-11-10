# NBA data, performance and reminder behavior

### Chinese names and portrait cache

`NBAPlayerNames.zh-Hans.json` contains 522 entries read from the [NBA China active-player roster](https://china.nba.cn/playerindex/) on 2026-10-29, plus local spelling fixes and the existing common-name overrides. Name matching normalizes accents, punctuation and suffixes. A checked-in 519-player ESPN roster snapshot verifies the current name coverage; unknown future names retain the original spelling instead of an invented translation.

Portraits use a shared memory cache and an on-disk cache in the app's cache directory. Favorite-team portraits are prefetched on startup, and both teams are prefetched when a game is pinned. Concurrent requests share a download; stale portraits remain visible while refreshing in the background, and failures back off for one minute. Team logos remain bundled locally.

The game picker uses aligned compact score rows rather than large cards. Its opaque surface and foreground share the same light/dark appearance to avoid black text on a gray translucent background.

Player detail downloads and caches complete same-season league statistics. Each season metric ranks only players in that metric's ESPN eligibility set with valid data (and positive attempts for shooting). Unqualified or zero-attempt players retain their real values but show “样本不足” with no metric rank or tier. A recorded 0% with positive attempts, zero points and zero turnovers are valid observations. Cards expose rank / population and the percentage strictly outperformed, excluding ties. Low turnover counts describe quantity, not ball-handling ability.

The avatar shows **近期数据表现估计（基础技术统计）**, separately from the original current-season EFF per appearance. Raw EFF remains `(PTS + REB + AST + STL + BLK - (FGA - FGM) - (FTA - FTM) - TOV) / GP`, documented in [Wayne Winston’s NESSIS material, page 1](https://www.nessis.org/nessis09/Winston.pdf). EFF is statistical production, not Game Score or complete player impact. The estimate does not adjust for pace, opponents or overall defense, and no names or award ranks tune its weights.

The approved v3 estimate uses only the immediately previous season in the same stage. Valid historical evidence requires actual GP ≥3 and cumulative MIN ≥60, plus complete valid EFF counts. `K_eff = 20 * priorGP / (priorGP + 20)` and `estimate = (currentTotalEFF + K_eff * priorEFFperGame) / (currentGP + K_eff)`. Missing, invalid or insufficient historical evidence sets K_eff to zero. A failed historical request is labelled separately from a successful response with no player record; no older season or old EFF ranking silently substitutes for it.

Everyone uses the same entry conditions: current actual GP ≥3 and MIN ≥60, **effectiveGP ≥10 and effectiveMIN ≥200**. `effectiveGP = currentGP + K_eff`; `effectiveMIN = currentMIN + K_eff * priorMIN / priorGP` when historical evidence is valid, otherwise current actual minutes. Without usable history, the same conditions therefore require current actual 10GP/200MIN. These are product minimum evidence rules, not statistical confidence guarantees; historical equivalent amounts are not independent actual appearances/minutes. Every colored rank is labelled “初步估计”. Waiting players keep their original current data and a neutral dashed avatar distinct from the ranked gray tier. Details expose raw current/prior EFF, actual GP/MIN, historical weight, equivalent amounts, prior source date/failure status and minutes-per-game comparison; role minutes do not change the weights.

Cumulative inputs must be finite nonnegative integers with positive GP and legal made/attempted counts. Missing data is not filled with zero; negative EFF is valid. The algebra cancels priorGP before calculation: numerator `currentTotalEFF*(priorGP+20)+20*priorTotalEFF`, denominator `currentGP*(priorGP+20)+20*priorGP`. Checked integer arithmetic rejects overflow; signed full-width rational comparisons preserve exact ties and thresholds before display rounding. Ties share competition rank; tiers remain rank/population ≤1%, ≤5%, ≤10%, ≤25%, ≤50%, then gray, without forced red ranks in small pools.

Algorithm version is `eff-estimate-v3-k20-effective10g200m`. Existing `NBALeagueSnapshots-v1` files are raw, not cached grades, and are recomputed without deleting preferences or favorites. A compatible immediately previous raw snapshot can be reused non-destructively. Historical all-athlete inputs otherwise use one request and separate `NBALeaguePerformanceInputs-v1/year-type.json` files, 24-hour reuse and 60-second failure backoff; the same-scope stale cache may remain visible with its date and refresh-failure label. Current single-metric snapshots retain their independent eligibility lists and 15-minute policy. All memory, pending-request and disk keys separate season and stage.

Offline fixtures retain current 2026–27 (425 players) and completed 2025–26 (582) / 2024–25 (569) raw inputs and provenance. The delivered v3 reference CSV covers every current player: 236 preliminary estimates and 189 waiting, with the target estimate 1471/105 ≈14.009524, rank124/236. Exact score, historical equivalent amount, effective evidence and ranking are cross-checked per row. This product choice has not been validated with early-season game-by-game backtests and does not represent pure current-season output, total season contribution or award eligibility.

The game table still grades each live numeric value separately against its existing matching-season per-game distribution; plus/minus still compares the current game's participating players. Those live cell comparisons were not replaced by EFF or by the player-detail single-metric pools. The table retains restrained text accents and tiny ticks. Player cards retain the installed metallic/gem styling over the shared low-contrast team-tinted canvas.

The first-level NBA menu includes a history entry with previous/next-day navigation and a date field. History is fetched on demand, cached locally, and filtered by the fixed Beijing calendar date after fetching the two relevant US schedule dates. Selecting a historical event opens its box score directly without replacing the live pinned game. The history screen keeps a back path to its date list and today's menu.

### Tomorrow reservations (local customization)

Schedule days and tip-off times use Asia/Shanghai (Beijing time), independent of the Mac's timezone. From 12:00 inclusive, the menu adds tomorrow's games while retaining today's list and any still-live game. A single manually selected game persists by event ID and a small display snapshot, survives midnight and restarts, and takes priority over automatic favorite-team pinning. Pregame status shows team logos and the Beijing tip-off time. Missing responses or network failures preserve the reservation; explicit cancellation/postponement statuses remain visible.

The schedule cache stores raw ESPN date buckets (`NBAScheduleDates-v1/yyyyMMdd.json`). Beijing day D requests provider dates D−1 and D and filters event timestamps into [00:00, next 00:00); tomorrow shares D and adds D+1. Known live games retain their original date buckets until an updated status is received. Concurrent callers share pending work. Live data uses a 15-second cache, games within 15 minutes of tip-off use 30 seconds, and other schedule buckets use 15 minutes. Noon, midnight and wake-up recalculate the window without resetting the pin or preloading every player.

### NBA game reminders (local customization)

Settings → 比赛提醒 contains an opt-in system-notification switch and individual milestone switches. Pregame,
start, close finish and final are preselected; halftime and each overtime period are optional.
Sound defaults off. Enabling system notifications is the only automatic permission-request path; startup
and the welcome tour do not request notification access. Existing reminder choices are retained.

The scope is the union of a manually pinned game and games involving followed NBA teams,
independent of automatic pinning. The existing schedule polling supplies successful, timestamped
observations; display-only cache playback and failed refreshes never generate reminders. No
extra polling timer or background service is installed. Data older than 60 seconds is ignored;
an observation gap over five minutes starts a new baseline. These are product suppression
rules, not a guarantee of upstream score latency. Initial live/final snapshots do not replay
past milestones; an upcoming game inside ten minutes may receive one reminder using its actual
remaining minutes. Halftime requires explicit source status. A close finish requires fourth
quarter/overtime, a numeric clock strictly above zero and at most 120 seconds, and a score gap
of at most five. Each period has at most one close-finish alert.

A persistent claim-before-send ledger (`MenuScores/nba-reminder-ledger-v1.json` in Application
Support) deduplicates event and milestone, with period-specific overtime/close-finish keys.
Simultaneous milestones collapse to the most important enabled one. A submission failure or
crash can lose an alert; it is not exactly-once delivery. Ledger corruption pauses reminders
instead of replaying events. No reminders are scheduled far ahead, so rescheduling, cancellation
and removal from the followed scope cannot leave a stale future system request. Reminders
require the App running, network access and system authorization; sleep/exit delivery is not
guaranteed. These are local notifications, not remote push. Clicking one opens a single reusable
NBA detail window without replacing the menu-bar reservation.


## Optional notch output

The NBA notch controller consumes the same successful schedule observations; it does not fetch data. `enableNotch` and `nbaNotchMilestones` default off and persist independently of system notifications. Existing milestone switches apply to both outputs. Event detection/ledger claiming occurs once, followed by overlay-first dispatch; unavailable or busy overlay falls back only when system notifications are enabled and authorized. Overlay-only delivery never checks or requests system authorization.

The compact display follows the current pin. A milestone can temporarily present another followed match for eight seconds, then returns to the latest pin without writing it. Hovering prevents replacement or timed collapse; incoming alerts fall back to the enabled system channel while the surface is busy. Data older than 60 seconds, failed refreshes and restored snapshots have a waiting state. Screen selection uses persistent display UUIDs with a safe main-screen fallback. Disabling releases windows, timers and screen/wake observers; no global shortcut is registered.

DynamicNotchKit retains the upstream window/animation foundation with local lifecycle, floating-compact, passive-window and hover-expiry adaptations. Hardware-notch anchors use the standard status-bar level and preserve the requested screen-top frame; external floating cards use normal floating level. Neither uses the original screen-saver level or becomes key. Real notification delivery and physical multi-monitor/sleep behavior require separate device acceptance.

Identical hover notifications preserve the first pending transition instead of cancelling it. The passive tracking area follows visible geometry without being replaced during layout, and compact height does not change on hover. Hosted regressions exercise the real delayed state transitions with window presentation suppressed.


## Compact and expanded match views (2.4.7)

Menu-bar, history, notification and notch detail routes default to a screen-aware
compact view targeting 600 × 498 points, bounded by the hosting screen. It groups
the matchup, period/time and period matrix on the left, beside all seven core
team comparisons: FG/3PT/FT made-attempted and percentage, rebounds with offensive
boards, assists, turnovers and fouls. Team tabs form the player section header.
Starter and bench headings appear once per group in both modes, using declared
`starter` values; missing starter facts remain unassigned. Jersey/DNP information,
avatar ratings, existing numeric columns and drilldown remain. The default
compact viewport shows six complete34-point player rows plus two16-point group
headings (236 points); headers use12-point text and auxiliary lines use11-point
text. Short screens use normal page scrolling.

Its explicit “打开大看板” button opens one independent, resizable window targeting
1080 × 680 points. Only after that window is visible does the originating popover
or small detail window close. If presentation fails, the compact surface stays
open with a retry message. Opening the same match reuses the window; another match
switches it. Closing the large window does not reopen the compact surface or
change the pinned match.

The expanded view groups the matchup beside the period matrix, the score chart
beside team comparison, and both rosters below. Roster headers align and one shared
scroll area moves both teams. Narrow windows stack the same content on one page.
Body and numeric table text, compact key values and period-score values use 12
points. Static, low-opacity team light is limited to the matchup identity area;
the chart and tables keep a neutral canvas. Each team retains its own identity,
avatar rating and player-detail tint. Full pregame analysis remains available in
the expanded window, separate from in-game totals.

Both views share a weakly registered per-match session and one visibility-driven
summary refresh loop. Opening the expanded window does not add a second poller.
The compact roster and expanded match share ranking and avatar preparation;
pregame schedule preparation remains tied to the full pregame view. Closing the last consumer stops its work; player navigation retains
the summary snapshot without requiring a second match refresh loop.

The existing summary response supplies header `linescores`, named `boxscore.teams`
statistics and `plays`. Missing periods/statistics remain unknown, while actual zero
counts remain zero. A zero-attempt shooting percentage is unavailable. Halftime is
labelled as the end of the second quarter, rather than a running zero clock.

Cumulative score paths use both absolute scores from every valid play, including
non-scoring corrections; `scoreValue` is not summed. Provider array order is retained,
not re-sorted by sequence number. Equal timestamps may retain vertical corrections;
identical samples at the same timestamp are coalesced. Missing/invalid times or
backwards clocks break the path. No starting score is manufactured. Regulation and
overtime lengths come from the response format; missing format/events show no path.
The curve's event timestamp is displayed independently from the newer headline clock.
Hovering shows the nearest observed timestamp and both observed scores, with the last
correction selected when several observations share a time.

Team comparison uses source totals for shooting, rebounds (including offensive),
assists, total turnovers, fouls, paint and fast-break points. Largest leads are per
team; a matching repeated lead-change count is displayed once. The confusing
`turnoverPoints` field, bonus state, possession, shot clock and `active` roster flag
are not presented as new live features. A small star identifies each team's current
points leader, including ties. Additional current-game shooting, defensive and
turnover/foul columns are available in the existing player detail.

Archived real halftime, in-progress and final response sections and their provenance
are retained in test fixtures. Overtime timing/layout is covered by explicit synthetic
tests; no real overtime acceptance is claimed. Debug `--dashboard-preview <directory>`
opens an interactive native host for these snapshots without production polling,
notifications, avatar writes or preference changes. Its optional image export captures
the currently rendered native view into that same QA directory.
