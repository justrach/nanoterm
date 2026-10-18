//! A visual's card on its own, through ui.Tester: columns or bars by how
//! many values, the controls, and a visual that stopped.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const visual = @import("visual.zig");
const view_visual = @import("view_visual.zig");
const theme = @import("theme.zig");

const Page = struct {
    cards: []const struct { []const u8, *visual.Visual },

    fn view(p: *Page, c: *ui.Context) void {
        const s = ui.div(c).column().sizeFull().p(24).gap(20).bg(theme.background).scrollY();
        defer s.end();
        for (p.cards) |card| view_visual.card(c, card[0], card[1]);
    }
};

const rollout =
    \\local traffic = 40
    \\local canary = true
    \\return function()
    \\    local peak = traffic * (if canary then 1.1 else 1.4)
    \\    return ui.column{
    \\        ui.text('Illustrative rollout scenario: synthetic, not a benchmark.'),
    \\        ui.row{
    \\            ui.stat{label='Baseline', value=traffic .. 'k rps'},
    \\            ui.stat{label='Peak', value=math.floor(peak) .. 'k rps'},
    \\            ui.stat{label='Headroom', value=math.floor(100 - peak * 0.8) .. '%'},
    \\        },
    \\        ui.chart{label='Requests per second (k)', values={traffic, traffic * 1.2, peak, traffic * 0.9}, labels={'Mon', 'Tue', 'Wed', 'Thu'}},
    \\        ui.slider{label='Baseline traffic', value=traffic, min=10, max=100, onChange=function(v) traffic = math.floor(v) end},
    \\        ui.row{
    \\            ui.toggle{label='Canary first', value=canary, onChange=function(b) canary = b end},
    \\            ui.button{label='Double it', onClick=function() traffic = math.min(100, traffic * 2) end},
    \\        },
    \\        ui.rule{},
    \\        ui.text(if canary then 'Canary keeps the peak within capacity.' else 'A full rollout peaks higher.'),
    \\    }
    \\end
;

const many =
    \\return function()
    \\    local v, l = {}, {}
    \\    for i = 1, 14 do v[i] = (i * 37) % 23 - 4 l[i] = 'Service ' .. i end
    \\    return ui.chart{label='Latency change (ms)', values=v, labels=l}
    \\end
;

const explainer =
    \\local tab, step = 1, 1
    \\local stages = {
    \\    {name = 'Event', what = 'A click, key, resize or animation asks for a frame. An idle app draws nothing.', files = {{'src/ui/surface.zig', 'macOS view, display link'}, {'src/linux/surface.zig', 'GTK drawing area'}}},
    \\    {name = 'View', what = 'Your view function builds this frame\'s box tree from your state.', files = {{'src/ui/context.zig', 'boxes, ids, input'}}},
    \\    {name = 'Layout', what = 'Flexbox measures and places every box.', files = {{'src/ui/layout.zig', 'measure, arrange, grow'}}},
    \\    {name = 'Paint', what = 'Boxes become GPU instances: rects, glyphs, shadows.', files = {{'src/ui/paint.zig', 'instances, clipping'}, {'src/ui/metal.zig', 'Metal renderer'}}},
    \\}
    \\return function()
    \\    local s = stages[step]
    \\    local rows = {}
    \\    for i, f in s.files do rows[i] = {f[1], f[2]} end
    \\    return ui.column{
    \\        ui.tabs{options = {'Native UI', 'Web + typed IPC'}, value = tab, onChange = function(i) tab = i end},
    \\        ui.flow{label = 'One frame', steps = {'Event', 'View', 'Layout', 'Paint'}, active = step, onSelect = function(i) step = i end},
    \\        ui.group{title = `{step} · {s.name}`,
    \\            ui.text(s.what),
    \\            ui.table{columns = {'File', 'Role'}, rows = rows},
    \\            ui.row{ui.badge{label = 'macOS', tone = 'success'}, ui.badge{label = 'Linux', tone = 'accent'}, ui.badge{label = 'Windows', tone = 'neutral'}},
    \\        },
    \\        ui.progress{label = 'Through the frame', value = step, max = 4},
    \\        ui.list{items = {'Nothing polls', 'Every file under 600 lines'}, ordered = true},
    \\        ui.note('Paths are relative to the nanoui repository.'),
    \\    }
    \\end
;

test "an explainer: tabs, a flow whose steps change a group, a table" {
    const gpa = std.testing.allocator;
    const v = try visual.Visual.create(gpa, explainer);
    defer v.destroy();
    try std.testing.expect(v.err == null);
    var page: Page = .{ .cards = &.{.{ "How nanoui draws a frame", v }} };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&page, Page.view), .{ .width = 900, .height = 900, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("1 · Event"));
    try std.testing.expect(t.hasText("src/linux/surface.zig"));
    try t.clickText("Layout");
    t.settle(1);
    try std.testing.expect(t.hasText("3 · Layout"));
    try std.testing.expect(t.hasText("measure, arrange, grow"));
    try std.testing.expect(t.hasText("75%"));
    try t.screenshot("/tmp/nanoterm-visual-explainer.png");
}

test "a visual's card: columns, bars, controls, and one that stopped" {
    const gpa = std.testing.allocator;
    const a = try visual.Visual.create(gpa, rollout);
    defer a.destroy();
    const b = try visual.Visual.create(gpa, many);
    defer b.destroy();
    const e = try visual.Visual.create(gpa, "return function() return ui.text{text='x', color='red'} end");
    defer e.destroy();
    var page: Page = .{ .cards = &.{ .{ "Rollout capacity", a }, .{ "Latency by service", b }, .{ "Broken", e } } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&page, Page.view), .{ .width = 820, .height = 1500, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Rollout capacity"));
    try std.testing.expect(t.hasText("Peak: 44k rps"));
    try std.testing.expect(t.hasText("Wed"));
    try std.testing.expect(t.hasText("Showing the first 12 of 14 values"));
    try std.testing.expect(t.containsText("styling is not supported"));
    try t.clickText("Double it");
    t.settle(1);
    try std.testing.expect(t.hasText("Baseline: 80k rps"));
    try t.screenshot("/tmp/nanoterm-visual-card.png");
}
