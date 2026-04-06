const std = @import("std");
const mem = std.mem;
const Stringify = std.json.Stringify;
const slurm = @import("slurm");

/// Structure used to define special behaviour for type serialization
const SlurmType = struct {
    typ: type,
    serialize_fn: *const fn (s: *Stringify, data: anytype, opts: SlurmType) anyerror!void = serializeContainer,
    options: []const Option = &.{},
    extra_members: []const Option = &.{},

    /// Special serialization for selected fields.
    const Option = struct {
        name: [:0]const u8,
        new_name: ?[:0]const u8 = null,
        serialize_fn: *const fn (s: *Stringify, instance: anytype, field: anytype, opts: anytype) anyerror!void = serializeMemberDefault,
        serialize_fn_args: ?*const anyopaque = null,
    };
};

/// Skips a field / container entirely
fn noop(s: *Stringify, data: anytype, opts: anytype) !void {
    _ = s;
    _ = data;
    _ = opts;
}

fn noopMember(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    _ = s;
    _ = instance;
    _ = field;
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
            .{ .name = "tres_fmt_str", .serialize_fn = toDict },
            .{ .name = "partitions", .serialize_fn = toArray },
            .{ .name = "features_act", .serialize_fn = toArray },
            .{ .name = "features", .serialize_fn = toArray },
        },
    },
    .{
        .typ = *slurm.Job,
        .options = &.{
            .{ .name = "pn_min_memory", .new_name = "memory", .serialize_fn = parseJobMemory },
            .{ .name = "node_inx", .serialize_fn = noopMember },
            .{ .name = "priority_array", .serialize_fn = noopMember },
            .{ .name = "req_node_inx", .serialize_fn = noopMember },
            .{ .name = "exc_node_inx", .serialize_fn = noopMember },
            .{ .name = "array_bitmap", .serialize_fn = noopMember },
            .{ .name = "tres_req_str", .serialize_fn = toDict },
            .{ .name = "tres_alloc_str", .serialize_fn = toDict },
            .{ .name = "tres_per_job", .serialize_fn = toDict },
            .{ .name = "requeue", .serialize_fn = toBool },
            .{ .name = "time_min", .serialize_fn = toNumber, .serialize_fn_args = &NumberOptions{ .zero_is_noval = true } },
        },
        .extra_members = &.{
            .{ .name = "memory_total", .serialize_fn = parseJobMemoryTotal },
        },
    },
    .{
        .typ = *slurm.Partition,
        .options = &.{
            .{ .name = "node_inx", .serialize_fn = noopMember },
            .{ .name = "job_defaults_list", .serialize_fn = noopMember },
            .{ .name = "deny_accounts", .serialize_fn = toArray, },
            .{ .name = "allow_accounts", .serialize_fn = toArray, },
            .{ .name = "allow_alloc_nodes", .serialize_fn = toArray, },
            .{ .name = "allow_groups", .serialize_fn = toArray, },
            .{ .name = "allow_qos", .serialize_fn = toArray, },
            .{ .name = "deny_qos", .serialize_fn = toArray, },
            .{ .name = "qos_char", .new_name = "assigned_qos" },
            .{ .name = "tres_fmt_str", .new_name = "configured_tres", .serialize_fn = toDict },
        },
    },
    .{
        .typ = *slurm.Partition.LoadResponse,
        .serialize_fn = stringifyLoadResponse,
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

pub fn parseJobMemory(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    const value = instance.memory();
    try s.objectField(field.json_key);
    try toNumberRaw(s, value, opts);
}

pub fn parseJobMemoryTotal(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    const value = instance.memoryTotal();
    try s.objectField(field.json_key);
    try toNumberRaw(s, value, opts);
}

pub fn serializeMemberDefault(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    _ = opts;

    const value = @field(instance, field.name);

    switch (@typeInfo(field.type)) {
        .int => |info| {
            switch (info.signedness) {
                .unsigned => {
                    try toNumber(s, instance, field, null);
                    return;
                },
                .signed => {},
            }
        },
        else => {},
    }
    try write(s, value, field.json_key);
}

const DictOptions = struct {
    sep1: u8 = ',',
    sep2: u8 = '=',
};

pub fn toDict(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    const options: *const DictOptions = blk: {
        if (opts == null) {
            break :blk &.{};
        } else {
            break :blk @ptrCast(opts);
        }
    };

    const value = @field(instance, field.name);
    try s.objectField(field.json_key);

    const buf = slurm.parseCStrZ(value) orelse {
        try s.print("{{}}", .{});
        return;
    };

    try s.beginObject();
    var it_outer = std.mem.splitScalar(u8, buf, options.sep1);
    while (it_outer.next()) |item| {
        var it_inner = std.mem.splitScalar(u8, item, options.sep2);
        const key = it_inner.first();
        const val = it_inner.rest();

        try s.objectField(key);
        try s.write(val);
    }
    try s.endObject();
}

const ArrayOptions = struct {
    sep: u8 = ',',
};

pub fn toArray(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    const options: *const ArrayOptions = blk: {
        if (opts == null) {
            break :blk &.{};
        } else {
            break :blk @ptrCast(opts);
        }
    };

    const value = @field(instance, field.name);
    try s.objectField(field.json_key);

    const buf = slurm.parseCStrZ(value) orelse {
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
    flat: bool = false,
};

pub fn toNumberRaw(s: *Stringify, data: anytype, opts: anytype) !void {
    const T = @TypeOf(data);
    const raw_number = @as(T, data);

    const options: *const NumberOptions = blk: {
        if (opts) |o| break :blk @ptrCast(o);
        break :blk &.{};
    };

    const value: ?T = blk: {
        const has_value = slurm.common.numberHasValue(data);

        if ((options.zero_is_noval and raw_number == 0) or !has_value) {
            break :blk null;
        } else {
            break :blk data;
        }
    };

    switch (options.flat) {
        false => try s.write(Number(T){
            .value = value,
            .infinite = slurm.common.numberIsInfinite(data),
        }),
        true => try s.write(value),
    }
}

pub fn toNumber(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    const field_value = @field(instance, field.name);
    try s.objectField(field.json_key);
    try toNumberRaw(s, field_value, opts);
}

pub fn toBool(s: *Stringify, instance: anytype, field: anytype, opts: anytype) !void {
    _ = opts;
    const field_value = @field(instance, field.name);
    try s.objectField(field.json_key);
    if (field_value == 0) try s.write(false) else try s.write(true);
}

pub fn stringifyLoadResponse(s: *Stringify, data: anytype, opts: SlurmType) !void {
    _ = opts;

    try s.beginArray();
    var iter = data.iter();
    while (iter.next()) |item| {
        try write(s, item, null);
    }
    try s.endArray();
}

pub const Field = struct {
    json_key: [:0]const u8,
    name: [:0]const u8,
    @"type": type,
};

fn serializeContainer(s: *Stringify, data: anytype, typ: SlurmType) !void {
    std.debug.assert(typ.typ != @TypeOf(undefined));

    try s.beginObject();

    const T = @TypeOf(data.*);
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const option: SlurmType.Option = comptime blk: {
            @setEvalBranchQuota(5000);
            for (typ.options) |opt| {
                if (mem.eql(u8, field.name, opt.name)) break :blk opt;
            }

            break :blk .{
                .name = field.name,
            };
        };

        const f: Field = .{
            .json_key = if (option.new_name) |new_name| new_name else field.name,
            .name = field.name,
            .@"type" = field.type,
        };
        try option.serialize_fn(s, data, f, option.serialize_fn_args);
    }

    inline for (typ.extra_members) |extra_member| {
        const f: Field = .{
            .json_key = extra_member.name,
            .name = extra_member.name,
            .@"type" = undefined,
        };
        try extra_member.serialize_fn(s, data, f, extra_member.serialize_fn_args);
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
    try s.beginObject();
    try s.objectField("data");
    try write(&s, value, null);
    try s.endObject();
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
