const std = @import("std");
const mem = std.mem;
const Stringify = std.json.Stringify;
const slurm = @import("slurm");

/// Structure used to define special behaviour for type serialization
const SlurmType = struct {
    typ: type,
    serialize_fn: *const fn (s: *Stringify, data: anytype, opts: SlurmType) anyerror!void = serializeContainer,
    options: []const Option = &.{},

    /// Special serialization for selected fields.
    const Option = struct {
        name: [:0]const u8,
        serialize_fn: *const fn (s: *Stringify, data: anytype, opts: anytype) anyerror!void,
        serialize_fn_args: ?*const anyopaque = null,
    };
};

/// Skips a field / container entirely
fn noop(s: *Stringify, data: anytype, opts: anytype) !void {
    _ = s;
    _ = data;
    _ = opts;
}

const default_field_type: SlurmType = .{
    .typ = undefined,
    .serialize_fn = serializeDefault,
};

const tdefs: []const SlurmType = &.{
    .{
        .typ = *slurm.Node,
        .options = &.{
            .{ .name = "free_mem", .serialize_fn = toNumber },
            .{ .name = "tres_fmt_str", .serialize_fn = toDict },
            .{ .name = "partitions", .serialize_fn = toArray },
            .{ .name = "features_act", .serialize_fn = toArray },
            .{ .name = "features", .serialize_fn = toArray },
        },
    },
    .{
        .typ = *slurm.Job,
        .options = &.{
            .{ .name = "node_inx", .serialize_fn = noop },
            .{ .name = "priority_array", .serialize_fn = noop },
            .{ .name = "req_node_inx", .serialize_fn = noop },
            .{ .name = "exc_node_inx", .serialize_fn = noop },
            .{ .name = "array_bitmap", .serialize_fn = noop },
            .{ .name = "tres_req_str", .serialize_fn = toDict },
            .{ .name = "tres_alloc_str", .serialize_fn = toDict },
            .{ .name = "tres_per_job", .serialize_fn = toDict },
            .{ .name = "time_min", .serialize_fn = toNumber, .serialize_fn_args = &NumberOptions{ .zero_is_noval = true } },
        },
    },
    .{
        .typ = *slurm.Node.LoadResponse,
        .serialize_fn = stringifyLoadResponse,
    },
    .{
        .typ = *slurm.Job.LoadResponse,
        .serialize_fn = stringifyLoadResponse,
    },
    .{
        .typ = ?*slurm.job.JobResources,
        .serialize_fn = noop,
    },
};

pub fn fmt(value: anytype, options: Stringify.Options) Formatter(@TypeOf(value)) {
    return Formatter(@TypeOf(value)){ .value = value, .options = options };
}

const DictOptions = struct {
    sep1: u8 = ',',
    sep2: u8 = '=',
};

pub fn toDict(s: *Stringify, data: anytype, opts: anytype) !void {
    const options: *const DictOptions = blk: {
        if (opts == null) {
            break :blk &.{};
        } else {
            break :blk @ptrCast(opts);
        }
    };

    const buf = slurm.parseCStrZ(data) orelse {
        try s.print("{{}}", .{});
        return;
    };

    try s.beginObject();
    var it_outer = std.mem.splitScalar(u8, buf, options.sep1);
    while (it_outer.next()) |item| {
        var it_inner = std.mem.splitScalar(u8, item, options.sep2);
        const key = it_inner.first();
        const value = it_inner.rest();

        try s.objectField(key);
        try s.write(value);
    }
    try s.endObject();
}

const ArrayOptions = struct {
    sep: u8 = ',',
};

pub fn toArray(s: *Stringify, data: anytype, opts: anytype) !void {
    const options: *const ArrayOptions = blk: {
        if (opts == null) {
            break :blk &.{};
        } else {
            break :blk @ptrCast(opts);
        }
    };

    const buf = slurm.parseCStrZ(data) orelse {
        try s.print("[]", .{});
        return;
    };

    try s.beginArray();
    var it = std.mem.splitScalar(u8, buf, options.sep);
    while (it.next()) |item| {
        try s.write(item);
    }
    try s.endArray();
}

fn Number(comptime T: type) type {
    return struct {
        value: ?T,
        infinite: ?bool = null,
    };
}

pub const NumberOptions = struct {
    zero_is_noval: bool = false,
};

pub fn toNumber(s: *Stringify, data: anytype, opts: anytype) !void {
    const T = @TypeOf(data);
    const raw_number = @as(T, data);

    const options: *const NumberOptions = blk: {
        if (opts) |o| break :blk @ptrCast(o);
        break :blk &.{};
    };

    const value: ?T = blk: {
        const has_value = slurm.uint.has_value(data);

        if ((options.zero_is_noval and raw_number == 0) or !has_value) {
            break :blk null;
        } else {
            break :blk data;
        }
    };

    const num: Number(T) = .{
        .value = value,
        .infinite = slurm.uint.is_infinite(data),
    };

    try s.write(num);
}

pub fn stringifyLoadResponse(s: *Stringify, data: anytype, opts: SlurmType) !void {
    _ = opts;

    try s.beginObject();
    try s.objectField("data");

    try s.beginArray();
    var iter = data.iter();
    while (iter.next()) |item| {
        try write(s, item, null);
    }
    try s.endArray();

    try s.endObject();
}

fn serializeContainer(s: *Stringify, data: anytype, typ: SlurmType) !void {
    std.debug.assert(typ.typ != @TypeOf(undefined));

    try s.beginObject();

    const T = @TypeOf(data.*);
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const field_option: ?SlurmType.Option = comptime blk: {
            @setEvalBranchQuota(5000);
            for (typ.options) |opt| {
                if (mem.eql(u8, field.name, opt.name)) break :blk opt;
            }

            break :blk null;
        };

        const field_value = @field(data, field.name);
        if (field_option) |option| {
            if (option.serialize_fn != noop) try s.objectField(field.name);
            try option.serialize_fn(s, field_value, option.serialize_fn_args);
        } else {
            //            try s.objectField(field.name);
            try write(s, field_value, field.name);
        }
    }

    try s.endObject();
}

fn serializeDefault(s: *Stringify, value: anytype, opts: SlurmType) !void {
    _ = opts;
    try s.write(value);
}

pub fn write(s: *Stringify, value: anytype, key: ?[]const u8) std.Io.Writer.Error!void {
    const T = @TypeOf(value);

    const tdef: SlurmType = comptime blk: {
        for (tdefs) |def| {
            if (T == def.typ) break :blk def;
        }

        break :blk default_field_type;
    };

    if (key) |k| {
        if (tdef.serialize_fn == noop) return;
        try s.objectField(k);
    }

    try tdef.serialize_fn(s, value, tdef);
}

pub fn serialize(value: anytype, options: Stringify.Options, writer: *std.Io.Writer) !void {
    var s: Stringify = .{ .writer = writer, .options = options };
    try write(&s, value, null);
}

pub fn stringify(allocator: mem.Allocator, value: anytype, options: Stringify.Options) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{fmt(value, options)});
}

/// Formats the given value using stringify.
pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: Stringify.Options,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try serialize(self.value, self.options, writer);
        }
    };
}
