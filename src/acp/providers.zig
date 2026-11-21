//! The provider an agent's session answers through, and the credentials it
//! may switch to another with. One session runs at a time, so it owns the
//! client outright.

const std = @import("std");

const synth = @import("synth.zig");
const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Provider = @import("../provider/provider.zig");

const Providers = @This();

io: std.Io,
auth: *Auth,
chatgpt: ?*chatgpt_auth.Store,
backend: *Backend,
/// Catalog id of the provider `backend` points at.
active_id: []const u8,
/// Nothing usable has been chosen: a turn asks for a provider first.
missing: bool = false,
/// What `backend` was built from, until `start` has reached it.
unstarted: ?struct { config: *const Config, active: catalog.Active },
/// The configured model is yet to be checked against what the provider has.
model_unchecked: bool = false,
request_route: bool = false,
model_policy: Config.ModelPolicy.Policy = .{},

/// `backend` is built from `active` but not yet reached: an agent answers
/// `initialize` first, and reaches it when the first session opens.
pub fn init(io: std.Io, config: *const Config, auth: *Auth, chatgpt: ?*chatgpt_auth.Store, backend: *Backend, active: catalog.Active) Providers {
    return .{
        .io = io,
        .auth = auth,
        .chatgpt = chatgpt,
        .backend = backend,
        .active_id = active.entry.id,
        .model_policy = config.model_requests,
        .unstarted = .{ .config = config, .active = active },
    };
}

pub fn deinit(self: *Providers) void {
    const allocator = self.backend.options.allocator;
    self.backend.deinit();
    allocator.destroy(self.backend);
}

/// Reach the provider, once, and settle whether it is usable.
pub fn start(self: *Providers, arena: std.mem.Allocator, db: *Database) !void {
    const unstarted = self.unstarted orelse return;
    self.unstarted = null;
    if (unstarted.config.model_requests.agent != null) {
        try self.backend.startWithoutProbe();
        self.request_route = true;
        self.missing = false;
        return;
    }
    try self.backend.start();
    self.model_unchecked = true;
    self.missing = !try usable(arena, db, unstarted.config, unstarted.active, self.auth, self.chatgpt, self.backend);
}

/// Check the configured model against what the provider has, once, and say
/// whether it did. Kept out of `start`, which a session waits on to open: the
/// check is a round trip to the provider, as on master's first frame.
pub fn checkModel(self: *Providers) bool {
    if (!self.model_unchecked) return false;
    self.model_unchecked = false;
    self.backend.ensureModel() catch {};
    return true;
}

/// Whether the session has nothing to answer it: none was chosen, or the
/// ChatGPT sign-in it runs on has ended.
pub fn isMissing(self: *const Providers) bool {
    if (self.request_route) return false;
    if (self.missing) return true;
    if (!std.mem.eql(u8, self.active_id, catalog.chatgpt_id)) return false;
    const store = self.chatgpt orelse return true;
    return !store.isUsable();
}

/// Each provider in the catalog: where it is, whether it has what it needs,
/// and whether it is the one in use.
pub fn states(self: *const Providers, arena: std.mem.Allocator, db: *Database) ![]const synth.ProviderState {
    const missing = self.isMissing();
    const out = try arena.alloc(synth.ProviderState, catalog.all.len);
    for (catalog.all, out) |entry, *state| state.* = .{
        .id = entry.id,
        .host = try self.endpoint(arena, db, entry),
        .connected = self.isConnected(entry),
        .active = !missing and std.mem.eql(u8, entry.id, self.active_id),
    };
    return out;
}

/// Whether a provider has what it needs to be asked anything.
pub fn isConnected(self: *const Providers, entry: catalog.Entry) bool {
    if (entry.key == .oauth) return entry.ready(self.auth, self.chatgpt);
    return self.auth.key(entry.id) != null;
}

/// Where a provider is reached: the host last connected for one whose host
/// is the person's to set, or the catalog's.
pub fn hostOf(arena: std.mem.Allocator, db: *Database, entry: catalog.Entry) ![]const u8 {
    if (!entry.host_editable) return entry.host;
    const remembered = try db.providerHost(arena, entry.id);
    return if (remembered.len > 0) remembered else entry.host;
}

pub fn endpoint(self: *const Providers, arena: std.mem.Allocator, db: *Database, entry: catalog.Entry) ![]const u8 {
    if (std.mem.eql(u8, entry.id, self.active_id)) return self.backend.currentHost();
    return hostOf(arena, db, entry);
}

pub const ModelSelection = union(enum) {
    automatic,
    select: []const u8,
    keep: []const u8,
};

