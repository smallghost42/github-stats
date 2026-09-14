const builtin = @import("builtin");
const std = @import("std");
const version = @import("options").version;

const argparse = @import("argparse.zig");
const glob = @import("glob.zig");
const templateFill = @import("template.zig").fill;

const HttpClient = @import("http_client.zig");
const Statistics = @import("statistics.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
    // Even though we change it later, this is necessary to ensure that debug
    // logs aren't stripped in release builds.
    .log_level = .debug,
};

var log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    else => .warn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const embedded_overview_template = @embedFile("templates/overview.svg");
const embedded_languages_template = @embedFile("templates/languages.svg");
const embedded_contributions_template =
    @embedFile("templates/contributions.svg");

const Args = struct {
    access_token: ?[]const u8 = null,
    json_input_file: ?[]const u8 = null,
    json_output_file: ?[]const u8 = null,
    silent: bool = false,
    debug: bool = false,
    verbose: bool = false,
    exclude_repos: ?[]const u8 = null,
    exclude_langs: ?[]const u8 = null,
    exclude_private: bool = false,
    overview_output_file: ?[]const u8 = null,
    languages_output_file: ?[]const u8 = null,
    contributions_output_file: ?[]const u8 = null,
    overview_template: ?[]const u8 = null,
    languages_template: ?[]const u8 = null,
    contributions_template: ?[]const u8 = null,
    max_retries: ?usize = 25,
    version: bool = false,
    dump_overview_template: ?[]const u8 = null,
    dump_languages_template: ?[]const u8 = null,
    dump_contributions_template: ?[]const u8 = null,

    const Self = @This();

    pub fn init(main_init: std.process.Init) !Self {
        return try argparse.parse(main_init, Self, struct {
            fn errorCheck(a: Self, stderr: *std.Io.Writer) !bool {
                if ((a.access_token == null or a.access_token.?.len == 0) and
                    a.json_input_file == null and !a.version)
                {
                    try stderr.print(
                        "You must pass an input file or a GitHub token.\n",
                        .{},
                    );
                    return false;
                }
                return true;
            }
        }.errorCheck);
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Self).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .pointer => |pointer| switch (pointer.size) {
                            .slice => if (@field(self, field.name)) |p|
                                allocator.free(p),
                            else => comptime unreachable,
                        },
                        .bool, .int => {},
                        else => comptime unreachable,
                    }
                },
                .pointer => |p| switch (p.size) {
                    .slice => allocator.free(@field(self, field.name)),
                    else => comptime unreachable,
                },
                .bool, .int => {},
                else => comptime unreachable,
            }
        }
    }
};

fn overview(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    return templateFill(a, template, stats);
}

fn languages(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    const progress = try a.alloc([]const u8, stats.languages.count());
    const lang_list = try a.alloc([]const u8, stats.languages.count());
    for (
        stats.languages.keys(),
        stats.languages.values(),
        progress,
        lang_list,
        0..,
    ) |language, count, *progress_s, *lang_s, i| {
        const color = stats.language_colors.get(language);
        const percent =
            100 * if (stats.languages_total == 0)
                0.0
            else
                @as(f64, @floatFromInt(count)) /
                    @as(f64, @floatFromInt(stats.languages_total));
        progress_s.* = try std.fmt.allocPrint(a,
            \\<span style="
            \\  background-color: {s}; 
            \\  width: {d:.3}%;
            \\" class="progress-item"></span>
        , .{ color orelse "#000", percent });
        lang_s.* = try std.fmt.allocPrint(a,
            \\<li style="animation-delay: {d}ms;">
            \\  <svg 
            \\      xmlns="http://www.w3.org/2000/svg" 
            \\      class="octicon"
            \\      style="fill: {s};" 
            \\      viewBox="0 0 16 16" 
            \\      version="1.1" 
            \\      width="16" 
            \\      height="16"
            \\  ><path 
            \\      fill-rule="evenodd" 
            \\      d="M8 4a4 4 0 100 8 4 4 0 000-8z"
            \\  ></path></svg>
            \\  <span class="lang">{s}</span>
            \\  <span class="percent">{d:.2}%</span>
            \\</li>
            \\
        , .{ (i + 1) * 150, color orelse "#000", language, percent });
    }
    return templateFill(
        a,
        template,
        struct { lang_list: []const u8, progress: []const u8 }{
            .lang_list = try std.mem.concat(a, u8, lang_list),
            .progress = try std.mem.concat(a, u8, progress),
        },
    );
}

