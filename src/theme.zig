//! nanoterm's look: Harness's default palettes, Codegraff Dark and
//! Codegraff Light (warm neutrals, an amber accent), with its roles derived
//! as Harness derives them (hover and borders from white or black, the
//! selection from the accent). `apply` switches the palette; the view
//! hands nanoui the result every frame.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Appearance = enum { dark, light };

/// A palette's seeds, as Harness's `codegraff_dark`/`codegraff_light`.
const Seeds = struct {
    dark: bool,
    background: u24,
    shell: u24,
    raised: u24,
    text: u24,
    muted: u24,
    faint: u24,
    accent: u24,
    danger: u24,
    warning: u24,
    success: u24,
    ansi: [16]u24,
    /// comment, keyword, string, number, type, function.
    syntax: [6]u24,
};

const codegraff_dark: Seeds = .{
    .dark = true,
    .background = 0x16140f,
    .shell = 0x1f1c16,
    .raised = 0x2a261e,
    .text = 0xedeae2,
    .muted = 0x9a9384,
    .faint = 0x5c564b,
    .accent = 0xe8a33d,
    .danger = 0xd2674f,
    .warning = 0xd9a441,
    .success = 0x7fa86b,
    .ansi = .{ 0x16140f, 0xd2674f, 0x7fa86b, 0xd9a441, 0x8a9bb0, 0xbd80e4, 0x7fa86b, 0xedeae2, 0x5c564b, 0xd2674f, 0x7fa86b, 0xe8a33d, 0x8a9bb0, 0xbd80e4, 0x9a9384, 0xfaf8f3 },
    .syntax = .{ 0x5c564b, 0xe8a33d, 0x7fa86b, 0xd9a441, 0xedeae2, 0xe8a33d },
};

const codegraff_light: Seeds = .{
    .dark = false,
    .background = 0xfaf8f3,
    .shell = 0xf0ece3,
    .raised = 0xe7e1d5,
    .text = 0x1a1813,
    .muted = 0x6b6557,
    .faint = 0xa8a090,
    .accent = 0xc77d20,
    .danger = 0xb14228,
    .warning = 0x9a6e1b,
    .success = 0x5c7e47,
    .ansi = .{ 0x1a1813, 0xb14228, 0x5c7e47, 0x9a6e1b, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x6b6557, 0xa8a090, 0xb14228, 0x5c7e47, 0xc77d20, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x1a1813 },
    .syntax = .{ 0xa8a090, 0xc77d20, 0x5c7e47, 0x9a6e1b, 0x1a1813, 0xc77d20 },
};

pub var appearance: Appearance = .dark;
pub var dark = true;

pub var background: Color = default.background;
pub var panel: Color = default.panel;
pub var raised: Color = default.raised;
pub var block_hover: Color = default.block_hover;
pub var block_selected: Color = default.block_selected;
pub var border: Color = default.border;
pub var text: Color = default.text;
pub var muted: Color = default.muted;
pub var faint: Color = default.faint;
pub var accent: Color = default.accent;
/// Text and icons on an accent fill.
pub var on_accent: Color = default.on_accent;
/// The agent's mark (its avatar, name, visuals).
pub var agent: Color = default.agent;
pub var success: Color = default.success;
pub var failure: Color = default.failure;
pub var warning: Color = default.warning;
pub var cwd: Color = default.cwd;
pub var branch: Color = default.branch;
pub var shadow: Color = default.shadow;
/// Harness's stronger edge, and its maximum-contrast plate (switch knobs).
pub var border_strong: Color = default.border_strong;
pub var solid: Color = default.solid;
/// The composer's fill (Harness's input glass, opaque).
pub var input: Color = default.input;

/// The fonts: Geist for text, JetBrains Mono for code and output (the
/// system's SF Pro and SF Mono where they are not installed).
pub const font = "Geist";
pub const mono_font = "JetBrains Mono";

// Code: panels, inline code, and syntax colors.
pub var code_bg: Color = default.code_bg;
pub var code_header: Color = default.code_header;
pub var code_inline: Color = default.code_inline;
pub var code_inline_bg: Color = default.code_inline_bg;
pub var syn_keyword: Color = default.syn_keyword;
pub var syn_string: Color = default.syn_string;
pub var syn_number: Color = default.syn_number;
pub var syn_comment: Color = default.syn_comment;
pub var syn_type: Color = default.syn_type;
pub var syn_call: Color = default.syn_call;

/// The 16 ANSI colors: normal 0–7, bright 8–15.
pub var ansi: [16]Color = default.ansi;

