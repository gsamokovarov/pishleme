const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const process = std.process;
const stdtime = std.time;
const c = std.c;

const cc = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("sys/proc.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("sys/event.h");
});

const SECONDS_PER_DAY: i64 = 86400;
const GRACE_PERIOD_SECONDS: u64 = 5;
const POLLING_INTERVAL_MILLISECONDS: u64 = 1000;

var g_daemon_running: bool = true;

fn signalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    g_daemon_running = false;
}

const AppRule = struct {
    name: []const u8,
    time_limit_seconds: u64,
    start_time: ?i64 = null,
    elapsed_time: u64 = 0,
    process_ids: ArrayList(c.pid_t),
    grace_period_start: ?i64 = null,

    fn init(_: Allocator, name: []const u8, time_limit_seconds: u64) AppRule {
        return AppRule{
            .name = name,
            .time_limit_seconds = time_limit_seconds,
            .process_ids = ArrayList(c.pid_t){},
        };
    }

    fn deinit(self: *AppRule, allocator: Allocator) void {
        self.process_ids.deinit(allocator);
    }

    fn isTimeExceeded(self: *const AppRule) bool {
        return self.elapsed_time >= self.time_limit_seconds;
    }

    fn clearState(self: *AppRule) void {
        self.process_ids.clearRetainingCapacity();
        self.grace_period_start = null;
    }
};

