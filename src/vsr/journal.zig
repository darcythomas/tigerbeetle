const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const constants = @import("../constants.zig");

const Message = @import("../message_pool.zig").MessagePool.Message;
const util = @import("../util.zig");
const vsr = @import("../vsr.zig");
const Header = vsr.Header;
const IOPS = @import("../iops.zig").IOPS;

const log = std.log.scoped(.journal);

/// The WAL consists of two contiguous circular buffers on disk:
/// - `vsr.Zone.wal_headers`
/// - `vsr.Zone.wal_prepares`
///
/// In each ring, the `op` for reserved headers is set to the corresponding slot index.
/// This helps WAL recovery detect misdirected reads/writes.
const Ring = enum {
    /// A circular buffer of (redundant) prepare message headers.
    headers,
    /// A circular buffer of prepare messages. Each slot is padded to `constants.message_size_max`.
    prepares,

    /// Returns the slot's offset relative to the start of the ring.
    inline fn offset(comptime ring: Ring, slot: Slot) u64 {
        assert(slot.index < slot_count);
        switch (ring) {
            .headers => {
                comptime assert(constants.sector_size % @sizeOf(Header) == 0);
                const ring_offset = vsr.sector_floor(slot.index * @sizeOf(Header));
                assert(ring_offset < headers_size);
                return ring_offset;
            },
            .prepares => {
                const ring_offset = constants.message_size_max * slot.index;
                assert(ring_offset < prepares_size);
                return ring_offset;
            },
        }
    }
};

const headers_per_sector = @divExact(constants.sector_size, @sizeOf(Header));
const headers_per_message = @divExact(constants.message_size_max, @sizeOf(Header));
comptime {
    assert(headers_per_sector > 0);
    assert(headers_per_message > 0);
}

/// A slot is an index within:
///
/// - the on-disk headers ring
/// - the on-disk prepares ring
/// - `journal.headers`
/// - `journal.headers_redundant`
/// - `journal.dirty`
/// - `journal.faulty`
///
/// A header's slot is `header.op % constants.journal_slot_count`.
const Slot = struct { index: usize };

/// An inclusive, non-empty range of slots.
const SlotRange = struct {
    head: Slot,
    tail: Slot,

    /// Returns whether this range (inclusive) includes the specified slot.
    ///
    /// Cases (`·`=included, ` `=excluded):
    ///
    /// * `head < tail` → `  head··tail  `
    /// * `head > tail` → `··tail  head··` (The range wraps around).
    /// * `head = tail` → panic            (Caller must handle this case separately).
    fn contains(range: *const SlotRange, slot: Slot) bool {
        // To avoid confusion, the empty range must be checked separately by the caller.
        assert(range.head.index != range.tail.index);

        if (range.head.index < range.tail.index) {
            return range.head.index <= slot.index and slot.index <= range.tail.index;
        }
        if (range.head.index > range.tail.index) {
            return slot.index <= range.tail.index or range.head.index <= slot.index;
        }
        unreachable;
    }
};

const slot_count = constants.journal_slot_count;
const headers_size = constants.journal_size_headers;
const prepares_size = constants.journal_size_prepares;

pub const write_ahead_log_zone_size = headers_size + prepares_size;

comptime {
    assert(slot_count > 0);
    assert(slot_count % 2 == 0);
    assert(slot_count % headers_per_sector == 0);
    assert(slot_count >= headers_per_sector);
    // The length of the prepare pipeline is the upper bound on how many ops can be
    // reordered during a view change. See `recover_prepares_callback()` for more detail.
    assert(slot_count > constants.pipeline_max);

    assert(headers_size > 0);
    assert(headers_size % constants.sector_size == 0);

    assert(prepares_size > 0);
    assert(prepares_size % constants.sector_size == 0);
    assert(prepares_size % constants.message_size_max == 0);
}

