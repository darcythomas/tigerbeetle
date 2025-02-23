const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;
const log_main = std.log.scoped(.main);

const build_options = @import("tigerbeetle_build_options");

const vsr = @import("vsr");
const constants = vsr.constants;
const config = vsr.config.configs.current;
const tracer = vsr.tracer;

const cli = @import("cli.zig");
const fatal = cli.fatal;

const IO = vsr.io.IO;
const Time = vsr.time.Time;
const Storage = vsr.storage.Storage;

const MessageBus = vsr.message_bus.MessageBusReplica;
const MessagePool = vsr.message_pool.MessagePool;
const StateMachine = vsr.state_machine.StateMachineType(Storage, .{
    .message_body_size_max = constants.message_body_size_max,
});

const Replica = vsr.ReplicaType(StateMachine, MessageBus, Storage, Time);

const SuperBlock = vsr.SuperBlockType(Storage);
const superblock_zone_size = vsr.superblock.superblock_zone_size;
const data_file_size_min = vsr.superblock.data_file_size_min;

pub const log_level: std.log.Level = constants.log_level;
pub const log = constants.log;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var parse_args = try cli.parse_args(allocator);
    defer parse_args.deinit(allocator);

    switch (parse_args) {
        .format => |*args| try Command.format(allocator, args.cluster, args.replica, args.path),
        .start => |*args| try Command.start(&arena, args),
        .version => |*args| try Command.version(allocator, args.verbose),
    }
}

// Pad the cluster id number and the replica index with 0s
const filename_fmt = "cluster_{d:0>10}_replica_{d:0>3}.tigerbeetle";
const filename_len = fmt.count(filename_fmt, .{ 0, 0 });

const Command = struct {
    dir_fd: os.fd_t,
    fd: os.fd_t,
    io: IO,
    storage: Storage,
    message_pool: MessagePool,

    fn init(
        command: *Command,
        allocator: mem.Allocator,
        path: [:0]const u8,
        must_create: bool,
    ) !void {
        // TODO Resolve the parent directory properly in the presence of .. and symlinks.
        // TODO Handle physical volumes where there is no directory to fsync.
        const dirname = std.fs.path.dirname(path) orelse ".";
        command.dir_fd = try IO.open_dir(dirname);
        errdefer os.close(command.dir_fd);

        const basename = std.fs.path.basename(path);
        command.fd = try IO.open_file(command.dir_fd, basename, data_file_size_min, must_create);
        errdefer os.close(command.fd);

        command.io = try IO.init(128, 0);
        errdefer command.io.deinit();

        command.storage = try Storage.init(&command.io, command.fd);
        errdefer command.storage.deinit();

        command.message_pool = try MessagePool.init(allocator, .replica);
        errdefer command.message_pool.deinit(allocator);
    }

    fn deinit(command: *Command, allocator: mem.Allocator) void {
        command.message_pool.deinit(allocator);
        command.storage.deinit();
        command.io.deinit();
        os.close(command.fd);
        os.close(command.dir_fd);
    }

    pub fn format(allocator: mem.Allocator, cluster: u32, replica: u8, path: [:0]const u8) !void {
        var command: Command = undefined;
        try command.init(allocator, path, true);
        defer command.deinit(allocator);

        var superblock = try SuperBlock.init(
            allocator,
            .{
                .storage = &command.storage,
                .storage_size_limit = data_file_size_min,
                .message_pool = &command.message_pool,
            },
        );
        defer superblock.deinit(allocator);

        try vsr.format(Storage, allocator, cluster, replica, &command.storage, &superblock);
    }

    pub fn start(arena: *std.heap.ArenaAllocator, args: *const cli.Command.Start) !void {
        var tracer_allocator = if (constants.tracer_backend == .tracy)
            tracer.TracerAllocator.init(arena.allocator())
        else
            arena;

        // TODO Panic if the data file's size is larger that args.storage_size_limit.
        // (Here or in Replica.open()?).

        const allocator = tracer_allocator.allocator();

        try tracer.init(allocator);
        defer tracer.deinit(allocator);

        var command: Command = undefined;
        try command.init(allocator, args.path, false);
        defer command.deinit(allocator);

        var replica: Replica = undefined;
        replica.open(allocator, .{
            .replica_count = @intCast(u8, args.addresses.len),
            .storage_size_limit = args.storage_size_limit,
            .storage = &command.storage,
            .message_pool = &command.message_pool,
            .time = .{},
            .state_machine_options = .{
                // TODO Tune lsm_forest_node_count better.
                .lsm_forest_node_count = 4096,
                .cache_entries_accounts = args.cache_accounts,
                .cache_entries_transfers = args.cache_transfers,
                .cache_entries_posted = args.cache_transfers_posted,
            },
            .message_bus_options = .{
                .configuration = args.addresses,
                .io = &command.io,
            },
        }) catch |err| switch (err) {
            error.NoAddress => fatal("all --addresses must be provided", .{}),
            else => |e| return e,
        };

        // Calculate how many bytes are allocated inside `arena`.
        // TODO This does not account for the fact that any allocations will be rounded up to the nearest page by `std.heap.page_allocator`.
        var allocation_count: usize = 0;
        var allocation_size: usize = 0;
        {
            var node_maybe = arena.state.buffer_list.first;
            while (node_maybe) |node| {
                allocation_count += 1;
                allocation_size += node.data.len;
                node_maybe = node.next;
            }
        }
        log_main.info("{}: Allocated {} bytes in {} regions during replica init", .{
            replica.replica,
            allocation_size,
            allocation_count,
        });

        log_main.info("{}: cluster={}: listening on {}", .{
            replica.replica,
            replica.cluster,
            args.addresses[replica.replica],
        });

        while (true) {
            replica.tick();
            try command.io.run_for_ns(constants.tick_ms * std.time.ns_per_ms);
        }
    }

    pub fn version(allocator: mem.Allocator, verbose: bool) !void {
        _ = allocator;

        var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = stdout_buffer.writer();
        // TODO Pass an actual version number in on build, instead of just saying "experimental".
        try stdout.writeAll("TigerBeetle version experimental\n");

        if (verbose) {
            try std.fmt.format(
                stdout,
                \\
                \\git_commit="{s}"
                \\
            ,
                .{build_options.git_commit orelse "?"},
            );

            try stdout.writeAll("\n");
            inline for (.{ "mode", "zig_version" }) |declaration| {
                try print_value(stdout, "build." ++ declaration, @field(builtin, declaration));
            }

            // TODO(Zig): Use meta.fieldNames() after upgrading to 0.10.
            // See: https://github.com/ziglang/zig/issues/10235
            try stdout.writeAll("\n");
            inline for (std.meta.fields(@TypeOf(config.cluster))) |field| {
                try print_value(stdout, "cluster." ++ field.name, @field(config.cluster, field.name));
            }

            try stdout.writeAll("\n");
            inline for (std.meta.fields(@TypeOf(config.process))) |field| {
                try print_value(stdout, "process." ++ field.name, @field(config.process, field.name));
            }
        }
        try stdout_buffer.flush();
    }
};

fn print_value(
    writer: anytype,
    comptime field: []const u8,
    comptime value: anytype,
) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .Fn => {}, // Ignore the log() function.
        .Pointer => try std.fmt.format(writer, "{s}=\"{s}\"\n", .{
            field,
            std.fmt.fmtSliceEscapeLower(value),
        }),
        else => try std.fmt.format(writer, "{s}={}\n", .{
            field,
            value,
        }),
    }
}
