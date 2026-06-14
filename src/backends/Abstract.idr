-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- paint.type — abstract operation surface for the unified backend pattern.
--
-- This module is the single source of truth for what an operation IS in
-- paint.type. Every concrete backend (CpuReferenceBackend, NvidiaCudaBackend,
-- AppleMetalBackend, …) implements this surface; the dispatcher routes calls
-- through one of them; the AffineScript application only ever sees this
-- surface, never a backend.
--
-- Governed by ADR-0002 (Foundation — Universal Cross-Platform, Unified
-- Backend/Kernel Surface). See docs/decisions/0002-foundation-cross-platform.adoc.
--
-- The pattern is borrowed from hyperpolymath/Axiom.jl (`src/backends/abstract.jl`).
-- Where Axiom uses Julia multiple dispatch with a concrete-backend tag, we use
-- Idris2 interfaces (a.k.a. typeclasses) with a record-as-vtable representation
-- that survives codegen to C. Capability flags here correspond to Axiom's
-- "kernel hook coverage" probe; the dispatcher's transparent fallback maps to
-- Axiom's CPU fallback in `backends/gpu_hooks.jl`.

module Backends.Abstract

import Data.Bits
import Data.So
import Data.Vect
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- 1. Platform model (carried over from src/interface/Abi/Types.idr)
--------------------------------------------------------------------------------

public export
data OS = Linux | MacOS | Windows | Android | IOS | FreeBSD | OpenBSD | NetBSD
        | DragonFly | Minix | Illumos | Haiku | Browser | RiscVBare

public export
data Arch = X86_64 | Aarch64 | Armv7 | Riscv64 | Riscv32 | Ppc64le
          | Wasm32 | Wasm64

public export
record Platform where
  constructor MkPlatform
  os   : OS
  arch : Arch

--------------------------------------------------------------------------------
-- 2. Capability descriptor
--
--   Every backend declares which kernel classes it can serve, at which
--   precision tiers, and with which memory characteristics.
--------------------------------------------------------------------------------

||| Kernel classes a backend may report. Capabilities are flags, not a directory
||| layout: a single backend may report multiple classes (e.g. AppleSilicon
||| reports {gpu, npu, vector, crypto, audio}).
public export
data KernelClass
  = ClassDsp        -- digital signal processing (audio servers, image DSP)
  | ClassFpga       -- reconfigurable fabric
  | ClassAudio      -- OS audio servers
  | ClassMath       -- general numerical kernels
  | ClassGpu        -- graphics / GPU compute
  | ClassPhysics    -- physics simulation (brush dynamics)
  | ClassCrypto     -- hardware crypto cores
  | ClassIo         -- async I/O (file / network)
  | ClassVector     -- SIMD on CPU
  | ClassTensor     -- dedicated tensor / NPU silicon

public export
data Precision
  = PrecF16 | PrecBF16 | PrecF32 | PrecF64
  | PrecI8  | PrecI16  | PrecI32 | PrecI64
  | PrecF8E5M2 | PrecF8E4M3        -- experimental tiers

||| Memory characteristic the backend exposes. UnifiedHost is the Apple-style
||| zero-copy host/device sharing; DiscreteDevice is the classic dGPU situation.
public export
data MemoryModel
  = UnifiedHost            -- host RAM is the device's RAM
  | UnifiedFabric          -- separate but cache-coherent (Grace-Hopper, MI300A)
  | DiscreteDevice         -- explicit transfers required
  | StreamingOnly          -- pipeline through; no random-access device memory

public export
record CapabilityEntry where
  constructor MkCapability
  class     : KernelClass
  precs     : List Precision
  memModel  : MemoryModel
  deviceIdx : Maybe Nat        -- which device, when there are multiple

public export
record BackendId where
  constructor MkBackendId
  vendor : String              -- "nvidia", "amd", "apple", "intel", "cpu", ...
  name   : String              -- "cuda", "rocm", "metal", "level-zero", "ref", ...
  major  : Nat
  minor  : Nat

