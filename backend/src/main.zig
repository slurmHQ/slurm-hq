const std = @import("std");
const slurm = @import("slurm");
const tk = @import("tokamak");
const api = @import("api.zig");

fn cors(children: []const tk.Route) tk.Route {
    const H = struct {
        fn handle(ctx: *tk.Context) anyerror!void {
            ctx.res.header("Access-Control-Allow-Origin", "*");
            ctx.res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE");

            // if (ctx.req.method == .OPTIONS) {
            //     try ctx.res.send("", .{});
            //     return;
            // }

            try ctx.next();
        }
    };

    return .{ .handler = &H.handle, .children = children };
}

const routes: []const tk.Route = &.{
    cors(&.{
        .group("/api", &.{.router(api)}),
    }),
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer _ = arena.deinit();

    slurm.init(null);

    const server_opts: tk.ServerOptions = .{
        .listen = .{
            .hostname = "0.0.0.0",
            .port = 8000,
        },
    };
    var server: tk.Server = try .init(allocator, routes, server_opts);
    defer server.deinit();

    try server.start();
}
