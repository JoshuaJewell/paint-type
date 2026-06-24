-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Typing Proof: Public API type safety  (TP-2)
-- Proves properties about the exported `pt_*` FFI surface and the
-- host_core Command/Response contract.
--
-- Ground truth:
--   * src/interface/ffi/src/main.zig  — the 25 `export fn pt_*` symbols,
--     the `Result` enum {ok=0, error=1, invalid_param=2, busy=3}, opaque
--     u64 handles (tiles, layer stacks, u16 slots), and the per-call
--     null / bad-magic / out-of-bounds validation discipline.
--   * src/host_core/src/protocol.rs — the Command / Response sum types and
--     the base64 DirtyRect carried by a Painted response.
--
-- This file is pure Lean 4 core (NO mathlib, NO Std imports): it typechecks
-- with a bare `lean ApiTypes.lean` invocation.

/-! ## 1. The API result functor (`ApiResult`) -/

-- Example: Result type used across API boundaries
inductive ApiResult (α : Type) where
  | ok    : α → ApiResult α
  | error : Nat → String → ApiResult α

namespace ApiResult
  -- Proof: map preserves structure (functor law: map id = id)
  def map (f : α → β) : ApiResult α → ApiResult β
    | .ok v      => .ok (f v)
    | .error c m => .error c m

  theorem map_id : ∀ (r : ApiResult α), map id r = r := by
    intro r
    cases r with
    | ok v => simp [map]
    | error c m => simp [map]

  -- Proof: map composition (functor law: map (g ∘ f) = map g ∘ map f)
  theorem map_comp (f : α → β) (g : β → γ) :
      ∀ (r : ApiResult α), map (g ∘ f) r = map g (map f r) := by
    intro r
    cases r with
    | ok v => simp [map, Function.comp]
    | error c m => simp [map]
end ApiResult

/-! ## 2. Bounded numeric invariant (kept from scaffold, now well-typed)

The scaffold left `max` as a free identifier, which Lean resolved to the
builtin `Max.max` function and failed to elaborate. We bind it as an
explicit `Nat` parameter so the invariant is real and the file compiles. -/

structure BoundedNat (max : Nat) where
  val : Nat
  le_max : val ≤ max

theorem bounded_nat_le {max : Nat} (b : BoundedNat max) : b.val ≤ max :=
  b.le_max

-- Proof: zero is always bounded (every bound accepts 0)
def zeroBounded {max : Nat} : BoundedNat max :=
  ⟨0, Nat.zero_le max⟩

/-! ## 3. The `pt_*` result-code discipline

The Zig `Result` enum is a closed numeric tag set. The FFI returns *only*
these four codes for its `u32`-returning operations; every exported
operation is total (it always returns one of these, never traps). -/

-- Faithful model of `pub const Result = enum(u32) { ok, error, invalid_param, busy }`
inductive PtCode where
  | ok            -- 0
  | err           -- 1   (Zig `error`)
  | invalidParam  -- 2
  | busy          -- 3
deriving DecidableEq, Repr

namespace PtCode
  -- Numeric encoding, matching `@intFromEnum(Result.*)` in Zig and
  -- `Abi.Types.resultFromCode` in Idris2.
  def toU32 : PtCode → Nat
    | ok           => 0
    | err          => 1
    | invalidParam => 2
    | busy         => 3

  def ofU32? : Nat → Option PtCode
    | 0 => some ok
    | 1 => some err
    | 2 => some invalidParam
    | 3 => some busy
    | _ => none

  -- Type-safety property: the numeric encoding is a total injection into
  -- the 0..3 window and round-trips. No `pt_*` return value can decode to
  -- a code outside the closed enum.
  theorem ofU32_toU32 (c : PtCode) : ofU32? c.toU32 = some c := by
    cases c <;> rfl

  theorem toU32_lt_four (c : PtCode) : c.toU32 < 4 := by
    cases c <;> decide

  -- Injectivity: distinct codes have distinct encodings (the tag set is
  -- genuinely 4-valued, not collapsed).
  theorem toU32_injective {a b : PtCode} (h : a.toU32 = b.toU32) : a = b := by
    cases a <;> cases b <;> first | rfl | (simp [toU32] at h)
