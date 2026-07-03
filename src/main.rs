//! Wire client for the MRE: performs the exact sequence a multiplexing client
//! (e.g. a mobile relay) performs when its user navigates between panes —
//! ONE wire connection that re-points itself with `AttachTerminal { takeover:
//! true }` from terminal A to terminal B, then disconnects.
//!
//! Bug (herdr <= 0.7.1, also present on master): terminal A stays at this
//! client's small size for every other attached client, because
//! `attach_terminal_client` never removes the previous terminal's
//! `direct_attach_resize_locks` / `terminal_attach_owners` entries when the
//! SAME client re-attaches elsewhere, and `remove_client` only cleans the
//! client's CURRENT terminal on detach (so B recovers, A does not).
//!
//! Usage:
//!     herdr-pane-resize-leak-rep <client-socket> <terminal_A> <terminal_B> [rows] [cols]
//!
//! The client announces `PHASE:<NAME>` on stdout after each step and waits for
//! one line on stdin before continuing, so a harness can measure the pane PTY
//! sizes between phases (see repro.sh).

mod wire;

use std::io::{BufRead, Write as _};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use wire::{
    read_server_message, write_message, ClientKeybindings, ClientLaunchMode, ClientMessage,
    RenderEncoding, ServerMessage, HERDR_PROTOCOL_VERSION,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!(
            "usage: herdr-pane-resize-leak-rep <client-socket> <terminal_A> <terminal_B> [rows] [cols]"
        );
        std::process::exit(2);
    }
    let socket = &args[1];
    let term_a = args[2].clone();
    let term_b = args[3].clone();
    let rows: u16 = args.get(4).map(|s| s.parse().unwrap()).unwrap_or(20);
    let cols: u16 = args.get(5).map(|s| s.parse().unwrap()).unwrap_or(40);

    let stream = UnixStream::connect(socket).expect("connect wire socket");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();

    // Standard terminal-attach handshake.
    write_message(
        &mut &stream,
        &ClientMessage::Hello {
            version: HERDR_PROTOCOL_VERSION,
            cols,
            rows,
            cell_width_px: 0,
            cell_height_px: 0,
            requested_encoding: RenderEncoding::TerminalAnsi,
            keybindings: ClientKeybindings::Server,
            launch_mode: ClientLaunchMode::TerminalAttach,
        },
    )
    .expect("send Hello");
    match read_server_message(&mut &stream).expect("read Welcome") {
        ServerMessage::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }

    // Attach terminal A at the small client size.
    attach(&stream, &term_a, rows, cols);
    drain(&stream, 1500);
    checkpoint("ATTACHED_A");

    // Re-point the SAME connection at terminal B — the navigation step.
    attach(&stream, &term_b, rows, cols);
    drain(&stream, 1500);
    checkpoint("SWITCHED_TO_B");

    // Disconnect entirely.
    drop(stream);
    checkpoint("DISCONNECTED");
}

fn attach(stream: &UnixStream, terminal_id: &str, rows: u16, cols: u16) {
    write_message(
        &mut &*stream,
        &ClientMessage::AttachTerminal {
            terminal_id: terminal_id.to_owned(),
            takeover: true,
        },
    )
    .expect("send AttachTerminal");
    write_message(
        &mut &*stream,
        &ClientMessage::Resize {
            cols,
            rows,
            cell_width_px: 0,
            cell_height_px: 0,
        },
    )
    .expect("send Resize");
}

/// Read and discard server frames for ~ms milliseconds.
fn drain(stream: &UnixStream, ms: u64) {
    let deadline = std::time::Instant::now() + Duration::from_millis(ms);
    stream
        .set_read_timeout(Some(Duration::from_millis(200)))
        .unwrap();
    while std::time::Instant::now() < deadline {
        let _ = read_server_message(&mut &*stream);
    }
}

/// Announce a phase and wait for the harness to ack with one stdin line.
fn checkpoint(name: &str) {
    println!("PHASE:{name}");
    std::io::stdout().flush().unwrap();
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
}