pub fn JournalType(comptime Replica: type, comptime Storage: type) type {
    return struct {
        const Journal = @This();
        const Sector = *align(constants.sector_size) [constants.sector_size]u8;

        const Status = union(enum) {
            init: void,
            recovering: fn (journal: *Journal) void,
            recovered: void,
        };

        pub const Read = struct {
            journal: *Journal,
            completion: Storage.Read,
            callback: fn (replica: *Replica, prepare: ?*Message, destination_replica: ?u8) void,

            message: *Message,
            op: u64,
            checksum: u128,
            destination_replica: ?u8,
        };

        pub const Write = struct {
            pub const Trigger = enum { append, fix, repair, pipeline };

            journal: *Journal,
            callback: fn (replica: *Replica, wrote: ?*Message, trigger: Trigger) void,

            message: *Message,
            trigger: Trigger,

            /// True if this Write has acquired a lock on a sector of headers.
            /// This also means that the Write is currently writing sectors or queuing to do so.
            header_sector_locked: bool = false,

            /// Linked list of Writes waiting to acquire the same header sector as this Write.
            header_sector_next: ?*Write = null,

            /// This is reset to undefined and reused for each Storage.write_sectors() call.
            range: Range,
        };

        /// State that needs to be persisted while waiting for an overlapping
        /// concurrent write to complete. This is a range on the physical disk.
        const Range = struct {
            completion: Storage.Write,
            callback: fn (write: *Journal.Write) void,
            buffer: []const u8,
            ring: Ring,
            /// Offset within the ring.
            offset: u64,

            /// If other writes are waiting on this write to proceed, they will
            /// be queued up in this linked list.
            next: ?*Range = null,
            /// True if a Storage.write_sectors() operation is in progress for this buffer/offset.
            locked: bool,

            fn overlaps(journal: *const Range, other: *const Range) bool {
                if (journal.ring != other.ring) return false;

                if (journal.offset < other.offset) {
                    return journal.offset + journal.buffer.len > other.offset;
                } else {
                    return other.offset + other.buffer.len > journal.offset;
                }
            }
        };

        const HeaderChunks = std.StaticBitSet(util.div_ceil(slot_count, headers_per_message));

        storage: *Storage,
        replica: u8,

        /// A header is located at `slot == header.op % headers.len`.
        ///
        /// Each slot's `header.command` is either `prepare` or `reserved`.
        /// When the slot's header is `reserved`, the header's `op` is the slot index.
        ///
        /// During recovery, store the (unvalidated) headers of the prepare ring.
        headers: []align(constants.sector_size) Header,

        /// Store headers whose prepares are on disk.
        /// Redundant headers are updated after the corresponding prepare(s) are written,
        /// whereas `headers` are updated beforehand.
        ///
        /// Consider this example:
        /// 1. Ops 6 and 7 arrive.
        /// 2. The write of prepare 7 finishes (before prepare 6).
        /// 3. Op 7 continues on to write the redundant headers.
        ///    Because prepare 6 is not yet written, header 6 is written as reserved.
        /// 4. If at this point the replica crashes & restarts, slot 6 is in case `@J`
        ///    (decision=nil) which can be locally repaired.
        ///    In contrast, if op 6's prepare header was written in step 3, it would be case `@I`,
        ///    which requires remote repair.
        ///
        /// During recovery, store the redundant (unvalidated) headers.
        headers_redundant: []align(constants.sector_size) Header,

        /// We copy-on-write to these buffers, as the in-memory headers may change while writing.
        /// The buffers belong to the IOP at the corresponding index in IOPS.
        headers_iops: *align(constants.sector_size) [constants.journal_iops_write_max][constants.sector_size]u8,

        /// A set bit indicates a chunk of redundant headers that no read has been issued to yet.
        header_chunks_requested: HeaderChunks = HeaderChunks.initFull(),
        /// A set bit indicates a chunk of redundant headers that has been recovered.
        header_chunks_recovered: HeaderChunks = HeaderChunks.initEmpty(),

        /// Statically allocated read IO operation context data.
        reads: IOPS(Read, constants.journal_iops_read_max) = .{},

        /// Statically allocated write IO operation context data.
        writes: IOPS(Write, constants.journal_iops_write_max) = .{},

        /// Whether an entry is in memory only and needs to be written or is being written:
        /// We use this in the same sense as a dirty bit in the kernel page cache.
        /// A dirty bit means that we have not prepared the entry, or need to repair a faulty entry.
        dirty: BitSet,

        /// Whether an entry was written to disk and this write was subsequently lost due to:
        /// * corruption,
        /// * a misdirected write (or a misdirected read, we do not distinguish), or else
        /// * a latent sector error, where the sector can no longer be read.
        /// A faulty bit means that we prepared and then lost the entry.
        /// A faulty bit requires the dirty bit to also be set so that callers need not check both.
        /// A faulty bit is used then only to qualify the severity of the dirty bit.
        faulty: BitSet,

        /// The checksum of the prepare in the corresponding slot.
        /// This is used to respond to `request_prepare` messages even when the slot is faulty.
        /// For example, the slot may be faulty because the redundant header is faulty.
        ///
        /// The checksum will missing (`prepare_checksums[i]=0`, `prepare_inhabited[i]=false`) when:
        /// * the message in the slot is reserved,
        /// * the message in the slot is being written, or when
        /// * the message in the slot is corrupt.
        // TODO: `prepare_checksums` and `prepare_inhabited` should be combined into a []?u128,
        // but that type is currently unusable (as of Zig 0.9.1).
        // See: https://github.com/ziglang/zig/issues/9871
        prepare_checksums: []u128,
        /// When prepare_inhabited[i]==false, prepare_checksums[i]==0.
        /// (`undefined` would may more sense than `0`, but `0` allows it to be asserted).
        prepare_inhabited: []bool,

        status: Status = .init,

        pub fn init(allocator: Allocator, storage: *Storage, replica: u8) !Journal {
            // TODO Fix this assertion:
            // assert(write_ahead_log_zone_size <= storage.size);

            var headers = try allocator.allocAdvanced(
                Header,
                constants.sector_size,
                slot_count,
                .exact,
            );
            errdefer allocator.free(headers);
            for (headers) |*header| header.* = undefined;

            var headers_redundant = try allocator.allocAdvanced(
                Header,
                constants.sector_size,
                slot_count,
                .exact,
            );
            errdefer allocator.free(headers_redundant);
            for (headers_redundant) |*header| header.* = undefined;

            var dirty = try BitSet.init_full(allocator, slot_count);
            errdefer dirty.deinit(allocator);

            var faulty = try BitSet.init_full(allocator, slot_count);
            errdefer faulty.deinit(allocator);

            var prepare_checksums = try allocator.alloc(u128, slot_count);
            errdefer allocator.free(prepare_checksums);
            std.mem.set(u128, prepare_checksums, 0);

            var prepare_inhabited = try allocator.alloc(bool, slot_count);
            errdefer allocator.free(prepare_inhabited);
            std.mem.set(bool, prepare_inhabited, false);

            const headers_iops = (try allocator.allocAdvanced(
                [constants.sector_size]u8,
                constants.sector_size,
                constants.journal_iops_write_max,
                .exact,
            ))[0..constants.journal_iops_write_max];
            errdefer allocator.free(headers_iops);

            log.debug("{}: slot_count={} size={} headers_size={} prepares_size={}", .{
                replica,
                slot_count,
                std.fmt.fmtIntSizeBin(write_ahead_log_zone_size),
                std.fmt.fmtIntSizeBin(headers_size),
                std.fmt.fmtIntSizeBin(prepares_size),
            });

            var journal = Journal{
                .storage = storage,
                .replica = replica,
                .headers = headers,
                .headers_redundant = headers_redundant,
                .dirty = dirty,
                .faulty = faulty,
                .prepare_checksums = prepare_checksums,
                .prepare_inhabited = prepare_inhabited,
                .headers_iops = headers_iops,
            };

            assert(@mod(@ptrToInt(&journal.headers[0]), constants.sector_size) == 0);
            assert(journal.dirty.bits.bit_length == slot_count);
            assert(journal.faulty.bits.bit_length == slot_count);
            assert(journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);
            assert(journal.prepare_checksums.len == slot_count);
            assert(journal.prepare_inhabited.len == slot_count);

            for (journal.headers) |*h| assert(!h.valid_checksum());
            for (journal.headers_redundant) |*h| assert(!h.valid_checksum());

            return journal;
        }

        pub fn deinit(journal: *Journal, allocator: Allocator) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);

            journal.dirty.deinit(allocator);
            journal.faulty.deinit(allocator);
            allocator.free(journal.headers);
            allocator.free(journal.headers_redundant);
            allocator.free(journal.headers_iops);
            allocator.free(journal.prepare_checksums);
            allocator.free(journal.prepare_inhabited);

            {
                var it = journal.reads.iterate();
                while (it.next()) |read| replica.message_bus.unref(read.message);
            }
            {
                var it = journal.writes.iterate();
                while (it.next()) |write| replica.message_bus.unref(write.message);
            }
        }

        /// Returns whether this is a fresh database WAL; no prepares (except the root) have ever
        /// been written. This determines whether a replica can transition immediately to normal
        /// status, or if it needs to run recovery protocol.
        ///
        /// Called by the replica immediately after WAL recovery completes, but before the replica
        /// issues any I/O from handling messages.
        pub fn is_empty(journal: *const Journal) bool {
            assert(journal.status == .recovered);
            assert(journal.writes.executing() == 0);

            if (!journal.headers[0].valid_checksum()) return false;
            if (journal.headers[0].operation != .root) return false;

            const replica = @fieldParentPtr(Replica, "journal", journal);
            assert(journal.headers[0].checksum == Header.root_prepare(replica.cluster).checksum);
            assert(journal.headers[0].checksum == journal.prepare_checksums[0]);
            assert(journal.prepare_inhabited[0]);

            // If any message is faulty, we must fall back to VSR recovery protocol (i.e. treat
            // this as a non-empty WAL) since that message may have been a prepare.
            if (journal.faulty.count > 0) return false;

            for (journal.headers[1..]) |*header| {
                if (header.command == .prepare) return false;
            }

            for (journal.prepare_inhabited[1..]) |inhabited| {
                if (inhabited) return false;
            }

            return true;
        }

        pub fn slot_for_op(_: *const Journal, op: u64) Slot {
            return Slot{ .index = op % slot_count };
        }

        pub fn slot_with_op(journal: *const Journal, op: u64) ?Slot {
            if (journal.header_with_op(op)) |_| {
                return journal.slot_for_op(op);
            } else {
                return null;
            }
        }

        pub fn slot_with_op_and_checksum(journal: *const Journal, op: u64, checksum: u128) ?Slot {
            if (journal.header_with_op_and_checksum(op, checksum)) |_| {
                return journal.slot_for_op(op);
            } else {
                return null;
            }
        }

        pub fn slot_for_header(journal: *const Journal, header: *const Header) Slot {
            assert(header.command == .prepare);
            return journal.slot_for_op(header.op);
        }

        pub fn slot_with_header(journal: *const Journal, header: *const Header) ?Slot {
            assert(header.command == .prepare);
            return journal.slot_with_op(header.op);
        }

        /// Returns any existing header at the location indicated by header.op.
        /// The existing header may have an older or newer op number.
        pub fn header_for_prepare(journal: *const Journal, header: *const Header) ?*const Header {
            assert(header.command == .prepare);
            return journal.header_for_op(header.op);
        }

        /// We use `op` directly to index into the headers array and locate ops without a scan.
        /// The existing header may have an older or newer op number.
        pub fn header_for_op(journal: *const Journal, op: u64) ?*const Header {
            const slot = journal.slot_for_op(op);
            const existing = &journal.headers[slot.index];
            switch (existing.command) {
                .prepare => {
                    assert(journal.slot_for_op(existing.op).index == slot.index);
                    return existing;
                },
                .reserved => {
                    assert(existing.op == slot.index);
                    return null;
                },
                else => unreachable,
            }
        }

        /// Returns the entry at `@mod(op)` location, but only if `entry.op == op`, else `null`.
        /// Be careful of using this without considering that there may still be an existing op.
        pub fn header_with_op(journal: *const Journal, op: u64) ?*const Header {
            if (journal.header_for_op(op)) |existing| {
                if (existing.op == op) return existing;
            }
            return null;
        }

        /// As per `header_with_op()`, but only if there is an optional checksum match.
        pub fn header_with_op_and_checksum(
            journal: *const Journal,
            op: u64,
            checksum: ?u128,
        ) ?*const Header {
            if (journal.header_with_op(op)) |existing| {
                assert(existing.op == op);
                if (checksum == null or existing.checksum == checksum.?) return existing;
            }
            return null;
        }

        pub fn previous_entry(journal: *const Journal, header: *const Header) ?*const Header {
            if (header.op == 0) {
                return null;
            } else {
                return journal.header_for_op(header.op - 1);
            }
        }

        pub fn next_entry(journal: *const Journal, header: *const Header) ?*const Header {
            return journal.header_for_op(header.op + 1);
        }

        /// Returns the highest op number prepared, in any slot without reference to the checkpoint.
        pub fn op_maximum(journal: *const Journal) u64 {
            assert(journal.status == .recovered);

            var op: u64 = 0;
            for (journal.headers) |*header| {
                if (header.command == .prepare) {
                    if (header.op > op) op = header.op;
                } else {
                    assert(header.command == .reserved);
                }
            }
            return op;
        }

        /// Returns the highest op number prepared, as per `header_ok()` in the untrusted headers.
        fn op_maximum_headers_untrusted(cluster: u32, headers_untrusted: []const Header) u64 {
            var op: u64 = 0;
            for (headers_untrusted) |*header_untrusted, slot_index| {
                const slot = Slot{ .index = slot_index };
                if (header_ok(cluster, slot, header_untrusted)) |header| {
                    if (header.command == .prepare) {
                        if (header.op > op) op = header.op;
                    } else {
                        assert(header.command == .reserved);
                    }
                }
            }
            return op;
        }

        pub fn has(journal: *const Journal, header: *const Header) bool {
            assert(journal.status == .recovered);
            assert(header.command == .prepare);

            const slot = journal.slot_for_op(header.op);
            const existing = &journal.headers[slot.index];
            if (existing.command == .reserved) {
                return false;
            } else {
                if (existing.checksum == header.checksum) {
                    assert(existing.checksum_body == header.checksum_body);
                    assert(existing.op == header.op);
                    return true;
                } else {
                    return false;
                }
            }
        }

        pub fn has_clean(journal: *const Journal, header: *const Header) bool {
            if (journal.slot_with_op_and_checksum(header.op, header.checksum)) |slot| {
                if (!journal.dirty.bit(slot)) {
                    assert(journal.prepare_inhabited[slot.index]);
                    assert(journal.prepare_checksums[slot.index] == header.checksum);
                    return true;
                }
            }
            return false;
        }

        pub fn has_dirty(journal: *const Journal, header: *const Header) bool {
            return journal.has(header) and journal.dirty.bit(journal.slot_with_header(header).?);
        }

        /// Copies latest headers between `op_min` and `op_max` (both inclusive) as fit in `dest`.
        /// Reverses the order when copying so that latest headers are copied first, which protects
        /// against the callsite slicing the buffer the wrong way and incorrectly, and which is
        /// required by message handlers that use the hash chain for repairs.
        /// Skips .reserved headers (gaps between headers).
        /// Zeroes the `dest` buffer in case the copy would underflow and leave a buffer bleed.
        /// Returns the number of headers actually copied.
        pub fn copy_latest_headers_between(
            journal: *const Journal,
            op_min: u64,
            op_max: u64,
            dest: []Header,
        ) usize {
            assert(journal.status == .recovered);
            assert(op_min <= op_max);
            assert(dest.len > 0);

            var copied: usize = 0;
            // Poison all slots; only slots less than `copied` are used.
            std.mem.set(Header, dest, undefined);

            // Start at op_max + 1 and do the decrement upfront to avoid overflow when op_min == 0:
            var op = op_max + 1;
            while (op > op_min) {
                op -= 1;

                if (journal.header_with_op(op)) |header| {
                    dest[copied] = header.*;
                    assert(dest[copied].invalid() == null);
                    copied += 1;
                    if (copied == dest.len) break;
                }
            }

            log.debug(
                "{}: copy_latest_headers_between: op_min={} op_max={} dest.len={} copied={}",
                .{
                    journal.replica,
                    op_min,
                    op_max,
                    dest.len,
                    copied,
                },
            );

            return copied;
        }

        const HeaderRange = struct { op_min: u64, op_max: u64 };

        /// Finds the latest break in headers between `op_min` and `op_max` (both inclusive).
        /// A break is a missing header or a header not connected to the next header by hash chain.
        /// On finding the highest break, extends the range downwards to cover as much as possible.
        /// We expect that `op_min` and `op_max` (`replica.commit_min` and `replica.op`) must exist.
        /// A range will never include `op_min` because this is already committed.
        /// A range will never include `op_max` because this must be up to date as the latest op.
        /// We must therefore first resolve any op uncertainty so that we can trust `op_max` here.
        ///
        /// For example: If ops 3, 9 and 10 are missing, returns: `{ .op_min = 9, .op_max = 10 }`.
        ///
        /// Another example: If op 17 is disconnected from op 18, 16 is connected to 17, and 12-15
        /// are missing, returns: `{ .op_min = 12, .op_max = 17 }`.
        pub fn find_latest_headers_break_between(
            journal: *const Journal,
            op_min: u64,
            op_max: u64,
        ) ?HeaderRange {
            assert(op_max >= op_min);
            assert(op_max - op_min + 1 <= slot_count);
            var range: ?HeaderRange = null;

            // We set B, the op after op_max, to null because we only examine breaks < op_max:
            var B: ?*const Header = null;

            var op = op_max + 1;
            while (op > op_min) {
                op -= 1;

                // Get the entry at @mod(op) location, but only if entry.op == op, else null:
                var A = journal.header_with_op(op);
                if (A) |a| {
                    if (B) |b| {
                        // If A was reordered then A may have a newer op than B (but an older view).
                        // However, here we use header_with_op() to assert a.op + 1 == b.op:
                        assert(a.op + 1 == b.op);

                        // We do not assert a.view <= b.view here unless the chain is intact because
                        // repair_header() may put a newer view to the left of an older view.

                        // A exists and B exists:
                        if (range) |*r| {
                            assert(b.op == r.op_min);
                            if (a.op == op_min) {
                                // A is committed, because we pass `commit_min` as `op_min`:
                                // Do not add A to range because A cannot be a break if committed.
                                break;
                            } else if (a.checksum == b.parent) {
                                // A is connected to B, but B is disconnected, add A to range:
                                assert(a.view <= b.view);
                                assert(a.op > op_min);
                                r.op_min = a.op;
                            } else if (a.view < b.view) {
                                // A is not connected to B, and A is older than B, add A to range:
                                r.op_min = a.op;
                            } else if (a.view > b.view) {
                                // A is not connected to B, but A is newer than B, close range:
                                break;
                            } else {
                                // Op numbers in the same view must be connected.
                                unreachable;
                            }
                        } else if (a.checksum == b.parent) {
                            // A is connected to B, and B is connected or B is op_max.
                            assert(a.view <= b.view);
                        } else if (a.view != b.view) {
                            // A is not connected to B, open range:
                            assert(a.op > op_min);
                            assert(b.op <= op_max);
                            range = .{ .op_min = a.op, .op_max = a.op };
                        } else {
                            // Op numbers in the same view must be connected.
                            unreachable;
                        }
                    } else {
                        // A exists and B does not exist (or B has a older/newer op number):
                        if (range) |r| {
                            // We cannot compare A to B, A may be older/newer, close range:
                            assert(r.op_min == op + 1);
                            break;
                        } else {
                            // We expect a range if B does not exist, unless:
                            assert(a.op == op_max);
                        }
                    }
                } else {
                    assert(op > op_min);
                    assert(op < op_max);

                    // A does not exist, or A has an older (or newer if reordered) op number:
                    if (range) |*r| {
                        // Add A to range:
                        assert(r.op_min == op + 1);
                        r.op_min = op;
                    } else {
                        // Open range:
                        assert(B != null);
                        range = .{ .op_min = op, .op_max = op };
                    }
                }

                B = A;
            }

            if (range) |r| {
                // We can never repair op_min (replica.commit_min) since that is already committed:
                assert(r.op_min > op_min);
                // We can never repair op_max (replica.op) since that is the latest op:
                // We can assume this because any existing view jump barrier must first be resolved.
                assert(r.op_max < op_max);
            }

            return range;
        }

        /// Read a prepare from disk. There must be a matching in-memory header.
        pub fn read_prepare(
            journal: *Journal,
            callback: fn (replica: *Replica, prepare: ?*Message, destination_replica: ?u8) void,
            op: u64,
            checksum: u128,
            destination_replica: ?u8,
        ) void {
            assert(journal.status == .recovered);
            assert(checksum != 0);

            const replica = @fieldParentPtr(Replica, "journal", journal);
            if (op > replica.op) {
                journal.read_prepare_log(op, checksum, "beyond replica.op");
                callback(replica, null, null);
                return;
            }

            const slot = journal.slot_with_op_and_checksum(op, checksum) orelse {
                journal.read_prepare_log(op, checksum, "no entry exactly");
                callback(replica, null, null);
                return;
            };

            if (journal.prepare_inhabited[slot.index] and
                journal.prepare_checksums[slot.index] == checksum)
            {
                journal.read_prepare_with_op_and_checksum(callback, op, checksum, destination_replica);
            } else {
                journal.read_prepare_log(op, checksum, "no matching prepare");
                callback(replica, null, null);
            }
        }

        /// Read a prepare from disk. There may or may not be an in-memory header.
        pub fn read_prepare_with_op_and_checksum(
            journal: *Journal,
            callback: fn (replica: *Replica, prepare: ?*Message, destination_replica: ?u8) void,
            op: u64,
            checksum: u128,
            destination_replica: ?u8,
        ) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);
            const slot = journal.slot_for_op(op);
            assert(journal.status == .recovered);
            assert(journal.prepare_inhabited[slot.index]);
            assert(journal.prepare_checksums[slot.index] == checksum);

            const message = replica.message_bus.get_message();
            defer replica.message_bus.unref(message);

            var message_size: usize = constants.message_size_max;

            // If the header is in-memory, we can skip the read from the disk.
            if (journal.header_with_op_and_checksum(op, checksum)) |exact| {
                if (exact.size == @sizeOf(Header)) {
                    message.header.* = exact.*;
                    // Normally the message's padding would have been zeroed by the MessageBus,
                    // but we are copying (only) a message header into a new buffer.
                    std.mem.set(u8, message.buffer[@sizeOf(Header)..constants.sector_size], 0);
                    callback(replica, message, destination_replica);
                    return;
                } else {
                    // As an optimization, we can read fewer than `message_size_max` bytes because
                    // we know the message's exact size.
                    message_size = vsr.sector_ceil(exact.size);
                    assert(message_size <= constants.message_size_max);
                }
            }

            const read = journal.reads.acquire() orelse {
                journal.read_prepare_log(op, checksum, "waiting for IOP");
                callback(replica, null, null);
                return;
            };

            read.* = .{
                .journal = journal,
                .completion = undefined,
                .message = message.ref(),
                .callback = callback,
                .op = op,
                .checksum = checksum,
                .destination_replica = destination_replica,
            };

            const buffer: []u8 = message.buffer[0..message_size];

            // Memory must not be owned by `journal.headers` as these may be modified concurrently:
            assert(@ptrToInt(buffer.ptr) < @ptrToInt(journal.headers.ptr) or
                @ptrToInt(buffer.ptr) > @ptrToInt(journal.headers.ptr) + headers_size);

            journal.storage.read_sectors(
                read_prepare_with_op_and_checksum_callback,
                &read.completion,
                buffer,
                .wal_prepares,
                Ring.prepares.offset(slot),
            );
        }

        fn read_prepare_with_op_and_checksum_callback(completion: *Storage.Read) void {
            const read = @fieldParentPtr(Journal.Read, "completion", completion);
            const journal = read.journal;
            const replica = @fieldParentPtr(Replica, "journal", journal);
            const op = read.op;
            const checksum = read.checksum;
            assert(journal.status == .recovered);

            defer {
                replica.message_bus.unref(read.message);
                journal.reads.release(read);
            }

            if (op > replica.op) {
                journal.read_prepare_log(op, checksum, "beyond replica.op");
                read.callback(replica, null, null);
                return;
            }

            const checksum_inhabited = journal.prepare_inhabited[journal.slot_for_op(op).index];
            const checksum_match = journal.prepare_checksums[journal.slot_for_op(op).index] == checksum;
            if (!checksum_inhabited or !checksum_match) {
                journal.read_prepare_log(op, checksum, "prepare changed during read");
                read.callback(replica, null, null);
                return;
            }

            // Check that the `headers` slot belongs to the same op that it did when the read began.
            // The slot may not match the Read's op/checksum due to either:
            // * The in-memory header changed since the read began.
            // * The in-memory header is reserved+faulty; the read was via `prepare_checksums`
            const slot = journal.slot_with_op_and_checksum(op, checksum);

            if (!read.message.header.valid_checksum()) {
                if (slot) |s| {
                    journal.faulty.set(s);
                    journal.dirty.set(s);
                }

                journal.read_prepare_log(op, checksum, "corrupt header after read");
                read.callback(replica, null, null);
                return;
            }
            assert(read.message.header.invalid() == null);

            if (read.message.header.cluster != replica.cluster) {
                // This could be caused by a misdirected read or write.
                // Though when a prepare spans multiple sectors, a misdirected read/write will
                // likely manifest as a checksum failure instead.
                if (slot) |s| {
                    journal.faulty.set(s);
                    journal.dirty.set(s);
                }

                journal.read_prepare_log(op, checksum, "wrong cluster");
                read.callback(replica, null, null);
                return;
            }

            if (read.message.header.op != op) {
                // Possible causes:
                // * The prepare was rewritten since the read began.
                // * Misdirected read/write.
                // * The combination of:
                //   * The primary is responding to a `request_prepare`.
                //   * The `request_prepare` did not include a checksum.
                //   * The requested op's slot is faulty, but the prepare is valid. Since the
                //     prepare is valid, WAL recovery set `prepare_checksums[slot]`. But on reading
                //     this entry it turns out not to have the right op.
                //   (This case (and the accompanying unnessary read) could be prevented by storing
                //   the op along with the checksum in `prepare_checksums`.)
                assert(slot == null);

                journal.read_prepare_log(op, checksum, "op changed during read");
                read.callback(replica, null, null);
                return;
            }

            if (read.message.header.checksum != checksum) {
                // This can also be caused by a misdirected read/write.
                assert(slot == null);

                journal.read_prepare_log(op, checksum, "checksum changed during read");
                read.callback(replica, null, null);
                return;
            }

            if (!read.message.header.valid_checksum_body(read.message.body())) {
                if (slot) |s| {
                    journal.faulty.set(s);
                    journal.dirty.set(s);
                }

                journal.read_prepare_log(op, checksum, "corrupt body after read");
                read.callback(replica, null, null);
                return;
            }

            read.callback(replica, read.message, read.destination_replica);
        }

        fn read_prepare_log(journal: *Journal, op: u64, checksum: ?u128, notice: []const u8) void {
            log.info(
                "{}: read_prepare: op={} checksum={}: {s}",
                .{ journal.replica, op, checksum, notice },
            );
        }

        pub fn recover(journal: *Journal, callback: fn (journal: *Journal) void) void {
            assert(journal.status == .init);
            assert(journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);
            assert(journal.reads.executing() == 0);
            assert(journal.writes.executing() == 0);
            assert(journal.header_chunks_requested.count() == HeaderChunks.bit_length);
            assert(journal.header_chunks_recovered.count() == 0);

            journal.status = .{ .recovering = callback };
            log.debug("{}: recover: recovering", .{journal.replica});

            var available: usize = journal.reads.available();
            while (available > 0) : (available -= 1) journal.recover_headers();

            assert(journal.header_chunks_recovered.count() == 0);
            assert(journal.header_chunks_requested.count() ==
                HeaderChunks.bit_length - journal.reads.executing());
        }

        fn recover_headers(journal: *Journal) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);
            assert(journal.status == .recovering);
            assert(journal.reads.available() > 0);

            if (journal.header_chunks_recovered.count() == HeaderChunks.bit_length) {
                assert(journal.header_chunks_requested.count() == 0);
                log.debug("{}: recover_headers: complete", .{journal.replica});
                journal.recover_prepares();
                return;
            }

            const chunk_index = journal.header_chunks_requested.findFirstSet() orelse return;
            assert(!journal.header_chunks_recovered.isSet(chunk_index));

            const message = replica.message_bus.get_message();
            defer replica.message_bus.unref(message);

            const chunk_read = journal.reads.acquire() orelse unreachable;
            chunk_read.* = .{
                .journal = journal,
                .completion = undefined,
                .message = message.ref(),
                .callback = undefined,
                .op = chunk_index,
                .checksum = undefined,
                .destination_replica = null,
            };

            const offset = constants.message_size_max * chunk_index;
            assert(offset < headers_size);

            const buffer = recover_headers_buffer(message, offset);
            assert(buffer.len > 0);
            assert(buffer.len <= constants.message_size_max);
            assert(buffer.len + offset <= headers_size);

            log.debug("{}: recover_headers: offset={} size={} recovering", .{
                journal.replica,
                offset,
                buffer.len,
            });

            journal.header_chunks_requested.unset(chunk_index);
            journal.storage.read_sectors(
                recover_headers_callback,
                &chunk_read.completion,
                buffer,
                .wal_headers,
                offset,
            );
        }

        fn recover_headers_callback(completion: *Storage.Read) void {
            const chunk_read = @fieldParentPtr(Journal.Read, "completion", completion);
            const journal = chunk_read.journal;
            const replica = @fieldParentPtr(Replica, "journal", journal);
            assert(journal.status == .recovering);
            assert(chunk_read.destination_replica == null);

            const chunk_index = chunk_read.op;
            assert(!journal.header_chunks_requested.isSet(chunk_index));
            assert(!journal.header_chunks_recovered.isSet(chunk_index));

            const chunk_buffer = recover_headers_buffer(
                chunk_read.message,
                chunk_index * constants.message_size_max,
            );
            assert(chunk_buffer.len >= @sizeOf(Header));
            assert(chunk_buffer.len % @sizeOf(Header) == 0);

            log.debug("{}: recover_headers: offset={} size={} recovered", .{
                journal.replica,
                chunk_index * constants.message_size_max,
                chunk_buffer.len,
            });

            // Directly store all the redundant headers in `journal.headers_redundant` (including any
            // that are invalid or corrupt). As the prepares are recovered, these will be replaced
            // or removed as necessary.
            const chunk_headers = std.mem.bytesAsSlice(Header, chunk_buffer);
            util.copy_disjoint(
                .exact,
                Header,
                journal.headers_redundant[chunk_index * headers_per_message ..][0..chunk_headers.len],
                chunk_headers,
            );

            // We must release before we call `recover_headers()` in case Storage is synchronous.
            // Otherwise, we would run out of messages and reads.
            replica.message_bus.unref(chunk_read.message);
            journal.reads.release(chunk_read);

            journal.header_chunks_recovered.set(chunk_index);
            journal.recover_headers();
        }

        fn recover_headers_buffer(message: *Message, offset: u64) []align(@alignOf(Header)) u8 {
            const max = std.math.min(constants.message_size_max, headers_size - offset);
            assert(max % constants.sector_size == 0);
            assert(max % @sizeOf(Header) == 0);
            return message.buffer[0..max];
        }

        /// Recover the prepares ring. Reads are issued concurrently.
        /// - `dirty` is initially full.
        ///   Bits are cleared when a read is issued to the slot.
        ///   All bits are set again before recover_slots() is called.
        /// - `faulty` is initially full.
        ///   Bits are cleared when the slot's read finishes.
        ///   All bits are set again before recover_slots() is called.
        /// - The prepare's headers are loaded into `journal.headers`.
        fn recover_prepares(journal: *Journal) void {
            assert(journal.status == .recovering);
            assert(journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);
            assert(journal.reads.executing() == 0);
            assert(journal.writes.executing() == 0);

            var available: usize = journal.reads.available();
            while (available > 0) : (available -= 1) journal.recover_prepare();

            assert(journal.writes.executing() == 0);
            assert(journal.reads.executing() > 0);
            assert(journal.reads.executing() + journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);
        }

        fn recover_prepare(journal: *Journal) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);
            assert(journal.status == .recovering);
            assert(journal.reads.available() > 0);
            assert(journal.dirty.count <= journal.faulty.count);

            if (journal.faulty.count == 0) {
                for (journal.headers) |_, index| journal.dirty.set(Slot{ .index = index });
                for (journal.headers) |_, index| journal.faulty.set(Slot{ .index = index });
                return journal.recover_slots();
            }

            const slot_index = journal.dirty.bits.findFirstSet() orelse return;
            const slot = Slot{ .index = slot_index };
            const message = replica.message_bus.get_message();
            defer replica.message_bus.unref(message);

            const read = journal.reads.acquire() orelse unreachable;
            read.* = .{
                .journal = journal,
                .completion = undefined,
                .message = message.ref(),
                .callback = undefined,
                .op = slot.index,
                .checksum = undefined,
                .destination_replica = null,
            };

            log.debug("{}: recover_prepare: recovering slot={}", .{
                journal.replica,
                slot.index,
            });

            journal.dirty.clear(slot);
            journal.storage.read_sectors(
                recover_prepare_callback,
                &read.completion,
                // We load the entire message to verify that it isn't torn or corrupt.
                // We don't know the message's size, so use the entire buffer.
                message.buffer[0..constants.message_size_max],
                .wal_prepares,
                Ring.prepares.offset(slot),
            );
        }

        fn recover_prepare_callback(completion: *Storage.Read) void {
            const read = @fieldParentPtr(Journal.Read, "completion", completion);
            const journal = read.journal;
            const replica = @fieldParentPtr(Replica, "journal", journal);

            assert(journal.status == .recovering);
            assert(journal.dirty.count <= journal.faulty.count);
            assert(read.destination_replica == null);

            const slot = Slot{ .index = @intCast(u64, read.op) };
            assert(slot.index < slot_count);
            assert(!journal.dirty.bit(slot));
            assert(journal.faulty.bit(slot));

            // Check `valid_checksum_body` here rather than in `recover_done` so that we don't need
            // to hold onto the whole message (just the header).
            if (read.message.header.valid_checksum() and
                read.message.header.valid_checksum_body(read.message.body()))
            {
                journal.headers[slot.index] = read.message.header.*;
            }

            replica.message_bus.unref(read.message);
            journal.reads.release(read);

            journal.faulty.clear(slot);
            journal.recover_prepare();
        }

        /// When in doubt about whether a particular message was received, it must be marked as
        /// faulty to avoid nacking a prepare which was received then lost/misdirected/corrupted.
        ///
        ///
        /// There are two special cases where faulty slots must be carefully handled:
        ///
        /// A) Redundant headers are written in batches. Slots that are marked faulty are written
        /// as invalid (zeroed). This ensures that if the replica crashes and recovers, the
        /// entries are still faulty rather than reserved.
        /// The recovery process must be conservative about which headers are stored in
        /// `journal.headers`. To understand why this is important, consider what happens if it did
        /// load the faulty header into `journal.headers`, and then reads it back after a restart:
        ///
        /// 1. Suppose slot 8 is in case @D. Per the table below, mark slot 8 faulty.
        /// 2. Suppose slot 9 is also loaded as faulty.
        /// 3. Journal recovery finishes. The replica beings to repair its missing/broken messages.
        /// 4. VSR recovery protocol fetches the true prepare for slot 9.
        /// 5. The message from step 4 is written to slot 9 of the prepares.
        /// 6. The header from step 4 is written to slot 9 of the redundant headers.
        ///    But writes to the redundant headers are done in batches of `headers_per_sector`!
        ///    So if step 1 loaded slot 8's prepare header into `journal.headers`, slot 8's
        ///    redundant header would be updated at the same time (in the same write) as slot 9.
        /// 7! Immediately after step 6's write finishes, suppose the replica crashes (e.g. due to
        ///    power failure.
        /// 8! Journal recovery again — but now slot 8 is loaded *without* being marked faulty.
        ///    So we may incorrectly nack slot 8's message.
        ///
        /// Therefore, recovery will never load a header into a slot *and* mark that slot faulty.
        ///
        ///
        /// B) When replica_count=1, repairing broken/lost prepares over VSR is not an option,
        /// so if a message is faulty the replica will abort.
        ///
        ///
        /// Recovery decision table:
        ///
        ///   label                   @A  @B  @C  @D  @E  @F  @G  @H  @I  @J  @K  @L  @M  @N
        ///   header valid             0   1   1   0   0   0   1   1   1   1   1   1   1   1
        ///   header reserved          _   1   0   _   _   _   1   1   0   1   0   0   0   0
        ///   prepare valid            0   0   0   1   1   1   1   1   1   1   1   1   1   1
        ///   prepare reserved         _   _   _   1   0   0   0   0   1   1   0   0   0   0
        ///   prepare.op is maximum    _   _   _   _   0   1   0   1   _   _   _   _   _   _
        ///   match checksum           _   _   _   _   _   _   _   _   _  !1   0   0   0   1
        ///   match op                 _   _   _   _   _   _   _   _   _  !1   <   >   1  !1
        ///   match view               _   _   _   _   _   _   _   _   _  !1   _   _  !0  !1
        ///   decision (replicas>1)  vsr vsr vsr vsr vsr fix vsr fix vsr nil fix vsr vsr eql
        ///   decision (replicas=1)              fix fix     fix
        ///
        /// Legend:
        ///
        ///    0  false
        ///    1  true
        ///   !0  assert false
        ///   !1  assert true
        ///    _  ignore
        ///    <  header.op < prepare.op
        ///    >  header.op > prepare.op
        ///  eql  The header and prepare are identical; no repair necessary.
        ///  nil  Reserved; dirty/faulty are clear, no repair necessary.
        ///  fix  When replicas=1, use intact prepare. When replicas>1, use VSR `request_prepare`.
        ///  vsr  Repair with VSR `request_prepare`.
        ///
        /// A "valid" header/prepare:
        /// 1. has a valid checksum
        /// 2. has the correct cluster
        /// 3. is in the correct slot (op % slot_count)
        /// 4. has command=reserved or command=prepare
        fn recover_slots(journal: *Journal) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);

            assert(journal.status == .recovering);
            assert(journal.reads.executing() == 0);
            assert(journal.writes.executing() == 0);
            assert(journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);

            const prepare_op_max = std.math.max(
                replica.op_checkpoint,
                op_maximum_headers_untrusted(replica.cluster, journal.headers),
            );

            var cases: [slot_count]*const Case = undefined;

            for (journal.headers) |_, index| {
                const slot = Slot{ .index = index };
                const header = header_ok(replica.cluster, slot, &journal.headers_redundant[index]);
                const prepare = header_ok(replica.cluster, slot, &journal.headers[index]);

                cases[index] = recovery_case(header, prepare, prepare_op_max);

                // `prepare_checksums` improves the availability of `request_prepare` by being more
                // flexible than `headers` regarding the prepares it references. It may hold a
                // prepare whose redundant header is broken, as long as the prepare itjournal is valid.
                if (prepare != null and prepare.?.command == .prepare) {
                    assert(!journal.prepare_inhabited[index]);
                    journal.prepare_inhabited[index] = true;
                    journal.prepare_checksums[index] = prepare.?.checksum;
                }
            }
            assert(journal.headers.len == cases.len);

            // Refine cases @B and @C: Repair (truncate) a prepare if it was torn during a crash.
            if (journal.recover_torn_prepare(&cases)) |torn_slot| {
                assert(cases[torn_slot.index].decision(replica.replica_count) == .vsr);
                cases[torn_slot.index] = &case_cut;

                log.warn("{}: recover_slots: torn prepare in slot={}", .{
                    journal.replica,
                    torn_slot.index,
                });
            }

            for (cases) |case, index| journal.recover_slot(Slot{ .index = index }, case);
            assert(cases.len == slot_count);

            util.copy_disjoint(.exact, Header, journal.headers_redundant, journal.headers);

            log.debug("{}: recover_slots: dirty={} faulty={}", .{
                journal.replica,
                journal.dirty.count,
                journal.faulty.count,
            });

            journal.recover_fix();
        }

        /// Returns a slot that is safe to truncate.
        //
        /// Truncate any prepare that was torn while being appended to the log before a crash, when:
        /// * the maximum valid op is the same in the prepare headers and redundant headers,
        /// * in the slot following the maximum valid op:
        ///   - the redundant header is valid,
        ///   - the redundant header is reserved, and/or the op is at least a log cycle behind,
        ///   - the prepare is corrupt, and
        /// * there are no faults except for those between `op_checkpoint` and `op_max + 1`,
        ///   so that we can be sure that the maximum valid op is in fact the maximum.
        fn recover_torn_prepare(journal: *const Journal, cases: []const *const Case) ?Slot {
            const replica = @fieldParentPtr(Replica, "journal", journal);

            assert(journal.status == .recovering);
            assert(journal.dirty.count == slot_count);
            assert(journal.faulty.count == slot_count);

            const op_max = op_maximum_headers_untrusted(replica.cluster, journal.headers_redundant);
            if (op_max != op_maximum_headers_untrusted(replica.cluster, journal.headers)) return null;
            if (op_max < replica.op_checkpoint) return null;
            // We can't assume that the header at `op_max` is a prepare — an empty journal with a
            // corrupt root prepare (op_max=0) will be repaired later.

            const torn_op = op_max + 1;
            const torn_slot = journal.slot_for_op(torn_op);

            const torn_prepare_untrusted = &journal.headers[torn_slot.index];
            if (torn_prepare_untrusted.valid_checksum()) return null;
            // The prepare is at least corrupt, possibly torn, but not valid and simply misdirected.

            const header_untrusted = &journal.headers_redundant[torn_slot.index];
            const header = header_ok(replica.cluster, torn_slot, header_untrusted) orelse return null;
            // The redundant header is valid, also for the correct cluster and not misdirected.

            if (header.command == .prepare) {
                // The redundant header was already written, so the prepare is corrupt, not torn.
                if (header.op == torn_op) return null;

                assert(header.op < torn_op); // Since torn_op > op_max.
                // The redundant header is from any previous log cycle.
            } else {
                assert(header.command == .reserved);

                // This is the first log cycle.

                // TODO Can we be more sure about this? What if op_max is clearly many cycles ahead?
                // Any previous log cycle is then expected to have a prepare, not a reserved header,
                // unless the prepare header was lost, in which case this slot may also not be torn.
            }

            const checkpoint_index = journal.slot_for_op(replica.op_checkpoint).index;
            const known_range = SlotRange{
                .head = Slot{ .index = checkpoint_index },
                .tail = torn_slot,
            };

            // We must be certain that the torn prepare really was being appended to the WAL.
            // Return null if any faults do not lie between the checkpoint and the torn prepare,
            // such as:
            //
            //   (fault  [checkpoint..........torn]        fault)
            //   (...torn]    fault     fault  [checkpoint......)
            //
            // When there is a fault between the checkpoint and the torn prepare, we cannot be
            // certain if the prepare was truly torn (safe to truncate) or corrupted (not safe to
            // truncate).
            //
            // When the checkpoint and torn op are in the same slot, then we can only be certain
            // if there are no faults other than the torn op itjournal.
            for (cases) |case, index| {
                // Do not use `faulty.bit()` because the decisions have not been processed yet.
                if (case.decision(replica.replica_count) == .vsr) {
                    if (checkpoint_index == torn_slot.index) {
                        assert(op_max >= replica.op_checkpoint);
                        assert(torn_op > replica.op_checkpoint);
                        if (index != torn_slot.index) return null;
                    } else {
                        if (!known_range.contains(Slot{ .index = index })) return null;
                    }
                }
            }

            // The prepare is torn.
            assert(!journal.prepare_inhabited[torn_slot.index]);
            assert(!torn_prepare_untrusted.valid_checksum());
            assert(cases[torn_slot.index].decision(replica.replica_count) == .vsr);
            return torn_slot;
        }

        fn recover_slot(journal: *Journal, slot: Slot, case: *const Case) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);
            const cluster = replica.cluster;

            assert(journal.status == .recovering);
            assert(journal.dirty.bit(slot));
            assert(journal.faulty.bit(slot));

            const header = header_ok(cluster, slot, &journal.headers_redundant[slot.index]);
            const prepare = header_ok(cluster, slot, &journal.headers[slot.index]);
            const decision = case.decision(replica.replica_count);
            switch (decision) {
                .eql => {
                    assert(header.?.command == .prepare);
                    assert(prepare.?.command == .prepare);
                    assert(header.?.checksum == prepare.?.checksum);
                    assert(journal.prepare_inhabited[slot.index]);
                    assert(journal.prepare_checksums[slot.index] == prepare.?.checksum);
                    journal.headers[slot.index] = header.?.*;
                    journal.dirty.clear(slot);
                    journal.faulty.clear(slot);
                },
                .nil => {
                    assert(header.?.command == .reserved);
                    assert(prepare.?.command == .reserved);
                    assert(header.?.checksum == prepare.?.checksum);
                    assert(header.?.checksum == Header.reserved(cluster, slot.index).checksum);
                    assert(!journal.prepare_inhabited[slot.index]);
                    assert(journal.prepare_checksums[slot.index] == 0);
                    journal.headers[slot.index] = header.?.*;
                    journal.dirty.clear(slot);
                    journal.faulty.clear(slot);
                },
                .fix => {
                    journal.headers[slot.index] = prepare.?.*;
                    journal.faulty.clear(slot);
                    assert(journal.dirty.bit(slot));
                    if (replica.replica_count == 1) {
                        // @D, @E, @F, @G, @H, @K
                    } else {
                        assert(prepare.?.command == .prepare);
                        assert(journal.prepare_inhabited[slot.index]);
                        assert(journal.prepare_checksums[slot.index] == prepare.?.checksum);
                        // @F, @H, @K
                    }
                },
                .vsr => {
                    journal.headers[slot.index] = Header.reserved(cluster, slot.index);
                    assert(journal.dirty.bit(slot));
                    assert(journal.faulty.bit(slot));
                },
                .cut => {
                    assert(header != null);
                    assert(prepare == null);
                    assert(!journal.prepare_inhabited[slot.index]);
                    assert(journal.prepare_checksums[slot.index] == 0);
                    journal.headers[slot.index] = Header.reserved(cluster, slot.index);
                    journal.dirty.clear(slot);
                    journal.faulty.clear(slot);
                },
            }

            switch (decision) {
                .eql, .nil => {
                    log.debug("{}: recover_slot: recovered slot={} label={s} decision={s}", .{
                        journal.replica,
                        slot.index,
                        case.label,
                        @tagName(decision),
                    });
                },
                .fix, .vsr, .cut => {
                    log.warn("{}: recover_slot: recovered slot={} label={s} decision={s}", .{
                        journal.replica,
                        slot.index,
                        case.label,
                        @tagName(decision),
                    });
                },
            }
        }

        /// Repair the redundant headers for slots with decision=fix, one sector at a time.
        fn recover_fix(journal: *Journal) void {
            assert(journal.status == .recovering);
            assert(journal.writes.executing() == 0);
            assert(journal.dirty.count >= journal.faulty.count);
            assert(journal.dirty.count <= slot_count);

            var fix_sector: ?usize = null;
            var dirty_iterator = journal.dirty.bits.iterator(.{ .kind = .set });
            while (dirty_iterator.next()) |dirty_slot| {
                if (journal.faulty.bit(Slot{ .index = dirty_slot })) continue;

                const dirty_slot_sector = @divFloor(dirty_slot, headers_per_sector);
                if (fix_sector) |fix_sector_| {
                    if (fix_sector_ != dirty_slot_sector) break;
                } else {
                    fix_sector = dirty_slot_sector;
                }
                journal.dirty.clear(Slot{ .index = dirty_slot });
            }

            if (fix_sector == null) return journal.recover_done();

            const write = journal.writes.acquire().?;
            write.* = .{
                .journal = journal,
                .callback = undefined,
                .message = undefined,
                .trigger = .fix,
                .range = undefined,
            };

            const buffer: []u8 = journal.header_sector(fix_sector.?, write);
            const buffer_headers = std.mem.bytesAsSlice(Header, buffer);
            assert(buffer_headers.len == headers_per_sector);

            const offset = Ring.headers.offset(Slot{ .index = fix_sector.? * headers_per_sector });
            journal.write_sectors(recover_fix_callback, write, buffer, .headers, offset);
        }

        fn recover_fix_callback(write: *Journal.Write) void {
            const journal = write.journal;
            assert(journal.status == .recovering);
            assert(write.trigger == .fix);

            journal.writes.release(write);
            journal.recover_fix();
        }

        fn recover_done(journal: *Journal) void {
            assert(journal.status == .recovering);
            assert(journal.reads.executing() == 0);
            assert(journal.writes.executing() == 0);
            assert(journal.dirty.count <= slot_count);
            assert(journal.faulty.count <= slot_count);
            assert(journal.faulty.count == journal.dirty.count);
            assert(journal.header_chunks_requested.count() == 0);
            assert(journal.header_chunks_recovered.count() == HeaderChunks.bit_length);

            const replica = @fieldParentPtr(Replica, "journal", journal);
            const callback = journal.status.recovering;
            journal.status = .recovered;

            // Abort if all slots are faulty, since something is very wrong.
            if (journal.faulty.count == slot_count) @panic("WAL is completely corrupt");
            if (journal.faulty.count > 0 and replica.replica_count == 1) @panic("WAL is corrupt");

            if (journal.headers[0].op == 0 and journal.headers[0].command == .prepare) {
                assert(journal.headers[0].checksum == Header.root_prepare(replica.cluster).checksum);
                assert(!journal.faulty.bit(Slot{ .index = 0 }));
            }

            for (journal.headers) |*header, index| {
                assert(header.valid_checksum());
                assert(header.cluster == replica.cluster);
                assert(std.meta.eql(header.*, journal.headers_redundant[index]));
                if (header.command == .reserved) {
                    assert(header.op == index);
                } else {
                    assert(header.command == .prepare);
                    assert(header.op % slot_count == index);
                    assert(journal.prepare_inhabited[index]);
                    assert(journal.prepare_checksums[index] == header.checksum);
                    assert(!journal.faulty.bit(Slot{ .index = index }));
                }
            }

            // From here it's over to the Recovery protocol from VRR 2012.
            callback(journal);
        }

        /// Removes entries from `op_min` (inclusive) onwards.
        /// Used after a view change to remove uncommitted entries discarded by the new primary.
        pub fn remove_entries_from(journal: *Journal, op_min: u64) void {
            assert(journal.status == .recovered);
            assert(op_min > 0);

            log.debug("{}: remove_entries_from: op_min={}", .{ journal.replica, op_min });

            for (journal.headers) |*header, index| {
                // We must remove the header regardless of whether it is a prepare or reserved,
                // since a reserved header may have been marked faulty for case @G, and
                // since the caller expects the WAL to be truncated, with clean slots.
                if (header.op >= op_min) {
                    // TODO Explore scenarios where the data on disk may resurface after a crash.
                    const slot = journal.slot_for_op(header.op);
                    assert(slot.index == index);
                    journal.remove_entry(slot);
                }
            }
        }

        pub fn remove_entry(journal: *Journal, slot: Slot) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);

            const reserved = Header.reserved(replica.cluster, slot.index);
            journal.headers[slot.index] = reserved;
            journal.headers_redundant[slot.index] = reserved;
            journal.dirty.clear(slot);
            journal.faulty.clear(slot);
            // Do not clear `prepare_inhabited`/`prepare_checksums`. The prepare is
            // untouched on disk, and may be useful later. Consider this scenario:
            //
            // 1. Op 4 is received; start writing it.
            // 2. Op 4's prepare is written (setting `prepare_checksums`), start writing
            //    the headers.
            // 3. View change. Op 4 is discarded by `remove_entries_from`.
            // 4. View change. Op 4 (the same one from before) is back, marked as dirty. But
            //    we don't start a write, because `journal.writing()` says it is already in
            //    progress.
            // 5. Op 4's header write finishes (`write_prepare_on_write_header`).
            //
            // If `remove_entries_from` cleared `prepare_checksums`,
            // `write_prepare_on_write_header` would clear `dirty`/`faulty` for a slot with
            // `prepare_inhabited=false`.
        }

        pub fn set_header_as_dirty(journal: *Journal, header: *const Header) void {
            assert(journal.status == .recovered);
            assert(header.command == .prepare);

            log.debug("{}: set_header_as_dirty: op={} checksum={}", .{
                journal.replica,
                header.op,
                header.checksum,
            });

            const slot = journal.slot_for_header(header);

            if (journal.has(header)) {
                assert(journal.dirty.bit(slot));
                // Do not clear any faulty bit for the same entry.
            } else {
                // Overwriting a new op with an old op would be a correctness bug; it could cause a
                // message to be uncommitted.
                assert(journal.headers[slot.index].op <= header.op);

                journal.headers[slot.index] = header.*;
                journal.dirty.set(slot);
                journal.faulty.clear(slot);
            }
        }

        /// `write_prepare` uses `write_sectors` to prevent concurrent disk writes.
        // TODO To guard against torn writes, don't write simultaneously to all redundant header
        // sectors. (This is mostly a risk for single-replica clusters with small WALs).
        pub fn write_prepare(
            journal: *Journal,
            callback: fn (journal: *Replica, wrote: ?*Message, trigger: Write.Trigger) void,
            message: *Message,
            trigger: Journal.Write.Trigger,
        ) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);

            assert(journal.status == .recovered);
            assert(message.header.command == .prepare);
            assert(message.header.size >= @sizeOf(Header));
            assert(message.header.size <= message.buffer.len);
            assert(journal.has(message.header));
            assert(replica.replica_count != 1 or journal.writes.executing() == 0);

            // The underlying header memory must be owned by the buffer and not by journal.headers:
            // Otherwise, concurrent writes may modify the memory of the pointer while we write.
            assert(@ptrToInt(message.header) == @ptrToInt(message.buffer.ptr));

            const slot = journal.slot_with_header(message.header).?;

            if (!journal.dirty.bit(slot)) {
                // Any function that sets the faulty bit should also set the dirty bit:
                assert(!journal.faulty.bit(slot));
                assert(journal.prepare_inhabited[slot.index]);
                assert(journal.prepare_checksums[slot.index] == message.header.checksum);
                assert(journal.headers_redundant[slot.index].checksum == message.header.checksum);
                journal.write_prepare_debug(message.header, "skipping (clean)");
                callback(replica, message, trigger);
                return;
            }

            assert(journal.has_dirty(message.header));

            const write = journal.writes.acquire() orelse {
                journal.write_prepare_debug(message.header, "waiting for IOP");
                callback(replica, null, trigger);
                return;
            };

            journal.write_prepare_debug(message.header, "starting");

            write.* = .{
                .journal = journal,
                .callback = callback,
                .message = message.ref(),
                .trigger = trigger,
                .range = undefined,
            };

            // Slice the message to the nearest sector, we don't want to write the whole buffer:
            const buffer = message.buffer[0..vsr.sector_ceil(message.header.size)];
            const offset = Ring.prepares.offset(slot);

            if (builtin.mode == .Debug) {
                // Assert that any sector padding has already been zeroed:
                var sum_of_sector_padding_bytes: u8 = 0;
                for (buffer[message.header.size..]) |byte| sum_of_sector_padding_bytes |= byte;
                assert(sum_of_sector_padding_bytes == 0);
            }

            journal.prepare_inhabited[slot.index] = false;
            journal.prepare_checksums[slot.index] = 0;

            journal.write_sectors(write_prepare_header, write, buffer, .prepares, offset);
        }

        /// Attempt to lock the in-memory sector containing the header being written.
        /// If the sector is already locked, add this write to the wait queue.
        fn write_prepare_header(write: *Journal.Write) void {
            const journal = write.journal;
            const message = write.message;
            assert(journal.status == .recovered);

            {
                // `prepare_inhabited[slot.index]` is usually false here, but may be true if two
                // (or more) writes to the same slot were queued concurrently and this is not the
                // first to finish writing its prepare.
                const slot = journal.slot_for_header(message.header);
                journal.prepare_inhabited[slot.index] = true;
                journal.prepare_checksums[slot.index] = message.header.checksum;
            }

            if (journal.slot_with_op_and_checksum(message.header.op, message.header.checksum)) |slot| {
                journal.headers_redundant[slot.index] = message.header.*;
            } else {
                journal.write_prepare_debug(message.header, "entry changed while writing sectors");
                journal.write_prepare_release(write, null);
                return;
            }

            assert(!write.header_sector_locked);
            assert(write.header_sector_next == null);

            const write_offset = journal.offset_logical_in_headers_for_message(message);

            var it = journal.writes.iterate();
            while (it.next()) |other| {
                if (other == write) continue;
                if (!other.header_sector_locked) continue;

                const other_offset = journal.offset_logical_in_headers_for_message(other.message);
                if (other_offset == write_offset) {
                    // The `other` and `write` target the same sector; append to the list.
                    var tail = other;
                    while (tail.header_sector_next) |next| tail = next;
                    tail.header_sector_next = write;
                    return;
                }
            }

            write.header_sector_locked = true;
            journal.write_prepare_on_lock_header_sector(write);
        }

        fn write_prepare_on_lock_header_sector(journal: *Journal, write: *Write) void {
            assert(journal.status == .recovered);
            assert(write.header_sector_locked);

            // TODO It's possible within this section that the header has since been replaced but we
            // continue writing, even when the dirty bit is no longer set. This is not a problem
            // but it would be good to stop writing as soon as we see we no longer need to.
            // For this, we'll need to have a way to tweak write_prepare_release() to release locks.
            // At present, we don't return early here simply because it doesn't yet do that.

            const message = write.message;
            const slot_of_message = journal.slot_for_header(message.header);
            const offset = Ring.headers.offset(slot_of_message);
            assert(offset % constants.sector_size == 0);

            const buffer: []u8 = journal.header_sector(
                @divFloor(slot_of_message.index, headers_per_sector),
                write,
            );

            log.debug("{}: write_header: op={} sectors[{}..{}]", .{
                journal.replica,
                message.header.op,
                offset,
                offset + constants.sector_size,
            });

            // Memory must not be owned by journal.headers as these may be modified concurrently:
            assert(@ptrToInt(buffer.ptr) < @ptrToInt(journal.headers.ptr) or
                @ptrToInt(buffer.ptr) > @ptrToInt(journal.headers.ptr) + headers_size);

            journal.write_sectors(write_prepare_on_write_header, write, buffer, .headers, offset);
        }

        fn write_prepare_on_write_header(write: *Journal.Write) void {
            const journal = write.journal;
            const message = write.message;

            assert(write.header_sector_locked);
            journal.write_prepare_unlock_header_sector(write);

            if (!journal.has(message.header)) {
                journal.write_prepare_debug(message.header, "entry changed while writing headers");
                journal.write_prepare_release(write, null);
                return;
            }

            journal.write_prepare_debug(message.header, "complete, marking clean");

            const slot = journal.slot_with_header(message.header).?;
            journal.dirty.clear(slot);
            journal.faulty.clear(slot);

            journal.write_prepare_release(write, message);
        }

        /// Release the lock held by a write on an in-memory header sector and pass
        /// it to a waiting Write, if any.
        fn write_prepare_unlock_header_sector(journal: *Journal, write: *Journal.Write) void {
            assert(write.header_sector_locked);
            write.header_sector_locked = false;

            // Unlike the ranges of physical memory we lock when writing to disk,
            // these header sector locks are always an exact match, so there's no
            // need to re-check the waiting writes against all other writes.
            if (write.header_sector_next) |waiting| {
                write.header_sector_next = null;

                assert(waiting.header_sector_locked == false);
                waiting.header_sector_locked = true;
                journal.write_prepare_on_lock_header_sector(waiting);
            }
            assert(write.header_sector_next == null);
        }

        fn write_prepare_release(journal: *Journal, write: *Journal.Write, wrote: ?*Message) void {
            const replica = @fieldParentPtr(Replica, "journal", journal);
            const write_callback = write.callback;
            const write_trigger = write.trigger;
            const write_message = write.message;

            // Release the write prior to returning control to the caller.
            // This allows us to enforce journal.writes.len≤1 when replica_count=1, because the
            // callback may immediately start the next write.
            journal.writes.release(write);
            write_callback(replica, wrote, write_trigger);
            replica.message_bus.unref(write_message);
        }

        fn write_prepare_debug(journal: *const Journal, header: *const Header, status: []const u8) void {
            log.debug("{}: write: view={} op={} len={}: {} {s}", .{
                journal.replica,
                header.view,
                header.op,
                header.size,
                header.checksum,
                status,
            });
        }

        fn offset_logical_in_headers_for_message(journal: *const Journal, message: *Message) u64 {
            return Ring.headers.offset(journal.slot_for_header(message.header));
        }

        fn write_sectors(
            journal: *Journal,
            callback: fn (write: *Journal.Write) void,
            write: *Journal.Write,
            buffer: []const u8,
            ring: Ring,
            offset: u64, // Offset within the Ring.
        ) void {
            write.range = .{
                .callback = callback,
                .completion = undefined,
                .buffer = buffer,
                .ring = ring,
                .offset = offset,
                .locked = false,
            };
            journal.lock_sectors(write);
        }

        /// Start the write on the current range or add it to the proper queue
        /// if an overlapping range is currently being written.
        fn lock_sectors(journal: *Journal, write: *Journal.Write) void {
            assert(!write.range.locked);
            assert(write.range.next == null);

            var it = journal.writes.iterate();
            while (it.next()) |other| {
                if (other == write) continue;
                if (!other.range.locked) continue;

                if (other.range.overlaps(&write.range)) {
                    var tail = &other.range;
                    while (tail.next) |next| tail = next;
                    tail.next = &write.range;
                    return;
                }
            }

            log.debug("{}: write_sectors: ring={} offset={} len={} locked", .{
                journal.replica,
                write.range.ring,
                write.range.offset,
                write.range.buffer.len,
            });

            write.range.locked = true;
            journal.storage.write_sectors(
                write_sectors_on_write,
                &write.range.completion,
                write.range.buffer,
                switch (write.range.ring) {
                    .headers => .wal_headers,
                    .prepares => .wal_prepares,
                },
                write.range.offset,
            );
            // We rely on the Storage.write_sectors() implementation being always synchronous,
            // in which case writes never actually need to be queued, or always asynchronous,
            // in which case write_sectors_on_write() doesn't have to handle lock_sectors()
            // synchronously completing a write and making a nested write_sectors_on_write() call.
            //
            // We don't currently allow Storage implementations that are sometimes synchronous and
            // sometimes asynchronous as we don't have a use case for such a Storage implementation
            // and doing so would require a significant complexity increase.
            switch (Storage.synchronicity) {
                .always_synchronous => assert(!write.range.locked),
                .always_asynchronous => assert(write.range.locked),
            }
        }

        fn write_sectors_on_write(completion: *Storage.Write) void {
            const range = @fieldParentPtr(Range, "completion", completion);
            const write = @fieldParentPtr(Journal.Write, "range", range);
            const journal = write.journal;

            assert(write.range.locked);
            write.range.locked = false;

            log.debug("{}: write_sectors: ring={} offset={} len={} unlocked", .{
                journal.replica,
                write.range.ring,
                write.range.offset,
                write.range.buffer.len,
            });

            // Drain the list of ranges that were waiting on this range to complete.
            var current = range.next;
            range.next = null;
            while (current) |waiting| {
                assert(waiting.locked == false);
                current = waiting.next;
                waiting.next = null;
                journal.lock_sectors(@fieldParentPtr(Journal.Write, "range", waiting));
            }

            range.callback(write);
        }

        /// Returns a sector of redundant headers, ready to be written to the specified sector.
        /// `sector_index` is relative to the start of the redundant header zone.
        fn header_sector(
            journal: *const Journal,
            sector_index: usize,
            write: *const Journal.Write,
        ) Sector {
            assert(journal.status != .init);
            assert(journal.writes.items.len == journal.headers_iops.len);
            assert(sector_index < @divFloor(slot_count, headers_per_sector));

            const replica = @fieldParentPtr(Replica, "journal", journal);
            const sector_slot = Slot{ .index = sector_index * headers_per_sector };
            assert(sector_slot.index < slot_count);

            const write_index = @divExact(
                @ptrToInt(write) - @ptrToInt(&journal.writes.items),
                @sizeOf(Journal.Write),
            );

            // TODO The compiler should not need this align cast as the type of `headers_iops`
            // ensures that each buffer is properly aligned.
            const sector = @alignCast(constants.sector_size, &journal.headers_iops[write_index]);
            const sector_headers = std.mem.bytesAsSlice(Header, sector);
            assert(sector_headers.len == headers_per_sector);

            var i: usize = 0;
            while (i < headers_per_sector) : (i += 1) {
                const slot = Slot{ .index = sector_slot.index + i };

                if (journal.faulty.bit(slot)) {
                    // Redundant faulty headers are deliberately written as invalid.
                    // This ensures that faulty headers are still faulty when they are read back
                    // from disk during recovery. This prevents faulty entries from changing to
                    // reserved (and clean) after a crash and restart (e.g. accidentally converting
                    // a case `@D` to a `@J` after a restart).
                    sector_headers[i] = .{
                        .checksum = 0,
                        .cluster = replica.cluster,
                        .command = .reserved,
                    };
                    assert(!sector_headers[i].valid_checksum());
                } else {
                    // Write headers from `headers_redundant` instead of `headers` — we need to
                    // avoid writing (leaking) a redundant header before its corresponding prepare
                    // is on disk.
                    sector_headers[i] = journal.headers_redundant[slot.index];
                }
            }
            return sector;
        }

        pub fn writing(journal: *Journal, op: u64, checksum: u128) bool {
            const slot = journal.slot_for_op(op);
            var found: bool = false;
            var it = journal.writes.iterate();
            while (it.next()) |write| {
                const write_slot = journal.slot_for_op(write.message.header.op);

                // It's possible that we might be writing the same op but with a different checksum.
                // For example, if the op we are writing did not survive the view change and was
                // replaced by another op. We must therefore do the search primarily on checksum.
                // However, we compare against the 64-bit op first, since it's a cheap machine word.
                if (write.message.header.op == op and write.message.header.checksum == checksum) {
                    // If we truly are writing, then the dirty bit must be set:
                    assert(journal.dirty.bit(journal.slot_for_op(op)));
                    found = true;
                } else if (write_slot.index == slot.index) {
                    // If the in-progress write of '{op, checksum}' will be overwritten by another
                    // write to the same slot, writing() must return false.
                    found = false;
                }
            }
            return found;
        }
    };
}

