-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Mechanisation: Undo graph monotonicity  (PROOF-NEEDS INV-2)
--
-- Ground truth:
--   src/paint_core/src/undo.rs — doc-comment "# Monotonicity invariant
--   (PROOF-NEEDS INV-2)" on `UndoGraph<T>`. The four contract clauses are:
--
--   (1) Length is monotonic non-decreasing. After one `commit`,
--       `g'.len() == g.len() + 1`; `len()` never decreases (no removal API).
--   (2) Old revisions survive. `checkout(r)` of an existing `r` returns the
--       same value before and after any further `commit` (append-only `Vec`,
--       existing entries never mutated).
--   (3) Parent edges are immutable & point strictly to lower IDs. Every
--       non-root `r` has `parent_of(r) = Some(p)` with `p < r`, set once at
--       allocation; cycles are impossible by construction.
--   (4) Ancestry is acyclic and terminates along the root-ward path, in at
--       most `r.as_u32()` steps.
--
-- This file is pure Lean 4 core (NO mathlib, NO Std imports): it typechecks
-- with a bare `lean UndoGraph.lean` invocation. It contains no `sorry`,
-- `admit`, or `native_decide`.

/-! ## 0. Model

We model the graph exactly as `undo.rs` stores it: an append-only sequence
of nodes indexed by `RevId = Nat`, where node `i` carries a value and a
`parent : Option Nat`. The *well-formedness* discipline that `commit`
maintains (clause 3, "edges point strictly to lower IDs") is captured by a
predicate `WF`: the root (id `0`) has `parent = none`, and every other node
`i` has `parent = some p` with `p < i`.

`commit` in Rust does `new_id = RevId(len)`, then `nodes.push(node)`, then
records the child — never touching existing entries. We model this as `List`
*snoc* (append at the end), which is the formal mirror of `Vec::push`, and
prove the four clauses about it. -/

namespace UndoGraph

/-- One revision node: a parent pointer (`none` only for the root) and a
carried snapshot value of arbitrary type `α`. Mirrors `struct Node<T>`
(the `children` field is derived data, irrelevant to INV-2). -/
structure Node (α : Type) where
  parent : Option Nat
  value  : α

/-- The graph is the append-only node sequence, indexed by `RevId = Nat`.
Mirrors `struct UndoGraph<T> { nodes: Vec<Node<T>> }`. -/
abbrev Graph (α : Type) := List (Node α)

/-! ## 1. Observers (faithful models of the `pub fn`s)

`len`, `checkout`, `parent_of` are the `&self` read APIs; in Rust they read
from the `Vec` and never mutate. We reuse `List.length` and `List.get?`,
whose totality and out-of-bounds-→`none` behaviour exactly match
`Vec::len` / `Vec::get` / `slice::get`. -/

/-- `g.len()` — total revision count (including the root). -/
def len (g : Graph α) : Nat := g.length

/-- `g.checkout(r)` — value at revision `r`, `none` if unknown.
Mirrors `self.nodes.get(r).map(|n| &n.value)`. -/
def checkout (g : Graph α) (r : Nat) : Option α :=
  (g.get? r).map Node.value

/-- `g.parent_of(r)` — parent of `r`, `none` for the root or unknown ids.
Mirrors `self.nodes.get(r).and_then(|n| n.parent)`. -/
def parentOf (g : Graph α) (r : Nat) : Option Nat :=
  (g.get? r).bind Node.parent

/-! ## 2. Mutators

`commit` appends one node whose id is the current length (so the new
revision's id equals the old length, dense and sequential, matching
`RevId(self.nodes.len() as u32)`), with `parent := some p`. We expose it
as `List` snoc.

Because the value type is arbitrary and the new id is always `len g`, the
`commit` here takes the (already-validated) parent `p`; clause (3)'s
`p < new_id` is discharged from the precondition `p < len g`, which is
exactly the `parent_idx < self.nodes.len()` check `commit` performs before
push. -/

/-- Append a child of `p` carrying `v`. The new revision's id is `len g`. -/
def commit (g : Graph α) (p : Nat) (v : α) : Graph α :=
  g ++ [{ parent := some p, value := v }]

/-! ### 2.1 Stale-parent clamp (mechanises `undo.rs`'s `effective_parent`)

`undo.rs`'s `commit` does NOT take a pre-validated parent: it *clamps* a
stale/out-of-range requested parent to `RevId::ROOT` (`0`) before pushing:

```rust
let parent_idx = parent.0 as usize;
let effective_parent = if parent_idx < self.nodes.len() { parent }
                       else { RevId::ROOT };
```