/// Every role of a palette.
const Palette = struct {
    background: Color,
    panel: Color,
    raised: Color,
    block_hover: Color,
    block_selected: Color,
    border: Color,
    text: Color,
    muted: Color,
    faint: Color,
    accent: Color,
    on_accent: Color,
    agent: Color,
    success: Color,
    failure: Color,
    warning: Color,
    cwd: Color,
    branch: Color,
    shadow: Color,
    border_strong: Color,
    solid: Color,
    input: Color,
    code_bg: Color,
    code_header: Color,
    code_inline: Color,
    code_inline_bg: Color,
    syn_keyword: Color,
    syn_string: Color,
    syn_number: Color,
    syn_comment: Color,
    syn_type: Color,
    syn_call: Color,
    ansi: [16]Color,
};

const default = palette(.dark);

/// Puts appearance `a`'s palette in place.
pub fn apply(a: Appearance) void {
    const p = palette(a);
    appearance = a;
    dark = a == .dark;
    background = p.background;
    panel = p.panel;
    raised = p.raised;
    block_hover = p.block_hover;
    block_selected = p.block_selected;
    border = p.border;
    text = p.text;
    muted = p.muted;
    faint = p.faint;
    accent = p.accent;
    on_accent = p.on_accent;
    agent = p.agent;
    success = p.success;
    failure = p.failure;
    warning = p.warning;
    cwd = p.cwd;
    branch = p.branch;
    shadow = p.shadow;
    border_strong = p.border_strong;
    solid = p.solid;
    input = p.input;
    code_bg = p.code_bg;
    code_header = p.code_header;
    code_inline = p.code_inline;
    code_inline_bg = p.code_inline_bg;
    syn_keyword = p.syn_keyword;
    syn_string = p.syn_string;
    syn_number = p.syn_number;
    syn_comment = p.syn_comment;
    syn_type = p.syn_type;
    syn_call = p.syn_call;
    ansi = p.ansi;
}

/// Appearance `a`'s palette, from its seeds.
fn palette(a: Appearance) Palette {
    @setEvalBranchQuota(10_000);
    const s = if (a == .dark) codegraff_dark else codegraff_light;
    var p: Palette = undefined;
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    const tone = if (s.dark) white else black;
    p.background = .hex(s.background);
    p.panel = .hex(s.shell);
    p.raised = .hex(s.raised);
    p.text = .hex(s.text);
    p.muted = .hex(s.muted);
    p.faint = .hex(s.faint);
    p.accent = .hex(s.accent);
    p.failure = .hex(s.danger);
    p.warning = .hex(s.warning);
    p.success = .hex(s.success);
    // Harness's derived roles, flattened onto the background.
    p.block_hover = p.background.mix(tone, if (s.dark) 0.07 else 0.05);
    p.block_selected = p.background.mix(p.accent, if (s.dark) 0.16 else 0.12);
    p.border = p.background.mix(tone, if (s.dark) 0.10 else 0.12);
    p.border_strong = p.background.mix(tone, if (s.dark) 0.18 else 0.22);
    p.solid = if (s.dark) Color.hex(0xebebef) else Color.hex(0x232328);
    p.input = if (s.dark) p.background.mix(p.raised, 0.72) else p.panel;
    // Amber takes dark text, in both (Harness's best-on color).
    p.on_accent = if (s.dark) p.background else p.text;
    p.agent = .hex(s.ansi[5]);
    p.cwd = .hex(s.ansi[4]);
    p.branch = p.success;
    p.shadow = .{ .a = if (s.dark) 0.5 else 0.14 };
    p.code_bg = if (s.dark) p.background.mix(black, 0.28) else p.panel;
    p.code_header = if (s.dark) p.panel else p.raised;
    p.code_inline = p.accent;
    p.code_inline_bg = p.raised;
    p.syn_comment = .hex(s.syntax[0]);
    p.syn_keyword = .hex(s.syntax[1]);
    p.syn_string = .hex(s.syntax[2]);
    p.syn_number = .hex(s.syntax[3]);
    p.syn_type = .hex(s.syntax[4]);
    p.syn_call = .hex(s.syntax[5]);
    for (&p.ansi, s.ansi) |*o, v| o.* = .hex(v);
    return p;
}

/// xterm's 256 colors: the 16, a 6×6×6 cube, 24 grays.
pub fn color256(i: u8) Color {
    if (i < 16) return ansi[i];
    if (i < 232) {
        const n = i - 16;
        const levels = [6]f32{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[n / 36] / 255, .g = levels[(n / 6) % 6] / 255, .b = levels[n % 6] / 255 };
    }
    const g = @as(f32, @floatFromInt(8 + 10 * @as(u32, i - 232))) / 255;
    return .{ .r = g, .g = g, .b = g };
}

/// nanoui's theme, in this palette.
pub fn ui() nanoui.ui.Theme {
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = background;
    t.surface = panel;
    t.surface_hover = block_hover;
    t.text = text;
    t.muted = muted;
    t.border = border;
    t.accent = accent;
    t.accent_hover = accent.mix(text, 0.12);
    t.accent_text = on_accent;
    t.track = if (dark) raised else raised;
    t.danger = failure;
    t.success = success;
    t.shadow = shadow;
    t.font = font;
    t.mono_font = mono_font;
    return t;
}
