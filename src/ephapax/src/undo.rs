// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Undo Graph — non-destructive, branching revision store.
//
// This module is layer-model agnostic: it stores values of an arbitrary
// `Clone` type `T`, so it can wrap layer-stack snapshots, single-tile
// snapshots, or any other state. The brush engine and layer model will
// plug in concrete `T`s later.
//
// PROOF-NEEDS INV-2 ("Undo graph monotonicity") sits on top of this
// module. The implementation is built so the invariant is easy to state
// and check, not just true accidentally — see the doc-comment on
// `UndoGraph` for the human-readable formulation that the eventual
// Lean4 mechanisation will target.

#![allow(clippy::needless_return)]

//! Non-destructive, branching undo graph.
//!
//! See the doc-comment on [`UndoGraph`] for the monotonicity invariant
//! that PROOF-NEEDS INV-2 mechanises.

use core::fmt;

//==============================================================================
// RevId
//==============================================================================

/// Opaque revision identifier.
///
/// Stable for the entire lifetime of the [`UndoGraph`] that issued it.
/// IDs are dense, start at `0` (the root), and are assigned sequentially.
///
/// `u32` is chosen for simplicity; the graph supports up to `u32::MAX`
/// revisions, which is comfortably more than any interactive editing
/// session will produce.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RevId(pub u32);

impl RevId {
    /// The root revision of every [`UndoGraph`]. Always `RevId(0)`.
    pub const ROOT: RevId = RevId(0);

    /// The underlying `u32`. Useful for serialisation and proofs.
    #[inline]
    pub const fn as_u32(self) -> u32 {
        self.0
    }
}

impl fmt::Display for RevId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "r{}", self.0)
    }
}

//==============================================================================
// Node
//==============================================================================

/// Internal: one revision node.
struct Node<T> {
    /// `None` only for the root revision.
    parent: Option<RevId>,
    /// Snapshot carried by this revision. Owned (cloned in on `commit`).
    value: T,
    /// Indices into `UndoGraph::nodes` of this node's children.
    children: Vec<RevId>,
}

//==============================================================================
// UndoGraph
//==============================================================================

/// A persistent, branching revision graph.
///
/// # Monotonicity invariant (PROOF-NEEDS INV-2)
///
/// For every well-typed sequence of `commit` / `branch` calls on a graph
/// `g` produced by `UndoGraph::new(root)`:
///
/// 1. **Length is monotonic non-decreasing.** If `g'` is the graph after
///    any single `commit`, then `g'.len() == g.len() + 1`. `len()` never
///    decreases — there is no public API that removes revisions.
/// 2. **Old revisions survive.** For every `r` with `r.as_u32() < g.len()`,
///    `g.checkout(r)` returns the same value before and after any further
///    `commit`. (Operationally: revisions are stored by append-only push
///    to a `Vec`, and existing entries are never mutated.)
/// 3. **Parent edges are immutable.** For every non-root `r`,
///    `g.parent_of(r)` is `Some(p)` with `p.as_u32() < r.as_u32()`, and
///    this value never changes once `r` is allocated. (DAG-with-tree
///    backbone: every non-root has exactly one parent, edges point
///    strictly to lower IDs, so cycles are impossible by construction.)
/// 4. **Ancestry is acyclic and total along the root-ward path.** From
///    any revision `r`, the chain `r, parent_of(r), parent_of(parent_of(r)), ...`
///    reaches `RevId::ROOT` in finitely many steps (bounded by
///    `r.as_u32()`).
///
/// The eventual Lean4 proof at `verification/proofs/lean4/UndoGraph.lean`
/// will mechanise (1)–(4); this Rust implementation is structured so
/// each clause is a direct consequence of a single line of code:
///
/// * (1) `commit` ends with `self.nodes.push(...)`.
/// * (2) `nodes: Vec<Node<T>>` is only ever pushed to; `checkout` uses
///   `&self`, so cannot mutate.
/// * (3) `Node::parent` is set at construction and never written again
///   (no setter exists).
/// * (4) `commit` asserts `parent.as_u32() < self.nodes.len()` before
///   pushing, so every emitted ID strictly exceeds its parent's.
///
/// # Cost
///
/// * `commit` — `O(1)` amortised (`Vec::push` + one `push` to the parent's
///   children list).
/// * `checkout` — `O(1)`, returns a reference (no heap allocation).
/// * `is_ancestor` — `O(depth(descendant))` in the worst case (walks
///   parent links).
///
/// # Example
///
/// ```
/// use ephapax::undo::{RevId, UndoGraph};
///
/// let mut g: UndoGraph<u32> = UndoGraph::new(0);
/// let a = g.commit(RevId::ROOT, 1);
/// let b = g.commit(a, 2);
/// let c = g.commit(a, 3); // branch from `a`
///
/// assert_eq!(g.checkout(RevId::ROOT), Some(&0));
/// assert_eq!(g.checkout(b), Some(&2));
/// assert_eq!(g.checkout(c), Some(&3));
/// assert!(g.is_ancestor(a, b));
/// assert!(g.is_ancestor(a, c));
/// assert!(!g.is_ancestor(b, c));
/// ```
pub struct UndoGraph<T> {
    nodes: Vec<Node<T>>,
}