/// @B and @C:
/// This prepare header is corrupt.
/// We may have a valid redundant header, but need to recover the full message.
///
/// Case @B may be caused by crashing while writing the prepare (torn write).
///
/// @D:
/// This is possibly a torn prepare to the redundant headers, so when replica_count=1 we must
/// repair this locally. The probability that this results in an incorrect recovery is:
///   P(crash during first WAL wrap)
///     × P(redundant header is corrupt)
///     × P(lost write to prepare covered by the corrupt redundant header)
/// which is negligible, and does not impact replica_count>1.
///
/// @E:
/// Valid prepare, corrupt header. One of:
///
/// 1. The replica crashed while writing the redundant header (torn write).
/// 2. The read to the header is corrupt or misdirected.
/// 3. Multiple faults, for example: the redundant header read is corrupt, and the prepare read is
///    misdirected.
///
///
/// @F and @H:
/// The replica is recovering from a crash after writing the prepare, but before writing the
/// redundant header.
///
///
/// @G:
/// One of:
///
/// * A misdirected read to a reserved header.
/// * The redundant header's write was lost or misdirected.
///
/// For multi-replica clusters, don't repair locally to prevent data loss in case of 2 lost writes.
///
///
/// @I:
/// The redundant header is present & valid, but the corresponding prepare was a lost or misdirected
/// read or write.
///
///
/// @J:
/// This slot is legitimately reserved — this may be the first fill of the log.
///
///
/// @K and @L:
/// When the redundant header & prepare header are both valid but distinct ops, always pick the
/// higher op.
///
/// For example, consider slot_count=10, the op to the left is 12, the op to the right is 14, and
/// the tiebreak is between an op=3 and op=13. Choosing op=13 over op=3 is safe because the op=3
/// must be from a previous wrap — it is too far back (>pipeline) to have been replaced by a view
/// change.
///
/// The length of the prepare pipeline is the upper bound on how many ops can be reordered during a
/// view change.
///
/// @K:
/// When the higher op belongs to the prepare, repair locally.
/// The most likely cause for this case is that the log wrapped, but the redundant header write was
/// lost.
///
/// @L:
/// When the higher op belongs to the header, mark faulty.
///
///
/// @M:
/// The message was rewritten due to a view change.
/// A single-replica cluster doesn't ever change views.
///
///
/// @N:
/// The redundant header matches the message's header.
/// This is the usual case: both the prepare and header are correct and equivalent.
const recovery_cases = table: {
    const __ = Matcher.any;
    const _0 = Matcher.is_false;
    const _1 = Matcher.is_true;
    // The replica will abort if any of these checks fail:
    const a0 = Matcher.assert_is_false;
    const a1 = Matcher.assert_is_true;

    break :table [_]Case{
        // Legend:
        //
        //    R>1  replica_count > 1
        //    R=1  replica_count = 1
        //     ok  valid checksum ∧ valid cluster ∧ valid slot ∧ valid command
        //    nil  command == reserved
        //     ✓∑  header.checksum == prepare.checksum
        //    op⌈  prepare.op is maximum of all prepare.ops
        //    op=  header.op == prepare.op
        //    op<  header.op <  prepare.op
        //   view  header.view == prepare.view
        //
        //        Label  Decision      Header  Prepare Compare
        //               R>1   R=1     ok  nil ok  nil op⌈ ✓∑  op= op< view
        Case.init("@A", .vsr, .vsr, .{ _0, __, _0, __, __, __, __, __, __ }),
        Case.init("@B", .vsr, .vsr, .{ _1, _1, _0, __, __, __, __, __, __ }),
        Case.init("@C", .vsr, .vsr, .{ _1, _0, _0, __, __, __, __, __, __ }),
        Case.init("@D", .vsr, .fix, .{ _0, __, _1, _1, __, __, __, __, __ }),
        Case.init("@E", .vsr, .fix, .{ _0, __, _1, _0, _0, __, __, __, __ }),
        Case.init("@F", .fix, .fix, .{ _0, __, _1, _0, _1, __, __, __, __ }),
        Case.init("@G", .vsr, .fix, .{ _1, _1, _1, _0, _0, __, __, __, __ }),
        Case.init("@H", .fix, .fix, .{ _1, _1, _1, _0, _1, __, __, __, __ }),
        Case.init("@I", .vsr, .vsr, .{ _1, _0, _1, _1, __, __, __, __, __ }),
        Case.init("@J", .nil, .nil, .{ _1, _1, _1, _1, __, a1, a1, a0, a1 }), // normal path: reserved
        Case.init("@K", .fix, .fix, .{ _1, _0, _1, _0, __, _0, _0, _1, __ }), // header.op < prepare.op
        Case.init("@L", .vsr, .vsr, .{ _1, _0, _1, _0, __, _0, _0, _0, __ }), // header.op > prepare.op
        Case.init("@M", .vsr, .vsr, .{ _1, _0, _1, _0, __, _0, _1, a0, a0 }),
        Case.init("@N", .eql, .eql, .{ _1, _0, _1, _0, __, _1, a1, a0, a1 }), // normal path: prepare
    };
};

