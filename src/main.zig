const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("linux/net.h");
    @cInclude("linux/prctl.h");
    @cInclude("seccomp.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

const scmpActAllow: u32 = 0x7fff0000;
const scmpActErrno: u32 = 0x00050000;

const Profile = enum {
    local_cli,
    monitor,
    strict_test,

    fn parse(value: []const u8) ?Profile {
        if (std.mem.eql(u8, value, "local-cli")) return .local_cli;
        if (std.mem.eql(u8, value, "monitor")) return .monitor;
        if (std.mem.eql(u8, value, "strict-test")) return .strict_test;
        return null;
    }
};

const Options = struct {
    profile: Profile = .local_cli,
    deny_inet: bool = false,
    deny_netlink: bool = false,
    syscall_rules: std.StringArrayHashMapUnmanaged(bool) = .{},
    command_index: usize = 0,

    fn addDeny(self: *Options, allocator: std.mem.Allocator, name: []const u8) !void {
        try self.syscall_rules.put(allocator, name, true);
    }

    fn addAllow(self: *Options, allocator: std.mem.Allocator, name: []const u8) !void {
        try self.syscall_rules.put(allocator, name, false);
    }
};

fn usage() void {
    std.debug.print(
        \\Usage: secwrap [OPTIONS] -- <command> [args...]
        \\
        \\Options:
        \\  --profile <name>          local-cli, monitor, or strict-test
        \\  --deny-inet              deny IPv4 and IPv6 socket creation
        \\  --allow-netlink          allow AF_NETLINK socket creation
        \\  --deny-syscall <name>    deny a syscall by name
        \\  --allow-syscall <name>   remove a named syscall deny
        \\  -h, --help               show this help
        \\
    , .{});
}

fn applyProfile(options: *Options, allocator: std.mem.Allocator) !void {
    switch (options.profile) {
        .local_cli => {
            options.deny_inet = true;
            options.deny_netlink = true;
            try addLocalCliSyscalls(options, allocator);
        },
        .monitor => {
            options.deny_inet = true;
            options.deny_netlink = false;
            try addLocalCliSyscalls(options, allocator);
        },
        .strict_test => {
            try options.addDeny(allocator, "getdents64");
        },
    }
}

fn addLocalCliSyscalls(options: *Options, allocator: std.mem.Allocator) !void {
    const names = [_][]const u8{
        "ptrace",
        "process_vm_readv",
        "process_vm_writev",
        "bpf",
        "perf_event_open",
        "keyctl",
        "add_key",
        "request_key",
        "init_module",
        "finit_module",
        "delete_module",
        "mount",
        "umount2",
        "pivot_root",
        "swapon",
        "swapoff",
        "reboot",
        "kexec_load",
        "open_by_handle_at",
    };

    for (names) |name| {
        try options.addDeny(allocator, name);
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var options = Options{};
    var deferred_overrides = std.array_list.Managed([]const u8).init(allocator);
    defer deferred_overrides.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command_index = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.command_index = 0;
            return options;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingProfile;
            options.profile = Profile.parse(args[i]) orelse return error.UnknownProfile;
        } else if (std.mem.eql(u8, arg, "--deny-inet")) {
            try deferred_overrides.append("--deny-inet");
        } else if (std.mem.eql(u8, arg, "--allow-netlink")) {
            try deferred_overrides.append("--allow-netlink");
        } else if (std.mem.eql(u8, arg, "--deny-syscall") or std.mem.eql(u8, arg, "--allow-syscall")) {
            if (i + 1 >= args.len) return error.MissingSyscall;
            try deferred_overrides.append(arg);
            i += 1;
            try deferred_overrides.append(args[i]);
        } else {
            return error.UnknownOption;
        }
    }

    try applyProfile(&options, allocator);

    i = 0;
    while (i < deferred_overrides.items.len) : (i += 1) {
        const item = deferred_overrides.items[i];
        if (std.mem.eql(u8, item, "--deny-inet")) {
            options.deny_inet = true;
        } else if (std.mem.eql(u8, item, "--allow-netlink")) {
            options.deny_netlink = false;
        } else if (std.mem.eql(u8, item, "--deny-syscall")) {
            i += 1;
            try options.addDeny(allocator, deferred_overrides.items[i]);
        } else if (std.mem.eql(u8, item, "--allow-syscall")) {
            i += 1;
            try options.addAllow(allocator, deferred_overrides.items[i]);
        }
    }

    if (options.command_index == 0 or options.command_index >= args.len) return error.MissingCommand;
    return options;
}

fn errnoAction(errno: u32) u32 {
    return scmpActErrno | (errno & 0x0000ffff);
}