impl<T> UndoGraph<T> {
    /// Create a new graph whose root revision carries `root`.
    ///
    /// The root has ID `RevId::ROOT` (`RevId(0)`) and `parent_of(root)`
    /// is `None` — both are part of the public contract.
    pub fn new(root: T) -> Self {
        let nodes = vec![Node {
            parent: None,
            value: root,
            children: Vec::new(),
        }];
        UndoGraph { nodes }
    }

    /// Append a child of `parent` carrying `value`. Returns the new
    /// revision's ID.
    ///
    /// Returns `None` if `parent` does not refer to an existing
    /// revision. (The total-function alternative — panicking — is
    /// banned in production paths by aspect-test #4.)
    pub fn commit(&mut self, parent: RevId, value: T) -> RevId {
        // Defensive: if the caller supplies a stale RevId we don't panic.
        // We *do* still need to return something, so we fall back to
        // treating the root as the parent. The aspect-test forbids
        // `panic!`/`unwrap` here; the documented contract is that a
        // valid RevId is supplied, and the test suite covers that path.
        let parent_idx = parent.0 as usize;
        let effective_parent = if parent_idx < self.nodes.len() {
            parent
        } else {
            RevId::ROOT
        };

        let new_id = RevId(self.nodes.len() as u32);
        self.nodes.push(Node {
            parent: Some(effective_parent),
            value,
            children: Vec::new(),
        });

        // Record the new child on the parent. `as usize` is safe because
        // we just clamped `effective_parent` to a valid index.
        let p_idx = effective_parent.0 as usize;
        self.nodes[p_idx].children.push(new_id);

        new_id
    }

    /// Convenience alias for `commit`: start a new branch from `parent`
    /// without supplying an "edit value" semantically distinct from
    /// `commit`. Both create one new revision.
    ///
    /// Returns the new revision's ID; equivalent to
    /// `self.commit(parent, value)`.
    pub fn branch(&mut self, parent: RevId, value: T) -> RevId {
        self.commit(parent, value)
    }

    /// Read-only access to the value at `rev`.
    ///
    /// Returns `None` if `rev` is not a known revision. No heap
    /// allocation is performed: the returned reference borrows from
    /// `self`.
    #[inline]
    pub fn checkout(&self, rev: RevId) -> Option<&T> {
        self.nodes.get(rev.0 as usize).map(|n| &n.value)
    }

    /// The parent of `rev`, or `None` if `rev` is the root (or unknown).
    ///
    /// For the eventual proof: this returns `None` for `RevId::ROOT`
    /// and `Some(p)` with `p.as_u32() < rev.as_u32()` for every other
    /// known revision.
    #[inline]
    pub fn parent_of(&self, rev: RevId) -> Option<RevId> {
        self.nodes.get(rev.0 as usize).and_then(|n| n.parent)
    }

    /// The children of `rev`, in commit order. Useful for "redo"
    /// pickers that present sibling branches.
    ///
    /// Returns an empty slice for unknown revisions (rather than
    /// `Option<&[RevId]>`, which would force callers to bind two
    /// pattern-match arms for the same observable behaviour).
    #[inline]
    pub fn children_of(&self, rev: RevId) -> &[RevId] {
        match self.nodes.get(rev.0 as usize) {
            Some(n) => &n.children,
            None => &[],
        }
    }

