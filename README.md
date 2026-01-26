# Clawdbot Control

A native macOS application for managing Clawdbot. Provides a graphical interface for users who prefer not to use the command line.

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (ARM64) Mac
- [Clawdbot](https://github.com/clawdbot/clawdbot) installed via Homebrew at `/opt/homebrew/bin/clawdbot`

## Installation

### Quick Install

```bash
./install.sh
```

### Manual Build

```bash
./build.sh
cp -R build/Clawdbot\ Control.app /Applications/
```

## Features

### Main Dashboard

- Start, stop, and restart the Clawdbot gateway
- View running status with uptime display
- Monitor CPU and memory usage
- View and search logs in real-time
- Run health checks (`clawdbot doctor`)
- View channel status (WhatsApp, Signal)

### Menu Bar

- Quick access from the menu bar icon
- Start/Stop/Restart controls
- Open dashboard
- Run health check
- Toggle auto-start

### Settings

- Auto-start on login (via LaunchAgent)
- System notifications for status changes
- Configurable refresh interval
- Log display options

## Usage

### Opening the App

- **Spotlight**: Press `Cmd+Space`, type "Clawdbot", press Enter
- **Menu Bar**: Click the antenna icon in the top-right corner
- **Applications**: Double-click in `/Applications/Clawdbot Control.app`

### Basic Controls

| Action | Description |
|--------|-------------|
| Start | Starts the Clawdbot gateway |
| Stop | Stops the Clawdbot gateway |
| Restart | Stops and starts the gateway |
| Dashboard | Opens the web dashboard at http://127.0.0.1:18789 |
| Health Check | Runs `clawdbot doctor` diagnostics |

### Auto-Start on Login

Enable auto-start from the Settings sidebar. This creates a LaunchAgent at:
```
~/Library/LaunchAgents/com.clawdbot.autostart.plist
```

## File Structure

```
clawdbot-control-app/
├── src/
│   ├── main.swift      # SwiftUI application source
│   └── Info.plist      # Application metadata
├── resources/
│   ├── AppIcon.icns    # Application icon
│   └── icon_1024.png   # Icon source image
├── build.sh            # Build script
├── install.sh          # Build and install script
└── README.md
```

## Configuration

The app reads Clawdbot configuration from:
```
~/.clawdbot/clawdbot.json
```

Logs are read from:
```
/tmp/clawdbot/clawdbot-YYYY-MM-DD.log
```

## Technical Details

- **Language**: Swift 5 with SwiftUI
- **Frameworks**: AppKit, SwiftUI, UserNotifications
- **Architecture**: Native ARM64
- **Bundle ID**: com.clawdbot.control

## Troubleshooting

### App does not detect Clawdbot

Ensure Clawdbot is installed at `/opt/homebrew/bin/clawdbot`. The app expects this path for Homebrew installations on Apple Silicon Macs.

### Menu bar icon not appearing

The app must be running for the menu bar icon to appear. Check Activity Monitor for "ClawdbotControl" process.

### Auto-start not working

1. Check that the LaunchAgent file exists at `~/Library/LaunchAgents/com.clawdbot.autostart.plist`
2. Run `launchctl list | grep clawdbot` to verify it is loaded
3. Check Console.app for any error messages

## License

MIT License
