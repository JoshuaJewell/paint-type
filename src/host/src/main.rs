// SPDX-License-Identifier: PMPL-1.0-or-later
//
// paint-type desktop host. Boots a Gossamer window, loads the bundled
// web UI, and registers one IPC command. Each
// __gossamer_invoke("dispatch", payload) call deserialises a Command,
// runs host_core::dispatch against the shared document, and returns the
// Response as JSON for the web UI to act on.

use gossamer_rs::App;
use host_core::dispatch::dispatch;
use host_core::document::Document;
use host_core::protocol::Command;
use std::sync::{Arc, Mutex};

fn main() -> Result<(), gossamer_rs::Error> {
    let mut app = App::new("paint.type", 1024, 768)?;

    // Shared document, guarded for the Send + 'static command handler.
    let doc: Arc<Mutex<Option<Document>>> = Arc::new(Mutex::new(None));

    let doc_for_cmd = Arc::clone(&doc);
    app.command("dispatch", move |payload| {
        let cmd: Command =
            serde_json::from_value(payload).map_err(|e| format!("bad command: {e}"))?;
        let mut guard = doc_for_cmd
            .lock()
            .map_err(|_| "document lock poisoned".to_string())?;
        let response = dispatch(&mut guard, cmd);
        serde_json::to_value(&response).map_err(|e| e.to_string())
    });

    // Lock the webview down to its own origin plus inline UI script.
    app.set_csp("default-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'")?;

    // Load the UI. By default the bundled, self-contained HTML is used;
    // setting PT_UI_FILE loads HTML from disk instead, which is handy for
    // iterating on the front end without recompiling. The hot-reload path
    // is dev-only; a size cap (default 10 MiB, tunable via
    // PT_UI_FILE_MAX_BYTES) bounds the read so a huge file — accidental
    // or hostile — cannot exhaust host RAM. Closes the
    // panic-attack UnboundedAllocation finding on this file.
    const PT_UI_FILE_MAX_BYTES_DEFAULT: u64 = 10 * 1024 * 1024;
    match std::env::var("PT_UI_FILE") {
        Ok(path) => {
            let max_bytes: u64 = std::env::var("PT_UI_FILE_MAX_BYTES")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(PT_UI_FILE_MAX_BYTES_DEFAULT);
            let meta = std::fs::metadata(&path)
                .map_err(|e| gossamer_rs::Error::InvalidString(format!("{path}: {e}")))?;
            if meta.len() > max_bytes {
                return Err(gossamer_rs::Error::InvalidString(format!(
                    "{path}: file size {} exceeds PT_UI_FILE_MAX_BYTES ({})",
                    meta.len(),
                    max_bytes
                )));
            }
            let html = std::fs::read_to_string(&path)
                .map_err(|e| gossamer_rs::Error::InvalidString(format!("{path}: {e}")))?;
            app.load_html(&html)?;
        }
        Err(_) => app.load_html(UI_HTML)?,
    }

    app.run();
    Ok(())
}

// The UI is embedded at compile time from src/ui/index.html.
const UI_HTML: &str = include_str!("../../ui/index.html");
