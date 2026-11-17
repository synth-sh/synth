const std = @import("std");
const Provider = @import("../provider/provider.zig");
const Request = @import("request.zig");
const ContextPatch = @import("../core/request_context.zig");

pub fn onRetry(ptr: *anyopaque, info: Provider.RetryInfo) ?u64 {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.turn.hook_input.attempt = @intCast(info.attempt);
    self.turn.hook_input.retry_delay_ms = info.delay_ms;
    self.turn.hook_input.retry_allowed = info.allowed;
    self.turn.hook_input.http_status = info.status;
    self.turn.hook_input.error_type = self.hook_arena.allocator().dupe(u8, info.error_type) catch return null;
    self.turn.hook_input.error_message = self.hook_arena.allocator().dupe(u8, info.error_message) catch return null;
    const result = requestHook(self, .model_retry) catch return null;
    if (!(result.retry_allowed orelse info.allowed)) return null;
    return @min(result.retry_delay_ms orelse info.delay_ms, @import("../provider/retry.zig").max_delay_ms);
}

fn requestHook(self: *Request, event: @import("../core/hooks.zig").Event) !@import("../core/hooks.zig").Result {
    var runner = (self.turn.hooks orelse return .{}).*;
    runner.stop = &self.stop;
    var input = self.turn.hook_input;
    input.event = event;
    input.model = self.provider.model;
    input.provider = self.provider.name;
    const result = try runner.evaluate(self.hook_arena.allocator(), input);
    if (result.message) |message| if (runner.runtime) |runtime| try runtime.notice(message);
    return result;
}

pub fn prepare(self: *Request) !void {
    const a = self.hook_arena.allocator();
    const purpose = self.turn.hook_input.request_purpose;
    self.turn.hook_input.route = self.turn.model_policy.selected(purpose) orelse "";
    if (self.turn.hooks) |runner| {
        var input = self.turn.hook_input;
        input.event = .model_resolve;
        if (runner.hasMatching(a, input, false)) try describeContext(self);
    }
    const resolution = try requestHook(self, .model_resolve);
    if (resolution.model_route) |id| {
        if (id.len == 0) return error.ModelRouteDenied;
        self.turn.hook_input.route = id;
    }
    if (self.turn.hook_input.route.len > 0) {
        const route = try self.turn.model_policy.route(self.turn.hook_input.route, purpose);
        const owned = self.owned_backend orelse return error.ModelRoutingUnavailable;
        self.provider_mutex.lockUncancelable(self.io);
        defer self.provider_mutex.unlock(self.io);
        try owned.configure(route);
        self.provider = owned.provider();
        self.turn.settings.merge(route.settings);
    } else if (self.turn.model_policy.restrict_routes) return error.ModelRouteDenied;
    self.turn.hook_input.model = try a.dupe(u8, self.provider.model);
    self.turn.hook_input.provider = try a.dupe(u8, self.provider.name);
    self.turn.hook_input.request_settings = try std.json.Stringify.valueAlloc(a, self.turn.settings, .{ .emit_null_optional_fields = false });
    const settings = try requestHook(self, .model_settings);
    if (settings.settings) |encoded| self.turn.settings.merge(try std.json.parseFromSliceLeaky(@import("../core/model_policy.zig").Settings, a, encoded, .{}));
    try self.turn.settings.validate();
    self.turn.hook_input.request_settings = try std.json.Stringify.valueAlloc(a, self.turn.settings, .{ .emit_null_optional_fields = false });
    if (self.owned_backend) |owned| {
        self.provider_mutex.lockUncancelable(self.io);
        defer self.provider_mutex.unlock(self.io);
        try owned.settings(self.turn.settings);
        self.provider = owned.provider();
    } else if (self.turn.settings.reasoning_effort != null) return error.UnsupportedModelSettings;
    if (self.turn.hooks) |runner| {
        var input = self.turn.hook_input;
        input.event = .model_context;
        if (!runner.hasMatching(a, input, false)) return;
        try describeContext(self);
        const context = try requestHook(self, .model_context);
        if (context.context_edits != null or context.request_context != null) {
            if (purpose == .approval_judge) return error.ReviewerContextImmutable;
            self.prepared_conversation = .init(self.allocator);
            for (self.conversation.messages.items) |msg| try self.prepared_conversation.?.adoptMessage(try msg.clone(self.allocator));
            if (context.context_edits) |encoded| {
                const edits = try std.json.parseFromSliceLeaky([]const ContextPatch.Edit, a, encoded, .{});
                try ContextPatch.apply(&self.prepared_conversation.?, edits);
            }
            if (context.request_context) |encoded| {
                const patch = try std.json.parseFromSliceLeaky(ContextPatch.Patch, a, encoded, .{});
                if (patch.system) |value| try replaceTurnText(self, &self.turn.system, value);
                if (patch.instruction) |value| try replaceTurnText(self, &self.turn.instruction, value);
                if (patch.tools) |names| {
                    const selected = try ContextPatch.selectTools(a, self.turn.tools_json, names);
                    try replaceTurnText(self, &self.turn.tools_json, selected);
                    self.restricted_tools = true;
                }
                try ContextPatch.apply(&self.prepared_conversation.?, patch.messages);
            }
            try describeContext(self);
        }
    }
}

fn replaceTurnText(self: *Request, target: *[]const u8, value: []const u8) !void {
    const copy = try self.allocator.dupe(u8, value);
    self.allocator.free(target.*);
    target.* = copy;
}

fn describeContext(self: *Request) !void {
    const a = self.hook_arena.allocator();
    self.turn.hook_input.request_context = try std.json.Stringify.valueAlloc(a, if (self.prepared_conversation) |*prepared| prepared.messages.items else self.conversation.messages.items, .{ .emit_null_optional_fields = false });
    self.turn.hook_input.request_system = try a.dupe(u8, self.turn.system);
    self.turn.hook_input.request_instruction = try a.dupe(u8, self.turn.instruction);
    self.turn.hook_input.request_tools = try a.dupe(u8, self.turn.tools_json);
    var routes: std.ArrayList(std.json.Value) = .empty;
    for (self.turn.model_policy.routes) |route| {
        const encoded = try std.json.Stringify.valueAlloc(a, .{ .id = route.id, .provider = route.provider, .protocol = route.protocol, .endpoint = route.endpoint, .model = route.model, .context_limit = route.context_limit, .purposes = route.purposes }, .{});
        try routes.append(a, try std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{}));
    }
    self.turn.hook_input.request_routes = try std.json.Stringify.valueAlloc(a, routes.items, .{});
}
