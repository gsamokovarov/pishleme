# Pishleme

You know the pet deterrent sprays that keep those pesky pets out of forbidden
areas? They are effective because they create a negative association with the
area. And it's not you who has to enforce the rule.

Some kids don't need deterrents. Others do, I call them pishlemes. If you have
a pishleme, you know what I mean.

![Deterrent](./assets/deterrent.png)

## Features

- Monitor multiple applications simultaneously
- Set individual time limits for each application
- Global time restrictions (e.g., 9AM-5PM only)
- Automatic daemon installation

## Building

```bash
zig build
```

## Usage

```bash
pishleme [options]
```

### Options

- `--app <name> --time <seconds>` - Monitor application and enforce time limit
- `--hours <start>-<end>` - Restrict ALL applications to specific hours (24-hour format)
- `--install` - Generate and install launchd plist for daemon mode
- `--help` - Show help message

### Examples

Monitor Safari for 1 hour (3600 seconds):
```bash
pishleme --app Safari --time 3600
```

Monitor multiple applications with global time restrictions:
```bash
pishleme --hours 9-17 --app Safari --time 3600 --app Discord --time 1800
```

Install as daemon with restrictions:
```bash
pishleme --install --hours 9-17 --app Safari --time 3600 --app Discord --time 1800
```

Show help:
```bash
pishleme --help
```

## Requirements

- macOS (uses BSD sysctl and kqueue)
- Zig 0.15.1+ compiler for building
- Appropriate permissions to kill processes

## Installation as macOS Daemon

Pishleme includes an automatic installation feature that generates and setups a
daemon using `launchd`. This allows it to run in the background and enforce
rules without user intervention.

### Automatic Installation

Use the `--install` option with your desired configuration:

```bash
# Install daemon with time restrictions and app limits
pishleme --install --hours 9-17 --app Safari --time 3600 --app Discord --time 1800
```

This will:

1. Generate a plist file with the current binary path and your specified options
1. Install it to `~/Library/LaunchAgents/com.pishleme.daemon.plist`
1. Provide instructions for starting/stopping the daemon

### Managing the Daemon

After installation, control the daemon with:

```bash
# Start the daemon
launchctl load ~/Library/LaunchAgents/com.pishleme.daemon.plist

# Stop the daemon
launchctl unload ~/Library/LaunchAgents/com.pishleme.daemon.plist

# Check daemon status
launchctl list | grep pishleme
```

### Cross-Architecture Support

Build for Intel Macs when running on Apple Silicon:

```bash
zig build x86  # Creates pishleme-x86_64 binary
```

## Security Notes

- The daemon runs in user space (LaunchAgent, not LaunchDaemon)
- Log files are stored in `/var/log/pishleme.log`
- The daemon automatically restarts if it crashes (`KeepAlive: true`)
- It starts automatically at login (`RunAtLoad: true`)
- Daily timer resets occur at midnight automatically
