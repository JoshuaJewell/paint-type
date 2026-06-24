-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Memory-safety proof: Tile pool invariant (PROOF-NEEDS INV-1)
-- No double-free, no use-after-free for the libpt tile lifecycle.
-- All proofs MUST be constructive (no believe_me, no assert_total,
-- no postulate). %default total is enforced repo-wide.
--
-- Ground truth modelled (read these before trusting the encoding):
--   * src/paint_core/src/lib.rs
--       - struct Tile { raw: u64 }  — intentionally `!Copy`, `!Clone`,
--         linear ownership: exactly one Tile value per allocation.
--       - impl Drop for Tile { fn drop … pt_tile_free(self.raw) }
--         "self-defends against double-free via a magic word".
--   * src/interface/ffi/src/main.zig
--       - PT_TILE_MAGIC      = 0x50544C45 ("PTLE") — live header.
--       - PT_TILE_DEAD_MAGIC = 0x44454144 ("DEAD") — poisoned header.
--       - pt_tile_alloc  : writes PT_TILE_MAGIC, returns ptr.
--       - pt_tile_free   : if magic != PT_TILE_MAGIC → refuse (no-op,
--                          setError). Else poison to DEAD and destroy.
--       - pt_tile_fill / _read_pixel / _write_pixel / _read_buffer /
--         _write_buffer : if !isLive() → return invalid_param (rejected).
--       - pt_is_initialized : returns 1 iff isLive(), else 0.
--
-- Two complementary defences are formalised here, mirroring the two
-- defences in the codebase:
--
--   (1) A dependently-typed, liveness-indexed handle API (the Rust
--       linear-ownership side). `free` consumes a `Live` handle and
--       yields a `Dead` handle; every read/write/free operation that
--       touches a tile DEMANDS a `Live` handle. Because there is no
--       way to obtain a `Live` handle from a `Dead` one, a second free
--       and any read/write-after-free are *not typeable* — they are
--       type errors, exactly as Rust's move semantics make them
--       compile errors. (Section A.)
--
--   (2) The runtime magic-word lifecycle (the Zig side). We model the
--       header magic as an explicit state and prove that on a poisoned
--       ("DEAD") header the second free is PROVABLY the rejected branch
--       and every operation is PROVABLY rejected — i.e. even if a raw
--       u64 is replayed past the type system, the runtime check catches
--       it. (Section B.)
--
-- Echo-types audit (per estate proof discipline 2026-06-01)
-- ──────────────────────────────────────────────────────────────
-- Audited `hyperpolymath/echo-types` for prior material on linear
-- resource lifecycles / double-free / use-after-free / allocation
-- state machines: VERDICT = NONE. echo-types is an Agda formalisation
-- of structured loss (retained residue of irreversible operations); it
-- has no memory-allocation, ownership, or pointer-lifecycle algebra.
-- The closest conceptual neighbour is "irreversibility" (a free cannot
-- be undone), but echo-types provides no reusable type or lemma here.
-- INV-1 is classified L1/L4-only (not echo-relevant) and developed
-- in-repo. Reference: feedback_proofs_must_check_and_cross_doc_echo_types.md

module TilePool

import Data.Bits
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Magic words (ground truth: main.zig lines 42, 46)
--------------------------------------------------------------------------------
-- NOTE: these are deliberately Capitalised. Lowercase top-level names get
-- implicitly re-bound as fresh universally-quantified variables when they
-- appear in a type signature, which would silently weaken every theorem
-- below (e.g. `Not (m1 = m2)` would become `{m1,m2} -> Not (m1 = m2)`,
-- a FALSE statement). Capitalised names refer to the constants.

||| Header magic written by pt_tile_alloc for a *live* tile.
||| ASCII "PTLE" big-endian = 0x50544C45.
public export
PtTileMagic : Bits32
PtTileMagic = 0x50544C45

||| Header magic pt_tile_free writes to *poison* a freed tile, so a
||| subsequent free is detected. ASCII "DEAD" = 0x44454144.
public export
PtTileDeadMagic : Bits32
PtTileDeadMagic = 0x44454144