We mechanise that clamp here and prove it always yields an in-range parent
on any *non-empty* graph (`0 < len g`), which is the standing precondition
in `undo.rs` — the `Vec` always contains at least the root after `new`, so
`RevId::ROOT = 0` is in bounds. The earlier `commit`'s precondition
`p < len g` is then *discharged*, not assumed, via `effectiveParent`. -/

/-- `effective_parent`: a requested parent `p` is kept when in range
(`p < len g`), otherwise clamped to `ROOT = 0`. Faithful mirror of
`undo.rs`'s `effective_parent` `if parent_idx < self.nodes.len()` branch. -/
def effectiveParent (g : Graph α) (p : Nat) : Nat :=
  if p < len g then p else 0

/-- The clamp always produces an in-range parent on a non-empty graph: for
any requested `p` (including a stale, out-of-range one), `effectiveParent g p
< len g`. The kept branch is in range by construction; the clamped branch is
`ROOT = 0`, in range because the graph is non-empty. Mirrors the `undo.rs`
comment "we just clamped `effective_parent` to a valid index". -/
theorem effectiveParent_lt (g : Graph α) (p : Nat) (hne : 0 < len g) :
    effectiveParent g p < len g := by
  unfold effectiveParent
  split
  · assumption          -- kept branch: the `if` condition `p < len g` IS the goal
  · exact hne            -- clamped branch: parent is `0`, in range since `0 < len g`

/-! ## 3. Well-formedness (the structural invariant `commit` preserves)

`WF g` ⇔ for every id `i < len g`, node `i`'s parent is `none` if `i = 0`
and `some p` with `p < i` otherwise. This is clause (3) stated as an
invariant; clauses (1),(2),(4) are then theorems about `commit`/`checkout`,
and the acyclicity/termination of clause (4) follows from `WF` alone. -/

/-- Parent-pointer well-formedness at a single id. -/
def NodeWF (g : Graph α) (i : Nat) : Prop :=
  match parentOf g i with
  | none   => True                 -- root (or unknown): no upward edge
  | some p => p < i                -- non-root: strictly-lower parent id

/-- The graph-level invariant: every revision is parent-well-formed. -/
def WF (g : Graph α) : Prop := ∀ i, i < len g → NodeWF g i

/-! ## 4. Clause (1): length is monotonic, strictly +1 per commit -/

/-- `commit` increases the length by exactly one (the `g'.len() == g.len()+1`
half of clause (1)). -/
theorem len_commit (g : Graph α) (p : Nat) (v : α) :
    len (commit g p v) = len g + 1 := by
  simp [len, commit, List.length_append]

/-- `len` never decreases across a commit (the "never decreases" half). -/
theorem len_commit_ge (g : Graph α) (p : Nat) (v : α) :
    len g ≤ len (commit g p v) := by
  rw [len_commit]; exact Nat.le_succ _

/-- The new revision's id is exactly the pre-commit length, hence strictly
the largest live id — dense, sequential, never reused. Mirrors
`new_id = RevId(self.nodes.len())`. -/
theorem newId_eq_old_len (g : Graph α) (p : Nat) (v : α) :
    (len (commit g p v)) = (len g) + 1 := len_commit g p v

/-! ## 5. Clause (2): old revisions survive an arbitrary further commit

`checkout` of any *existing* revision returns the *same* value after a
commit. We prove the general statement: for every `r < len g`,
`checkout (commit g p v) r = checkout g r`. The proof reduces to the fact
that `List.get?` on an in-bounds index is unaffected by appending, which is
the formal content of "append-only push never mutates existing entries". -/

/-- `List.get?` at an in-bounds index is invariant under appending on the
right. (Pure-core lemma; mirrors `Vec::push` not touching live entries.) -/
theorem getAppend_lt {α : Type} (xs ys : List α) {r : Nat}
    (h : r < xs.length) : (xs ++ ys).get? r = xs.get? r := by
  induction xs generalizing r with
  | nil => exact absurd h (Nat.not_lt_zero r)
  | cons x xs ih =>
    cases r with
    | zero => rfl
    | succ r' =>
      simp only [List.cons_append, List.get?]
      exact ih (Nat.lt_of_succ_lt_succ h)

/-- Clause (2): checking out an existing revision is invariant under any
further commit. The hypothesis `r < len g` is exactly `r.as_u32() < g.len()`
in the Rust contract. -/
theorem checkout_commit_stable (g : Graph α) (p : Nat) (v : α)
    {r : Nat} (h : r < len g) :
    checkout (commit g p v) r = checkout g r := by
  unfold checkout commit len at *
  rw [getAppend_lt g [{ parent := some p, value := v }] h]