end PtCode

/-! ## 4. Opaque handles and the API state

`pt_tile_alloc` / `pt_layer_stack_new` hand back a `u64` the C/Idris2 caller
treats as opaque; only the Zig side dereferences it. We model a handle as a
tagged opaque token together with a liveness bit (the `magic` word). A
handle is either NULL (`0`) or LIVE or DEAD (poisoned magic). -/

inductive Handle where
  | null
  | live (id : Nat)
  | dead (id : Nat)
deriving DecidableEq, Repr

namespace Handle
  -- `isLive` mirrors the Zig `magic == PT_TILE_MAGIC` guard.
  def isLive : Handle → Bool
    | live _ => true
    | _      => false

  -- `pt_*_free` poisons the magic; freeing a live handle yields a dead one,
  -- freeing null or already-dead is a documented no-op (handle unchanged).
  def free : Handle → Handle
    | live id => dead id
    | h       => h

  -- Totality + idempotence of free: a second free never crashes and never
  -- re-liberates. This is the linear-ownership safety the Zig double-free
  -- guard provides ("Refuse rather than crash").
  theorem free_not_live (h : Handle) : (free h).isLive = false := by
    cases h <;> rfl

  theorem free_idempotent (h : Handle) : free (free h) = free h := by
    cases h <;> rfl
end Handle

/-! ## 5. The exported operation surface as a total transition system

We bundle the `u32`-returning `pt_*` operations into one inductive of
*operation requests* and give each a single total interpreter
`ApiState → ApiOp → ApiState × PtCode`. The point is type-preservation and
totality: *every* request, on *every* handle state (including null / dead /
out-of-bounds arguments), produces a well-formed `PtCode` and a well-formed
successor state — there is no stuck or trapping configuration. -/

-- A small abstract API state: the handle under operation, and a bounded
-- "busy" flag standing in for the `Result.busy` path.
structure ApiState where
  handle : Handle
  busy   : Bool
deriving DecidableEq, Repr

-- The mutating exported operations, abstracted over their concrete
-- arguments. `px`/`py` model the in-bounds predicate of the pixel ops
-- (valid iff both < TILE_SIZE = 64).
inductive ApiOp where
  | alloc                      -- pt_tile_alloc / pt_layer_stack_new
  | free                       -- pt_tile_free / pt_layer_stack_free
  | fill                       -- pt_tile_fill
  | writePixel (px py : Nat)   -- pt_tile_write_pixel  (bounds-checked)
  | readPixel  (px py : Nat)   -- pt_tile_read_pixel   (bounds-checked)
deriving Repr

namespace Api

-- TILE_SIZE from the Zig ground truth.
def tileSize : Nat := 64

-- The total interpreter. Mirrors the Zig control flow:
--   * null handle               → invalid_param
--   * non-live (dead) handle     → invalid_param  (bad magic)
--   * busy state                 → busy
--   * out-of-bounds pixel coords → invalid_param
--   * otherwise                  → ok
def step (s : ApiState) : ApiOp → ApiState × PtCode
  | .alloc =>
      -- Allocation always succeeds in-model (OOM is the only failure in Zig;
      -- we model the success path that establishes a live handle).
      ({ s with handle := .live 0 }, .ok)
  | .free =>
      -- Freeing is total: poison magic; never traps (Zig refuses double-free).
      ({ s with handle := s.handle.free }, .ok)
  | .fill =>
      if s.busy then (s, .busy)
      else if s.handle.isLive then (s, .ok)
      else (s, .invalidParam)
  | .writePixel px py =>
      if s.busy then (s, .busy)
      else if !s.handle.isLive then (s, .invalidParam)
      else if px ≥ tileSize ∨ py ≥ tileSize then (s, .invalidParam)
      else (s, .ok)
  | .readPixel px py =>
      if s.busy then (s, .busy)
      else if !s.handle.isLive then (s, .invalidParam)
      else if px ≥ tileSize ∨ py ≥ tileSize then (s, .invalidParam)
      else (s, .ok)

/-! ### 5.1 Totality of the API