public export
record Backend where
  constructor MkBackend
  id           : BackendId
  capabilities : List CapabilityEntry
  platform     : Platform

||| Predicate: backend serves a given kernel class at a given precision.
public export
serves : Backend -> KernelClass -> Precision -> Bool
serves b k p =
  any (\c => isClass c k && elem p c.precs) b.capabilities
where
  isClass : CapabilityEntry -> KernelClass -> Bool
  isClass c ClassDsp     = case c.class of ClassDsp     => True; _ => False
  isClass c ClassFpga    = case c.class of ClassFpga    => True; _ => False
  isClass c ClassAudio   = case c.class of ClassAudio   => True; _ => False
  isClass c ClassMath    = case c.class of ClassMath    => True; _ => False
  isClass c ClassGpu     = case c.class of ClassGpu     => True; _ => False
  isClass c ClassPhysics = case c.class of ClassPhysics => True; _ => False
  isClass c ClassCrypto  = case c.class of ClassCrypto  => True; _ => False
  isClass c ClassIo      = case c.class of ClassIo      => True; _ => False
  isClass c ClassVector  => case c.class of ClassVector  => True; _ => False
  isClass c ClassTensor  => case c.class of ClassTensor  => True; _ => False

--------------------------------------------------------------------------------
-- 3. Topology
--------------------------------------------------------------------------------

public export
record CpuTopology where
  constructor MkCpuTopology
  performanceCores : Nat
  efficiencyCores  : Nat
  hyperthreadRatio : Nat                 -- 1 = no SMT, 2 = SMT-2, ...
  l1Bytes          : Nat
  l2Bytes          : Nat
  l3Bytes          : Maybe Nat
  numaNodes        : Nat
  isaTier          : List String         -- ["avx2"], ["avx512f","vbmi","vaes"], ["neon","sve2","sme2"], ["rvv","zvbb","zvkn"], ...

public export
record MemoryTopology where
  constructor MkMemoryTopology
  totalRamBytes     : Bits64
  pageSize          : Nat
  hugePagesAvail    : Bool
  cxlBytes          : Maybe Bits64       -- CXL persistent-memory tier
  vramPerDevice     : List Bits64        -- ordered alongside GPU device list

public export
record NetworkTopology where
  constructor MkNetworkTopology
  loopbackUp        : Bool
  lanReachable      : Bool
  wanReachable      : Bool
  metered           : Bool
  costVectorRtt     : List Nat           -- ms RTT per discovered transport

public export
record Topology where
  constructor MkTopology
  cpu     : CpuTopology
  memory  : MemoryTopology
  network : NetworkTopology

public export
record CapabilityReport where
  constructor MkCapabilityReport
  generatedAtIso   : String
  selectedBackends : List BackendId      -- per-class default choices
  available        : List Backend
  topology         : Topology
  selfHealing      : Bool
  diagnostics      : List String

--------------------------------------------------------------------------------
-- 4. Result and error reporting
--------------------------------------------------------------------------------

public export
data Result : Type -> Type where
  Ok        : a -> Result a
  Err       : String -> Result a
  Fallback  : a -> String -> Result a    -- value came from the reference backend; reason

--------------------------------------------------------------------------------
-- 5. Core value types
--------------------------------------------------------------------------------

public export
data PixelFormat = RGBA16F | RGBA8 | R8 | A8 | RGBA32F | DisplayP3_16F | Rec2020_16F

public export
record CanvasId where
  constructor MkCanvasId
  raw : Bits64

public export
record LayerId where
  constructor MkLayerId
  raw : Bits64

public export
record SelectionMaskId where
  constructor MkSelectionMaskId
  raw : Bits64

public export
record Point where
  constructor MkPoint
  x : Double
  y : Double

public export
record Colour where
  constructor MkColour
  r : Double
  g : Double
  b : Double
  a : Double
  -- Colour space is carried at the canvas level; channels are linear-light here.

public export
record StrokePoint where
  constructor MkStrokePoint
  pos       : Point
  pressure  : Double     -- 0..1; identity at MVP, real values from tablet backends in v0.3
  tiltX     : Double     -- radians; 0 at MVP
  tiltY     : Double

