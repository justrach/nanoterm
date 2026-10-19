//! The menus and their keys, Ghostty's on macOS: each item runs an action
//! on the workspace, then redraws. Keys live in menu items, as Ghostty's
//! do, so the menu bar shows them and they work wherever the focus is.
const std = @import("std");
const nanoui = @import("nanoui");
const Workspace = @import("workspace.zig").Workspace;
const Item = nanoui.menu.Item;
const binds = @import("binds.zig");

pub const Actions = struct {
    w: *Workspace,

    fn done(a: *Actions) void {
        a.w.shared.redraw();
    }
    fn newTab(a: *Actions, _: *Item) void {
        if (a.w.tabs.items.len > 0) _ = a.w.newTab(a.w.focused().cwd()) catch {};
        a.done();
    }
    fn splitRight(a: *Actions, _: *Item) void {
        a.w.splitFocused(.horizontal);
        a.done();
    }
    fn splitDown(a: *Actions, _: *Item) void {
        a.w.splitFocused(.vertical);
        a.done();
    }
    fn close(a: *Actions, _: *Item) void {
        a.w.closeFocused();
        a.done();
    }
    fn nextPane(a: *Actions, _: *Item) void {
        a.w.focusNext(1);
        a.done();
    }
    fn prevPane(a: *Actions, _: *Item) void {
        a.w.focusNext(-1);
        a.done();
    }
    fn focusDir(comptime dir: @import("split.zig").Direction) fn (*Actions, *Item) void {
        return struct {
            fn f(a: *Actions, _: *Item) void {
                a.w.focusDirection(dir);
                a.done();
            }
        }.f;
    }
    fn resizeDir(comptime dir: @import("split.zig").Direction) fn (*Actions, *Item) void {
        return struct {
            fn f(a: *Actions, _: *Item) void {
                a.w.resizeFocused(dir);
                a.done();
            }
        }.f;
    }
    fn equalize(a: *Actions, _: *Item) void {
        a.w.equalize();
        a.done();
    }
    fn zoom(a: *Actions, _: *Item) void {
        a.w.toggleZoom();
        a.done();
    }
    fn nextTab(a: *Actions, _: *Item) void {
        a.w.nextTab(1);
        a.done();
    }
    fn prevTab(a: *Actions, _: *Item) void {
        a.w.nextTab(-1);
        a.done();
    }
    fn tabN(comptime n: usize) fn (*Actions, *Item) void {
        return struct {
            fn f(a: *Actions, _: *Item) void {
                a.w.selectTab(n);
                a.done();
            }
        }.f;
    }
    fn focusInput(a: *Actions, _: *Item) void {
        // The focused pane's input always has the keyboard: a redraw puts it back.
        a.w.shared.redraw();
    }
    fn agentMode(a: *Actions, _: *Item) void {
        a.w.focused().toggleMode();
        a.done();
    }
    fn clear(a: *Actions, _: *Item) void {
        a.w.focused().clear();
        a.done();
    }
    fn interrupt(a: *Actions, _: *Item) void {
        a.w.focused().interrupt();
    }
    fn zoomIn(a: *Actions, _: *Item) void {
        a.w.zoomBy(0.1);
        a.done();
    }

    fn zoomOut(a: *Actions, _: *Item) void {
        a.w.zoomBy(-0.1);
        a.done();
    }

    fn zoomReset(a: *Actions, _: *Item) void {
        a.w.zoom = 1;
        a.done();
    }

    fn find(a: *Actions, _: *Item) void {
        a.w.openFind();
        a.done();
    }

    fn palette(a: *Actions, _: *Item) void {
        a.w.openPalette();
        a.done();
    }
    fn models(a: *Actions, _: *Item) void {
        a.w.openModels();
        a.done();
    }
    fn autoMode(a: *Actions, _: *Item) void {
        a.w.focused().lock = null;
        a.done();
    }
    fn settings(a: *Actions, _: *Item) void {
        a.w.openSettings();
        a.done();
    }
    fn graff(a: *Actions, _: *Item) void {
        a.w.focused().choose(.graff);
        a.done();
    }
    fn claude(a: *Actions, _: *Item) void {
        a.w.focused().choose(.claude);
        a.done();
    }
};