const case_cut = Case{
    .label = "@Truncate",
    .decision_multiple = .cut,
    .decision_single = .cut,
    .pattern = undefined,
};

const RecoveryDecision = enum {
    /// The header and prepare are identical; no repair necessary.
    eql,
    /// Reserved; dirty/faulty are clear, no repair necessary.
    nil,
    /// Use intact prepare to repair redundant header. Dirty/faulty are clear.
    fix,
    /// If replica_count>1: Repair with VSR `request_prepare`. Mark dirty, mark faulty.
    /// If replica_count=1: Fail; cannot recover safely.
    vsr,
    /// Truncate the op, setting it to reserved. Dirty/faulty are clear.
    cut,
};

const Matcher = enum { any, is_false, is_true, assert_is_false, assert_is_true };

const Case = struct {
    label: []const u8,
    /// Decision when replica_count>1.
    decision_multiple: RecoveryDecision,
    /// Decision when replica_count=1.
    decision_single: RecoveryDecision,
    /// 0: header_ok(header)
    /// 1: header.command == reserved
    /// 2: header_ok(prepare) ∧ valid_checksum_body
    /// 3: prepare.command == reserved
    /// 4: prepare.op is maximum of all prepare.ops
    /// 5: header.checksum == prepare.checksum
    /// 6: header.op == prepare.op
    /// 7: header.op < prepare.op
    /// 8: header.view == prepare.view
    pattern: [9]Matcher,

    fn init(
        label: []const u8,
        decision_multiple: RecoveryDecision,
        decision_single: RecoveryDecision,
        pattern: [9]Matcher,
    ) Case {
        return .{
            .label = label,
            .decision_multiple = decision_multiple,
            .decision_single = decision_single,
            .pattern = pattern,
        };
    }

    fn check(case: *const Case, parameters: [9]bool) !bool {
        for (parameters) |b, i| {
            switch (case.pattern[i]) {
                .any => {},
                .is_false => if (b) return false,
                .is_true => if (!b) return false,
                .assert_is_false => if (b) return error.ExpectFalse,
                .assert_is_true => if (!b) return error.ExpectTrue,
            }
        }
        return true;
    }

    fn decision(case: *const Case, replica_count: u8) RecoveryDecision {
        assert(replica_count > 0);
        if (replica_count == 1) {
            return case.decision_single;
        } else {
            return case.decision_multiple;
        }
    }
};

