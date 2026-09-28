# Reprise

A macOS menu bar app that watches YouTube premieres, captures the LIVE broadcast the
moment it starts, and then grabs the VOD (the full, final version) once it's available —
`Première → Live → Reprise`.

Built on top of [yt-dlp](https://github.com/yt-dlp/yt-dlp) and ffmpeg. No Dock icon by
default; lives in the menu bar (red = a problem needs attention, blue = downloading,
green = idle and healthy — right-click the icon for a quick status menu).

## Requirements

- **Apple Silicon Mac** (the release build is arm64-only) running **macOS 14 (Sonoma) or later**
- [Homebrew](https://brew.sh), with:
  ```
  brew install yt-dlp ffmpeg
  ```
- Xcode Command Line Tools (`xcode-select --install`) — only needed if building from
  source (see below); the pre-built release doesn't need this

## Quickest: download the pre-built app

No building required — grab the latest `.zip` from
[Releases](https://github.com/reprise-labs/reprise/releases), unzip, drag `Reprise.app` into
`/Applications`, then **right-click → Open** the first time (Gatekeeper will warn about an
app from an unidentified developer — expected, not a bug; a plain double-click refuses to
open it, right-click → Open shows an "Open anyway" option a double-click doesn't).

Still need `yt-dlp` and `ffmpeg` installed via Homebrew either way (see Requirements
above) — those aren't bundled into the app.

## Build and install from source

On a fresh Mac, starting from nothing:

```bash
brew install yt-dlp ffmpeg   # skip if already installed
git clone https://github.com/reprise-labs/reprise.git
cd reprise
./install.sh
```

Already have the repo cloned? Just re-run `./install.sh` any time you pull new changes —
it builds a release binary, assembles `/Applications/Reprise.app` (icon and Info.plist
come from `Resources/`), signs it, and (re)launches it, replacing the previous build in
place (keeping a timestamped backup of the old executable).

## First launch

On first run, Reprise checks three things and opens its window automatically if any are
missing:

1. **Write access to its download folder** (`~/Downloads/Reprise` by default, or wherever
   you set in Settings) — System Settings → Privacy & Security → Files and Folders →
   Reprise → Downloads Folder.
2. **Full Disk Access**, needed to read Chrome's or Safari's cookies for login-gated
   premieres — System Settings → Privacy & Security → Full Disk Access → enable Reprise.
   (Public videos still download fine without this; only cookie-gated ones need it.)
3. **yt-dlp and ffmpeg installed** (see Requirements above). If either is missing, an
   **"Install via Homebrew"** button opens Terminal and runs the exact `brew install`
   command for you. The first time you use it, macOS will show a one-time permission
   prompt — *"Reprise" wants access to control "Terminal"* — click **Allow**; that's
   normal, not an error, and only needed once.

The in-app "Check again" button re-runs all three checks without needing a restart.

### Keeping Full Disk Access across rebuilds

Ad-hoc code signing (`codesign -s -`) hashes the binary's own contents, so the signature
changes on every rebuild — macOS then treats each build as a brand-new app and resets
Full Disk Access. `install.sh` looks for a persistent local signing identity named
**"Encore Local Signing"** and uses it if present; if it's missing (e.g. a fresh clone on
a machine that's never built Reprise before), it falls back to ad-hoc signing and tells
you so.

To stop needing to re-grant Full Disk Access after every rebuild, create that identity
once:

```bash
WORKDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout "$WORKDIR/encore.key" -out "$WORKDIR/encore.crt" \
  -days 7300 -nodes -subj "/CN=Encore Local Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -out "$WORKDIR/encore.p12" \
  -inkey "$WORKDIR/encore.key" -in "$WORKDIR/encore.crt" -passout pass:encorebuild
security import "$WORKDIR/encore.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P encorebuild -T /usr/bin/codesign -A
rm -rf "$WORKDIR"
```

The first `codesign` call afterward may prompt once to confirm `codesign` can use the new
key — click "Always Allow". From then on, `install.sh` signs with this identity and Full
Disk Access survives every future rebuild.

## Auto-start at login (optional)

Settings → General → **"Start at login"**. Uses macOS's standard Login Items mechanism
(`SMAppService`), so it also shows up in System Settings → General → Login Items like any
other app. If macOS reports it needs approval, enable Reprise there once.

## Notifications

Settings → paste a Pushover Application Token and User Key (from
[pushover.net](https://pushover.net)) to get push notifications for premieres going live,
downloads completing/failing, and the pre-flight checks below. Local macOS notification
banners are also shown automatically, no setup needed (macOS will ask for permission once
on first launch).

## What it actually does

- Tracks premieres you add by URL + scheduled time.
- Starting shortly before the scheduled time, polls the video's status.
- The moment it goes live, starts capturing immediately (`yt-dlp --live-from-start`).
- Once the VOD is available, downloads that too — the VOD is the complete, final version;
  the LIVE capture is the safety net in case the VOD never shows up.
- Sends a pre-flight push 24 hours and 1 hour before each premiere (yt-dlp up to date,
  folder/Chrome access OK, enough disk space, link still resolves) — catches problems
  while there's still time to fix them, not mid-broadcast.
- Recovers automatically if yt-dlp reports a failure but the recording is actually
  complete on disk (a known yt-dlp quirk at the end of some live streams).

## Data locations

- Tracked list, settings, log: `~/Library/Application Support/Reprise/`
- Downloads: `~/Downloads/Reprise` by default (configurable in Settings)

## License

[MIT](LICENSE) — do whatever you want with it.