public export
data BlendMode = BMNormal | BMMultiply | BMScreen
               -- v0.2 MVP set; additional modes (Overlay, SoftLight, ColorBurn, ...) land progressively

public export
data BrushProfile = BPHard | BPSoft | BPCustom String

public export
record BrushState where
  constructor MkBrushState
  radius   : Double         -- pixels
  hardness : Double         -- 0..1
  opacity  : Double         -- 0..1
  spacing  : Double         -- as fraction of radius
  profile  : BrushProfile

public export
data EraseMode = ETransparent | ERestoreBackground

public export
data ContiguousMode = ContigContiguous | ContigGlobal

public export
data AAMode = AAOff | AAOn | AASdf

public export
record Viewport where
  constructor MkViewport
  zoom     : Double     -- 1.0 = 100%
  panX     : Double
  panY     : Double
  rotation : Double     -- radians; 0 at MVP

public export
record TextStyle where
  constructor MkTextStyle
  family     : String
  sizePoints : Double
  weight     : Nat        -- 100..900
  italic     : Bool
  colour     : Colour

public export
record HistoryOp where
  constructor MkHistoryOp
  opcode   : String     -- machine-readable name (e.g. "stroke.brush")
  payload  : List Bits8 -- opaque serialised payload
  redoCost : Nat        -- bytes; budget input for bounded-memory undo

public export
record CapabilityFlag where
  constructor MkCapabilityFlag
  needs : List KernelClass    -- operations may advertise required kernel classes

--------------------------------------------------------------------------------
-- 6. The operation surface
--
--   Each MVP item maps to one or more operations. Every operation has a
--   reference implementation in CpuReferenceBackend; every accelerated
--   backend either overrides it or the dispatcher falls back transparently.
--
--   The shapes below are the canonical signatures the C ABI is generated from.
--------------------------------------------------------------------------------

