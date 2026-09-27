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
- Xcode Command Line Tools (`xcode-select --install`) — needed to build from source

## Build and install

On a fresh Mac, starting from nothing:

```bash
brew install yt-dlp ffmpeg   # skip if already installed
git clone https://github.com/htmverlof/reprise.git
cd reprise
./install.sh
```

Already have the repo cloned? Just re-run `./install.sh` any time you pull new changes —
it builds a release binary, assembles `/Applications/Reprise.app` (icon and Info.plist
come from `Resources/`), signs it, and (re)launches it, replacing the previous build in
place (keeping a timestamped backup of the old executable).

## First launch

On first run, Reprise checks two things and opens its window automatically if either is
missing:

1. **Write access to its download folder** (`~/Downloads/Reprise` by default, or wherever
   you set in Settings) — System Settings → Privacy & Security → Files and Folders →
   Reprise → Downloads Folder.
2. **Full Disk Access**, needed to read Chrome's cookies for login-gated premieres —
   System Settings → Privacy & Security → Full Disk Access → enable Reprise.
   (Public videos still download fine without this; only cookie-gated ones need it.)

The in-app "Check again" button re-runs both checks without needing a restart.

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

Create `~/Library/LaunchAgents/com.media.reprise.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.media.reprise</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Reprise.app/Contents/MacOS/Reprise</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/Library/Logs/reprise-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/Library/Logs/reprise-stderr.log</string>
</dict>
</plist>
```

Then: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.media.reprise.plist`

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
