//! What an agent lets the user choose, from ACP: its session config
//! options (model, mode, thought level: `configOptions`, set with
//! `session/set_config_option`) and its slash commands
//! (`available_commands_update`).
const std = @import("std");
const acp = @import("acp.zig");

pub const Choice = struct { value: []u8, name: []u8, description: []u8 };

pub const Option = struct {
    id: []u8,
    name: []u8,
    /// "model", "mode", "thought_level", or another the agent names.
    category: []u8,
    current: []u8,
    choices: []Choice,

    pub fn currentName(o: *const Option) []const u8 {
        for (o.choices) |c| if (std.mem.eql(u8, c.value, o.current)) return c.name;
        return o.current;
    }
};

pub const Command = struct { name: []u8, description: []u8, hint: []u8 };

pub const Config = struct {
    gpa: std.mem.Allocator,
    options: std.ArrayList(Option) = .empty,
    commands: std.ArrayList(Command) = .empty,

    pub fn deinit(c: *Config) void {
        c.clearOptions();
        c.options.deinit(c.gpa);
        c.clearCommands();
        c.commands.deinit(c.gpa);
    }

    fn clearOptions(c: *Config) void {
        for (c.options.items) |o| {
            for (o.choices) |ch| {
                c.gpa.free(ch.value);
                c.gpa.free(ch.name);
                c.gpa.free(ch.description);
            }
            c.gpa.free(o.choices);
            c.gpa.free(o.id);
            c.gpa.free(o.name);
            c.gpa.free(o.category);
            c.gpa.free(o.current);
        }
        c.options.clearRetainingCapacity();
    }

    fn clearCommands(c: *Config) void {
        for (c.commands.items) |cmd| {
            c.gpa.free(cmd.name);
            c.gpa.free(cmd.description);
            c.gpa.free(cmd.hint);
        }
        c.commands.clearRetainingCapacity();
    }

    /// The option of `category`, if the agent has one.
    pub fn find(c: *Config, category: []const u8) ?*Option {
        for (c.options.items) |*o| if (std.mem.eql(u8, o.category, category)) return o;
        return null;
    }

    pub fn byId(c: *Config, id: []const u8) ?*Option {
        for (c.options.items) |*o| if (std.mem.eql(u8, o.id, id)) return o;
        return null;
    }

    pub fn hasCommand(c: *const Config, name: []const u8) bool {
        for (c.commands.items) |cmd| if (std.mem.eql(u8, cmd.name, name)) return true;
        return false;
    }

    /// Takes the `configOptions` array (of a new session, a set's result,
    /// or a `config_option_update`), replacing what was known.
    pub fn setOptions(c: *Config, list: std.json.Value) void {
        if (list != .array) return;
        c.clearOptions();
        for (list.array.items) |o| {
            if (!std.mem.eql(u8, acp.str(o, "type") orelse "select", "select")) continue;
            const choices = acp.obj(o, "options") orelse continue;
            if (choices != .array) continue;
            var out: std.ArrayList(Choice) = .empty;
            for (choices.array.items) |ch| addChoices(c.gpa, &out, ch);
            const id = acp.str(o, "id") orelse continue;
            c.options.append(c.gpa, .{
                .id = c.gpa.dupe(u8, id) catch continue,
                .name = c.gpa.dupe(u8, acp.str(o, "name") orelse id) catch continue,
                .category = c.gpa.dupe(u8, acp.str(o, "category") orelse id) catch continue,
                .current = c.gpa.dupe(u8, acp.str(o, "currentValue") orelse "") catch continue,
                .choices = out.toOwnedSlice(c.gpa) catch continue,
            }) catch {};
        }
    }

    /// A choice, or a group of them ({group, name, options: [...]}).
    fn addChoices(gpa: std.mem.Allocator, out: *std.ArrayList(Choice), ch: std.json.Value) void {
        if (acp.obj(ch, "options")) |group| {
            if (group == .array) for (group.array.items) |g| addChoices(gpa, out, g);
            return;
        }
        const value = acp.str(ch, "value") orelse return;
        out.append(gpa, .{
            .value = gpa.dupe(u8, value) catch return,
            .name = gpa.dupe(u8, acp.str(ch, "name") orelse value) catch return,
            .description = gpa.dupe(u8, acp.str(ch, "description") orelse "") catch return,
        }) catch {};
    }

    pub fn setCommands(c: *Config, list: std.json.Value) void {
        if (list != .array) return;
        c.clearCommands();
        for (list.array.items) |cmd| {
            const name = acp.str(cmd, "name") orelse continue;
            c.commands.append(c.gpa, .{
                .name = c.gpa.dupe(u8, name) catch continue,
                .description = c.gpa.dupe(u8, acp.str(cmd, "description") orelse "") catch continue,
                .hint = c.gpa.dupe(u8, acp.str(acp.obj(cmd, "input") orelse .null, "hint") orelse "") catch continue,
            }) catch {};
        }
    }

    /// Records a value chosen before the agent confirms it.
    pub fn setCurrent(c: *Config, id: []const u8, value: []const u8) void {
        const o = c.byId(id) orelse return;
        const copy = c.gpa.dupe(u8, value) catch return;
        c.gpa.free(o.current);
        o.current = copy;
    }
};

test "config options and commands from ACP" {
    const gpa = std.testing.allocator;
    var c: Config = .{ .gpa = gpa };
    defer c.deinit();
    const json =
        \\{"configOptions":[
        \\ {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Default"},{"value":"plan","name":"Plan"}]},
        \\ {"id":"model","name":"Model","category":"model","type":"select","currentValue":"sonnet","options":[{"group":"g","name":"Claude","options":[{"value":"sonnet","name":"Sonnet","description":"fast"},{"value":"opus","name":"Opus"}]}]}],
        \\ "availableCommands":[{"name":"review","description":"review code","input":{"hint":"<target>"}},{"name":"clear","description":"wipe"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    c.setOptions(parsed.value.object.get("configOptions").?);
    c.setCommands(parsed.value.object.get("availableCommands").?);
    const model = c.find("model").?;
    try std.testing.expectEqual(@as(usize, 2), model.choices.len);
    try std.testing.expectEqualStrings("Sonnet", model.currentName());
    c.setCurrent("model", "opus");
    try std.testing.expectEqualStrings("Opus", c.find("model").?.currentName());
    try std.testing.expectEqualStrings("<target>", c.commands.items[0].hint);
    try std.testing.expect(c.hasCommand("clear"));
    // A later update replaces what was known.
    c.setOptions(parsed.value.object.get("configOptions").?);
    try std.testing.expectEqual(@as(usize, 2), c.options.items.len);
}