namespace Op

  -- MVP-1: Canvas
  public export
  CanvasNew    : Type
  CanvasNew    = (width : Nat) -> (height : Nat) -> (fmt : PixelFormat) -> (bg : Colour) -> Result CanvasId

  public export
  CanvasResize : Type
  CanvasResize = (c : CanvasId) -> (w : Nat) -> (h : Nat) -> (anchorX : Double) -> (anchorY : Double) -> Result ()

  -- MVP-2: Open / Save
  public export
  IoOpen : Type
  IoOpen = (path : String) -> (fmt : Maybe String) -> Result CanvasId

  public export
  IoSave : Type
  IoSave = (c : CanvasId) -> (path : String) -> (fmt : String) -> (options : List (String, String)) -> Result ()

  -- MVP-3: Pencil / brush
  public export
  ToolStrokePencil : Type
  ToolStrokePencil = (c : CanvasId) -> (layer : LayerId) -> (points : List Point) -> (colour : Colour) -> Result ()

  public export
  ToolStrokeBrush : Type
  ToolStrokeBrush = (c : CanvasId) -> (layer : LayerId) -> (state : BrushState) -> (points : List StrokePoint) -> (colour : Colour) -> Result ()

  -- MVP-4: Eraser
  public export
  ToolStrokeEraser : Type
  ToolStrokeEraser = (c : CanvasId) -> (layer : LayerId) -> (state : BrushState) -> (points : List StrokePoint) -> (mode : EraseMode) -> Result ()

  -- MVP-5: Eyedropper
  public export
  ToolSampleColour : Type
  ToolSampleColour = (c : CanvasId) -> (at : Point) -> (areaPx : Nat) -> Result Colour

  -- MVP-6: Fill bucket
  public export
  ToolFill : Type
  ToolFill = (c : CanvasId) -> (layer : LayerId) -> (seed : Point) -> (colour : Colour) -> (tolerance : Double) -> (mode : ContiguousMode) -> Result ()

  -- MVP-7: Selection
  public export
  SelectionRect : Type
  SelectionRect = (c : CanvasId) -> (x0 : Nat) -> (y0 : Nat) -> (x1 : Nat) -> (y1 : Nat) -> Result SelectionMaskId

  public export
  SelectionLasso : Type
  SelectionLasso = (c : CanvasId) -> (path : List Point) -> Result SelectionMaskId

  public export
  SelectionInvert : Type
  SelectionInvert = (c : CanvasId) -> (m : SelectionMaskId) -> Result SelectionMaskId

  public export
  SelectionCut : Type
  SelectionCut = (c : CanvasId) -> (layer : LayerId) -> (m : SelectionMaskId) -> Result ()

  public export
  SelectionCopy : Type
  SelectionCopy = (c : CanvasId) -> (layer : LayerId) -> (m : SelectionMaskId) -> Result ()

  public export
  SelectionPaste : Type
  SelectionPaste = (c : CanvasId) -> (layer : LayerId) -> (dst : Point) -> Result ()

  -- MVP-8: Shapes
  public export
  ShapeLine : Type
  ShapeLine = (c : CanvasId) -> (layer : LayerId) -> (a : Point) -> (b : Point) -> (width : Double) -> (colour : Colour) -> (aa : AAMode) -> Result ()

  public export
  ShapeRectangle : Type
  ShapeRectangle = (c : CanvasId) -> (layer : LayerId) -> (a : Point) -> (b : Point) -> (stroke : Maybe Double) -> (strokeColour : Maybe Colour) -> (fill : Maybe Colour) -> (aa : AAMode) -> Result ()

  public export
  ShapeEllipse : Type
  ShapeEllipse = (c : CanvasId) -> (layer : LayerId) -> (centre : Point) -> (rx : Double) -> (ry : Double) -> (stroke : Maybe Double) -> (strokeColour : Maybe Colour) -> (fill : Maybe Colour) -> (aa : AAMode) -> Result ()

  public export
  ShapePolygon : Type
  ShapePolygon = (c : CanvasId) -> (layer : LayerId) -> (vertices : List Point) -> (stroke : Maybe Double) -> (strokeColour : Maybe Colour) -> (fill : Maybe Colour) -> (aa : AAMode) -> Result ()

  -- MVP-9: Text
  public export
  TextRasterise : Type
  TextRasterise = (c : CanvasId) -> (layer : LayerId) -> (origin : Point) -> (text : String) -> (style : TextStyle) -> Result ()

  -- MVP-10: Undo / Redo
  public export
  HistoryRecord : Type
  HistoryRecord = (c : CanvasId) -> (op : HistoryOp) -> Result ()

  public export
  HistoryUndo : Type
  HistoryUndo = (c : CanvasId) -> Result ()

  public export
  HistoryRedo : Type
  HistoryRedo = (c : CanvasId) -> Result ()

  -- MVP-11: Zoom / pan / fit
  public export
  ViewportSet : Type
  ViewportSet = (c : CanvasId) -> (v : Viewport) -> Result ()

  public export
  ViewportFit : Type
  ViewportFit = (c : CanvasId) -> Result Viewport

  -- MVP-12: Layers — surface management AND the render path that uses them.
  --
  -- `canvasRenderRgba8` composites the visible layer stack with the per-layer
  -- blend mode and opacity, applies the background fill for any pixels not
  -- covered, and writes 8-bit-per-channel straight RGBA into the caller's
  -- buffer. Linear-light throughout the compositing pipeline; the 8-bit
  -- output is a truncating conversion, NOT an sRGB encode (the colour-space
  -- correct path lands once the display backend's colour-space metadata is
  -- wired in v0.3.0).
  public export
  CanvasRenderRgba8 : Type
  CanvasRenderRgba8 = (c : CanvasId) -> (x : Nat) -> (y : Nat) -> (w : Nat) -> (h : Nat) -> Result (List Bits8)

  public export
  LayerNew : Type
  LayerNew = (c : CanvasId) -> (afterLayer : Maybe LayerId) -> (name : String) -> Result LayerId

  public export
  LayerDelete : Type
  LayerDelete = (c : CanvasId) -> (l : LayerId) -> Result ()

  public export
  LayerReorder : Type
  LayerReorder = (c : CanvasId) -> (l : LayerId) -> (newIndex : Nat) -> Result ()

  public export
  LayerSetVisible : Type
  LayerSetVisible = (c : CanvasId) -> (l : LayerId) -> (visible : Bool) -> Result ()

  public export
  LayerSetOpacity : Type
  LayerSetOpacity = (c : CanvasId) -> (l : LayerId) -> (opacity : Double) -> Result ()

  public export
  LayerSetBlend : Type
  LayerSetBlend = (c : CanvasId) -> (l : LayerId) -> (mode : BlendMode) -> Result ()

  -- Capability introspection
  public export
  CapabilityReport : Type
  CapabilityReport = () -> Result CapabilityReport