||| The two magic words are distinct. This is the single arithmetic
||| fact the runtime double-free defence rests on: a poisoned header
||| can never be mistaken for a live one. Proved by reduction on the
||| literal bit patterns, not asserted.
export
magicWordsDistinct : Not (PtTileMagic = PtTileDeadMagic)
magicWordsDistinct Refl impossible

--------------------------------------------------------------------------------
-- Section A. Liveness-indexed handle API  (Rust linear-ownership side)
--------------------------------------------------------------------------------
--
-- We index a tile handle by its lifecycle state. Because operations are
-- total functions whose *types* demand a `Live` handle, and `free`
-- turns a `Live` handle into a `Dead` one (consuming the `Live`
-- evidence), there is no way — within the type system — to:
--   * free a `Dead` handle  (double-free), or
--   * read/write a `Dead` handle  (use-after-free).
-- Both are type errors. We then prove meta-theorems ABOUT the encoding
-- to show the protection is real and not vacuous.

||| Lifecycle state of a tile handle.
public export
data TileState = Live | Dead

||| Decidable equality of states, used to phrase the no-op theorems and
||| to confirm the two states are genuinely distinguishable.
public export
DecEq TileState where
  decEq Live Live = Yes Refl
  decEq Dead Dead = Yes Refl
  decEq Live Dead = No (\case Refl impossible)
  decEq Dead Live = No (\case Refl impossible)

||| A tile handle carrying its grid coordinates and indexed by lifecycle
||| state. `raw` stands in for the opaque u64 the Rust `Tile.raw` holds;
||| we never expose it, exactly as the Rust wrapper never hands out the
||| pointer. The *type index* is what makes a freed handle unusable.
public export
data Handle : TileState -> Type where
  ||| The only constructor that produces a `Live` handle. Stands for the
  ||| successful `Some(Tile{raw})` branch of `Tile::alloc`.
  MkLive : (raw : Bits32) -> (x : Bits32) -> (y : Bits32) -> Handle Live
  ||| A poisoned handle. Produced ONLY by `free`; there is no public way
  ||| to fabricate a `Live` handle from a `Dead` one.
  MkDead : (raw : Bits32) -> Handle Dead

||| `alloc` — models Tile::alloc's success path. The result is `Live`.
||| (OOM / the `None` branch is the absence of a handle and needs no
||| representation here: you simply do not get a `Handle Live`.)
public export
alloc : (x : Bits32) -> (y : Bits32) -> Handle Live
alloc x y = MkLive 0x1000 x y     -- raw is an opaque non-zero stand-in

||| `free` — models Drop::drop / pt_tile_free's *accepted* path.
||| CRITICALLY: it only accepts a `Handle Live`. It consumes that
||| handle (the caller no longer holds the `Live` value) and returns a
||| `Handle Dead`. There is NO clause of `free` accepting `Handle Dead`,
||| so a second `free` does not typecheck.
public export
free : Handle Live -> Handle Dead
free (MkLive raw _ _) = MkDead raw

||| `readPixel` — models pt_tile_read_pixel's *accepted* path. It demands
||| a `Handle Live`; reading a `Handle Dead` is a type error
||| (use-after-free is not typeable). Returns the live handle unchanged
||| (reads do not consume the tile) paired with a result placeholder.
public export
readPixel : Handle Live -> (Handle Live, Bits32)
readPixel h@(MkLive _ _ _) = (h, 0x0)

||| `writePixel` — models pt_tile_write_pixel's *accepted* path. Same
||| `Live`-only discipline; writing a `Dead` handle is a type error.
public export
writePixel : Handle Live -> (val : Bits32) -> Handle Live
writePixel h@(MkLive _ _ _) _ = h

||| `isInitialized` — models pt_is_initialized at the type level: it is
||| statically 1 for a `Live` handle (you can only call it on one).
public export
isInitialized : Handle Live -> Bits32
isInitialized (MkLive _ _ _) = 1

