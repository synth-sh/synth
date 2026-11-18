const std = @import("std");

pub const max_temperature: f32 = 2;
pub const max_probability: f32 = 1;
pub const max_tokens: u32 = 1_048_576;
pub const max_top_k: u32 = 1_048_576;
pub const max_context_limit: u32 = 1_048_576;
pub const max_penalty: f32 = 2;
pub const max_stops = 16;
pub const max_stop_bytes = 4096;
pub const max_attempts = 4;
pub const max_retry_delay_ms = @import("../provider/retry.zig").max_delay_ms;
pub const default_review_ms = 30_000;
pub const max_review_ms = 300_000;
pub const effort_levels = [_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh" };

pub const Purpose = enum { agent, approval_judge, compaction };
pub const Fallback = enum { ask, deny };

pub const Settings = struct {
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    top_k: ?u32 = null,
    seed: ?u32 = null,
    frequency_penalty: ?f32 = null,
    presence_penalty: ?f32 = null,
    stop: ?[]const []const u8 = null,
    max_output_tokens: ?u32 = null,
    reasoning_effort: ?[]const u8 = null,
    attempts: ?u8 = null,
    retry_delay_ms: ?u32 = null,

    pub fn validate(self: Settings) !void {
        if (self.temperature) |v| if (!std.math.isFinite(v) or v < 0 or v > max_temperature) return error.InvalidModelSettings;
        if (self.top_p) |v| if (!std.math.isFinite(v) or v <= 0 or v > max_probability) return error.InvalidModelSettings;
        if (self.top_k) |v| if (v == 0 or v > max_top_k) return error.InvalidModelSettings;
        inline for (.{ "frequency_penalty", "presence_penalty" }) |field| if (@field(self, field)) |v| {
            if (!std.math.isFinite(v) or v < -max_penalty or v > max_penalty) return error.InvalidModelSettings;
        };
        if (self.stop) |values| {
            if (values.len == 0 or values.len > max_stops) return error.InvalidModelSettings;
            for (values) |value| if (value.len == 0 or value.len > max_stop_bytes) return error.InvalidModelSettings;
        }
        if (self.max_output_tokens) |v| if (v == 0 or v > max_tokens) return error.InvalidModelSettings;
        if (self.attempts) |v| if (v == 0 or v > max_attempts) return error.InvalidModelSettings;
        if (self.retry_delay_ms) |v| if (v > max_retry_delay_ms) return error.InvalidModelSettings;
        if (self.reasoning_effort) |v| {
            for (effort_levels) |allowed| {
                if (std.mem.eql(u8, v, allowed)) break;
            } else return error.InvalidModelSettings;
        }
    }

    pub fn merge(self: *Settings, other: Settings) void {
        inline for (std.meta.fields(Settings)) |field| {
            if (@field(other, field.name)) |value| @field(self, field.name) = value;
        }
    }
};

pub const Route = struct {
    id: []const u8,
    provider: enum { openai, ollama },
    protocol: enum { chat, responses, messages } = .chat,
    endpoint: []const u8,
    model: []const u8,
    context_limit: u32 = 0,
    api_key: ?[]const u8 = null,
    purposes: []const Purpose = &.{ .agent, .approval_judge, .compaction },
    settings: Settings = .{},
};

pub const Policy = struct {
    routes: []const Route = &.{},
    agent: ?[]const u8 = null,
    approval_judge: ?[]const u8 = null,
    compaction: ?[]const u8 = null,
    restrict_routes: bool = false,
    reviewer_timeout_ms: u32 = default_review_ms,
    reviewer_fallback: Fallback = .ask,

    pub fn selected(self: Policy, purpose: Purpose) ?[]const u8 {
        return switch (purpose) {
            .agent => self.agent,
            .approval_judge => self.approval_judge,
            .compaction => self.compaction,
        };
    }

    pub fn route(self: Policy, id: []const u8, purpose: Purpose) !Route {
        for (self.routes) |value| {
            if (!std.mem.eql(u8, id, value.id)) continue;
            for (value.purposes) |allowed| if (allowed == purpose) return value;
            return error.ModelRoutePurposeDenied;
        }
        return error.ModelRouteDenied;
    }

    pub fn validate(self: Policy) !void {
        if (self.reviewer_timeout_ms == 0 or self.reviewer_timeout_ms > max_review_ms) return error.InvalidReviewerTimeout;
        for (self.routes, 0..) |value, i| {
            if (value.id.len == 0 or value.model.len == 0 or value.purposes.len == 0 or value.context_limit > max_context_limit) return error.InvalidModelRoute;
            const uri = std.Uri.parse(value.endpoint) catch return error.InvalidModelRoute;
            const supported_scheme = std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https");
            if (!supported_scheme or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidModelRoute;
            for (self.routes[0..i]) |earlier| if (std.mem.eql(u8, earlier.id, value.id)) return error.DuplicateModelRoute;
            if (value.provider == .ollama and value.protocol != .chat) return error.InvalidModelRoute;
            try value.settings.validate();
        }
        inline for (std.meta.tags(Purpose)) |purpose| {
            if (self.selected(purpose)) |id| {
                _ = try self.route(id, purpose);
            } else if (self.restrict_routes) return error.MissingModelRoute;
        }
    }
};

test "routes are purpose restricted and settings are bounded" {
    const policy: Policy = .{ .routes = &.{.{ .id = "review", .provider = .openai, .endpoint = "http://localhost:8000/v1", .model = "local", .purposes = &.{.approval_judge} }} };
    try policy.validate();
    _ = try policy.route("review", .approval_judge);
    try std.testing.expectError(error.ModelRoutePurposeDenied, policy.route("review", .agent));
    try std.testing.expectError(error.ModelRouteDenied, policy.route("remote", .agent));
    try std.testing.expectError(error.InvalidModelSettings, (Settings{ .attempts = max_attempts + 1 }).validate());
    try std.testing.expectError(error.InvalidModelSettings, (Settings{ .temperature = std.math.nan(f32) }).validate());
}
