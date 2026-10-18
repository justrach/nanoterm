//! Visuals as Harness's scripts make them: render, interact, re-render,
//! and the limits and rules that keep styling and surprises out.
const std = @import("std");
const visual = @import("visual.zig");

const dashboard =
    \\-- A stateful, native dashboard. The host chooses layout, typography and colors.
    \\local iterations = 3
    \\local compare = false
    \\local target = 8
    \\return function()
    \\    return ui.column{
    \\        ui.text('Design review'),
    \\        ui.row{
    \\            ui.stat{label='Iterations', value=tostring(iterations)},
    \\            ui.stat{label='Target', value=target},
    \\        },
    \\        ui.chart{label='Feedback resolved', values={2, 5, iterations + 4}, labels={'Mon', 'Tue', 'Wed'}},
    \\        ui.button{label='Add iteration', onClick=function() iterations += 1 end},
    \\        ui.toggle{label='Compare variants', value=compare, onChange=function(value) compare = value end},
    \\        ui.slider{label='Target iterations', value=target, min=1, max=20, onChange=function(value) target = math.floor(value) end},
    \\        ui.rule{},
    \\        ui.text{text=compare and 'Comparison enabled' or 'Single variant'},
    \\    }
    \\end
;

test "a dashboard renders, and its controls change it" {
    const v = try visual.Visual.create(std.testing.allocator, dashboard);
    defer v.destroy();
    try std.testing.expect(v.err == null);
    const root = v.tree.?;
    try std.testing.expectEqual(visual.Kind.column, root.kind);
    try std.testing.expectEqual(@as(usize, 8), root.children.len);
    const stat = root.children[1].children[0];
    try std.testing.expectEqualStrings("Iterations", stat.label);
    try std.testing.expectEqualStrings("3", stat.text);
    try std.testing.expectEqualStrings("8", root.children[1].children[1].text);
    try std.testing.expectEqual(@as(f64, 7), root.children[2].values[2]);

    v.call(root.children[3].handler.?, .click);
    try std.testing.expectEqualStrings("4", v.tree.?.children[1].children[0].text);
    try std.testing.expectEqual(@as(f64, 8), v.tree.?.children[2].values[2]);
    v.call(v.tree.?.children[4].handler.?, .{ .boolean = true });
    try std.testing.expectEqualStrings("Comparison enabled", v.tree.?.children[7].text);
    v.call(v.tree.?.children[5].handler.?, .{ .number = 12.7 });
    try std.testing.expectEqualStrings("12", v.tree.?.children[1].children[1].text);
    // A wrong input does nothing; out of range is clamped to the slider's.
    v.call(v.tree.?.children[5].handler.?, .click);
    v.call(v.tree.?.children[5].handler.?, .{ .number = 99 });
    try std.testing.expectEqualStrings("20", v.tree.?.children[1].children[1].text);

    try v.reset();
    try std.testing.expectEqualStrings("3", v.tree.?.children[1].children[0].text);
}

fn expectStops(script: []const u8, want: []const u8) !void {
    const v = try visual.Visual.create(std.testing.allocator, script);
    defer v.destroy();
    const err = v.err orelse return error.NoError;
    if (std.mem.indexOf(u8, err, want) == null) {
        std.debug.print("got: {s}\n", .{err});
        return error.WrongError;
    }
}

test "what a visual may not do" {
    try expectStops("return function() return ui.text{text='x', color='red'} end", "styling is not supported");
    try expectStops("return function() return ui.column{style={}} end", "styling is not supported");
    try expectStops("return function() return ui.chart{values={1, 0/0}} end", "finite number");
    try expectStops("return function() return ui.chart{values={1, 2}, labels={'a'}} end", "chart labels must match");
    try expectStops("return function() return ui.slider{value=11, min=0, max=10} end", "invalid slider");
    try expectStops("return function() return ui.toggle{value='yes'} end", "toggle value must be a boolean");
    try expectStops("return function() return {kind='text'} end", "expected a ui node kind");
    try expectStops("return function() local t = {} for i = 1, 600 do t[i] = ui.rule{} end return ui.column(t) end", "exceeds");
    try expectStops("return function() return ui.text(('x'):rep(9000)) end", "8 KiB");
    try expectStops("return 42", "must return a render function");
    try expectStops("return function() return ui.badge{label='x', tone='pink'} end", "tone is one of");
    try expectStops("return function() return ui.flow{steps={'a','b'}, active=3} end", "position out of range");
    try expectStops("return function() return ui.table{columns={'a','b'}, rows={{'1'}}} end", "one cell per column");
    try expectStops("return function() return ui.tabs{options={}} end", "tabs need options");
    try expectStops("return function() return ui.group{title='x', color='red'} end", "styling is not supported");
    try expectStops("return function() while true do end end", "budget");
    try expectStops("return function() return ui.text(io.open('/etc/passwd')) end", "attempt to index nil with open");
    try expectStops("return function() return ui.text(os.time()) end", "attempt to index nil with time");
    try expectStops("return function() return ui.text(require('x')) end", "attempt to call a nil value");
    try expectStops("return function( return end", "visual:1:");
    // A callback that errors stops the visual, visibly.
    const v = try visual.Visual.create(std.testing.allocator, "return function() return ui.button{label='Go', onClick=function() error('nope') end} end");
    defer v.destroy();
    v.call(v.tree.?.handler.?, .click);
    try std.testing.expect(std.mem.indexOf(u8, v.err.?, "nope") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), visual.validate("Title", "return 1"));
    try std.testing.expect(visual.validate(" ", "x") != null);
    try std.testing.expect(visual.validate("t", " \n") != null);
}
