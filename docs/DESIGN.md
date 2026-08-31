# Design

Token Bar uses one visual role per color:

| Color | Role |
| --- | --- |
| 🟡 `#FFD887` | Claude |
| 🔵 `#60AFFF` | Codex |
| ⚪ White | Available quota |
| 🔴 `#FF5F5F` | Gauge center |
| 🟠 `#F0A33A` | Stale data and warnings |

The palette takes inspiration from classic Gundam colors without copying character or franchise artwork.

macOS 26 and newer use Liquid Glass and concentric continuous corners.
macOS 14 and 15 use Material with the same spacing and corner hierarchy.

The menu bar gauge uses rounded arcs, a transparent background, and the same 35-degree rotation as the app mark.
Single-provider installations receive one full provider ring.
Dual-provider installations split the ring between Claude and Codex.
