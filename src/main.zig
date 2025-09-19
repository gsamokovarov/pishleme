const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const process = std.process;
const stdtime = std.time;
const c = std.c;

const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

extern fn time(tloc: ?*c.time_t) c.time_t;
extern fn localtime(timer: *const c.time_t) ?*tm;

const SIGKILL = 9;

const AppRule = struct {
    name: []const u8,
    time_limit_seconds: u64,
    start_time: ?i64 = null,
    elapsed_time: u64 = 0,
    process_ids: ArrayList(c.pid_t),
    grace_period_start: ?i64 = null,

    fn init(allocator: Allocator, name: []const u8, time_limit_seconds: u64) AppRule {
        return AppRule{
            .name = name,
            .time_limit_seconds = time_limit_seconds,
            .process_ids = ArrayList(c.pid_t).init(allocator),
        };
    }

    fn deinit(self: *AppRule) void {
        self.process_ids.deinit();
    }

    fn isTimeExceeded(self: *const AppRule) bool {
        return self.elapsed_time >= self.time_limit_seconds;
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
        const current_day = @divFloor(now, 86400); // 86400 seconds in a day

        return PishlemeDaemon{
            .allocator = allocator,
            .app_rules = ArrayList(AppRule).init(allocator),
            .last_reset_day = current_day,
        };
    }

    fn deinit(self: *PishlemeDaemon) void {
        for (self.app_rules.items) |*rule| {
            rule.deinit();
        }
        self.app_rules.deinit();
    }

    fn addAppRule(self: *PishlemeDaemon, name: []const u8, time_limit_seconds: u64) !void {
        const rule = AppRule.init(self.allocator, name, time_limit_seconds);
        try self.app_rules.append(rule);
    }

    fn setGlobalAllowedHours(self: *PishlemeDaemon, start_hour: u8, end_hour: u8) void {
        self.global_allowed_hours = .{ .start = start_hour, .end = end_hour };
    }

    fn isGloballyAllowed(self: *const PishlemeDaemon) bool {
        if (self.global_allowed_hours == null) return true;

        const now_time_t = time(null);
        const local_time = localtime(&now_time_t) orelse return true;

        const current_hour = @as(u8, @intCast(local_time.tm_hour));

        const allowed = self.global_allowed_hours.?;
        return current_hour >= allowed.start and current_hour < allowed.end;
    }

    fn findProcessesByName(self: *PishlemeDaemon, app_name: []const u8) !ArrayList(c.pid_t) {
        var pids = ArrayList(c.pid_t).init(self.allocator);
        errdefer pids.deinit();

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "pgrep", "-i", app_name },
        }) catch {
            return pids;
        };

        return self.parseProcessOutput(result, &pids);
    }

    fn parseProcessOutput(self: *PishlemeDaemon, result: std.process.Child.RunResult, pids: *ArrayList(c.pid_t)) !ArrayList(c.pid_t) {
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            var lines = std.mem.splitSequence(u8, result.stdout, "\n");
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                const trimmed = std.mem.trim(u8, line, " \t\n");
                if (trimmed.len == 0) continue;

                const pid = std.fmt.parseInt(c.pid_t, trimmed, 10) catch {
                    print("Warning: Failed to parse PID '{s}'\n", .{trimmed});
                    continue;
                };
                try pids.append(pid);
            }
        }

        return pids.*;
    }


    fn updateProcessList(self: *PishlemeDaemon, rule: *AppRule) !void {
        rule.process_ids.clearRetainingCapacity();
        const current_pids = try self.findProcessesByName(rule.name);
        defer current_pids.deinit();

        for (current_pids.items) |pid| {
            try rule.process_ids.append(pid);
        }

        // Debug output to help troubleshoot
        if (current_pids.items.len > 0) {
            print("DEBUG: Found {d} processes for {s}: ", .{ current_pids.items.len, rule.name });
            for (current_pids.items) |pid| {
                print("{d} ", .{pid});
            }
            print("\n", .{});
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
                print("Time already exceeded for {s} ({d}s). Grace period: 5 seconds before termination.\n", .{ rule.name, rule.elapsed_time });
            }

            const grace_elapsed = std.math.cast(u64, now - rule.grace_period_start.?) orelse 0;
            if (grace_elapsed >= 5) {
                killProcesses(rule, "Grace period expired");
            } else {
                const grace_remaining = 5 - grace_elapsed;
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

            const reason = std.fmt.allocPrint(self.allocator, "Time limit reached ({d}s)", .{total_time}) catch "Time limit reached";
            defer if (!std.mem.eql(u8, reason, "Time limit reached")) self.allocator.free(reason);
            killProcesses(rule, reason);
        } else {
            const remaining = rule.time_limit_seconds - total_time;
            print("{s}: Running - {d}/{d}s used, {d}s remaining\n", .{ rule.name, total_time, rule.time_limit_seconds, remaining });
        }
    }

    fn checkDailyReset(self: *PishlemeDaemon) void {
        const now = stdtime.timestamp();
        const current_day = @divFloor(now, 86400); // 86400 seconds in a day

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

        while (self.running) {
            self.checkDailyReset();

            for (self.app_rules.items) |*rule| {
                try self.checkAndEnforceTimeLimit(rule);
            }

            stdtime.sleep(1 * stdtime.ns_per_s);
        }
    }
};

fn killProcesses(rule: *AppRule, reason: []const u8) void {
    if (rule.process_ids.items.len == 0) return;

    print("{s}: {s}. Terminating {d} processes...\n", .{ rule.name, reason, rule.process_ids.items.len });
    for (rule.process_ids.items) |pid| {
        const result = c.kill(pid, SIGKILL);
        if (result == 0) {
            print("Killed process {d} with SIGKILL\n", .{pid});
        } else {
            print("Failed to kill process {d}\n", .{pid});
        }
    }
    rule.process_ids.clearRetainingCapacity();
    rule.grace_period_start = null;
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
