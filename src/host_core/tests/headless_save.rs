// SPDX-License-Identifier: PMPL-1.0-or-later
// Headless end-to-end: new_doc -> stroke -> save_png, no window.
use host_core::dispatch::dispatch;
use host_core::document::Document;
use host_core::protocol::{Command, Response};

#[test]
fn headless_new_doc_stroke_save() {
    let out = std::env::var("PT_HEADLESS_OUT").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("pt_headless.png")
            .to_string_lossy()
            .into_owned()
    });

    let mut doc: Option<Document> = None;
    assert_eq!(
        dispatch(&mut doc, Command::NewDoc { w: 128, h: 128 }),
        Response::Ack
    );
    dispatch(&mut doc, Command::SetColour { r: 0.0, g: 0.4, b: 1.0, a: 1.0 });
    dispatch(&mut doc, Command::SetBrush { diameter: 24, hardness: 0.0 });
    dispatch(&mut doc, Command::PointerDown { x: 30.0, y: 30.0 });
    dispatch(&mut doc, Command::PointerMove { x: 90.0, y: 90.0 });
    dispatch(&mut doc, Command::PointerUp);

    let res = dispatch(&mut doc, Command::SavePng { path: out.clone() });
    assert!(matches!(res, Response::Saved { .. }), "got {res:?}");

    let meta = std::fs::metadata(&out).expect("png exists");
    assert!(meta.len() > 0, "png is non-empty");
}