const PishlemeDaemon = struct {
    allocator: Allocator,
    app_rules: ArrayList(AppRule),
    running: bool = true,
    last_reset_day: i64,
    global_allowed_hours: ?struct { start: u8, end: u8 } = null,

    fn init(allocator: Allocator) PishlemeDaemon {
        const now = stdtime.timestamp();
        const current_day = @divFloor(now, SECONDS_PER_DAY);

        return PishlemeDaemon{
            .allocator = allocator,
            .app_rules = ArrayList(AppRule){},
            .last_reset_day = current_day,
        };
    }

    fn deinit(self: *PishlemeDaemon) void {
        for (self.app_rules.items) |*rule| {
            rule.deinit(self.allocator);
        }
        self.app_rules.deinit(self.allocator);
    }

    fn addAppRule(self: *PishlemeDaemon, name: []const u8, time_limit_seconds: u64) !void {
        const rule = AppRule.init(self.allocator, name, time_limit_seconds);
        try self.app_rules.append(self.allocator, rule);
    }

    fn setGlobalAllowedHours(self: *PishlemeDaemon, start_hour: u8, end_hour: u8) void {
        self.global_allowed_hours = .{ .start = start_hour, .end = end_hour };
    }

    fn isGloballyAllowed(self: *const PishlemeDaemon) bool {
        if (self.global_allowed_hours == null) return true;

        const now_time_t = cc.time(null);
        const local_time = cc.localtime(&now_time_t) orelse return true;

        const current_hour = std.math.cast(u8, local_time.*.tm_hour) orelse {
            print("Warning: Invalid hour value {d}, allowing access\n", .{local_time.*.tm_hour});
            return true;
        };

        const allowed = self.global_allowed_hours.?;
        return current_hour >= allowed.start and current_hour < allowed.end;
    }

    fn findProcessesByName(self: *PishlemeDaemon, app_name: []const u8) !ArrayList(c.pid_t) {
        var pids = ArrayList(c.pid_t){};
        errdefer pids.deinit(self.allocator);

        // Get process list size first
        var mib = [4]c_int{ cc.CTL_KERN, cc.KERN_PROC, cc.KERN_PROC_ALL, 0 };
        var size: usize = 0;

        if (cc.sysctl(&mib, 3, null, &size, null, 0) != 0) {
            print("Warning: Failed to get process list size for '{s}'\n", .{app_name});
            return pids;
        }

        const num_procs = size / @sizeOf(cc.kinfo_proc);
        if (num_procs == 0) return pids;

        // Allocate buffer for process list using actual struct
        const proc_list = self.allocator.alloc(cc.kinfo_proc, num_procs) catch |err| {
            print("Warning: Failed to allocate memory for process list: {}\n", .{err});
            return pids;
        };
        defer self.allocator.free(proc_list);

        // Get actual process list
        var actual_size = size;
        if (cc.sysctl(&mib, 3, proc_list.ptr, &actual_size, null, 0) != 0) {
            print("Warning: Failed to get process list for '{s}'\n", .{app_name});
            return pids;
        }

        const actual_num_procs = actual_size / @sizeOf(cc.kinfo_proc);

        // Search for matching process names using actual struct fields
        for (proc_list[0..actual_num_procs]) |proc| {
            const pid = proc.kp_proc.p_pid;

            // Skip invalid PIDs
            if (pid <= 0) continue;

            // Convert C string to Zig string
            const proc_name_len = std.mem.indexOfScalar(u8, &proc.kp_proc.p_comm, 0) orelse proc.kp_proc.p_comm.len;
            const proc_name = proc.kp_proc.p_comm[0..proc_name_len];

            // Skip empty names
            if (proc_name.len == 0) continue;

            // Case-insensitive partial match
            if (std.ascii.indexOfIgnoreCase(proc_name, app_name) != null) {
                try pids.append(self.allocator, pid);
            }
        }

        return pids;
    }

    fn updateProcessList(self: *PishlemeDaemon, rule: *AppRule) !void {
        rule.process_ids.clearRetainingCapacity();
        var current_pids = try self.findProcessesByName(rule.name);
        defer current_pids.deinit(self.allocator);

        for (current_pids.items) |pid| {
            try rule.process_ids.append(self.allocator, pid);
        }

    }

    fn checkAndEnforceTimeLimit(self: *PishlemeDaemon, rule: *AppRule) !void {
        try self.updateProcessList(rule);

        const now = stdtime.timestamp();

        if (rule.process_ids.items.len == 0) {
            if (rule.start_time != null) {
                const session_time = std.math.cast(u64, now - rule.start_time.?) orelse 0;
                rule.elapsed_time = std.math.add(u64, rule.elapsed_time, session_time) catch rule.elapsed_time;
                rule.start_time = null;
                print("{s}: Not running. Total usage: {d}s\n", .{ rule.name, rule.elapsed_time });
            }
            rule.grace_period_start = null;
            return;
        }

        if (!self.isGloballyAllowed()) {
            killProcesses(rule, "Outside allowed hours");
            rule.clearState();
            if (rule.start_time != null) {
                const session_time = std.math.cast(u64, now - rule.start_time.?) orelse 0;
                rule.elapsed_time = std.math.add(u64, rule.elapsed_time, session_time) catch rule.elapsed_time;
                rule.start_time = null;
            }
            return;
        }

        if (rule.isTimeExceeded()) {
            if (rule.grace_period_start == null) {
                rule.grace_period_start = now;
                print("Time already exceeded for {s} ({d}s). Grace period: {d} seconds before termination.\n", .{ rule.name, rule.elapsed_time, GRACE_PERIOD_SECONDS });
            }

            const grace_elapsed = std.math.cast(u64, now - rule.grace_period_start.?) orelse 0;
            if (grace_elapsed >= GRACE_PERIOD_SECONDS) {
                killProcesses(rule, "Grace period expired");
                rule.clearState();
            } else {
                const grace_remaining = GRACE_PERIOD_SECONDS - grace_elapsed;
                print("{s}: Time limit exceeded. Terminating in {d} seconds...\n", .{ rule.name, grace_remaining });
            }
            return;
        }

        if (rule.start_time == null) {
            rule.start_time = now;
            print("{s}: Started running. Current total usage: {d}s\n", .{ rule.name, rule.elapsed_time });
        }

        const session_time = std.math.cast(u64, now - rule.start_time.?) orelse {
            print("Warning: Session time overflow for {s}, resetting\n", .{rule.name});
            rule.start_time = now;
            return;
        };
        const total_time = std.math.add(u64, rule.elapsed_time, session_time) catch blk: {
            print("Warning: Total time overflow for {s}, capping at limit\n", .{rule.name});
            break :blk rule.time_limit_seconds;
        };

        if (total_time >= rule.time_limit_seconds) {
            rule.elapsed_time = total_time;
            rule.start_time = null;

            var reason_buffer: [64]u8 = undefined;
            const reason = std.fmt.bufPrint(&reason_buffer, "Time limit reached ({d}s)", .{total_time}) catch "Time limit reached";
            killProcesses(rule, reason);
            rule.clearState();
        } else {
            const remaining = rule.time_limit_seconds - total_time;
            print("{s}: Running - {d}/{d}s used, {d}s remaining\n", .{ rule.name, total_time, rule.time_limit_seconds, remaining });
        }
    }

    fn checkDailyReset(self: *PishlemeDaemon) void {
        const now = stdtime.timestamp();
        const current_day = @divFloor(now, SECONDS_PER_DAY);

        if (current_day > self.last_reset_day) {
            print("Daily reset: Resetting all application timers\n", .{});

            for (self.app_rules.items) |*rule| {
                rule.elapsed_time = 0;
                rule.start_time = null;
                rule.grace_period_start = null;
                rule.process_ids.clearRetainingCapacity();
                print("Reset timer for {s}\n", .{rule.name});
            }

            self.last_reset_day = current_day;
        }
    }

    fn run(self: *PishlemeDaemon) !void {
        print("Pishleme daemon started. Monitoring {} applications...\n", .{self.app_rules.items.len});
        print("Daily reset enabled: timers reset at midnight each day\n", .{});
        print("Using event-driven kqueue loop for efficient monitoring\n", .{});

        // Create kqueue for event monitoring
        const kq = cc.kqueue();
        if (kq == -1) {
            print("Error: Failed to create kqueue\n", .{});
            return;
        }
        defer _ = c.close(kq);

        // Set up timer event for periodic monitoring
        var timer_event: cc.struct_kevent = std.mem.zeroes(cc.struct_kevent);
        timer_event.ident = 1; // Timer ID
        timer_event.filter = cc.EVFILT_TIMER;
        timer_event.flags = cc.EV_ADD | cc.EV_ENABLE;
        timer_event.data = POLLING_INTERVAL_MILLISECONDS;

        if (cc.kevent(kq, &timer_event, 1, null, 0, null) == -1) {
            print("Error: Failed to add timer event\n", .{});
            return;
        }

        // Set up signal events for graceful shutdown
        var sigterm_event: cc.struct_kevent = std.mem.zeroes(cc.struct_kevent);
        sigterm_event.ident = cc.SIGTERM;
        sigterm_event.filter = cc.EVFILT_SIGNAL;
        sigterm_event.flags = cc.EV_ADD | cc.EV_ENABLE;

        var sigint_event: cc.struct_kevent = std.mem.zeroes(cc.struct_kevent);
        sigint_event.ident = cc.SIGINT;
        sigint_event.filter = cc.EVFILT_SIGNAL;
        sigint_event.flags = cc.EV_ADD | cc.EV_ENABLE;

        // Block signals so kqueue can handle them
        var sigset: cc.sigset_t = undefined;
        _ = cc.sigemptyset(&sigset);
        _ = cc.sigaddset(&sigset, cc.SIGTERM);
        _ = cc.sigaddset(&sigset, cc.SIGINT);
        _ = cc.sigprocmask(cc.SIG_BLOCK, &sigset, null);

        if (cc.kevent(kq, &sigterm_event, 1, null, 0, null) == -1) {
            print("Warning: Failed to add SIGTERM event\n", .{});
        }

        if (cc.kevent(kq, &sigint_event, 1, null, 0, null) == -1) {
            print("Warning: Failed to add SIGINT event\n", .{});
        }

        // Event loop
        var events: [10]cc.struct_kevent = undefined;

        while (self.running and g_daemon_running) {
            // Wait for events (blocking)
            const nevents = cc.kevent(kq, null, 0, &events, events.len, null);

            if (nevents == -1) {
                print("Error: kevent failed\n", .{});
                break;
            }

            // Process events
            for (events[0..@intCast(nevents)]) |event| {
                switch (event.filter) {
                    cc.EVFILT_TIMER => {
                        // Timer fired - do periodic monitoring
                        self.checkDailyReset();

                        for (self.app_rules.items) |*rule| {
                            try self.checkAndEnforceTimeLimit(rule);
                        }
                    },
                    cc.EVFILT_SIGNAL => {
                        // Signal received - graceful shutdown
                        print("Received signal {d}, shutting down gracefully...\n", .{event.ident});
                        g_daemon_running = false;
                        self.running = false;
                    },
                    else => {
                        // Unknown event type
                        print("Warning: Unknown event filter {d}\n", .{event.filter});
                    },
                }
            }
        }

        print("Pishleme daemon stopped\n", .{});
    }
};

