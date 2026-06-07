;; SPDX-License-Identifier: AGPL-3.0-or-later
(bot-directive
  (bot "robot-repo-automaton")
  (scope "automated fixes")
  (allow ("low-risk automated edits"))
  (deny ("core logic changes without approval"))
  (notes "Only apply fixes backed by explicit rule approval"))