fn recovery_case(header: ?*const Header, prepare: ?*const Header, prepare_op_max: u64) *const Case {
    const h_ok = header != null;
    const p_ok = prepare != null;

    if (h_ok) assert(header.?.invalid() == null);
    if (p_ok) assert(prepare.?.invalid() == null);

    const parameters = .{
        h_ok,
        if (h_ok) header.?.command == .reserved else false,
        p_ok,
        if (p_ok) prepare.?.command == .reserved else false,
        if (p_ok) prepare.?.op == prepare_op_max else false,
        if (h_ok and p_ok) header.?.checksum == prepare.?.checksum else false,
        if (h_ok and p_ok) header.?.op == prepare.?.op else false,
        if (h_ok and p_ok) header.?.op < prepare.?.op else false,
        if (h_ok and p_ok) header.?.view == prepare.?.view else false,
    };

    var result: ?*const Case = null;
    for (recovery_cases) |*case| {
        const match = case.check(parameters) catch {
            log.err("recovery_case: impossible state: case={s} parameters={any}", .{
                case.label,
                parameters,
            });
            unreachable;
        };
        if (match) {
            assert(result == null);
            result = case;
        }
    }
    // The recovery table is exhaustive.
    // Every combination of parameters matches exactly one case.
    return result.?;
}