/// Sets the menu bar, as Ghostty lays out its macOS menus. (Built here,
/// where it is used: the template's submenus live in this frame.)
pub fn install(app: *nanoui.App, acts: *Actions) !void {
    const of = nanoui.MenuClick.of;
    const A = Actions;
    try app.setMenu(&.{
        .{ .label = "nanoterm", .submenu = &.{
            .{ .role = .about },
            .separator,
            .{ .label = "Settings…", .accelerator = binds.accel("Cmd+,"), .click = of(acts, A.settings) },
            .separator,
            .{ .role = .hide },
            .{ .role = .hide_others },
            .{ .role = .unhide },
            .separator,
            .{ .role = .quit },
        } },
        .{ .label = "Shell", .submenu = &.{
            .{ .label = "New Tab", .accelerator = binds.accel("Cmd+T"), .click = of(acts, A.newTab) },
            .{ .label = "Split Right", .accelerator = binds.accel("Cmd+D"), .click = of(acts, A.splitRight) },
            .{ .label = "Split Down", .accelerator = binds.accel("Cmd+Shift+D"), .click = of(acts, A.splitDown) },
            .separator,
            .{ .label = "Close", .accelerator = binds.accel("Cmd+W"), .click = of(acts, A.close) },
            .separator,
            .{ .label = "Clear", .accelerator = binds.accel("Cmd+K"), .click = of(acts, A.clear) },
            .{ .label = "Stop", .click = of(acts, A.interrupt) },
        } },
        .{ .role = .edit_menu },
        .{ .label = "Agent", .submenu = &.{
            .{ .label = "Toggle Agent Mode", .accelerator = binds.accel("Cmd+I"), .click = of(acts, A.agentMode) },
            .{ .label = "Detect Mode Automatically", .click = of(acts, A.autoMode) },
            .{ .label = "Choose Agent and Model…", .accelerator = binds.accel("Cmd+Shift+M"), .click = of(acts, A.models) },
            .{ .label = "Command Palette…", .accelerator = binds.accel("Cmd+P"), .click = of(acts, A.palette) },
            .{ .label = "Focus Input", .accelerator = binds.accel("Cmd+L"), .click = of(acts, A.focusInput) },
            .separator,
            .{ .label = "graff", .click = of(acts, A.graff) },
            .{ .label = "Claude Code", .click = of(acts, A.claude) },
        } },
        .{ .label = "View", .submenu = &.{
            .{ .label = "Bigger Text", .accelerator = binds.accel("Cmd+="), .click = of(acts, A.zoomIn) },
            .{ .label = "Smaller Text", .accelerator = binds.accel("Cmd+-"), .click = of(acts, A.zoomOut) },
            .{ .label = "Actual Size", .accelerator = binds.accel("Cmd+0"), .click = of(acts, A.zoomReset) },
            .separator,
            .{ .label = "Find…", .accelerator = binds.accel("Cmd+F"), .click = of(acts, A.find) },
            .separator,
            .{ .role = .toggle_full_screen },
        } },
        .{ .label = "Window", .submenu = &.{
            .{ .role = .minimize },
            .{ .role = .zoom },
            .separator,
            .{ .label = "Select Next Split", .accelerator = binds.accel("Cmd+]"), .click = of(acts, A.nextPane) },
            .{ .label = "Select Previous Split", .accelerator = binds.accel("Cmd+["), .click = of(acts, A.prevPane) },
            .{ .label = "Select Split", .submenu = &.{
                .{ .label = "Left", .accelerator = binds.accel("Cmd+Alt+Left"), .click = of(acts, A.focusDir(.left)) },
                .{ .label = "Right", .accelerator = binds.accel("Cmd+Alt+Right"), .click = of(acts, A.focusDir(.right)) },
                .{ .label = "Above", .accelerator = binds.accel("Cmd+Alt+Up"), .click = of(acts, A.focusDir(.up)) },
                .{ .label = "Below", .accelerator = binds.accel("Cmd+Alt+Down"), .click = of(acts, A.focusDir(.down)) },
            } },
            .{ .label = "Resize Split", .submenu = &.{
                .{ .label = "Move Divider Left", .accelerator = binds.accel("Cmd+Ctrl+Left"), .click = of(acts, A.resizeDir(.left)) },
                .{ .label = "Move Divider Right", .accelerator = binds.accel("Cmd+Ctrl+Right"), .click = of(acts, A.resizeDir(.right)) },
                .{ .label = "Move Divider Up", .accelerator = binds.accel("Cmd+Ctrl+Up"), .click = of(acts, A.resizeDir(.up)) },
                .{ .label = "Move Divider Down", .accelerator = binds.accel("Cmd+Ctrl+Down"), .click = of(acts, A.resizeDir(.down)) },
                .separator,
                .{ .label = "Equalize Splits", .accelerator = binds.accel("Cmd+Ctrl+="), .click = of(acts, A.equalize) },
            } },
            .{ .label = "Zoom Split", .accelerator = binds.accel("Cmd+Shift+Enter"), .click = of(acts, A.zoom) },
            .separator,
            // ⌘⇧] and ⌘⇧[: AppKit matches the shifted characters.
            .{ .label = "Show Next Tab", .accelerator = binds.accel("Cmd+}"), .click = of(acts, A.nextTab) },
            .{ .label = "Show Previous Tab", .accelerator = binds.accel("Cmd+{"), .click = of(acts, A.prevTab) },
            .{ .label = "Tab 1", .accelerator = binds.accel("Cmd+1"), .click = of(acts, A.tabN(0)) },
            .{ .label = "Tab 2", .accelerator = binds.accel("Cmd+2"), .click = of(acts, A.tabN(1)) },
            .{ .label = "Tab 3", .accelerator = binds.accel("Cmd+3"), .click = of(acts, A.tabN(2)) },
            .{ .label = "Tab 4", .accelerator = binds.accel("Cmd+4"), .click = of(acts, A.tabN(3)) },
            .{ .label = "Tab 5", .accelerator = binds.accel("Cmd+5"), .click = of(acts, A.tabN(4)) },
            .{ .label = "Tab 6", .accelerator = binds.accel("Cmd+6"), .click = of(acts, A.tabN(5)) },
            .{ .label = "Tab 7", .accelerator = binds.accel("Cmd+7"), .click = of(acts, A.tabN(6)) },
            .{ .label = "Tab 8", .accelerator = binds.accel("Cmd+8"), .click = of(acts, A.tabN(7)) },
            .{ .label = "Tab 9", .accelerator = binds.accel("Cmd+9"), .click = of(acts, A.tabN(8)) },
            .separator,
            .{ .role = .front },
        } },
    });
}