fn checkRc(rc: c_int, what: []const u8) !void {
    if (rc < 0) {
        std.debug.print("{s}: failed with libseccomp rc {d}\n", .{ what, rc });
        return error.SeccompFailed;
    }
}

fn resolveSyscall(name: []const u8) !c_int {
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return error.InvalidSyscall;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;

    const nr = c.seccomp_syscall_resolve_name(@ptrCast(&buf));
    if (nr == c.__NR_SCMP_ERROR) return error.InvalidSyscall;
    return nr;
}

fn addDenySyscall(ctx: c.scmp_filter_ctx, name: []const u8) !void {
    const nr = try resolveSyscall(name);
    try checkRc(c.seccomp_rule_add_array(ctx, errnoAction(c.EPERM), nr, 0, null), name);
}

fn addDenySocketFamily(ctx: c.scmp_filter_ctx, family: u32) !void {
    const socket_nr = try resolveSyscall("socket");
    var cmp = c.struct_scmp_arg_cmp{
        .arg = 0,
        .op = c.SCMP_CMP_EQ,
        .datum_a = family,
        .datum_b = 0,
    };
    try checkRc(c.seccomp_rule_add_array(ctx, errnoAction(c.EPERM), socket_nr, 1, &cmp), "socket family rule");
}

fn installSeccomp(options: Options) !void {
    if (builtin.os.tag != .linux) return error.LinuxOnly;

    if (c.prctl(
        c.PR_SET_NO_NEW_PRIVS,
        @as(c_ulong, 1),
        @as(c_ulong, 0),
        @as(c_ulong, 0),
        @as(c_ulong, 0),
    ) != 0) {
        return error.NoNewPrivsFailed;
    }

    const ctx = c.seccomp_init(scmpActAllow) orelse return error.SeccompFailed;
    defer c.seccomp_release(ctx);

    if (options.deny_inet) {
        try addDenySocketFamily(ctx, c.AF_INET);
        try addDenySocketFamily(ctx, c.AF_INET6);
    }
    if (options.deny_netlink) {
        try addDenySocketFamily(ctx, c.AF_NETLINK);
    }

    for (options.syscall_rules.keys(), options.syscall_rules.values()) |name, deny| {
        if (deny) {
            try addDenySyscall(ctx, name);
        }
    }

    try checkRc(c.seccomp_load(ctx), "seccomp_load");
}

fn execCommand(allocator: std.mem.Allocator, command: []const []const u8) !noreturn {
    var argv = try allocator.alloc(?[*:0]const u8, command.len + 1);
    for (command, 0..) |arg, idx| {
        argv[idx] = try allocator.dupeZ(u8, arg);
    }
    argv[command.len] = null;

    _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
    const errno = std.posix.errno(-1);
    std.debug.print("exec failed for '{s}': {s}\n", .{ command[0], @tagName(errno) });
    std.process.exit(127);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    var arg_list = std.array_list.Managed([]const u8).init(allocator);
    while (arg_iter.next()) |arg| {
        try arg_list.append(arg);
    }
    const args = arg_list.items;

    if (args.len == 1) {
        usage();
        std.process.exit(2);
    }

    const options = parseArgs(allocator, args) catch |err| {
        std.debug.print("secwrap: {s}\n\n", .{@errorName(err)});
        usage();
        std.process.exit(2);
    };

    if (options.command_index == 0) {
        usage();
        return;
    }

    installSeccomp(options) catch |err| {
        std.debug.print("secwrap: refusing to execute target: {s}\n", .{@errorName(err)});
        std.process.exit(126);
    };

    try execCommand(allocator, args[options.command_index..]);
}

test "local-cli profile denies inet and netlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "secwrap", "--profile", "local-cli", "--", "true" };
    const options = try parseArgs(arena.allocator(), &args);
    try std.testing.expect(options.deny_inet);
    try std.testing.expect(options.deny_netlink);
    try std.testing.expectEqual(@as(usize, 4), options.command_index);
}

test "monitor profile allows netlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "secwrap", "--profile", "monitor", "--", "btop" };
    const options = try parseArgs(arena.allocator(), &args);
    try std.testing.expect(options.deny_inet);
    try std.testing.expect(!options.deny_netlink);
}

test "explicit syscall allow removes profile deny" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = [_][]const u8{ "secwrap", "--profile", "local-cli", "--allow-syscall", "ptrace", "--", "true" };
    const options = try parseArgs(arena.allocator(), &args);
    try std.testing.expectEqual(false, options.syscall_rules.get("ptrace").?);
}
