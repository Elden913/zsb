const std = @import("std");
const Io = std.Io;

pub const pulse = @cImport({
    @cInclude("pulse/pulseaudio.h");
});
const c = @cImport({
    @cInclude("time.h");
});
const dsb = @import("dsb");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const zdwl = wayland.client.zdwl;
const posix = std.posix;
const linux = std.os.linux;
var io: std.Io = undefined;

const Workspace = struct {
    active: bool,
    urgent: bool,
    shown: bool,
};
 
const Settings = struct {
    background:      u32 = 0xFF0f1416,
    color:           u32 = 0xFFdee3e6,
    tag_focused_fg:  u32 = 0xFFdee3e6,
    tag_focused_bg:  u32 = 0xFF252b2d,
    tag_urgent_fg:   u32 = 0xFF690005,
    tag_urgent_bg:   u32 = 0xFFffb4ab,
    tag_inactive_fg: u32 = 0xFFbfc8cc,
    tag_inactive_bg: u32 = 0xFF1b2023,

    idle: u32 = 0x271D1B,
    info: u32 = 0xFFB5A0,
    good: u32 = 0xD9C58D,
    critical: u32 = 0xFFB4AB,

    tag_width: i32 = 60,
    separator_gap: i32 = 15,
    separator_width: i32 = 3,
    separator_color: u32 = 0xFF252b2d,
    height: i32 = 25,
};

const BUF_LEN: usize = 128;
const SCALE: i32 = 2;

var scaled_height: i32 = 0;
var scaled_width: i32 = 0;
var gpa: std.heap.DebugAllocator(.{}) = .init;

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    output: ?*wl.Output = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    dwl_ipc: ?*zdwl.IpcManagerV2 = null,
};
pub const State = struct {
    buffer: *wl.Buffer = undefined,
    font: *fcft.Font,
    baseline: i32,
    image: ?*pixman.Image,
    surface: *wl.Surface,

    configured: bool,
    running: bool,

    volumefd: i32,
    volume: std.atomic.Value(u32),
    volume_muted: std.atomic.Value(bool),

    battery_charge_full: i32,
    battery_current_now_file: Io.File,
    battery_charge_now_file: Io.File,
    battery_status_file: Io.File,

    workspacefd: i32,
    workspaces: []Workspace,

    prev_tear_left: i32,
    prev_tear_right: i32,

    settings: Settings,
};

fn dwl_ipc_manager_listener(dwl_ipc_manager: *zdwl.IpcManagerV2, event: zdwl.IpcManagerV2.Event, state: *State) void {
    _ = dwl_ipc_manager;
    switch (event) {
        .tags => |ev| {
            state.workspaces = gpa.allocator().alloc(Workspace, ev.amount) catch @panic("couldn't allocate workspaces");
        },
        else => return,
    }
}

fn dwl_ipc_output_listener(dwl_output: *zdwl.IpcOutputV2, event: zdwl.IpcOutputV2.Event, state: *State) void {
    _ = dwl_output;
    switch (event) {
        .tag => |ev| {
            const active = ev.state == .active;
            const urgent = ev.state == .urgent;

            state.workspaces[ev.tag] = Workspace{
                .active = active,
                .urgent = urgent,
                .shown = (active or urgent) or ev.clients > 0,
            };
            const val: [8]u8 = @bitCast(@as(u64, 1));
            panic_errno_usize(std.os.linux.write(state.workspacefd, &val, 8));
        },
        else => return,
    }
}

fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |ev| {
            if (std.mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(ev.name, wl.Compositor, ev.version) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(ev.name, wl.Shm, ev.version) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                globals.output = registry.bind(ev.name, wl.Output, ev.version) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                globals.layer_shell = registry.bind(ev.name, zwlr.LayerShellV1, ev.version) catch return;
            } else if (std.mem.orderZ(u8, ev.interface, zdwl.IpcManagerV2.interface.name) == .eq) {
                globals.dwl_ipc = registry.bind(ev.name, zdwl.IpcManagerV2, ev.version) catch return;
            }
        },
        .global_remove => |ev| {
            _ = ev;
        },
    }
}