fn ptToString(a: std.mem.Allocator, x: f64, y: f64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:.1},{d:.1}", .{ x, y });
}

fn numToString(a: std.mem.Allocator, n: f64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d:.1}", .{n});
}

fn fmtCount(a: std.mem.Allocator, n: usize) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{d}", .{n});
    if (s.len <= 3) return s;
    var buf = try std.ArrayList(u8).initCapacity(a, s.len + (s.len - 1) / 3);
    defer buf.deinit(a);
    var i: usize = 0;
    for (s) |c| {
        if (i > 0 and (s.len - i) % 3 == 0) try buf.append(a, ',');
        try buf.append(a, c);
        i += 1;
    }
    return try buf.toOwnedSlice(a);
}

fn contributions(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
) ![]const u8 {
    const a = arena.allocator();
    const cx: f64 = 222;
    const cy: f64 = 125;
    const R: f64 = 62;
    const RAD: f64 = std.math.pi / 180.0;

    const items = [_]struct {
        label: []const u8,
        count: usize,
        color: []const u8,
        angle: f64,
        lx: f64,
        ly: f64,
        anchor: []const u8,
    }{
        .{
            .label = "Commits",
            .count = stats.commit_contributions,
            .color = "#3fb950",
            .angle = -90,
            .lx = 222,
            .ly = 52,
            .anchor = "middle",
        },
        .{
            .label = "Pull requests",
            .count = stats.pr_contributions,
            .color = "#a371f7",
            .angle = -18,
            .lx = 284,
            .ly = 100,
            .anchor = "start",
        },
        .{
            .label = "Issues",
            .count = stats.issue_contributions,
            .color = "#f85149",
            .angle = 54,
            .lx = 262,
            .ly = 180,
            .anchor = "start",
        },
        .{
            .label = "Code reviews",
            .count = stats.review_contributions,
            .color = "#ffa657",
            .angle = 126,
            .lx = 181,
            .ly = 180,
            .anchor = "end",
        },
        .{
            .label = "Repos created",
            .count = stats.repo_contributions,
            .color = "#58a6ff",
            .angle = 198,
            .lx = 158,
            .ly = 102,
            .anchor = "end",
        },
    };

    var total: usize = 0;
    var max_count: usize = 0;
    for (items) |it| {
        total += it.count;
        max_count = @max(max_count, it.count);
    }

    var outer: [items.len][2]f64 = undefined;
    var values: [items.len][2]f64 = undefined;
    for (items, 0..) |it, i| {
        const ct = std.math.cos(it.angle * RAD);
        const st = std.math.sin(it.angle * RAD);
        outer[i] = .{ cx + R * ct, cy + R * st };
        const frac: f64 =
            if (max_count == 0)
                0
            else
                @as(f64, @floatFromInt(it.count)) /
                    @as(f64, @floatFromInt(max_count));
        const r = frac * R;
        values[i] = .{ cx + r * ct, cy + r * st };
    }

    var body = std.ArrayList(u8).initCapacity(a, 4096) catch unreachable;
    errdefer body.deinit(a);

    const ring_fracs = [_]f64{ 0.25, 0.5, 0.75, 1.0 };
    for (ring_fracs) |f| {
        var ring_pts = std.ArrayList(u8).initCapacity(a, 128) catch unreachable;
        errdefer ring_pts.deinit(a);
        for (items, 0..) |it, i| {
            if (i > 0) try ring_pts.append(a, ' ');
            const x = cx + f * R * std.math.cos(it.angle * RAD);
            const y = cy + f * R * std.math.sin(it.angle * RAD);
            try ring_pts.appendSlice(a, try ptToString(a, x, y));
        }
        try body.appendSlice(a, "<polygon class=\"grid\" points=\"");
        try body.appendSlice(a, ring_pts.items);
        try body.appendSlice(a, "\"/>\n");
    }

    for (outer) |pt| {
        try body.appendSlice(a, "<line class=\"axis\" x1=\"");
        try body.appendSlice(a, try numToString(a, cx));
        try body.appendSlice(a, "\" y1=\"");
        try body.appendSlice(a, try numToString(a, cy));
        try body.appendSlice(a, "\" x2=\"");
        try body.appendSlice(a, try numToString(a, pt[0]));
        try body.appendSlice(a, "\" y2=\"");
        try body.appendSlice(a, try numToString(a, pt[1]));
        try body.appendSlice(a, "\"/>\n");
    }

    if (max_count > 0) {
        var pts = std.ArrayList(u8).initCapacity(a, 128) catch unreachable;
        errdefer pts.deinit(a);
        for (values, 0..) |pt, i| {
            if (i > 0) try pts.append(a, ' ');
            try pts.appendSlice(a, try ptToString(a, pt[0], pt[1]));
        }
        try body.appendSlice(
            a,
            "<polygon fill=\"#3fb950\" fill-opacity=\"0.18\" " ++
                "stroke=\"#3fb950\" stroke-width=\"2\" " ++
                "stroke-linejoin=\"round\" points=\"",
        );
        try body.appendSlice(a, pts.items);
        try body.appendSlice(a, "\"/>\n");
    }

    for (items, 0..) |it, i| {
        const pt = values[i];
        try body.appendSlice(a, "<circle cx=\"");
        try body.appendSlice(a, try numToString(a, pt[0]));
        try body.appendSlice(a, "\" cy=\"");
        try body.appendSlice(a, try numToString(a, pt[1]));
        try body.appendSlice(a, "\" r=\"3\" fill=\"");
        try body.appendSlice(a, it.color);
        try body.appendSlice(a, "\"/>\n");

        try body.appendSlice(a, "<text x=\"");
        try body.appendSlice(a, try numToString(a, it.lx));
        try body.appendSlice(a, "\" y=\"");
        try body.appendSlice(a, try numToString(a, it.ly));
        try body.appendSlice(a, "\" text-anchor=\"");
        try body.appendSlice(a, it.anchor);
        try body.appendSlice(a, "\"><tspan class=\"name\" fill=\"");
        try body.appendSlice(a, it.color);
        try body.appendSlice(a, "\">");
        try body.appendSlice(a, it.label);
        try body.appendSlice(a, " </tspan><tspan class=\"count\">");
        try body.appendSlice(a, try fmtCount(a, it.count));
        try body.appendSlice(a, "</tspan></text>\n");
    }

    try body.appendSlice(a, "<text x=\"222\" y=\"199\" text-anchor=\"middle\" class=\"total\">Total: ");
    try body.appendSlice(a, try fmtCount(a, total));
    try body.appendSlice(a, "</text>\n");

    return templateFill(
        a,
        template,
        struct { radar_body: []const u8 }{
            .radar_body = try body.toOwnedSlice(a),
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try Args.init(init);
    defer args.deinit(allocator);
    if (args.silent) {
        log_level = .err;
    } else if (args.debug) {
        log_level = .debug;
    } else if (args.verbose) {
        log_level = .info;
    }

    if (args.version) {
        const stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &.{});
        try writer.interface.print(
            \\GitHub Stats version {s}
            \\https://github.com/jstrieb/github-stats
            \\Created by Jacob Strieb
            \\
        , .{version});
        return;
    }

    if (args.dump_overview_template) |path| {
        try writeFile(io, path, embedded_overview_template);
        return;
    }

    if (args.dump_languages_template) |path| {
        try writeFile(io, path, embedded_languages_template);
        return;
    }

    if (args.dump_contributions_template) |path| {
        try writeFile(io, path, embedded_contributions_template);
        return;
    }

    const exclude_repos =
        if (args.exclude_repos) |exclude|
            try splitList(allocator, exclude, " ,\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_repos) |exclude| allocator.free(exclude);
    const exclude_langs =
        if (args.exclude_langs) |exclude|
            try splitList(allocator, exclude, ",\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_langs) |exclude| allocator.free(exclude);

    var stats: Statistics = if (args.json_input_file) |path| stats: {
        const data = try readFile(allocator, io, path);
        defer allocator.free(data);
        break :stats try Statistics.initFromJson(allocator, data);
    } else if (args.access_token) |access_token| stats: {
        std.log.info("Collecting statistics from GitHub API", .{});
        var client: HttpClient = try .init(allocator, io, access_token);
        defer client.deinit();
        break :stats try Statistics.init(
            &client,
            allocator,
            io,
            args.max_retries,
        );
    } else unreachable;
    defer stats.deinit(allocator);

    if (args.json_output_file) |path| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try writeFile(
            io,
            path,
            try std.json.Stringify.valueAlloc(
                arena.allocator(),
                stats,
                .{ .whitespace = .indent_2 },
            ),
        );
    }

    var aggregate_stats: struct {
        languages: std.array_hash_map.String(u64),
        language_colors: std.array_hash_map.String([]const u8),
        contributions: usize,
        name: []const u8,
        languages_total: usize = 0,
        stars: usize = 0,
        forks: usize = 0,
        lines_changed: usize = 0,
        views: usize = 0,
        repos: usize = 0,
        commit_contributions: usize = 0,
        pr_contributions: usize = 0,
        issue_contributions: usize = 0,
        review_contributions: usize = 0,
        repo_contributions: usize = 0,
    } = .{
        .contributions = stats.repo_contributions +
            stats.issue_contributions +
            stats.commit_contributions +
            stats.pr_contributions +
            stats.review_contributions,
        .commit_contributions = stats.commit_contributions,
        .pr_contributions = stats.pr_contributions,
        .issue_contributions = stats.issue_contributions,
        .review_contributions = stats.review_contributions,
        .repo_contributions = stats.repo_contributions,
        .languages = try .init(allocator, &.{}, &.{}),
        .language_colors = try .init(allocator, &.{}, &.{}),
        .name = stats.name,
    };
    defer aggregate_stats.languages.deinit(allocator);
    defer aggregate_stats.language_colors.deinit(allocator);
    for (stats.repositories) |repository| {
        if (glob.matchAny(exclude_repos orelse &.{}, repository.name) or
            (args.exclude_private and repository.private))
        {
            continue;
        }
        aggregate_stats.stars += repository.stars;
        aggregate_stats.forks += repository.forks;
        aggregate_stats.lines_changed += repository.lines_changed;
        aggregate_stats.views += repository.views;
        aggregate_stats.repos += 1;
        if (repository.languages) |langs| for (langs) |language| {
            if (glob.matchAny(exclude_langs orelse &.{}, language.name)) {
                continue;
            }
            if (language.color) |color| {
                try aggregate_stats.language_colors.put(
                    allocator,
                    language.name,
                    color,
                );
            }
            var total = aggregate_stats.languages.get(language.name) orelse 0;
            total += language.size;
            try aggregate_stats.languages.put(allocator, language.name, total);
            aggregate_stats.languages_total += language.size;
        };
    }
    aggregate_stats.languages.sort(struct {
        values: @TypeOf(aggregate_stats.languages.values()),
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            // Sort in reverse order
            return self.values[a] > self.values[b];
        }
    }{ .values = aggregate_stats.languages.values() });

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try writeFile(
            io,
            args.overview_output_file orelse "overview.svg",
            try overview(
                &arena,
                aggregate_stats,
                if (args.overview_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_overview_template,
            ),
        );

        try writeFile(
            io,
            args.languages_output_file orelse "languages.svg",
            try languages(
                &arena,
                aggregate_stats,
                if (args.languages_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_languages_template,
            ),
        );

        try writeFile(
            io,
            args.contributions_output_file orelse "contributions.svg",
            try contributions(
                &arena,
                aggregate_stats,
                if (args.contributions_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_contributions_template,
            ),
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    std.log.info("Reading data from '{s}'", .{path});
    const in =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) in.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = in.reader(io, &read_buffer);
    return try (&reader.interface).allocRemaining(allocator, .unlimited);
}

fn writeFile(
    io: std.Io,
    path: []const u8,
    data: []const u8,
) !void {
    std.log.info("Writing data to '{s}'", .{path});
    const out =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdout()
        else
            try std.Io.Dir.cwd().createFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) out.close(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &write_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn splitList(
    allocator: std.mem.Allocator,
    original: []const u8,
    separators: []const u8,
) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer list.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, original, separators);
    while (iterator.next()) |pattern| {
        try list.append(allocator, std.mem.trim(u8, pattern, " "));
    }
    return try list.toOwnedSlice(allocator);
}
