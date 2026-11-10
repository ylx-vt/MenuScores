# League scope

The current app exposes NBA schedules, game details, historical games and player statistics. It does not expose the original app’s multi-sport navigation.

Legacy non-NBA favorites are retained and remain visible in the saved favorites list. Their league IDs and display metadata are compatibility data, not a promise of active schedule support.

Future leagues should provide their own schedule/status adapters and presentation rules over shared cache, pinning and notification infrastructure. NBA periods, clutch thresholds and player models must not be assumed to apply to another sport.