--------------------------------------------------------------------------------
-- 7. The Backend interface (vtable)
--
--   Every concrete backend builds a value of this record. The dispatcher holds
--   a list of these and selects per operation according to the capability
--   report. Idris2 generates a C header from this declaration so Zig modules
--   can fill it in via extern functions.
--------------------------------------------------------------------------------

public export
record BackendImpl where
  constructor MkBackendImpl

  -- Identity + capability
  identity         : Backend

  -- MVP-1
  canvasNew        : Op.CanvasNew
  canvasResize     : Op.CanvasResize

  -- MVP-2
  ioOpen           : Op.IoOpen
  ioSave           : Op.IoSave

  -- MVP-3
  toolStrokePencil : Op.ToolStrokePencil
  toolStrokeBrush  : Op.ToolStrokeBrush

  -- MVP-4
  toolStrokeEraser : Op.ToolStrokeEraser

  -- MVP-5
  toolSampleColour : Op.ToolSampleColour

  -- MVP-6
  toolFill         : Op.ToolFill

  -- MVP-7
  selectionRect    : Op.SelectionRect
  selectionLasso   : Op.SelectionLasso
  selectionInvert  : Op.SelectionInvert
  selectionCut     : Op.SelectionCut
  selectionCopy    : Op.SelectionCopy
  selectionPaste   : Op.SelectionPaste

  -- MVP-8
  shapeLine        : Op.ShapeLine
  shapeRectangle   : Op.ShapeRectangle
  shapeEllipse     : Op.ShapeEllipse
  shapePolygon     : Op.ShapePolygon

  -- MVP-9
  textRasterise    : Op.TextRasterise

  -- MVP-10
  historyRecord    : Op.HistoryRecord
  historyUndo      : Op.HistoryUndo
  historyRedo      : Op.HistoryRedo

  -- MVP-11
  viewportSet      : Op.ViewportSet
  viewportFit      : Op.ViewportFit

  -- MVP-12
  layerNew         : Op.LayerNew
  layerDelete      : Op.LayerDelete
  layerReorder     : Op.LayerReorder
  layerSetVisible  : Op.LayerSetVisible
  layerSetOpacity  : Op.LayerSetOpacity
  layerSetBlend    : Op.LayerSetBlend
  canvasRenderRgba8: Op.CanvasRenderRgba8

  -- Capability
  capability       : Op.CapabilityReport

--------------------------------------------------------------------------------
-- 8. Numerical-equivalence epsilon per operation
--
--   When the test harness compares an accelerated backend against the CPU
--   reference, each operation declares its tolerated max-abs-error and the
--   metric. MVP rule: pixel-identical for integer-output operations; epsilon
--   per channel for floating-point compositing.
--------------------------------------------------------------------------------

public export
data EpsilonMetric = MaxAbsDiff | MaxRelDiff | MaxUlpDiff Nat

public export
record OpEpsilon where
  constructor MkOpEpsilon
  opName : String
  metric : EpsilonMetric
  value  : Double

