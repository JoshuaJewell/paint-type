;; SPDX-License-Identifier: AGPL-3.0-or-later
(bot-directive
  (bot "rhodibot")
  (scope "rsr-compliance")
  (allow ("metadata" "docs" "repo-structure checks"))
  (deny ("destructive edits without approval"))
  (notes "Auto-fix allowed only for formatting in docs and metadata"))