fn layer_surface_listener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, state: *State) void {
    switch (event) {
        .configure => |config| {
            layer_surface.ackConfigure(config.serial);
            state.surface.commit();
            scaled_width = @as(i32, @intCast(config.width)) * SCALE;
            state.configured = true;
        },
        .closed => {
            state.running = false;
        },
    }
}
const fcft = @import("fcft");
const pixman = @import("pixman");
const unicode = std.unicode;
var font_names = [_][*:0]const u8{ "Iosvmata Nerd Font:size=30", "Noto Color Emoji:size=18" };

inline fn pixman_color_from_u32(color: u32) pixman.Color {
    const alpha = (color & 0xff000000) >> 24;
    const red = (color & 0x00ff0000) >> 16;
    const green = (color & 0x0000ff00) >> 8;
    const blue = color & 0x000000ff;

    const a = alpha | alpha << 8;
    const r = red | red << 8;
    const g = green | green << 8;
    const b = blue | blue << 8;
    return .{
        .alpha = @as(u16, @intCast(a)),
        .red = @as(u16, @intCast(r)),
        .green = @as(u16, @intCast(g)),
        .blue = @as(u16, @intCast(b)),
    };
}

const SolidFillCache = struct {
    const Entry = struct {
        hex_color: u32,
        image: *pixman.Image,
    };

    entries: [16]Entry = undefined,
    count: usize = 0,

    pub fn get(self: *SolidFillCache, hex_color: u32) *pixman.Image {
        for (self.entries[0..self.count]) |entry| {
            if (entry.hex_color == hex_color) return entry.image;
        }
        if (self.count < 16) {
            const pix_color = pixman_color_from_u32(hex_color);
            const img = pixman.Image.createSolidFill(&pix_color).?;
            self.entries[self.count] = .{ .hex_color = hex_color, .image = img };
            self.count += 1;
            return img;
        }

        const pix_color = pixman_color_from_u32(hex_color);
        return pixman.Image.createSolidFill(&pix_color).?;
    }
};
var solid_fill_cache = SolidFillCache{};

fn draw_char_centered(state: *State, ch: u8, x: i32, color: u32) void {
    const src_paint = solid_fill_cache.get(color);
    const glyph = state.font.rasterizeCharUtf32(ch, .default) catch return;
    pixman.Image.composite32(.over, src_paint, glyph.pix, state.image.?, 0, 0, 0, 0, x - @divFloor(glyph.width, 2), state.baseline - glyph.y, glyph.width, glyph.height);
}

fn renderTextRun(state: *State, text_run: *const fcft.TextRun, x: i32, color: u32) void {
    const src_paint = solid_fill_cache.get(color);
    var xpos = x;
    for (text_run.glyphs, 0..text_run.count) |glyph, _| {
        pixman.Image.composite32(.over, src_paint, glyph.pix, state.image.?, 0, 0, 0, 0, xpos + glyph.x, state.baseline - glyph.y, glyph.width, glyph.height);
        xpos += glyph.advance.x;
    }
}

fn createTextRun(state: *State, text: []const u8) !struct { *const fcft.TextRun, i32 } {
    var u32_buf: [BUF_LEN]u32 = undefined;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| {
        u32_buf[i] = @as(u32, cp);
        i += 1;
    }
    const text_run = try state.font.rasterizeTextRunUtf32(u32_buf[0..i], .default);
    var width: i32 = 0;
    for (text_run.glyphs, 0..text_run.count) |g, _| {
        width += @intCast(g.advance.x);
    }
    return .{ text_run, width };
}

