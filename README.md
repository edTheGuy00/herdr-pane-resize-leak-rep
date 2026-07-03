# herdr-pane-resize-leak-rep

Minimal reproduction for a **herdr** server bug (v0.7.1, also present on master):

> A terminal-attach wire client that re-points to another terminal on the same
> connection (`AttachTerminal { takeover: true }`) leaks the **previous**
> terminal's `direct_attach_resize_locks` / `terminal_attach_owners` entries.
> Locked terminals are skipped by the pane-layout resize pass, so for every
> other attached client the previous terminal stays stuck at the attach
> client's (small) size — permanently, surviving the attach client's
> disconnect — until something re-attaches and detaches exactly that terminal.

Real-world impact: any multiplexing client (e.g. a mobile relay) that navigates
across panes leaves every visited pane shrunken on the co-attached desktop TUI.

## Run it

```bash
docker build -t herdr-resize-leak .
docker run --rm herdr-resize-leak
```

Exit code **1** = bug reproduced (doubles as a regression test: a fixed herdr
exits 0). Expected output on herdr 0.7.1:

```
>> phases (small client is 20x40):
   baseline                         A=50x200  B=50x200
   small client attached to A       A=20x40   B=50x200
   small client switched A -> B     A=20x40   B=20x40     <-- A should have been restored
   small client disconnected        A=20x40   B=50x200    <-- A stuck forever; B restored
❌ BUG REPRODUCED: pane A is stuck at 20x40 ...
```

(Exact desktop numbers vary with the TUI's chrome; what matters is A never
returns to its baseline while B does.)

Test another herdr release: `docker build --build-arg HERDR_VERSION=<x.y.z> ...`

## What it does

1. Starts a "desktop" herdr TUI client (200×50) inside tmux — this attaches the
   default workspace and creates pane/terminal **A**; a second tab adds
   terminal **B**.
2. A small (20×40) wire client (`src/main.rs`, protocol framing in
   `src/wire.rs`) performs: `Hello` → `AttachTerminal A (takeover)` → `Resize`
   → `AttachTerminal B (takeover)` → `Resize` → disconnect.
3. Between phases the harness (`repro.sh`) measures both pane PTYs with
   `stty size` and prints the table; verdict compares A's final size to its
   baseline.

## Root cause (herdr source, v0.7.1 tag)

- `src/server/headless.rs:2111` `attach_terminal_client` — inserts the lock +
  owner entry for the NEW terminal and resizes it, but never cleans the SAME
  client's previous terminal on re-attach (only a *different* existing owner is
  handled, `:2130-2151`).
- `src/server/headless.rs:1154` `remove_client` — on detach/disconnect removes
  the lock/owner for the client's **current** terminal only.
- `src/ui/panes.rs:201,218,261,293` — the layout resize pass skips any terminal
  present in `direct_attach_resize_locks`, so a leaked lock pins the stale size
  forever.
- `src/server/headless.rs:2408` `ClientResize` — direct-attach resizes hit the
  terminal runtime unreconciled (why the shrink happens; by design).

The wire framing in `src/wire.rs` is vendored from
[muxr-core](https://github.com/f0x-it-llc/muxr-core) (MIT): independently
authored against herdr's public protocol, not derived from herdr's AGPL source.
