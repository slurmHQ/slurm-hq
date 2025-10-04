const std = @import("std");
const slurm = @import("slurm");
const json = @import("json.zig");
const Allocator = std.mem.Allocator;

fn getNodes(allocator: Allocator, name: ?[]const u8) ![]const u8 {
    _ = slurm.init(null);

    const node_resp = try slurm.loadNodes();
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

fn getJobs(allocator: Allocator, id: ?u32) ![]const u8 {
    _ = slurm.init(null);

    const data = try slurm.loadJobs();

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