fn draw_volume(state: *State, buf: []u8, right: i32) !i32 {
    var text: []u8 = undefined;
    var color: u32 = undefined;
    if (state.volume_muted.load(.seq_cst)) {
        text = try std.fmt.bufPrintZ(buf, "󰖁 {}%", .{state.volume.load(.seq_cst)});
        color = state.settings.idle;
    } else {
        text = try std.fmt.bufPrintZ(buf, "󰕾 {}%", .{state.volume.load(.seq_cst)});
        color = state.settings.color;
    }
    const vol_text_run, const vol_width = try createTextRun(state, text);
    renderTextRun(state, vol_text_run, scaled_width - vol_width - right, color);
    return vol_width;
}

fn draw_battery(state: *State, buf: []u8, right: i32) !i32 {
    const charge_now_len = try Io.File.readPositionalAll(state.battery_charge_now_file, io, buf, 0);
    const charge_now = try std.fmt.parseInt(i32, buf[0 .. charge_now_len - 1], 10);
    const current_now_len = try Io.File.readPositionalAll(state.battery_current_now_file, io, buf, 0);
    const current_now = try std.fmt.parseInt(i32, buf[0 .. current_now_len - 1], 10);
    _ = try Io.File.readPositionalAll(state.battery_status_file, io, buf[0..1], 0);
    const battery_percentage = @divFloor(charge_now * 100, state.battery_charge_full);
    var text: []u8 = undefined;
    var color: u32 = undefined;
    switch (buf[0]) {
        'C' => {
            const charge_remaining = state.battery_charge_full - charge_now;
            const hrs = @divFloor(charge_remaining, current_now);
            const mnts = @divFloor(@mod(charge_remaining, current_now) * 60, current_now);
            text = try std.fmt.bufPrintZ(buf, "󰂄 {}% > {}h {}m", .{ battery_percentage, hrs, mnts });
            color = state.settings.good;
        },
        'D' => {
            const hrs = @divFloor(charge_now, current_now);
            const mnts = @divFloor(@mod(charge_now, current_now) * 60, current_now);
            text = try std.fmt.bufPrintZ(buf, "󱊢 {}% > {}h {}m", .{ battery_percentage, hrs, mnts });
            color = state.settings.color;
        },
        'F' => {
            text = try std.fmt.bufPrintZ(buf, "󰁹 {}% > full", .{battery_percentage});
            color = state.settings.color;
        },
        else => {
            text = try std.fmt.bufPrintZ(buf, "NO INFO BAT", .{});
            color = state.settings.critical;
        },
    }
    const battery_text_run, const battery_width = try createTextRun(state, text);
    renderTextRun(state, battery_text_run, scaled_width - battery_width - right, color);
    return battery_width;
}

fn draw_separator(state: *State, buf: []u8, right: i32) i32 {
    _ = buf;
    _ = pixman.fill(state.image.?.getData().?, scaled_width, 32, scaled_width - right - state.settings.separator_width - state.settings.separator_gap, 0, state.settings.separator_width, scaled_height, state.settings.separator_color);
    return state.settings.separator_gap * 2 + state.settings.separator_width;
}
fn draw_time(state: *State, buf: []u8, right: i32) !i32 {
    const time = c.time(null);
    const tm = c.localtime(&time);
    const len = c.strftime(
        &buf[0],
        BUF_LEN,
        "%a %d/%m %H:%M",
        tm,
    );
    const time_text_run, const time_width = try createTextRun(state, buf[0..len]);
    renderTextRun(state, time_text_run, scaled_width - time_width - right, state.settings.color);
    return time_width;
}

