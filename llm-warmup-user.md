# LLM Warmup — paint-type (User)

## What is paint-type?

paint-type is a cross-platform open-source image editor in the spirit of Paint.NET —
capable enough for real work, simple enough to reach for without thinking.

paint-type is in early development. There is no user-installable application yet.
The first public release (v0.3.0) will provide a basic canvas with layers and tools
running in the Gossamer desktop shell.

## Planned User Features

- Non-destructive layer model
- Standard painting tools: brush, eraser, selection, fill
- RGBA16F (high dynamic range) canvas
- Open/save PNG and paint-type native format
- Real-time collaboration via Burble WebRTC (v0.5.0)
- Plugin support (v0.4.0)

## Status

The application is not yet runnable. Current work is on the image engine
(Ephapax) and the ABI bridge (Idris2/Zig). A usable desktop application
is targeted for v0.3.0.

## Quick Context

- License: PMPL-1.0-or-later (open source)
- Owner: Joshua Jewell (JoshuaJewell on GitHub)
- Contact: paint-type@pm.me
- GitHub: https://github.com/JoshuaJewell/paint-type
- See `ROADMAP.adoc` for the milestone plan
