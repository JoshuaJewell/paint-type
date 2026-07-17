<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Schema: hyperpolymath/standards/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc -->

# Proof debt

Ledger of every soundness-relevant escape hatch in paint-type's own
proof-bearing code (Idris2 ABI modules, Lean4/Agda artifacts, TLA+ specs,
and `unsafe`-adjacent Rust). Proof *coverage* status (11/16 obligations
discharged) lives in `PROOF-STATUS.adoc`; this file tracks only escapes —
`believe_me`, `assert_total`, `partial`, `sorry`, `postulate`, `Admitted`,
and friends.

As of 2026-07-17, paint-type's first-party proof files contain **zero**
undocumented escape hatches. The 8 markers the trusted-base scan finds in
this repository are all inside the vendored `third_party/gossamer/` tree and
are exempted via `.trusted-base-ignore` — they are gossamer's trusted base,
tracked upstream in `hyperpolymath/gossamer`, not debt this repo can pay
down. If a vendor sync ever grows that set, re-review the exemption rather
than widening it silently.

## (a) Discharged in this repo

- (none — entries are removed when the proof lands)

## (b) Budgeted — tested with refutation budget

- (none)

## (c) Necessary axiom

- (none)

## (d) DEBT — actively to be closed

- (none — new first-party escape hatches MUST be entered here with an
  owner and a deadline, or annotated inline with `TRUSTED:`/`AXIOM:` per
  the policy)
