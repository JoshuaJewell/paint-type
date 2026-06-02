// SPDX-License-Identifier: PMPL-1.0-or-later
//
// host_core -- the display-independent heart of the paint.type desktop
// shell: the command protocol, the document model, the dispatch entry
// point, and the PNG codec. Depends only on paint_core, so the whole seam
// is unit-testable with no window and no WebKitGTK.

pub mod codec;
pub mod dispatch;
pub mod document;
pub mod protocol;