fn draw_right(state: *State, buf: []u8) !void {
    _ = pixman.fill(state.image.?.getData().?, scaled_width, 32, 0, 0, scaled_width, scaled_height, state.settings.background);
    var right: i32 = 0;
    right += state.settings.separator_gap;
    right += try draw_time(state, buf, right);
    right += draw_separator(state, buf, right);
    right += try draw_volume(state, buf, right);
    right += draw_separator(state, buf, right);
    right += try draw_battery(state, buf, right);

    const max_tear = @max(state.prev_tear_right, right);
    _ = pixman.fill(state.image.?.getData().?, scaled_width, 32, scaled_width - max_tear, 0, max_tear - right, scaled_height, state.settings.background);

    state.surface.damageBuffer(scaled_width - max_tear, 0, max_tear, scaled_height);
    state.prev_tear_right = max_tear;
    state.surface.attach(state.buffer, 0, 0);
    state.surface.commit();
}

fn draw_left(state: *State) !void {
    var n_shown: i32 = 0;
    for (state.workspaces, 0..state.workspaces.len) |wp, i| {
        if (wp.shown) {
            var bgcol: u32 = state.settings.tag_inactive_bg;
            var fgcol: u32 = state.settings.tag_inactive_fg;
            if (wp.active) {
                bgcol = state.settings.tag_focused_bg;
                fgcol = state.settings.tag_focused_fg;
            } else if (wp.urgent) {
                bgcol = state.settings.tag_urgent_bg;
                fgcol = state.settings.tag_urgent_fg;
            }
            _ = pixman.fill(state.image.?.getData().?, scaled_width, 32, @intCast(n_shown * state.settings.tag_width), 0, state.settings.tag_width, scaled_height, bgcol);
            draw_char_centered(state, @as(u8, @intCast(i + 1)) + '0', @intCast(n_shown * state.settings.tag_width + @divFloor(state.settings.tag_width, 2)), fgcol);
            n_shown += 1;
        }
    }
    const max_tear = @max(state.prev_tear_left, n_shown * state.settings.tag_width);
    _ = pixman.fill(state.image.?.getData().?, scaled_width, 32, n_shown * state.settings.tag_width, 0, max_tear, scaled_height, state.settings.background);
    state.surface.damageBuffer(0, 0, max_tear, scaled_height);
    state.prev_tear_left = max_tear;
    state.surface.attach(state.buffer, 0, 0);
    state.surface.commit();
}

