//! What a session does for the program reading its input (cat, a REPL, a
//! prompt for a password): Return sends the line exactly as typed, spaces
//! and all, and an empty one too; ^D on an empty input is the end of input,
//! as the terminal has it. Full-screen programs take the keys themselves
//! (view_screen.zig).
const Session = @import("session.zig").Session;

/// A program runs here, reading what is typed.
pub fn reading(a: *const Session) bool {
    return a.shell.busy() and !a.shell.remoteReady() and a.shell.fullScreen() == null;
}

pub fn line(a: *Session) void {
    a.shell.input(a.input.text());
    a.shell.input("\n");
    a.input.clear();
    a.history_pos = null;
    a.menu.close();
}

/// ^D: the terminal's end-of-file character, which ends a line-reading
/// program's input.
pub fn eof(a: *Session) void {
    a.shell.input("\x04");
}
