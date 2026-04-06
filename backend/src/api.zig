const std = @import("std");
const slurm = @import("slurm");
const tk = @import("tokamak");
const json = @import("json.zig");
const Allocator = std.mem.Allocator;
const uid_t = std.posix.uid_t;
const allocPrint = std.fmt.allocPrint;

fn getNodes(allocator: Allocator, name: ?[]const u8) ![]const u8 {
    const node_resp = try slurm.node.load();
    defer node_resp.deinit();

    if (name) |n| {
        var iter = node_resp.iter();
        while (iter.next()) |node| {
            const node_name = slurm.parseCStrZ(node.name);
            if (node_name == null) continue;

            if (std.mem.eql(u8, node_name.?, n)) {
                return json.stringify(allocator, node, .{ .whitespace = .indent_4 });
            }
        }

        // TODO: proper return
        return "";
    }
    return json.stringify(allocator, node_resp, .{ .whitespace = .indent_4 });
}

fn getPartitions(allocator: Allocator, name: ?[]const u8) ![]const u8 {
    const resp = try slurm.partition.load();
    defer resp.deinit();

    if (name) |n| {
        var iter = resp.iter();
        while (iter.next()) |part| {
            const node_name = slurm.parseCStrZ(part.name);
            if (node_name == null) continue;

            if (std.mem.eql(u8, node_name.?, n)) {
                return json.stringify(allocator, part, .{ .whitespace = .indent_4 });
            }
        }

        // TODO: proper return
        return "";
    }
    return json.stringify(allocator, resp, .{ .whitespace = .indent_4 });
}

const JobBriefInfo = struct {
    id: u32,
    state: ?[]const u8 = null,
    user_name: ?[]const u8 = null,
    account: ?[:0]const u8 = null,
    partition: ?[:0]const u8 = null,
    qos: ?[:0]const u8 = null,
    //    resources: ?Resources = null,

    const Resources = struct {
        cpus: u32,
        memory: u64,
        gpus: u32,
    };
};

const QueueSummary = std.ArrayListUnmanaged(JobBriefInfo);

fn uidToName(allocator: Allocator, uid: uid_t) ![]const u8 {
    //  if (job.user_name) |uname| {
    //      return std.mem.span(uname);
    //  }

    const passwd_info = std.c.getpwuid(uid);
    if (passwd_info) |pwd| {
        if (pwd.name) |name| {
            const pwd_name = std.mem.span(name);
            return try allocator.dupe(u8, pwd_name);
        }
    }
    return try allocPrint(allocator, "{d}", .{uid});
}

fn getQueueSummary(allocator: Allocator) ![]const u8 {
    _ = slurm.init(null);

    const data = try slurm.job.load();
    var queue_summary: QueueSummary = .empty;

    var iter = data.iter();
    while (iter.next()) |job| {
        const job_brief: JobBriefInfo = .{
            .id = job.job_id,
            .state = try job.state.toStr(allocator),
            .user_name = try uidToName(allocator, job.user_id),
            .account = slurm.parseCStrZ(job.account),
            .partition = slurm.parseCStrZ(job.partition),
            .qos = slurm.parseCStrZ(job.qos),
            //          .resources = .{
            //              .cpus = job.num_cpus,
            //              .memory = job.memory(),
            //              .gpus = 1, // TODO
            //          },
        };
        try queue_summary.append(allocator, job_brief);
    }

    return json.stringify(allocator, queue_summary.items, .{ .whitespace = .indent_4 });
}

fn getJobs(allocator: Allocator, id: ?u32) ![]const u8 {
    const data = try slurm.job.load();

    if (id) |job_id| {
        var iter = data.iter();
        while (iter.next()) |job| {
            if (job_id == job.job_id) {
                return json.stringify(allocator, job, .{ .whitespace = .indent_4 });
            }
        }

        // TODO: proper return;
        return "";
    }
    return json.stringify(allocator, data, .{ .whitespace = .indent_4 });
}

pub fn @"GET /queue"(allocator: std.mem.Allocator, res: *tk.Response) ![]const u8 {
    res.content_type = .JSON;
    return getQueueSummary(allocator);
}

pub fn @"GET /jobs"(allocator: std.mem.Allocator) ![]const u8 {
    return getJobs(allocator, null);
}

pub fn @"GET /jobs/:id"(allocator: std.mem.Allocator, id: u32) ![]const u8 {
    return getJobs(allocator, id);
}

pub fn @"GET /nodes"(allocator: std.mem.Allocator) ![]const u8 {
    return getNodes(allocator, null);
}

pub fn @"GET /nodes/:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return getNodes(allocator, name);
}

pub fn @"GET /partitions"(allocator: std.mem.Allocator) ![]const u8 {
    return getPartitions(allocator, null);
}

pub fn @"GET /partitions/:name"(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return getPartitions(allocator, name);
}
