# Pishleme - macOS Parental Control Tool

A command-line daemon for enforcing time limits on macOS applications by terminating them with SIGKILL when their allocated time is exceeded.

## Features

- Monitor multiple applications simultaneously
- Set individual time limits for each application
- Global time restrictions (e.g., 9AM-5PM only)
- Persistent time tracking across application restarts
- Daemon mode for background operation
- Automatic plist generation and installation
- Process termination with SIGKILL for reliable enforcement
- Event-driven kqueue monitoring for efficiency

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

## How It Works

1. The daemon monitors specified applications using BSD sysctl to find running processes
2. Time tracking starts when the application is first detected running
3. Time accumulates across application sessions (if you quit and restart, time continues counting)
4. Global time restrictions are enforced (applications killed outside allowed hours)
5. When time limits are exceeded, a 5-second grace period is provided before termination
6. All processes matching the application name are terminated with SIGKILL
7. The daemon uses kqueue for efficient event-driven monitoring
8. Daily reset occurs at midnight to restart time tracking

## Requirements

- macOS (uses BSD sysctl and kqueue)
- Zig 0.15.1+ compiler for building
- Appropriate permissions to kill processes (may require running as admin for some applications)

## Installation as macOS Daemon

Pishleme includes an automatic installation feature that generates and installs the launchd plist file for you.

### Automatic Installation

Use the `--install` option with your desired configuration:

```bash
# Install daemon with time restrictions and app limits
pishleme --install --hours 9-17 --app Safari --time 3600 --app Discord --time 1800
```

This will:
1. Generate a plist file with the current binary path and your specified options
2. Install it to `~/Library/LaunchAgents/com.pishleme.daemon.plist`
3. Provide instructions for starting/stopping the daemon

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