`step` is a *total* function (Lean checks termination/totality at
definition time: it is non-recursive and pattern-complete). The lemma
below makes the type-safety content explicit: for every state and every
operation, `step` returns a successor state whose `handle` is still a
well-formed `Handle` and a code in the closed 0..3 enum window. There is no
configuration on which the public API gets stuck or returns an undefined
code. -/

theorem step_code_in_enum (s : ApiState) (op : ApiOp) :
    (step s op).2.toU32 < 4 := by
  exact PtCode.toU32_lt_four _

-- Type preservation #1: the result code always decodes back to itself,
-- i.e. the `u32` a `pt_*` call returns is always a *valid* enum member.
-- (Strengthening of the totality claim: not just "< 4" but "a real code".)
theorem step_code_valid (s : ApiState) (op : ApiOp) :
    PtCode.ofU32? (step s op).2.toU32 = some (step s op).2 :=
  PtCode.ofU32_toU32 _

/-! ### 5.2 The handle never silently revives, and `ok` ⇒ a live or
allocating context.

A genuine type-safety invariant (beyond functor laws): an operation can
only succeed with `ok` when it is `alloc` (which establishes liveness) or
when it operated on a *live* handle while not busy. Equivalently: you can
never get `ok` from a mutating pixel op on a NULL or DEAD handle. This is
exactly the use-after-free / null-deref protection the Zig magic-word guard
encodes. -/

theorem write_ok_implies_live {s : ApiState} {px py : Nat}
    (h : (step s (.writePixel px py)).2 = .ok) : s.handle.isLive = true := by
  simp only [step] at h
  -- Case on busy, then on liveness, then on bounds; only the all-pass
  -- branch yields `.ok`, and it forces `isLive = true`.
  by_cases hb : s.busy
  · simp [hb] at h
  · simp [hb] at h
    by_cases hl : s.handle.isLive
    · exact hl
    · simp [hl] at h

theorem read_ok_implies_live {s : ApiState} {px py : Nat}
    (h : (step s (.readPixel px py)).2 = .ok) : s.handle.isLive = true := by
  simp only [step] at h
  by_cases hb : s.busy
  · simp [hb] at h
  · simp [hb] at h
    by_cases hl : s.handle.isLive
    · exact hl
    · simp [hl] at h

-- And the bounds guard: an `ok` pixel write forces both coords in-range.
theorem write_ok_implies_in_bounds {s : ApiState} {px py : Nat}
    (h : (step s (.writePixel px py)).2 = .ok) :
    px < tileSize ∧ py < tileSize := by
  simp only [step] at h
  by_cases hb : s.busy
  · simp [hb] at h
  · simp [hb] at h
    by_cases hl : s.handle.isLive
    · simp [hl] at h
      by_cases hbnd : px ≥ tileSize ∨ py ≥ tileSize
      · simp [hbnd] at h
      · -- hbnd : ¬(px ≥ tileSize ∨ py ≥ tileSize); derive both < without push_neg
        have hpx : px < tileSize :=
          Nat.lt_of_not_le (fun hc => hbnd (Or.inl hc))
        have hpy : py < tileSize :=
          Nat.lt_of_not_le (fun hc => hbnd (Or.inr hc))
        exact ⟨hpx, hpy⟩
    · simp [hl] at h

-- Freeing then operating: after `free`, the handle is dead, so any
-- subsequent (non-busy) pixel write reports `invalid_param`, never `ok`.
-- This is the end-to-end use-after-free guarantee.
theorem write_after_free_not_ok (s : ApiState) (px py : Nat) :
    (step (step s .free).1 (.writePixel px py)).2 ≠ .ok := by
  intro hok
  have hlive : (step s .free).1.handle.isLive = true :=
    write_ok_implies_live hok
  -- but the freed handle is provably not live
  have hnot : (step s .free).1.handle.isLive = false := by
    simp only [step]
    exact Handle.free_not_live s.handle
  rw [hlive] at hnot
  exact Bool.noConfusion hnot

end Api

/-! ## 6. The host_core Command / Response typing