pub inline fn panic_errno_usize(errno: usize) void {
    if (linux.errno(errno) != .SUCCESS) {
        std.debug.panic("err: {}", .{linux.errno(errno)});
    }
}
pub inline fn panic_errno(errno: i32) void {
    const err = linux.errno(@as(usize, @intCast(errno)));
    if (err != .SUCCESS) {
        std.debug.panic("err: {}", .{err});
    }
}
const pulse_listener = @import("pulse_listener.zig");
pub fn main(init: std.process.Init) !void {
    var buf: [BUF_LEN]u8 = undefined;
    io = init.io;
    defer {
        for (solid_fill_cache.entries[0..solid_fill_cache.count]) |entry| {
            _ = entry.image.unref();
        }
    }
    const epfd: i32 = @intCast(linux.epoll_create());
    panic_errno(epfd);
    defer _ = linux.close(epfd);
    const timerfd: i32 = @intCast(linux.timerfd_create(linux.TIMERFD_CLOCK.REALTIME, .{ .NONBLOCK = true }));
    defer _ = linux.close(timerfd);
    panic_errno(timerfd);
    var time_spec: linux.timespec = undefined;
    panic_errno_usize(linux.clock_gettime(.REALTIME, &time_spec));
    const timer_flag = linux.itimerspec{
        .it_interval = .{ .sec = 1, .nsec = 0 },
        .it_value = .{ .sec = time_spec.sec + 1, .nsec = 0 },
    };

    panic_errno_usize(linux.timerfd_settime(timerfd, .{ .ABSTIME = true }, &timer_flag, null));
    var timer_epoll_event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = @as(i32, @intCast(timerfd)) } };
    panic_errno_usize(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, timerfd, &timer_epoll_event));

    const pulsefd: i32 = @intCast(linux.eventfd(0, linux.EFD.NONBLOCK));
    defer _ = linux.close(pulsefd);

    var pulse_epoll_event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = pulsefd } };
    panic_errno_usize(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, pulsefd, &pulse_epoll_event));
    const workspacefd: i32 = @intCast(linux.eventfd(0, linux.EFD.NONBLOCK));
    defer _ = linux.close(workspacefd);

    var workspace_epoll_event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = workspacefd } };
    panic_errno_usize(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, workspacefd, &workspace_epoll_event));

    if (!fcft.init(.auto, false, .info)) {
        return error.FcftInitFailed;
    }
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const wlfd = display.getFd();
    var wl_epoll_event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = @as(i32, @intCast(wlfd)) } };
    panic_errno_usize(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wlfd, &wl_epoll_event));

    const registry = try display.getRegistry();
    defer registry.destroy();
    var globals = Globals{};
    registry.setListener(*Globals, registry_listener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const shm = globals.shm orelse return error.NoWlShm;
    defer shm.destroy();
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    defer compositor.destroy();
    const output = globals.output orelse return error.NoWlOutput;
    defer output.destroy();

    const surface = try compositor.createSurface();
    surface.setBufferScale(SCALE);
    defer surface.destroy();
    const layer_shell = globals.layer_shell orelse return error.NoZwlrShellV1;
    defer layer_shell.destroy();
    const layer_surface = try layer_shell.getLayerSurface(surface, output, .top, "status_bar");
    defer layer_surface.destroy();
    const font = try fcft.Font.fromName(font_names[0..], null);

    const battery_charge_full = blk: {
        const battery_charge_full_file = try Io.Dir.openFileAbsolute(io, "/sys/class/power_supply/BAT1/charge_full", .{});
        defer battery_charge_full_file.close(io);
        const battery_charge_full_len = try Io.File.readPositionalAll(battery_charge_full_file, io, &buf, 0);
        break :blk try std.fmt.parseInt(i32, buf[0 .. battery_charge_full_len - 1], 10);
    };

    const settings_parsed: ?Settings = blk: {
        const config_dir = Io.Dir.openDirAbsolute(io, "/home/elden/.config/zsb/", .{}) catch {
            break :blk null;
        };
        const config = Io.Dir.readFileAllocOptions(config_dir, io, "settings.zon", gpa.allocator(), .unlimited, .of(u8), 0) catch {
            break :blk null;
        };
        defer gpa.allocator().free(config);

        break :blk try std.zon.parse.fromSliceAlloc(Settings, gpa.allocator(), config, null, .{.ignore_unknown_fields = true});
    };
    var settings: Settings = undefined;
    if (settings_parsed) |sp| {
        settings = sp;
    }
    else {
        settings = Settings {};
    }
    scaled_height = settings.height * SCALE;

    var state = State{
        .surface = surface,
        .configured = false,
        .baseline = @divFloor(scaled_height, 2) + @divFloor(font.ascent, 2) - @divFloor(font.descent, 2),
        .running = true,
        .font = font,
        .image = null,
        .battery_charge_full = battery_charge_full,
        .battery_charge_now_file = try Io.Dir.openFileAbsolute(io, "/sys/class/power_supply/BAT1/charge_now", .{}),
        .battery_current_now_file = try Io.Dir.openFileAbsolute(io, "/sys/class/power_supply/BAT1/current_now", .{}),
        .battery_status_file = try Io.Dir.openFileAbsolute(io, "/sys/class/power_supply/BAT1/status", .{}),
        .volumefd = pulsefd,
        .volume = std.atomic.Value(u32).init(0),
        .volume_muted = std.atomic.Value(bool).init(true),
        .workspacefd = workspacefd,
        .workspaces = undefined,
        .prev_tear_left = 0,
        .prev_tear_right = 0,
        .settings = settings,
    };
    defer state.battery_charge_now_file.close(io);
    defer state.battery_current_now_file.close(io);
    defer state.battery_status_file.close(io);
    defer gpa.allocator().free(state.workspaces);
    defer {
        if (settings_parsed) |sp| {
            std.zon.parse.free(gpa.allocator(), sp);
        }
    }
    const dwl_ipc = globals.dwl_ipc orelse return error.NoWldwl_ipc;
    defer dwl_ipc.destroy();
    dwl_ipc.setListener(*State, &dwl_ipc_manager_listener, &state);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const dwl_output = try dwl_ipc.getOutput(output);
    dwl_output.setListener(*State, &dwl_ipc_output_listener, &state);
    
    const m = pulse.pa_threaded_mainloop_new();
    if (m == null) return error.PulseAudioMainloopFailed;
    defer pulse.pa_threaded_mainloop_free(m);

    const mapi = pulse.pa_threaded_mainloop_get_api(m);
    const pc = pulse.pa_context_new(mapi, "Zig Volume Listener");
    if (pc == null) return error.PulseAudioContextFailed;
    defer pulse.pa_context_unref(pc);

    pulse.pa_context_set_state_callback(pc, pulse_listener.contextStateCallback, &state);

    if (pulse.pa_context_connect(pc, null, pulse.PA_CONTEXT_NOFLAGS, null) < 0) {
        return error.PulseAudioConnectFailed;
    }

    if (pulse.pa_threaded_mainloop_start(m) < 0) {
        return error.PulseAudioThreadFailed;
    }
    defer pulse.pa_threaded_mainloop_stop(m);

    layer_surface.setAnchor(.{
        .left = true,
        .top = true,
        .right = true,
    });
    layer_surface.setExclusiveZone(state.settings.height);
    layer_surface.setListener(*State, &layer_surface_listener, &state);

    surface.commit();
    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    const stride = scaled_width * 4;
    const size = stride * scaled_height;
    const buffer, state.image = blk: {
        const fd = try posix.memfd_create("dsb", 0);
        if (posix.errno(posix.system.ftruncate(fd, size)) != .SUCCESS) return error.FtruncateFailed;
        const data = try posix.mmap(
            null,
            @as(usize, @intCast(size)),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        const pool = try shm.createPool(fd, size);
        defer pool.destroy();

        break :blk .{ try pool.createBuffer(0, scaled_width, scaled_height, stride, wl.Shm.Format.argb8888), pixman.Image.createBits(.a8r8g8b8, scaled_width, scaled_height, @ptrCast(data), stride) orelse return error.PixmanCreateBitsFailed };
    };
    state.buffer = buffer;
    defer _ = state.image.?.unref();
    defer state.buffer.destroy();
    try draw_left(&state);
    try draw_right(&state, &buf);
    var epoll_events: [4]linux.epoll_event = undefined;
    var fd_buf: [8]u8 = undefined;
    while (state.running) {
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
        if (display.flush() != .SUCCESS) return error.FlushFailed;
        const n = linux.epoll_wait(epfd, &epoll_events, 4, -1);
        var wl_display_read = false;
        for (0..n) |o| {
            if (epoll_events[o].data.fd == wlfd) {
                wl_display_read = true;
            } else if (epoll_events[o].data.fd == timerfd) {
                panic_errno_usize(linux.read(timerfd, &fd_buf, 8));
                try draw_right(&state, &buf);
            } else if (epoll_events[o].data.fd == state.workspacefd) {
                panic_errno_usize(linux.read(state.workspacefd, &fd_buf, 8));
                try draw_left(&state);
            } else if (epoll_events[o].data.fd == state.volumefd) {
                panic_errno_usize(linux.read(state.volumefd, &fd_buf, 8));
                try draw_right(&state, &buf);
            }
        }
        if (wl_display_read) {
            if (display.readEvents() != .SUCCESS) return error.ReadEventsFailed;
            if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        } else {
            display.cancelRead();
        }
    }
}
