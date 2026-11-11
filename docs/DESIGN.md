# Design

Token Bar uses these visual marks:

| Mark | Role |
| --- | --- |
| 🟠 | Claude's original Clawd mark |
| 🔵 | Codex's original mark |
| ⚪ | Available quota and All heading |
| 🟡 | Gauge center and footer time after a failed reading |
| 🟠 | Stale data and warnings |

The palette takes inspiration from classic Gundam colors without copying character or franchise artwork.
Claude quota rings use lighter Gundam red at 0%, Gundam red at 50%, and darker Gundam red at 100%.
Codex quota rings follow the same progression in Gundam blue.
The menu bar gauge uses the same color scale for each provider's most constrained window, averaged across that provider's accounts because plan sizes are unknown.
Claude usage credits are a spending pool, so they do not move the gauge.
Provider marks keep their original colors independently of quota rings.
Refresh and Quit symbols use the normal label color.

macOS 26 and newer use Liquid Glass and concentric continuous corners.
macOS 14 and 15 use Material with the same spacing and corner hierarchy.

Each account has one quota row, titled by its folder, such as `Claude-work`, with a ring per window: 5-hour, Weekly, then model-specific or other quotas.
A ring shows the window's percentage inside; all rows share one set of columns titled above the first row, such as `5h`, `Week` or `Fable`, so Claude's and Codex's windows of the same length line up, and an account without a window leaves its column empty.
Hovering over a ring shows the reset countdown, the reset time and, at the pace so far in the window, its percentage at reset or when it reaches 100%.
A Weekly ring with a projection also shows the tokens and cost its percentage has used so far and what 100% comes to; 5-hour rings cannot, since local history is kept by day.
Claude rows come first, then Codex rows, keeping account order.
Provider headers weight each listed account's Weekly percentage by its estimated weekly tokens.
Hovering over a yellow footer time lists each account's errors once.
Hovering over WEEKLY lists each account's weekly percentage, reset, spend so far and full-week projection, or "no projection" with the reason when it is known.
Hovering over an activity card charts the cost and tokens of today and the seven days before it, this week and the seven weeks before it, or this year's months for Month, with All's bars split into Claude and Codex.
The Year card has no hover, since its chart would repeat Month's.
Periods before the local history starts are left out.
Below the chart, the card splits by Codex login, or by provider under All when both have usage.
Hover text gives numbers and errors only; a card with nothing to add shows none, and the method stays in [pricing](PRICING.md).
Claude history counts every Claude folder together, so Claude cards do not split by account.

The menu bar gauge uses rounded arcs, a transparent background, and the same 35-degree rotation as the app mark.
In the split gauge, Claude fills from the upper left toward the lower right, while Codex fills from the lower right toward the upper left.
Single-provider installations receive one full provider ring.
Dual-provider installations split the ring between Claude and Codex.