/// Returns the header, only if the header:
/// * has a valid checksum, and
/// * has the expected cluster, and
/// * has an expected command, and
/// * resides in the correct slot.
fn header_ok(cluster: u32, slot: Slot, header: *const Header) ?*const Header {
    // We must first validate the header checksum before accessing any fields.
    // Otherwise, we may hit undefined data or an out-of-bounds enum and cause a runtime crash.
    if (!header.valid_checksum()) return null;

    // A header with the wrong cluster, or in the wrong slot, may indicate a misdirected read/write.
    // All journalled headers should be reserved or else prepares.
    // A misdirected read/write to or from another storage zone may return the wrong message.
    const valid_cluster_command_and_slot = switch (header.command) {
        .prepare => header.cluster == cluster and slot.index == header.op % slot_count,
        .reserved => header.cluster == cluster and slot.index == header.op,
        else => false,
    };

    // Do not check the checksum here, because that would run only after the other field accesses.
    return if (valid_cluster_command_and_slot) header else null;
}

test "recovery_cases" {
    // Verify that every pattern matches exactly one case.
    //
    // Every possible combination of parameters must either:
    // * have a matching case
    // * have a case that fails (which would result in a panic).
    var i: usize = 0;
    while (i <= std.math.maxInt(u8)) : (i += 1) {
        var parameters: [9]bool = undefined;
        comptime var j: usize = 0;
        inline while (j < parameters.len) : (j += 1) {
            parameters[j] = i & (1 << j) != 0;
        }

        var case_match: ?*const Case = null;
        for (recovery_cases) |*case| {
            if (case.check(parameters) catch true) {
                try std.testing.expectEqual(case_match, null);
                case_match = case;
            }
        }
        if (case_match == null) @panic("no matching case");
    }
}

