// SPDX-License-Identifier: AGPL-3.0-or-later
//
// dispatch -- the single function the GUI calls. Pure: Document in,
// Response out, no I/O except SavePng which writes a file.

use crate::document::{Document, Rect};
use crate::protocol::{Command, DirtyRect, Response};
use base64::Engine;

/// Apply one command to the document, returning the response to hand
/// back to the web UI. `doc` is `None` until the first NewDoc.
pub fn dispatch(doc: &mut Option<Document>, cmd: Command) -> Response {
    if let Command::NewDoc { w, h } = cmd {
        *doc = Some(Document::new(w, h));
        return Response::Ack;
    }

    let Some(document) = doc.as_mut() else {
        return Response::Error {
            message: "no document; send new_doc first".to_string(),
        };
    };

    match cmd {
        Command::NewDoc { .. } => unreachable!("handled above"),
        Command::SetColour { r, g, b, a } => {
            document.set_colour(r, g, b, a);
            Response::Ack
        }
        Command::SetBrush { diameter } => {
            document.set_brush(diameter);
            Response::Ack
        }
        Command::PointerDown { x, y } => {
            let rect = document.pointer_down(x, y);
            paint(document, rect)
        }
        Command::PointerMove { x, y } => {
            let rect = document.pointer_move(x, y);
            paint(document, rect)
        }
        Command::PointerUp => Response::Ack,
        Command::SavePng { path } => {
            let w = document.width();
            let h = document.height();
            let rgba = document.render_all();
            match crate::codec::save_png(&path, &rgba, w, h) {
                Ok(()) => Response::Saved { path },
                Err(e) => Response::Error { message: e },
            }
        }
    }
}

fn paint(doc: &Document, rect: Rect) -> Response {
    if rect.w == 0 || rect.h == 0 {
        return Response::Ack;
    }
    let rgba = doc.render(rect);
    let rgba_base64 = base64::engine::general_purpose::STANDARD.encode(&rgba);
    Response::Painted {
        dirty: DirtyRect {
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
            rgba_base64,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Command, Response};

    fn decode(dirty_b64: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode(dirty_b64)
            .expect("valid base64")
    }

    #[test]
    fn new_doc_then_stroke_paints_non_transparent_pixels() {
        let mut doc: Option<Document> = None;

        assert_eq!(
            dispatch(&mut doc, Command::NewDoc { w: 128, h: 128 }),
            Response::Ack
        );
        assert_eq!(
            dispatch(
                &mut doc,
                Command::SetColour { r: 1.0, g: 0.0, b: 0.0, a: 1.0 }
            ),
            Response::Ack
        );
        assert_eq!(
            dispatch(&mut doc, Command::SetBrush { diameter: 16 }),
            Response::Ack
        );

        let down = dispatch(&mut doc, Command::PointerDown { x: 32.0, y: 32.0 });
        let Response::Painted { dirty } = down else {
            panic!("expected Painted, got {down:?}");
        };
        let bytes = decode(&dirty.rgba_base64);
        assert_eq!(bytes.len() as u32, dirty.w * dirty.h * 4);
        // A soft-round brush peaks near alpha 0.991, which quantises to ~253,
        // so assert a near-opaque red dab rather than exactly 255.
        let has_opaque = bytes.chunks_exact(4).any(|p| p[3] > 240 && p[0] > 200);
        assert!(has_opaque, "expected a near-opaque red pixel in the dab");

        assert_eq!(dispatch(&mut doc, Command::PointerUp), Response::Ack);
    }

    #[test]
    fn commands_before_new_doc_error() {
        let mut doc: Option<Document> = None;
        let r = dispatch(&mut doc, Command::PointerDown { x: 1.0, y: 1.0 });
        assert!(matches!(r, Response::Error { .. }));
    }

}