/// Store `key` when one is given and point the session at the provider.
/// Returns what the session now answers as.
pub fn connect(self: *Providers, entry: catalog.Entry, host: []const u8, key: ?[]const u8, model: ModelSelection) !Provider {
    if (self.model_policy.restrict_routes) return error.ModelRouteDenied;
    const same_endpoint = std.mem.eql(u8, entry.id, self.active_id) and std.mem.eql(u8, host, self.backend.currentHost());
    const credential: ?[]const u8 = key orelse self.auth.key(entry.id) orelse if (same_endpoint) self.backend.currentKey() else null;
    if (entry.key == .required and (credential == null or credential.?.len == 0)) return error.ProviderKeyRequired;
    if (entry.key == .oauth and key == null and !entry.ready(self.auth, self.chatgpt)) return error.NotSignedIn;
    const allocator = self.backend.options.allocator;
    const replacement = try allocator.create(Backend);
    errdefer allocator.destroy(replacement);
    var options = self.backend.options;
    options.host = "";
    options.label = "";
    options.model = "";
    options.api_key = null;
    replacement.* = .init(entry.kind, options);
    errdefer replacement.deinit();
    if (model == .keep and same_endpoint and entry.kind == .openai) {
        const openai = &replacement.client.openai;
        const previous_limit = self.backend.current().context_limit;
        // An existing model may still answer even when the new key's /models view omits it.
        try openai.setModel(model.keep);
        try openai.reconnect(.{ .host = host, .label = entry.label, .api_key = credential });
        if (previous_limit > 0 and (openai.model_listing == null or openai.is_model_unlisted)) {
            openai.context_limit = previous_limit;
        }
    } else {
        const provider = try replacement.connect(entry, host, credential);
        switch (model) {
            .automatic => {},
            .select, .keep => |name| {
                const set = provider.set_model orelse return error.ModelFixed;
                _ = try set(provider.userdata, name);
            },
        }
    }
    if (key != null) try self.saveCredential(entry, key);
    self.deinit();
    self.backend = replacement;
    self.active_id = entry.id;
    self.missing = false;
    self.model_unchecked = false;
    return replacement.provider();
}

pub fn saveCredential(self: *Providers, entry: catalog.Entry, key: ?[]const u8) !void {
    if (key) |secret| {
        try self.auth.set(entry.id, secret);
        try self.auth.save(self.io, self.auth.path);
    } else if (entry.key == .required and !entry.ready(self.auth, self.chatgpt)) {
        return error.ProviderKeyRequired;
    }
}

/// ChatGPT was signed out of: a session on it has nothing to answer it.
pub fn signedOut(self: *Providers) void {
    if (std.mem.eql(u8, self.active_id, catalog.chatgpt_id)) self.missing = true;
}

/// The models every usable provider offers, with their efforts and the level
/// last chosen for each: one whose key is optional counts without one, unlike
/// `isConnected`. The one in use answers through `session`; the rest get a
/// client of their own just for the asking.
pub fn offered(self: *const Providers, arena: std.mem.Allocator, db: *Database, session: Provider) ![]const synth.Offered {
    if (self.model_policy.restrict_routes) return &.{};
    var out: std.ArrayList(synth.Offered) = .empty;
    for (catalog.all) |entry| {
        if (!entry.ready(self.auth, self.chatgpt)) continue;
        if (std.mem.eql(u8, entry.id, self.active_id)) {
            try appendOffered(arena, db, &out, entry.id, entry.label, session);
            continue;
        }
        var backend: Backend = .init(entry.kind, .{
            .allocator = arena,
            .io = self.io,
            .host = try hostOf(arena, db, entry),
            .label = entry.label,
            .api_key = self.auth.key(entry.id),
            .chatgpt = self.chatgpt,
            .copilot_integration_id = self.backend.options.copilot_integration_id,
        });
        defer backend.deinit();
        backend.start() catch continue;
        try appendOffered(arena, db, &out, entry.id, entry.label, backend.provider());
    }
    return out.items;
}

/// What one provider offers, for an agent whose session can answer through
/// no other.
pub fn offeredBy(arena: std.mem.Allocator, db: *Database, id: []const u8, label: []const u8, provider: Provider) ![]const synth.Offered {
    var out: std.ArrayList(synth.Offered) = .empty;
    try appendOffered(arena, db, &out, id, label, provider);
    return out.items;
}

fn appendOffered(arena: std.mem.Allocator, db: *Database, out: *std.ArrayList(synth.Offered), id: []const u8, label: []const u8, provider: Provider) !void {
    const names = provider.models(arena) catch return;
    for (names) |name| {
        const efforts = provider.effortsFor(name);
        const levels = try arena.alloc([]const u8, efforts.levels.len);
        for (efforts.levels, levels) |level, *copy| copy.* = try arena.dupe(u8, level);
        const remembered = db.rememberedEffort(arena, id, name) catch "";
        try out.append(arena, .{
            .name = name,
            .provider = label,
            .provider_id = id,
            .efforts = levels,
            .effort = try arena.dupe(u8, efforts.pick(remembered)),
        });
    }
}

/// A provider someone chose, and that has what it needs; or, with nothing
/// chosen, a local server that actually answers. Defaulting to one that is not
/// there would only surface as an error on the first prompt.
pub fn usable(arena: std.mem.Allocator, db: *Database, config: *const Config, active: catalog.Active, auth: *const Auth, chatgpt: ?*chatgpt_auth.Store, backend: *Backend) !bool {
    if (!active.entry.ready(auth, chatgpt)) return false;
    const chosen = try db.activeProvider(arena);
    const was_chosen = chosen.len > 0 or config.provider_override.len > 0 or config.host_override.len > 0;
    if (was_chosen) return true;
    const models = backend.listModels(arena) catch return false;
    return models.len > 0;
}