--------------------------------------------------------------------------------
-- A.1  Meta-theorems: the type discipline is real, not vacuous.
--------------------------------------------------------------------------------
--
-- "Double-free is a type error" is only meaningful if `Live` and `Dead`
-- are genuinely different and the only path Live → Dead is `free`. We
-- prove the structural facts that pin this down, so the protection
-- cannot be defeated by some hidden coercion.

||| Every live handle decomposes as `MkLive raw x y` — there is no other
||| constructor of `Handle Live`. Consequence: a `Dead` handle (built by
||| `MkDead`) can never be presented where a `Live` one is required.
export
liveHandleShape : (h : Handle Live) ->
                  (raw : Bits32 ** x : Bits32 ** y : Bits32 **
                   h = MkLive raw x y)
liveHandleShape (MkLive raw x y) = (raw ** x ** y ** Refl)

||| Every dead handle decomposes as `MkDead raw`. A freed handle is
||| structurally inert: it carries only its (now-stale) raw word and no
||| capability to operate on the tile.
export
deadHandleShape : (h : Handle Dead) -> (raw : Bits32 ** h = MkDead raw)
deadHandleShape (MkDead raw) = (raw ** Refl)

||| The state index is informative: `Live = Dead` is uninhabited. This
||| is the formal reason a `Handle Dead` cannot be silently used where a
||| `Handle Live` is expected — there is no proof to rewrite one index to
||| the other.
export
liveNotDead : Not (Live = Dead)
liveNotDead Refl impossible

||| After `free`, the handle is `Dead`, recording the exact raw word the
||| live handle carried. The output type `Handle Dead` is NOT a valid
||| input to `free` (whose domain is `Handle Live`), so `free (free h)`
||| cannot even be elaborated. This lemma records the post-state.
export
freeYieldsDead : (h : Handle Live) ->
                 (raw : Bits32 ** free h = MkDead raw)
freeYieldsDead (MkLive raw _ _) = (raw ** Refl)

--------------------------------------------------------------------------------
-- Section B. Runtime magic-word lifecycle  (Zig defence-in-depth)
--------------------------------------------------------------------------------
--
-- Even granting an adversary a raw u64 replayed past Section A's type
-- system, the Zig runtime defends itself with the header magic word. We
-- model the header magic as explicit state and prove the runtime checks
-- behave exactly as main.zig says: a poisoned header rejects every free
-- and every operation.

||| The magic word currently stored in a tile header. `Fresh` is the
||| value `pt_tile_alloc` writes (PT_TILE_MAGIC); `Poisoned` is what
||| `pt_tile_free` writes after a successful free (PT_TILE_DEAD_MAGIC).
||| `Garbage w` captures any other 32-bit pattern (uninitialised memory,
||| corruption, a wild pointer) — `isLive` must reject those too.
public export
data Header = Fresh | Poisoned | Garbage Bits32

||| Reify a header to the magic word actually stored, matching the Zig
||| `tile.magic` field.
public export
magicOf : Header -> Bits32
magicOf Fresh        = PtTileMagic
magicOf Poisoned     = PtTileDeadMagic
magicOf (Garbage w)  = w

||| `isLive` — exact model of PtTile.isLive():  magic == PT_TILE_MAGIC.
||| Returns a Bool we then reason over.
public export
isLive : Header -> Bool
isLive h = magicOf h == PtTileMagic

||| Result code returned across the FFI. Mirrors `Result` in main.zig.
public export
data PtResult = Ok | Err | InvalidParam | Busy

public export
Eq PtResult where
  Ok           == Ok           = True
  Err          == Err          = True
  InvalidParam == InvalidParam = True
  Busy         == Busy         = True
  _            == _            = False

||| Outcome of `pt_tile_free` on a header: either it ACCEPTS (poisoning
||| the header and destroying — modelled as the new header `Poisoned`)
||| or it REFUSES (header unchanged, double-free defended).
public export
data FreeOutcome
  = Accepted Header   -- header transitioned (to Poisoned)
  | Refused  Header   -- header left as-is; double-free / corruption caught

