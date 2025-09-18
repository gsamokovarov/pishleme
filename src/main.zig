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
    allowed_hours: ?struct { start: u8, end: u8 } = null,

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

    fn isCurrentlyAllowed(self: *const AppRule) bool {
        if (self.allowed_hours == null) return true;

        const now_time_t = time(null);
        const local_time = localtime(&now_time_t) orelse return true;
 
        const current_hour = @as(u8, @intCast(local_time.tm_hour));

        const allowed = self.allowed_hours.?;
        return current_hour >= allowed.start and current_hour < allowed.end;
    }
};

const PishlemeDaemon = struct {
    allocator: Allocator,
    app_rules: ArrayList(AppRule),
    running: bool = true,
    last_reset_day: i64,

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

    fn addAppRuleWithHours(self: *PishlemeDaemon, name: []const u8, time_limit_seconds: u64, start_hour: u8, end_hour: u8) !void {
        var rule = AppRule.init(self.allocator, name, time_limit_seconds);
        rule.allowed_hours = .{ .start = start_hour, .end = end_hour };
        try self.app_rules.append(rule);
    }

    fn findProcessesByName(self: *PishlemeDaemon, app_name: []const u8) !ArrayList(c.pid_t) {
        var pids = ArrayList(c.pid_t).init(self.allocator);

        // First try exact match
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "pgrep", "-i", "-x", app_name },
        }) catch {
            // If pgrep fails, try with case-insensitive partial match for .app bundles
            const result2 = std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &[_][]const u8{ "pgrep", "-i", app_name },
            }) catch {
                return pids; // Return empty list if both fail
            };
            return self.parseProcessOutput(result2, &pids);
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
                const pid = std.fmt.parseInt(c.pid_t, std.mem.trim(u8, line, " \t\n"), 10) catch continue;
                try pids.append(pid);
            }
        }

        return pids.*;
    }

    fn killProcess(pid: c.pid_t) void {
        const result = c.kill(pid, SIGKILL);
        if (result == 0) {
            print("Killed process {d} with SIGKILL\n", .{pid});
        } else {
            print("Failed to kill process {d}\n", .{pid});
        }
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
                rule.elapsed_time += @intCast(now - rule.start_time.?);
                rule.start_time = null;
                print("{s}: Not running. Total usage: {d}s\n", .{ rule.name, rule.elapsed_time });
            }
            rule.grace_period_start = null;
            return;
        }

        if (!rule.isCurrentlyAllowed()) {
            print("{s}: Outside allowed hours. Terminating processes...\n", .{rule.name});
            for (rule.process_ids.items) |pid| {
                killProcess(pid);
            }
            rule.process_ids.clearRetainingCapacity();
            rule.grace_period_start = null;
            if (rule.start_time != null) {
                rule.elapsed_time += @intCast(now - rule.start_time.?);
                rule.start_time = null;
            }
            return;
        }

        if (rule.isTimeExceeded()) {
            if (rule.grace_period_start == null) {
                rule.grace_period_start = now;
                print("Time already exceeded for {s} ({d}s). Grace period: 5 seconds before termination.\n", .{ rule.name, rule.elapsed_time });
            }

            const grace_elapsed = @as(u64, @intCast(now - rule.grace_period_start.?));
            if (grace_elapsed >= 5) {
                print("Grace period expired for {s}. Terminating processes...\n", .{rule.name});

                for (rule.process_ids.items) |pid| {
                    killProcess(pid);
                }

                rule.process_ids.clearRetainingCapacity();
                rule.grace_period_start = null;
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

        const current_session_time = @as(u64, @intCast(now - rule.start_time.?));
        const total_time = rule.elapsed_time + current_session_time;

        if (total_time >= rule.time_limit_seconds) {
            rule.elapsed_time = total_time;
            rule.start_time = null;

            print("Time limit reached for {s} ({d}s). Terminating processes...\n", .{ rule.name, total_time });

            for (rule.process_ids.items) |pid| {
                killProcess(pid);
            }

            rule.process_ids.clearRetainingCapacity();
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

fn printUsage(program_name: []const u8) void {
    print("Usage: {s} [options]\n", .{program_name});
    print("Options:\n", .{});
    print("  --app <name> --time <seconds>        Monitor application and enforce time limit\n", .{});
    print("  --hours <start>-<end>               Restrict application to specific hours (24-hour format)\n", .{});
    print("  --help                               Show this help message\n", .{});
    print("\nExamples:\n", .{});
    print("  {s} --app Safari --time 3600\n", .{program_name});
    print("  {s} --app Discord --time 1800 --hours 10-20\n", .{program_name});
    print("  This monitors Discord for 30 minutes only between 10AM and 8PM\n", .{});
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

            var next_i = i + 4;
            var start_hour: ?u8 = null;
            var end_hour: ?u8 = null;

            if (next_i < args.len and std.mem.eql(u8, args[next_i], "--hours")) {
                if (next_i + 1 >= args.len) {
                    print("Error: --hours must be followed by hour range (e.g., 10-20)\n", .{});
                    printUsage(args[0]);
                    return;
                }

                const hours_str = args[next_i + 1];
                const dash_pos = std.mem.indexOf(u8, hours_str, "-") orelse {
                    print("Error: Invalid hour range format '{s}'. Use format like 10-20\n", .{hours_str});
                    return;
                };

                const start_str = hours_str[0..dash_pos];
                const end_str = hours_str[dash_pos + 1..];

                start_hour = std.fmt.parseInt(u8, start_str, 10) catch {
                    print("Error: Invalid start hour '{s}'\n", .{start_str});
                    return;
                };

                end_hour = std.fmt.parseInt(u8, end_str, 10) catch {
                    print("Error: Invalid end hour '{s}'\n", .{end_str});
                    return;
                };

                if (start_hour.? >= 24 or end_hour.? > 24 or start_hour.? >= end_hour.?) {
                    print("Error: Invalid hour range {d}-{d}. Hours must be 0-23 and start < end\n", .{ start_hour.?, end_hour.? });
                    return;
                }

                next_i += 2;
            }

            if (start_hour != null and end_hour != null) {
                try daemon.addAppRuleWithHours(app_name, time_limit, start_hour.?, end_hour.?);
                print("Added rule: {s} - {d} seconds, allowed {d}:00-{d}:00\n", .{ app_name, time_limit, start_hour.?, end_hour.? });
            } else {
                try daemon.addAppRule(app_name, time_limit);
                print("Added rule: {s} - {d} seconds\n", .{ app_name, time_limit });
            }

            i = next_i;
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
