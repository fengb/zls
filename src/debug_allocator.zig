//! This allocator collects information about allocation sizes

const std = @import("std");

const DebugAllocator = @This();

fn toMB(value: var) f64 {
    return switch (@TypeOf(value)) {
        f64 => value / (1024 * 1024),
        else => @intToFloat(f64, value) / (1024 * 1024),
    };
}

const Stats = struct {
    mean: f64 = 0,
    mean_of_squares: f64 = 0,
    total: usize = 0,
    count: usize = 0,

    fn addSample(self: *Stats, value: usize) void {
        const count_f64 = @intToFloat(f64, self.count);
        self.mean = (self.mean * count_f64 + @intToFloat(f64, value)) / (count_f64 + 1);
        self.mean_of_squares = (self.mean_of_squares * count_f64 + @intToFloat(f64, value * value)) / (count_f64 + 1);
        self.total += value;
        self.count += 1;
    }

    fn stdDev(self: Stats) f64 {
        return std.math.sqrt(self.mean_of_squares - self.mean * self.mean);
    }
};

pub const AllocationInfo = struct {
    allocation_stats: Stats = Stats{},
    deallocation_count: usize = 0,
    deallocation_total: usize = 0,

    reallocation_stats: Stats = Stats{},
    shrink_stats: Stats = Stats{},

    pub fn format(
        self: AllocationInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: var,
    ) !void {
        @setEvalBranchQuota(2000);

        // TODO: Make these behave like {Bi}, which doesnt work on floating point numbers.
        return std.fmt.format(
            out_stream,
            \\------------------------------------------ Allocation info ------------------------------------------
            \\{} total allocations (total: {d:.2} MB, mean: {d:.2} MB, std. dev: {d:.2} MB), {} deallocations
            \\{} current allocations ({d:.2} MB)
            \\{} reallocations (total: {d:.2} MB, mean: {d:.2} MB, std. dev: {d:.2} MB)
            \\{} shrinks (total: {d:.2} MB, mean: {d:.2} MB, std. dev: {d:.2} MB)
            \\-----------------------------------------------------------------------------------------------------
        ,
            .{
                self.allocation_stats.count,
                toMB(self.allocation_stats.total),
                toMB(self.allocation_stats.mean),
                toMB(self.allocation_stats.stdDev()),
                self.deallocation_count,
                self.allocation_stats.count - self.deallocation_count,
                toMB(self.allocation_stats.total + self.reallocation_stats.total - self.deallocation_total - self.shrink_stats.total),
                self.reallocation_stats.count,
                toMB(self.reallocation_stats.total),
                toMB(self.reallocation_stats.mean),
                toMB(self.reallocation_stats.stdDev()),
                self.shrink_stats.count,
                toMB(self.shrink_stats.total),
                toMB(self.shrink_stats.mean),
                toMB(self.shrink_stats.stdDev()),
            },
        );
    }
};

base_allocator: *std.mem.Allocator,
info: AllocationInfo,

// Interface implementation
allocator: std.mem.Allocator,

pub fn init(base_allocator: *std.mem.Allocator) DebugAllocator {
    return .{
        .base_allocator = base_allocator,
        .info = .{},
        .allocator = .{
            .reallocFn = realloc,
            .shrinkFn = shrink,
        },
    };
}

fn realloc(allocator: *std.mem.Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) ![]u8 {
    const self = @fieldParentPtr(DebugAllocator, "allocator", allocator);
    var data = try self.base_allocator.reallocFn(self.base_allocator, old_mem, old_align, new_size, new_align);
    if (old_mem.len == 0) {
        self.info.allocation_stats.addSample(new_size);
    } else if (new_size > old_mem.len) {
        self.info.reallocation_stats.addSample(new_size - old_mem.len);
    } else if (new_size < old_mem.len) {
        self.info.shrink_stats.addSample(old_mem.len - new_size);
    }
    return data;
}

fn shrink(allocator: *std.mem.Allocator, old_mem: []u8, old_align: u29, new_size: usize, new_align: u29) []u8 {
    const self = @fieldParentPtr(DebugAllocator, "allocator", allocator);
    if (new_size == 0) {
        if (self.info.allocation_stats.count == self.info.deallocation_count) {
            @panic("error - too many calls to free, most likely double free");
        }
        self.info.deallocation_total += old_mem.len;
        self.info.deallocation_count += 1;
    } else if (new_size < old_mem.len) {
        self.info.shrink_stats.addSample(old_mem.len - new_size);
    } else if (new_size > old_mem.len) {
        @panic("error - trying to shrink to a bigger size");
    }
    return self.base_allocator.shrinkFn(self.base_allocator, old_mem, old_align, new_size, new_align);
}
