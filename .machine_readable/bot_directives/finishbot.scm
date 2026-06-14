;; SPDX-License-Identifier: AGPL-3.0-or-later
(bot-directive
  (bot "finishbot")
  (scope "release readiness")
  (allow ("release checklists" "docs updates" "metadata fixes"))
  (deny ("code changes without approval"))
  (notes "Focus on polish, licensing, and packaging"))