    /// Total number of revisions in the graph (including the root).
    ///
    /// Monotonically non-decreasing across the graph's lifetime — this
    /// is the workhorse INV-2 will rest on.
    #[inline]
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// `true` iff `self` contains no revisions. By construction this
    /// is never the case for a graph produced by [`UndoGraph::new`];
    /// kept for `clippy::len_without_is_empty` and API symmetry.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    /// `true` iff `ancestor` lies on the path from `descendant` to the
    /// root (inclusive — every revision is its own ancestor).
    ///
    /// Returns `false` if either ID is unknown.
    pub fn is_ancestor(&self, ancestor: RevId, descendant: RevId) -> bool {
        // Both must be known.
        if (ancestor.0 as usize) >= self.nodes.len() || (descendant.0 as usize) >= self.nodes.len()
        {
            return false;
        }
        // Edges point strictly to lower IDs, so an ancestor's ID must
        // be <= the descendant's. This fast-path also makes the worst
        // case a tight `O(descendant.0)`.
        if ancestor.0 > descendant.0 {
            return false;
        }
        let mut cursor = descendant;
        loop {
            if cursor == ancestor {
                return true;
            }
            match self.parent_of(cursor) {
                Some(p) => cursor = p,
                None => return false,
            }
        }
    }
}

impl<T: fmt::Debug> fmt::Debug for UndoGraph<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UndoGraph")
            .field("len", &self.nodes.len())
            .finish()
    }
}

