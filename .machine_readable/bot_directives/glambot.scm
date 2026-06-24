;; SPDX-License-Identifier: AGPL-3.0-or-later
(bot-directive
  (bot "glambot")
  (scope "presentation + accessibility")
  (allow ("docs" "readme badges" "ui/accessibility suggestions"))
  (deny ("logic changes"))
  (notes "Edits limited to presentation layers"))