`protocol.rs` defines a `Command` sum and a `Response` sum; the host handles
each inbound command and returns a response. We model both sums faithfully
(including the base64 `DirtyRect` payload of a `Painted` response) and prove
that the dispatcher is *total and type-preserving*: every `Command` maps to
a well-formed `Response`, and every command's response lies in the response
sum's expected sub-family for that command. -/

namespace Protocol

-- base64 dirty-rect payload (protocol.rs `DirtyRect`).
structure DirtyRect where
  x : Nat
  y : Nat
  w : Nat
  h : Nat
  rgbaBase64 : String
deriving Repr

-- protocol.rs `enum Command`
inductive Command where
  | newDoc (w h : Nat)
  | setColour (r g b a : Float)
  | setBrush (diameter : Nat)
  | pointerDown (x y : Float)
  | pointerMove (x y : Float)
  | pointerUp
  | savePng (path : String)
deriving Repr

-- protocol.rs `enum Response`
inductive Response where
  | ack
  | painted (dirty : DirtyRect)
  | saved (path : String)
  | error (message : String)
deriving Repr

-- A faithful total dispatcher. The typing contract from protocol.rs:
--   * config commands (new doc, colour, brush) and pointer-up acknowledge;
--   * pointer down/move paint and so carry a DirtyRect;
--   * save returns the written path;
--   * the Error arm exists for any failure (here: a save with empty path).
def handle : Command → Response
  | .newDoc _ _      => .ack
  | .setColour _ _ _ _ => .ack
  | .setBrush _      => .ack
  | .pointerDown x y =>
      .painted { x := Float.toUInt64 x |>.toNat,
                 y := Float.toUInt64 y |>.toNat,
                 w := 1, h := 1, rgbaBase64 := "" }
  | .pointerMove x y =>
      .painted { x := Float.toUInt64 x |>.toNat,
                 y := Float.toUInt64 y |>.toNat,
                 w := 1, h := 1, rgbaBase64 := "" }
  | .pointerUp       => .ack
  | .savePng path    =>
      if path = "" then .error "empty path" else .saved path

-- Classify which response *shape* a command must yield (the typing
-- relation we are checking the dispatcher against).
def respShape : Response → Nat
  | .ack        => 0
  | .painted _  => 1
  | .saved _    => 2
  | .error _    => 3

def expectedShape : Command → Nat
  | .newDoc _ _        => 0
  | .setColour _ _ _ _ => 0
  | .setBrush _        => 0
  | .pointerDown _ _   => 1
  | .pointerMove _ _   => 1
  | .pointerUp         => 0
  | .savePng _         => 3 -- save may fail (error) ; success path below

-- Type-preservation #2: the dispatcher is total and every command produces
-- the *response family* its typing rule demands — except `savePng`, whose
-- success path is `saved` and whose empty-path path is `error`; both are
-- well-formed Response constructors, which is what totality guarantees.
-- We prove the unconditional part first:

theorem handle_total (c : Command) : ∃ r : Response, handle c = r :=
  ⟨handle c, rfl⟩

-- The interesting, non-vacuous part: for every NON-save command, the
-- response shape is exactly the one the typing rule predicts.
theorem handle_shape_correct (c : Command)
    (hns : ∀ p, c ≠ .savePng p) :
    respShape (handle c) = expectedShape c := by
  cases c with
  | newDoc w h      => rfl
  | setColour r g b a => rfl
  | setBrush d      => rfl
  | pointerDown x y => rfl
  | pointerMove x y => rfl
  | pointerUp       => rfl
  | savePng p       => exact absurd rfl (hns p)

-- And the save command lands in a well-typed branch either way: `saved`
-- on a non-empty path, `error` on the empty path. Neither is a stuck
-- state; both are genuine Response constructors.
theorem handle_save_well_typed (path : String) :
    respShape (handle (.savePng path)) = 2 ∨
    respShape (handle (.savePng path)) = 3 := by
  simp only [handle]
  by_cases h : path = ""
  · simp [h, respShape]
  · simp [h, respShape]

-- Surjectivity-flavoured completeness: every Response shape tag is in the
-- 0..3 window — the response sum is closed, mirroring `step_code_in_enum`.
theorem respShape_lt_four (r : Response) : respShape r < 4 := by
  cases r <;> simp only [respShape] <;> decide

end Protocol