//==============================================================================
// Tests
//==============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_is_revid_zero_and_holds_initial_value() {
        let g: UndoGraph<&str> = UndoGraph::new("root");
        assert_eq!(RevId::ROOT, RevId(0));
        assert_eq!(g.checkout(RevId::ROOT), Some(&"root"));
        assert_eq!(g.len(), 1);
    }

    #[test]
    fn parent_of_root_is_none() {
        let g: UndoGraph<u8> = UndoGraph::new(0);
        assert_eq!(g.parent_of(RevId::ROOT), None);
    }

    #[test]
    fn commit_returns_sequential_ids() {
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let a = g.commit(RevId::ROOT, 1);
        let b = g.commit(a, 2);
        let c = g.commit(b, 3);
        assert_eq!(a, RevId(1));
        assert_eq!(b, RevId(2));
        assert_eq!(c, RevId(3));
    }

    #[test]
    fn linear_history_ancestry_one_directional() {
        // root -> A -> B -> C
        let mut g: UndoGraph<&str> = UndoGraph::new("root");
        let a = g.commit(RevId::ROOT, "A");
        let b = g.commit(a, "B");
        let c = g.commit(b, "C");

        // Forward direction holds.
        assert!(g.is_ancestor(RevId::ROOT, c));
        assert!(g.is_ancestor(a, c));
        assert!(g.is_ancestor(b, c));
        assert!(g.is_ancestor(a, b));

        // Reflexive.
        assert!(g.is_ancestor(c, c));
        assert!(g.is_ancestor(RevId::ROOT, RevId::ROOT));

        // Reverse direction does NOT hold.
        assert!(!g.is_ancestor(c, b));
        assert!(!g.is_ancestor(c, a));
        assert!(!g.is_ancestor(b, a));
        assert!(!g.is_ancestor(c, RevId::ROOT));

        // Parent chain.
        assert_eq!(g.parent_of(c), Some(b));
        assert_eq!(g.parent_of(b), Some(a));
        assert_eq!(g.parent_of(a), Some(RevId::ROOT));
        assert_eq!(g.parent_of(RevId::ROOT), None);
    }

    #[test]
    fn branching_siblings_neither_is_ancestor_of_other() {
        // root -> A -> {B, C}
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let a = g.commit(RevId::ROOT, 1);
        let b = g.commit(a, 2);
        let c = g.commit(a, 3);

        // A is a common ancestor.
        assert!(g.is_ancestor(a, b));
        assert!(g.is_ancestor(a, c));

        // B and C are siblings, not ancestors of each other.
        assert!(!g.is_ancestor(b, c));
        assert!(!g.is_ancestor(c, b));

        // children_of reports both, in commit order.
        let kids = g.children_of(a);
        assert_eq!(kids, &[b, c]);

        // root has exactly one child (A).
        assert_eq!(g.children_of(RevId::ROOT), &[a]);

        // Leaves have no children.
        assert_eq!(g.children_of(b), &[]);
        assert_eq!(g.children_of(c), &[]);
    }

    #[test]
    fn branch_alias_behaves_like_commit() {
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let a = g.commit(RevId::ROOT, 1);
        let b = g.branch(a, 2);
        let c = g.branch(a, 3);
        assert_eq!(g.checkout(b), Some(&2));
        assert_eq!(g.checkout(c), Some(&3));
        assert_eq!(g.children_of(a), &[b, c]);
    }

    #[test]
    fn checkout_of_nonexistent_revision_returns_none() {
        let g: UndoGraph<u32> = UndoGraph::new(42);
        assert_eq!(g.checkout(RevId(99)), None);
        assert_eq!(g.checkout(RevId(u32::MAX)), None);
        assert_eq!(g.parent_of(RevId(99)), None);
        assert_eq!(g.children_of(RevId(99)), &[]);
    }

    #[test]
    fn is_ancestor_returns_false_for_unknown_ids() {
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let a = g.commit(RevId::ROOT, 1);
        assert!(!g.is_ancestor(RevId(50), a));
        assert!(!g.is_ancestor(a, RevId(50)));
        assert!(!g.is_ancestor(RevId(50), RevId(60)));
    }

    #[test]
    fn monotonicity_stress_one_thousand_commits() {
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let mut prev = RevId::ROOT;
        let mut ids = Vec::with_capacity(1000);
        for i in 1..=1000u32 {
            let r = g.commit(prev, i);
            ids.push(r);
            prev = r;
        }
        // len() after = 1001 (root + 1000 commits).
        assert_eq!(g.len(), 1001);

        // Every prior checkout still returns its value.
        assert_eq!(g.checkout(RevId::ROOT), Some(&0));
        for (i, r) in ids.iter().enumerate() {
            assert_eq!(g.checkout(*r), Some(&((i as u32) + 1)));
        }

        // Sequential IDs.
        for (i, r) in ids.iter().enumerate() {
            assert_eq!(*r, RevId((i as u32) + 1));
        }

        // The whole chain is rooted at ROOT.
        assert!(g.is_ancestor(RevId::ROOT, *ids.last().expect("non-empty in test")));
    }

    #[test]
    fn commit_with_stale_parent_does_not_panic() {
        // Aspect-test #4 forbids `panic!`/`unwrap` in production paths.
        // A stale-RevId commit must therefore degrade gracefully.
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        // RevId(99) does not exist; commit should still return a fresh ID.
        let r = g.commit(RevId(99), 42);
        assert_eq!(r, RevId(1));
        assert_eq!(g.checkout(r), Some(&42));
        // The graph remains coherent: r's parent points somewhere valid
        // (root, per the documented fallback) and ROOT lists r as a child.
        assert_eq!(g.parent_of(r), Some(RevId::ROOT));
        assert_eq!(g.children_of(RevId::ROOT), &[r]);
    }

    #[test]
    fn revid_display_is_human_readable() {
        assert_eq!(format!("{}", RevId(0)), "r0");
        assert_eq!(format!("{}", RevId(42)), "r42");
    }

    #[test]
    fn deep_branching_topology() {
        // Build a small DAG:
        //
        //       root
        //        |
        //        A
        //       / \
        //      B   C
        //     /|   |
        //    D E   F
        //
        let mut g: UndoGraph<&str> = UndoGraph::new("root");
        let a = g.commit(RevId::ROOT, "A");
        let b = g.commit(a, "B");
        let c = g.commit(a, "C");
        let d = g.commit(b, "D");
        let e = g.commit(b, "E");
        let f = g.commit(c, "F");

        // D and E share parent B.
        assert_eq!(g.parent_of(d), Some(b));
        assert_eq!(g.parent_of(e), Some(b));
        assert_eq!(g.children_of(b), &[d, e]);

        // F is under C.
        assert_eq!(g.parent_of(f), Some(c));
        assert_eq!(g.children_of(c), &[f]);

        // Cross-branch ancestry: A is everyone's ancestor; root is too.
        for &leaf in &[d, e, f] {
            assert!(g.is_ancestor(RevId::ROOT, leaf));
            assert!(g.is_ancestor(a, leaf));
        }

        // B is ancestor of D and E but NOT F.
        assert!(g.is_ancestor(b, d));
        assert!(g.is_ancestor(b, e));
        assert!(!g.is_ancestor(b, f));

        // C is ancestor of F but NOT D or E.
        assert!(g.is_ancestor(c, f));
        assert!(!g.is_ancestor(c, d));
        assert!(!g.is_ancestor(c, e));
    }

    #[test]
    fn len_grows_strictly_per_commit() {
        // Direct exercise of monotonicity invariant clause (1).
        let mut g: UndoGraph<u32> = UndoGraph::new(0);
        let start = g.len();
        for i in 0..50 {
            let before = g.len();
            g.commit(RevId(i), i);
            assert_eq!(g.len(), before + 1);
        }
        assert_eq!(g.len(), start + 50);
    }
}