pub const BitSet = struct {
    bits: std.DynamicBitSetUnmanaged,

    /// The number of bits set (updated incrementally as bits are set or cleared):
    count: u64 = 0,

    fn init_full(allocator: Allocator, count: usize) !BitSet {
        const bits = try std.DynamicBitSetUnmanaged.initFull(allocator, count);
        errdefer bits.deinit(allocator);

        return BitSet{
            .bits = bits,
            .count = count,
        };
    }

    fn deinit(bit_set: *BitSet, allocator: Allocator) void {
        assert(bit_set.count == bit_set.bits.count());

        bit_set.bits.deinit(allocator);
    }

    /// Clear the bit for a slot (idempotent):
    pub fn clear(bit_set: *BitSet, slot: Slot) void {
        if (bit_set.bits.isSet(slot.index)) {
            bit_set.bits.unset(slot.index);
            bit_set.count -= 1;
        }
    }

    /// Whether the bit for a slot is set:
    pub fn bit(bit_set: *const BitSet, slot: Slot) bool {
        return bit_set.bits.isSet(slot.index);
    }

    /// Set the bit for a slot (idempotent):
    pub fn set(bit_set: *BitSet, slot: Slot) void {
        if (!bit_set.bits.isSet(slot.index)) {
            bit_set.bits.set(slot.index);
            bit_set.count += 1;
            assert(bit_set.count <= bit_set.bits.bit_length);
        }
    }
};

