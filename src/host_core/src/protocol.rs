// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The command/response contract between the web UI and the core. Each
// inbound JavaScript __gossamer_invoke maps to one Command; the Response
// is serialised straight back as the invoke's resolved value.

use serde::{Deserialize, Serialize};

/// The active painting tool.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ToolKind {
    Brush,
    Eraser,
    Fill,
}

/// A rectangle of freshly composited pixels the UI must blit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DirtyRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// base64 of `w * h * 4` straight-alpha RGBA8 bytes.
    pub rgba_base64: String,
}

/// Inbound commands. `#[serde(tag = "cmd")]` lets the UI send
/// `{"cmd":"pointer_down","x":10,"y":20}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    NewDoc { w: u32, h: u32 },
    SetColour { r: f32, g: f32, b: f32, a: f32 },
    SetBrush { diameter: u32, hardness: f32 },
    OpenPng { path: String },
    PointerDown { x: f32, y: f32 },
    PointerMove { x: f32, y: f32 },
    PointerUp,
    SelectTool { kind: ToolKind },
    FillAt { x: f32, y: f32 },
    SavePng { path: String },
}

/// Outbound responses, serialised as the invoke result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "ok", rename_all = "snake_case")]
pub enum Response {
    /// Acknowledged, no pixels changed.
    Ack,
    /// One dirty rectangle to blit.
    Painted { dirty: DirtyRect },
    /// A file was written.
    Saved { path: String },
    /// A PNG was opened; the dirty rect covers the full canvas.
    Loaded { dirty: DirtyRect },
    /// Something failed; `message` is human-readable.
    Error { message: String },
}
