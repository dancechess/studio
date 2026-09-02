**Apple Silicon Mac, macOS 14 (Sonoma) or later.**

Download `@DMG@`, open it, drag **DC Studio** into Applications.

The build is ad-hoc signed but **not notarized**, so macOS quarantines it on
first launch. Clear that once:

```
xattr -dr com.apple.quarantine "/Applications/DC Studio.app"
```

GUI equivalent: try to open the app, then go to **System Settings ▸ Privacy &
Security** and click **Open Anyway**.

```
sha256  @SHA@
```

Bundles **@ENGINE@** (GPLv3, sources at <https://github.com/official-stockfish/Stockfish>)
and the Merida piece set (GPLv2+). DC Studio itself is GPLv3; its corresponding
source is this repository at tag `@TAG@`.
