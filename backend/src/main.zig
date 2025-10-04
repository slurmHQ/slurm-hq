const std = @import("std");
const slurm = @import("slurm");
const tk = @import("tokamak");
const api = @import("api.zig");

const routes: []const tk.Route = &.{
    .group("/api", &.{.router(api)}),
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();

    const server_opts: tk.ServerOptions = .{
        .listen = .{
            .hostname = "0.0.0.0",
            .port = 8080,
        },
    };
    var server: tk.Server = try .init(allocator, routes, server_opts);
    defer server.deinit();

    try server.start();
}
