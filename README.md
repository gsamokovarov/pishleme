# Pishleme - macOS Parental Control Tool

A command-line daemon for enforcing time limits on macOS applications by terminating them with SIGKILL when their allocated time is exceeded.

## Features

- Monitor multiple applications simultaneously
- Set individual time limits for each application
- Persistent time tracking across application restarts
- Daemon mode for background operation
- Process termination with SIGKILL for reliable enforcement

## Building

```bash
zig build
```

## Usage

```bash
pishleme --app <application_name> --time <seconds> [--app <app2> --time <seconds2>]
```

### Examples

Monitor Safari for 1 hour (3600 seconds):
```bash
pishleme --app Safari --time 3600
```

Monitor multiple applications:
```bash
pishleme --app Safari --time 3600 --app Discord --time 1800
```

Show help:
```bash
pishleme --help
```

## How It Works

1. The daemon monitors specified applications using `pgrep` to find running processes
2. Time tracking starts when the application is first detected running
3. Time accumulates across application sessions (if you quit and restart, time continues counting)
4. When the time limit is exceeded, all processes matching the application name are terminated with SIGKILL
5. The daemon continues monitoring and will kill the application again if relaunched after time limit exceeded

## Requirements

- macOS (uses `pgrep` command)
- Zig compiler for building
- Appropriate permissions to kill processes (may require running as admin for some applications)

## Installation as macOS Daemon

To run pishleme automatically at startup, you can create a Launch Daemon.

1. **Copy the plist file to LaunchDaemons directory:**
   ```bash
   sudo cp com.pishleme.daemon.plist /Library/LaunchDaemons/
   ```

2. **Set proper permissions:**
   ```bash
   sudo chown root:wheel /Library/LaunchDaemons/com.pishleme.daemon.plist
   sudo chmod 644 /Library/LaunchDaemons/com.pishleme.daemon.plist
   ```

3. **Load and start the daemon:**
   ```bash
   sudo launchctl load /Library/LaunchDaemons/com.pishleme.daemon.plist
   sudo launchctl start com.pishleme.daemon
   ```

## Security Notes

- The daemon runs as root to ensure it can kill any process
- Log files are stored in `/var/log/` and require sudo to access
- The daemon automatically restarts if it crashes (`KeepAlive: true`)
- It starts automatically at boot (`RunAtLoad: true`)