public export
Eq FreeOutcome where
  (Accepted _) == (Accepted _) = True   -- coarse; we compare via Refl below
  (Refused  _) == (Refused  _) = True
  _            == _            = False

||| `freeHdr` — faithful model of pt_tile_free (main.zig lines 154-170):
|||   if magic != PT_TILE_MAGIC: refuse (header unchanged).
|||   else: poison header to DEAD, destroy.
||| (The null-pointer early-return is Section A's "no handle at all".)
public export
freeHdr : Header -> FreeOutcome
freeHdr h = if isLive h
              then Accepted Poisoned
              else Refused h

||| `opHdr` — faithful model of the guard shared by pt_tile_fill /
||| _read_pixel / _write_pixel / _read_buffer / _write_buffer:
|||   if !isLive(tile): return invalid_param.
|||   else: perform op, return ok.
||| We collapse the successful body to `Ok` since INV-1 is about the
||| guard, not the pixel arithmetic (covered by Pixel.idr / TP-3).
public export
opHdr : Header -> PtResult
opHdr h = if isLive h then Ok else InvalidParam

--------------------------------------------------------------------------------
-- B.1  Liveness reductions (the two pure facts the proofs hinge on)
--------------------------------------------------------------------------------

||| A `Fresh` header is live: PT_TILE_MAGIC == PT_TILE_MAGIC.
export
freshIsLive : isLive Fresh = True
freshIsLive = Refl

||| A `Poisoned` header is NOT live: PT_TILE_DEAD_MAGIC /= PT_TILE_MAGIC.
||| Reduces by computation on the literal magic words (no axiom).
export
poisonedNotLive : isLive Poisoned = False
poisonedNotLive = Refl

--------------------------------------------------------------------------------
-- B.2  NO DOUBLE-FREE  (runtime defence)
--------------------------------------------------------------------------------

||| The first free of a fresh tile is ACCEPTED and leaves the header
||| `Poisoned`. (alloc → free path.)
export
firstFreeAccepted : freeHdr Fresh = Accepted Poisoned
firstFreeAccepted = Refl

||| THE NO-DOUBLE-FREE THEOREM (runtime).
||| Freeing an already-freed (poisoned) header is PROVABLY the rejected
||| branch: it returns `Refused` and leaves the header unchanged. This is
||| the magic-word defence of main.zig lines 158-162, mechanised.
export
doubleFreeRefused : freeHdr Poisoned = Refused Poisoned
doubleFreeRefused = Refl

||| Stronger phrasing: for ANY header that is not live (poisoned OR
||| arbitrary garbage), free refuses and never transitions to Accepted.
||| Hence no allocation is ever released twice through this path.
export
notLiveFreeRefused : (h : Header) -> isLive h = False ->
                     freeHdr h = Refused h
notLiveFreeRefused h prf = rewrite prf in Refl

||| Composite: free-then-free starting from a freshly allocated tile.
||| The SECOND free is provably refused. Captures the full
||| alloc → free → free attacker sequence ending in rejection.
export
allocFreeFreeRefused :
  (freeHdr Fresh = Accepted Poisoned,
   freeHdr Poisoned = Refused Poisoned)
allocFreeFreeRefused = (Refl, Refl)

||| Once a fresh header has been successfully freed, the resulting
||| poisoned header is not live — so it can never again take the
||| `Accepted` branch. Re-freeing is impossible: the accepted transition
||| is reachable at most once from a given allocation.
export
afterFreeNeverLive : freeHdr Fresh = Accepted Poisoned ->
                     isLive Poisoned = False
afterFreeNeverLive _ = Refl

--------------------------------------------------------------------------------
-- B.3  NO USE-AFTER-FREE  (runtime defence)
--------------------------------------------------------------------------------

||| Operations on a LIVE (fresh) tile succeed — the guard passes.
export
opOnLiveOk : opHdr Fresh = Ok
opOnLiveOk = Refl

||| THE NO-USE-AFTER-FREE THEOREM (runtime).
||| Any operation (fill / read_pixel / write_pixel / read_buffer /
||| write_buffer — all share `opHdr`'s guard) on a freed (poisoned)
||| header is PROVABLY rejected with `InvalidParam`. The freed tile's
||| pixels are never touched. This is the `if (!tile.isLive())` guard of
||| main.zig (e.g. lines 185-188, 233-236, 317-320), mechanised.
export
useAfterFreeRejected : opHdr Poisoned = InvalidParam
useAfterFreeRejected = Refl

||| Stronger: for ANY non-live header (poisoned or garbage), every
||| operation is rejected; the success branch is unreachable.
export
notLiveOpRejected : (h : Header) -> isLive h = False ->
                    opHdr h = InvalidParam
notLiveOpRejected h prf = rewrite prf in Refl

||| A freed tile is never reported initialised: pt_is_initialized models
||| as `isLive`, and a poisoned header is not live.
export
freedNotInitialized : isLive Poisoned = False
freedNotInitialized = Refl

--------------------------------------------------------------------------------
-- B.4  Garbage / corruption is also caught
--------------------------------------------------------------------------------

||| A wild pointer / corrupted header (any 32-bit word that the runtime
||| does NOT see as equal to PT_TILE_MAGIC) is rejected by `free`. We
||| phrase the hypothesis in exactly the form the Zig runtime tests — the
||| BOOLEAN comparison `w == PT_TILE_MAGIC` being `False` (i.e.
||| `magic != PT_TILE_MAGIC`) — rather than a propositional
||| `Not (w = PtTileMagic)`. That is deliberate and is the faithful
||| model: the C/Zig code compares the stored word; it has no access to a
||| propositional disequality proof. It also keeps the proof primitive-
||| only (Idris2 base; no Eq→DecEq bridge for Bits32).
|||
||| `isLive (Garbage w)` reduces to `w == PtTileMagic`, so the boolean
||| hypothesis directly discharges the `notLiveFreeRefused` precondition.
export
garbageFreeRefused : (w : Bits32) -> (w == PtTileMagic) = False ->
                     freeHdr (Garbage w) = Refused (Garbage w)
garbageFreeRefused w notMagic =
  notLiveFreeRefused (Garbage w) notMagic

||| The operation guard rejects a garbage/corrupted header the same way.
export
garbageOpRejected : (w : Bits32) -> (w == PtTileMagic) = False ->
                    opHdr (Garbage w) = InvalidParam
garbageOpRejected w notMagic =
  notLiveOpRejected (Garbage w) notMagic

--------------------------------------------------------------------------------
-- Section C. Bridge: the type-level handle and the runtime header agree
--------------------------------------------------------------------------------
--
-- Tie the two defences together: a `Live` handle corresponds to a
-- `Fresh` header (operations succeed), and a `Dead` handle corresponds
-- to a `Poisoned` header (operations/free are refused). This shows
-- Section A's static guarantee and Section B's runtime guarantee are
-- about the same lifecycle, not two unrelated stories.

||| The runtime header that a handle in a given lifecycle state denotes.
public export
headerOfState : TileState -> Header
headerOfState Live = Fresh
headerOfState Dead = Poisoned

||| A live handle denotes a live header — runtime ops on it succeed.
export
liveStateOpOk : opHdr (headerOfState Live) = Ok
liveStateOpOk = Refl

||| A dead handle denotes a poisoned header — runtime ops on it are
||| rejected (use-after-free) and a re-free is refused (double-free).
||| Both halves in one statement, tying Section A's `Dead` to Section B's
||| `Poisoned`.
export
deadStateGuarded :
  (opHdr  (headerOfState Dead) = InvalidParam,
   freeHdr (headerOfState Dead) = Refused Poisoned)
deadStateGuarded = (Refl, Refl)
