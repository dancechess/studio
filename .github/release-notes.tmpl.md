**Apple Silicon Mac, macOS 14 (Sonoma) or later.**

Download `@DMG@`, open it, drag **DC Studio** into Applications.

The build is ad-hoc signed but **not notarized**, so the first launch is
blocked with *"Apple could not verify "DC Studio" is free of malware..."*.
That dialog offers no way to continue — dismiss it without letting it move the
app to the trash, then either run

```
xattr -dr com.apple.quarantine "/Applications/DC Studio.app"
```

or open **System Settings ▸ Privacy & Security** and click **Open Anyway**
next to the message about DC Studio.

```
sha256  @SHA@
```

Bundles **@ENGINE@** (GPLv3, sources at <https://github.com/official-stockfish/Stockfish>)
and the Merida piece set (GPLv2+). DC Studio itself is GPLv3; its corresponding
source is this repository at tag `@TAG@`.