/// Format part of a new WAL's Zone.wal_headers, writing to `target`.
///
/// `offset_logical` is relative to the beginning of the `wal_headers` zone.
/// Returns the number of bytes written to `target`.
pub fn format_wal_headers(cluster: u32, offset_logical: u64, target: []u8) usize {
    assert(offset_logical <= constants.journal_size_headers);
    assert(offset_logical % constants.sector_size == 0);
    assert(target.len > 0);
    assert(target.len % @sizeOf(Header) == 0);
    assert(target.len % constants.sector_size == 0);

    var headers = std.mem.bytesAsSlice(Header, target);
    const headers_past = @divExact(offset_logical, @sizeOf(Header));
    const headers_count = std.math.min(headers.len, slot_count - headers_past);

    for (headers[0..headers_count]) |*header, i| {
        const slot = @divExact(offset_logical, @sizeOf(Header)) + i;
        if (slot == 0 and i == 0) {
            header.* = Header.root_prepare(cluster);
            assert(header.op == 0);
            assert(header.command == .prepare);
            assert(header.operation == .root);
        } else {
            header.* = Header.reserved(cluster, slot);
        }
    }
    return headers_count * @sizeOf(Header);
}

test "format_wal_headers" {
    const fuzz = @import("./journal_format_fuzz.zig");
    try fuzz.fuzz_format_wal_headers(constants.sector_size);
}

/// Format part of a new WAL's Zone.wal_prepares, writing to `target`.
///
/// `offset_logical` is relative to the beginning of the `wal_prepares` zone.
/// Returns the number of bytes written to `target`.
pub fn format_wal_prepares(cluster: u32, offset_logical: u64, target: []u8) usize {
    assert(offset_logical <= constants.journal_size_prepares);
    assert(offset_logical % constants.sector_size == 0);
    assert(target.len > 0);
    assert(target.len % @sizeOf(Header) == 0);
    assert(target.len % constants.sector_size == 0);

    const sectors_per_message = @divExact(constants.message_size_max, constants.sector_size);
    const sector_max = @divExact(constants.journal_size_prepares, constants.sector_size);

    var sectors = std.mem.bytesAsSlice([constants.sector_size]u8, target);
    for (sectors) |*sector_data, i| {
        const sector = @divExact(offset_logical, constants.sector_size) + i;
        if (sector == sector_max) {
            if (i == 0) {
                assert(offset_logical == constants.journal_size_prepares);
            }
            return i * constants.sector_size;
        } else {
            const message_slot = @divFloor(sector, sectors_per_message);
            assert(message_slot < slot_count);

            std.mem.set(u8, sector_data, 0);
            if (sector % sectors_per_message == 0) {
                // The header goes in the first sector of the message.
                var sector_header = std.mem.bytesAsValue(Header, sector_data[0..@sizeOf(Header)]);
                if (message_slot == 0) {
                    sector_header.* = Header.root_prepare(cluster);
                } else {
                    sector_header.* = Header.reserved(cluster, message_slot);
                }
            }
        }
    }
    return target.len;
}

test "format_wal_prepares" {
    const fuzz = @import("./journal_format_fuzz.zig");
    try fuzz.fuzz_format_wal_prepares(256 * 1024);
}
