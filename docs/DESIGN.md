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
Claude quota bars use lighter Gundam red at 0%, Gundam red at 50%, and darker Gundam red at 100%.
Codex quota bars follow the same progression in Gundam blue.
The menu bar gauge uses the same color scale for each provider's most constrained window, averaged across that provider's accounts because plan sizes are unknown.
Claude usage credits are a spending pool, so they do not move the gauge.
Provider marks keep their original colors independently of quota bars.
Refresh and Quit symbols use the normal label color.

macOS 26 and newer use Liquid Glass and concentric continuous corners.
macOS 14 and 15 use Material with the same spacing and corner hierarchy.

Quota rows are titled by account folder, such as `Claude-work · Weekly`, and show the full source path on hover.
All 5-hour rows come first, then all Weekly rows, keeping account order within each group.
Provider headers weight each listed account's Weekly percentage by its estimated weekly tokens.
Hovering over a yellow footer time lists each account's errors once.

The menu bar gauge uses rounded arcs, a transparent background, and the same 35-degree rotation as the app mark.
In the split gauge, Claude fills from the upper left toward the lower right, while Codex fills from the lower right toward the upper left.
Single-provider installations receive one full provider ring.
Dual-provider installations split the ring between Claude and Codex.
