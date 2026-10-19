//! What the video's terminal shows (video.zig): a test run that fails, a
//! question to the agent and its answer (written in: no agent runs), and a
//! README to go inside with Vim's keys. Nothing here is run.

pub const test_cmd = "zig build test";
pub const test_out =
    "\x1b[1mtest\x1b[0m\r\n" ++
    "\x1b[2m+- run test\x1b[0m 412 passed, \x1b[31m1 failed\x1b[0m\r\n" ++
    "\x1b[31merror:\x1b[0m 'pager.test.j off the last line comes back' failed:\r\n" ++
    "  expected \x1b[32m3\x1b[0m lines, found \x1b[31m4\x1b[0m\r\n" ++
    "  \x1b[2msrc/pager.zig:118:9\x1b[0m: p.lineCount()\r\n" ++
    "\x1b[1mBuild Summary:\x1b[0m 2/3 steps succeeded; 412/413 tests passed\r\n";

pub const question = "why did the pager test fail?";
pub const answer =
    \\The output ends with a newline, and the pager counted the empty line after it: `"a\nb\nc\n"` became **4** lines.
    \\
    \\Trim the last newlines before splitting, in `pager.enter`:
    \\
    \\```zig
    \\const text = std.mem.trimEnd(u8, buf, "\n");
    \\```
    \\
    \\That makes it 3, and `j` off the last line goes back to the input again.
;

pub const cat_cmd = "cat README.md";
pub const readme =
    "# nanoterm\r\n\r\n" ++
    "A terminal where commands and questions share one input.\r\n" ++
    "Commands run as blocks; questions go to your coding agent.\r\n\r\n" ++
    "## Keys\r\n\r\n" ++
    "- Standard, Emacs or Vim keys in the input\r\n" ++
    "- Vim: Esc, then k climbs into the output above\r\n" ++
    "- Inside: motions, / search, v and V select, y copies\r\n" ++
    "- Emacs: M-v goes in; C-s searches, M-w copies\r\n\r\n" ++
    "## Agents\r\n\r\n" ++
    "- Sign in with Codegraff, or bring your own agent\r\n" ++
    "- Each tab keeps one conversation\r\n\r\n" ++
    "## Engine\r\n\r\n" ++
    "- 315 MB/s for full-screen programs, measured in bench/\r\n" ++
    "- the same final screen as Ghostty and Alacritty\r\n";
