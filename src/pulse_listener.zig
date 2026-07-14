const std = @import("std");
const main = @import("main.zig");
const pulse = main.pulse;

export fn sinkInfoCallback(
    _: ?*pulse.pa_context,
    i: [*c]const pulse.pa_sink_info,
    eol: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (eol > 0 or i == null) return;

    const state: *main.State = @ptrCast(@alignCast(userdata));

    const avg_vol = pulse.pa_cvolume_avg(&i.*.volume);
    const vol_pct = (avg_vol * 100) / pulse.PA_VOLUME_NORM;

    state.vol.store(vol_pct, .seq_cst);

    const muted = i.*.mute != 0;

    state.vol_muted.store(muted, .seq_cst);

    const val: [8]u8 = @bitCast(@as(u64, 1));
    
    main.panic_errno_usize(std.os.linux.write(state.volfd, &val, 8));
}

export fn subscribeCallback(
    c: ?*pulse.pa_context,
    t: pulse.pa_subscription_event_type_t,
    index: u32,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const facility = t & pulse.PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
    const event_type = t & pulse.PA_SUBSCRIPTION_EVENT_TYPE_MASK;

    if (facility == pulse.PA_SUBSCRIPTION_EVENT_SINK and event_type == pulse.PA_SUBSCRIPTION_EVENT_CHANGE) {
        const op = pulse.pa_context_get_sink_info_by_index(
            c,
            index,
            sinkInfoCallback,
            userdata,
        );
        if (op != null) pulse.pa_operation_unref(op);
    }
}

pub export fn contextStateCallback(c: ?*pulse.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    const state = pulse.pa_context_get_state(c);
    switch (state) {
        pulse.PA_CONTEXT_READY => {
            pulse.pa_context_set_subscribe_callback(c, subscribeCallback, userdata);
            
            const op_sub = pulse.pa_context_subscribe(
                c,
                pulse.PA_SUBSCRIPTION_MASK_SINK,
                null,
                null,
            );
            if (op_sub != null) pulse.pa_operation_unref(op_sub);
            const op_info = pulse.pa_context_get_sink_info_list(c, sinkInfoCallback, userdata);
            if (op_info != null) pulse.pa_operation_unref(op_info);
        },
        pulse.PA_CONTEXT_FAILED, pulse.PA_CONTEXT_TERMINATED => {
            std.debug.print("pulseaudio disconnected\n", .{});
        },
        else => {},
    }
}