fn killProcesses(rule: *AppRule, reason: []const u8) void {
    if (rule.process_ids.items.len == 0) return;

    print("{s}: {s}. Terminating {d} processes...\n", .{ rule.name, reason, rule.process_ids.items.len });
    for (rule.process_ids.items) |pid| {
        const result = c.kill(pid, cc.SIGKILL);
        if (result == 0) {
            print("Killed process {d} with SIGKILL\n", .{pid});
        } else {
            print("Failed to kill process {d}\n", .{pid});
        }
    }
}

fn printUsage(program_name: []const u8) void {
    print("Usage: {s} [options]\n", .{program_name});
    print("Options:\n", .{});
    print("  --app <name> --time <seconds>        Monitor application and enforce time limit\n", .{});
    print("  --hours <start>-<end>               Restrict ALL applications to specific hours (24-hour format)\n", .{});
    print("  --help                               Show this help message\n", .{});
    print("\nExamples:\n", .{});
    print("  {s} --hours 9-17 --app Safari --time 3600 --app Discord --time 1800\n", .{program_name});
    print("  This sets global hours 9AM-5PM for all apps, then monitors Safari (1h) and Discord (30m)\n", .{});
    print("  {s} --app Safari --time 3600\n", .{program_name});
    print("  This monitors Safari for 1 hour with no time restrictions\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage(args[0]);
        return;
    }


    var daemon = PishlemeDaemon.init(allocator);
    defer daemon.deinit();

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--help")) {
            printUsage(args[0]);
            return;
        } else if (std.mem.eql(u8, args[i], "--hours")) {
            if (i + 1 >= args.len) {
                print("Error: --hours must be followed by hour range (e.g., 10-20)\n", .{});
                printUsage(args[0]);
                return;
            }

            const hours_str = args[i + 1];
            const dash_pos = std.mem.indexOf(u8, hours_str, "-") orelse {
                print("Error: Invalid hour range format '{s}'. Use format like 10-20\n", .{hours_str});
                return;
            };

            const start_str = hours_str[0..dash_pos];
            const end_str = hours_str[dash_pos + 1..];

            const start_hour = std.fmt.parseInt(u8, start_str, 10) catch {
                print("Error: Invalid start hour '{s}'\n", .{start_str});
                return;
            };

            const end_hour = std.fmt.parseInt(u8, end_str, 10) catch {
                print("Error: Invalid end hour '{s}'\n", .{end_str});
                return;
            };

            if (start_hour >= 24 or end_hour > 24 or start_hour >= end_hour) {
                print("Error: Invalid hour range {d}-{d}. Hours must be 0-23 and start < end\n", .{ start_hour, end_hour });
                return;
            }

            daemon.setGlobalAllowedHours(start_hour, end_hour);
            print("Set global allowed hours: {d}:00-{d}:00\n", .{ start_hour, end_hour });

            i += 2;
        } else if (std.mem.eql(u8, args[i], "--app")) {
            if (i + 3 >= args.len or !std.mem.eql(u8, args[i + 2], "--time")) {
                print("Error: --app must be followed by app name and --time with seconds\n", .{});
                printUsage(args[0]);
                return;
            }

            const app_name = args[i + 1];
            const time_str = args[i + 3];
            const time_limit = std.fmt.parseInt(u64, time_str, 10) catch {
                print("Error: Invalid time limit '{s}'\n", .{time_str});
                return;
            };

            try daemon.addAppRule(app_name, time_limit);
            print("Added rule: {s} - {d} seconds\n", .{ app_name, time_limit });

            i += 4;
        } else {
            print("Error: Unknown argument '{s}'\n", .{args[i]});
            printUsage(args[0]);
            return;
        }
    }

    if (daemon.app_rules.items.len == 0) {
        print("Error: No applications specified to monitor\n", .{});
        printUsage(args[0]);
        return;
    }

    try daemon.run();
}