/-- Corollary: a revision that *was* present (`checkout g r = some w`) still
reads back the same `w` after the commit. -/
theorem checkout_commit_preserves_value (g : Graph α) (p : Nat) (v : α)
    {r : Nat} {w : α} (h : r < len g) (hw : checkout g r = some w) :
    checkout (commit g p v) r = some w := by
  rw [checkout_commit_stable g p v h]; exact hw

/-! ## 6. Clause (3): commit preserves well-formedness (strictly-lower parents)

If `g` is well-formed and the (validated) parent `p < len g`, then the graph
after `commit g p v` is still well-formed: the new node sits at id `len g`
with parent `some p`, and `p < len g`. Existing nodes are unchanged
(clause (2)), so their well-formedness carries over. This is the immutable,
acyclic-by-construction edge discipline of clause (3). -/

/-- The parent pointer of an *existing* node is unchanged by a commit. -/
theorem parentOf_commit_lt (g : Graph α) (p : Nat) (v : α)
    {r : Nat} (h : r < len g) :
    parentOf (commit g p v) r = parentOf g r := by
  unfold parentOf commit len at *
  rw [getAppend_lt g [{ parent := some p, value := v }] h]

/-- `List.get?` at the first appended index returns the appended head.
(`xs.get? xs.length = (ys.get? 0)` when appending `ys`.) -/
theorem getAppend_eq {α : Type} (xs : List α) (y : α) (ys : List α) :
    (xs ++ y :: ys).get? xs.length = some y := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simpa [List.cons_append, List.get?] using ih

/-- The parent pointer of the *newly committed* node (id `len g`) is `some p`.
Mirrors `Node::parent` set once at construction. -/
theorem parentOf_commit_new (g : Graph α) (p : Nat) (v : α) :
    parentOf (commit g p v) (len g) = some p := by
  unfold parentOf commit len
  rw [getAppend_eq g { parent := some p, value := v } []]
  rfl

/-- Clause (3) preservation: a commit with a validated parent (`p < len g`)
on a well-formed graph yields a well-formed graph. The new edge points to a
strictly-lower id (`p < len g = new_id`), and every old edge is untouched. -/
theorem WF_commit (g : Graph α) (p : Nat) (v : α)
    (hwf : WF g) (hp : p < len g) :
    WF (commit g p v) := by
  intro i hi
  -- `i` ranges over `0 .. len g` (inclusive of the new id `len g`).
  rw [len_commit] at hi
  -- Either `i` is an old id (`i < len g`) or it is the new id (`i = len g`).
  rcases Nat.lt_or_ge i (len g) with hlt | hge
  · -- old node: parent unchanged, reuse `hwf`
    unfold NodeWF
    rw [parentOf_commit_lt g p v hlt]
    exact hwf i hlt
  · -- new node: `i = len g`, parent is `some p`, and `p < len g = i`
    have hieq : i = len g := Nat.le_antisymm (Nat.lt_succ_iff.mp hi) hge
    subst hieq
    unfold NodeWF
    rw [parentOf_commit_new g p v]
    exact hp

/-- **Stale-parent clamp, end to end** (mechanises `undo.rs`'s defensive
`effective_parent` path): committing with the *clamped* parent on a
non-empty, well-formed graph yields a well-formed graph for ANY requested
parent `p` — even a stale, out-of-range one. This is `WF_commit` with its
`p < len g` precondition *discharged* by the `effectiveParent` clamp
(`effectiveParent_lt`), exactly as `undo.rs` does: the caller need not supply
a validated parent; an out-of-range request is silently re-rooted to ROOT,
which is `0 < len g`. -/
theorem WF_commit_clamped (g : Graph α) (p : Nat) (v : α)
    (hwf : WF g) (hne : 0 < len g) :
    WF (commit g (effectiveParent g p) v) :=
  WF_commit g (effectiveParent g p) v hwf (effectiveParent_lt g p hne)

/-! ## 7. Clause (4): ancestry is acyclic and terminates root-ward

From `WF`, the parent pointer of any node strictly decreases its id. The
root-ward walk `r, parentOf r, parentOf (parentOf r), ...` therefore strictly
decreases the id at every step and must reach the root (`none` parent) in at
most `r` steps. We make this fully constructive:

* `ancestors g r fuel` walks up to `fuel` parent links from `r`.
* With `WF`, `r` steps of fuel always suffice to reach a node whose parent
  is `none` (the root) — i.e. the walk terminates. We prove the strict
  descent directly and conclude termination via well-founded recursion on the
  id (Lean's structural-recursion checker accepts the descent argument). -/

/-- A known node has an in-bounds id: if `parentOf g r = some p` then
`r < len g`. (A node whose parent is recorded must itself exist.) -/
theorem in_bounds_of_parent {g : Graph α} {r p : Nat}
    (h : parentOf g r = some p) : r < len g := by
  rcases Nat.lt_or_ge r (len g) with hlt | hge
  · exact hlt
  · -- out of bounds ⇒ `parentOf = none`, contradicting `h`
    exfalso
    have hnone : parentOf g r = none := by
      unfold parentOf len at *
      rw [List.get?_eq_none.mpr hge]; rfl
    rw [hnone] at h
    exact Option.noConfusion h

/-- Single root-ward step strictly decreases the id (the local acyclicity
fact). From `WF`, if `parentOf g r = some p` then `p < r`. A cycle would
require some step with `p ≥ r`, which `WF` forbids — so no cycle exists. -/
theorem parent_lt {g : Graph α} (hwf : WF g) {r p : Nat}
    (h : parentOf g r = some p) : p < r := by
  have hr : r < len g := in_bounds_of_parent h
  have hnode : NodeWF g r := hwf r hr
  unfold NodeWF at hnode
  rw [h] at hnode
  exact hnode

/-- The root-ward depth: number of parent links from `r` up to a node with no
parent. Defined by strong recursion on the id `r`; each recursive call is on
the strictly smaller parent id (`parent_lt`), so it terminates — this *is* the
"reaches `RevId::ROOT` in finitely many steps, bounded by `r`" content of
clause (4). It is a total Lean function precisely because ancestry is
well-founded. -/
def depth (g : Graph α) (hwf : WF g) (r : Nat) : Nat :=
  match hp : parentOf g r with
  | none   => 0
  | some p => depth g hwf p + 1
termination_by r
decreasing_by exact parent_lt hwf hp

/-- **Explicit step bound** (mechanises clause (4)'s quantitative
"bounded by `r.as_u32()` steps"): the root-ward depth from `r` is at most
`r` itself. Proof by well-founded recursion on `r` mirroring `depth`: the
`none` (root) case has depth `0 ≤ r`; the `some p` case has depth
`depth p + 1`, and by the IH `depth p ≤ p`, while `parent_lt` gives `p < r`,
i.e. `p + 1 ≤ r`, so `depth p + 1 ≤ p + 1 ≤ r`. -/
theorem depth_le_id (g : Graph α) (hwf : WF g) (r : Nat) :
    depth g hwf r ≤ r := by
  rw [depth.eq_def]
  match hp : parentOf g r with
  | none   => exact Nat.zero_le r
  | some p =>
    have hpr : p < r := parent_lt hwf hp
    have ih : depth g hwf p ≤ p := depth_le_id g hwf p
    exact Nat.succ_le_of_lt (Nat.lt_of_le_of_lt ih hpr)
termination_by r
decreasing_by exact parent_lt hwf hp

/-- Acyclicity, the headline of clause (4): **no revision is a proper
ancestor of itself**. Equivalently, the root-ward walk never returns to its
start: there is no `r` with `parentOf g r = some r`. Immediate from strict
descent (`r < r` is impossible). -/
theorem no_self_parent {g : Graph α} (hwf : WF g) (r : Nat) :
    parentOf g r ≠ some r := by
  intro h
  exact Nat.lt_irrefl r (parent_lt hwf h)

/-- Strengthened acyclicity / termination bound: the root-ward chain from any
`r` is bounded — formally, the parent id is always `< r`, so the sequence of
ids strictly decreases and (being a strictly decreasing sequence of `Nat`s)
must terminate at the root. We expose this as: every nonempty root-ward step
reaches a strictly smaller id, the exact "bounded by `r.as_u32()`" claim. -/
theorem chain_strictly_decreases {g : Graph α} (hwf : WF g) (r : Nat) :
    ∀ p, parentOf g r = some p → p < r :=
  fun _ h => parent_lt hwf h

/-! ## 8. End-to-end: a committed revision's ancestry terminates at the root

Putting clauses (3) and (4) together: after `commit g p v` on a well-formed
graph (with validated `p < len g`), the new revision `len g` has parent
`some p` with `p < len g`, and the whole graph stays well-formed — so the new
revision's own root-ward walk is finite (`depth` is defined on it). -/

theorem committed_revision_terminates (g : Graph α) (p : Nat) (v : α)
    (hwf : WF g) (hp : p < len g) :
    let g' := commit g p v
    ∃ hwf' : WF g', depth g' hwf' (len g) = depth g' hwf' p + 1 := by
  intro g'
  have hwf' : WF g' := WF_commit g p v hwf hp
  refine ⟨hwf', ?_⟩
  rw [depth.eq_def]
  rw [parentOf_commit_new g p v]

end UndoGraph