||| Per-operation tolerances declared once, consumed by the numerical-equivalence
||| harness. Adding a new operation requires extending this list.
public export
mvpEpsilons : List OpEpsilon
mvpEpsilons =
  [ MkOpEpsilon "canvas_new"          MaxAbsDiff       0.0
  , MkOpEpsilon "canvas_resize"       MaxAbsDiff       0.0
  , MkOpEpsilon "io_open"             MaxAbsDiff       0.0
  , MkOpEpsilon "io_save"             MaxAbsDiff       0.0
  , MkOpEpsilon "tool_stroke_pencil"  MaxAbsDiff       0.0   -- pixel-identical
  , MkOpEpsilon "tool_stroke_brush"   MaxAbsDiff       0.5   -- 1/65535 in F16 ≈ 1.5e-5; allow up to 0.5/255 in 8-bit view
  , MkOpEpsilon "tool_stroke_eraser"  MaxAbsDiff       0.0
  , MkOpEpsilon "tool_sample_colour"  MaxAbsDiff       0.0
  , MkOpEpsilon "tool_fill"           MaxAbsDiff       0.0   -- deterministic flood-fill
  , MkOpEpsilon "selection_rect"      MaxAbsDiff       0.0
  , MkOpEpsilon "selection_lasso"     MaxAbsDiff       0.0
  , MkOpEpsilon "selection_invert"    MaxAbsDiff       0.0
  , MkOpEpsilon "selection_cut"       MaxAbsDiff       0.0
  , MkOpEpsilon "selection_copy"      MaxAbsDiff       0.0
  , MkOpEpsilon "selection_paste"     MaxAbsDiff       0.0
  , MkOpEpsilon "shape_line"          MaxAbsDiff       0.0
  , MkOpEpsilon "shape_rectangle"     MaxAbsDiff       0.0
  , MkOpEpsilon "shape_ellipse"       MaxAbsDiff       0.5   -- midpoint ellipse may differ at sub-pixel edges
  , MkOpEpsilon "shape_polygon"       MaxAbsDiff       0.5
  , MkOpEpsilon "text_rasterise"      MaxAbsDiff       1.0   -- subpixel AA tolerated up to 1/255
  , MkOpEpsilon "history_record"      MaxAbsDiff       0.0
  , MkOpEpsilon "history_undo"        MaxAbsDiff       0.0
  , MkOpEpsilon "history_redo"        MaxAbsDiff       0.0
  , MkOpEpsilon "viewport_set"        MaxAbsDiff       0.0
  , MkOpEpsilon "viewport_fit"        MaxAbsDiff       0.0
  , MkOpEpsilon "layer_new"           MaxAbsDiff       0.0
  , MkOpEpsilon "layer_delete"        MaxAbsDiff       0.0
  , MkOpEpsilon "layer_reorder"       MaxAbsDiff       0.0
  , MkOpEpsilon "layer_set_visible"   MaxAbsDiff       0.0
  , MkOpEpsilon "layer_set_opacity"   MaxAbsDiff       0.5
  , MkOpEpsilon "layer_set_blend"     MaxAbsDiff       0.0
  , MkOpEpsilon "canvas_render_rgba8" MaxAbsDiff       1.0   -- accelerated backends may round the F16→8-bit step differently; 1/255 tolerated
  ]

--------------------------------------------------------------------------------
-- 9. Documentation: the dispatcher's contract
--------------------------------------------------------------------------------
--
-- The dispatcher (src/backends/dispatcher.zig) maintains a registry of
-- BackendImpl values, one per available backend. For each call to the
-- application API:
--
--   1. The dispatcher looks up the operation's required kernel classes
--      (operation → KernelClass list, declared in this module).
--   2. It chooses the highest-priority backend that serves every required
--      class at an acceptable precision (precision policy is host-configurable).
--   3. It invokes that backend's function pointer.
--   4. If the backend returns Err with a "not-implemented" tag, the dispatcher
--      transparently retries on the CpuReferenceBackend and re-wraps the
--      result as Fallback (carrying the reason).
--   5. Self-healing diagnostics record the fallback for the capability report.
--
-- The CpuReferenceBackend MUST implement every operation in BackendImpl
-- correctly. It is the oracle. No other backend's behaviour is verified
-- against itself; every accelerated backend is verified against the CPU
-- reference within the epsilon declared in `mvpEpsilons`.
