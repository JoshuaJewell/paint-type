#!/usr/bin/env pwsh
# One-off relicensing script: paint.type → AGPL-3.0-or-later.
# Skips .git, the LICENSE file (rewritten by hand), and binary artifacts.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

$skipDirs = @('.git', 'src\interface\build', 'target', 'node_modules')
$skipExt  = @('.ttc', '.ttm', '.png', '.jpg', '.gif', '.ico', '.pdf', '.zip', '.gz', '.tar', '.exe', '.dll', '.so', '.dylib', '.wasm', '.idx', '.pack', '.rev')

$replacements = @(
    @{ from = 'SPDX-License-Identifier: MPL-2.0'; to = 'SPDX-License-Identifier: AGPL-3.0-or-later' },
    @{ from = 'SPDX-License-Identifier:MPL-2.0';  to = 'SPDX-License-Identifier:AGPL-3.0-or-later'  },
    @{ from = 'SPDX-License-Identifier: MPL-2.0';           to = 'SPDX-License-Identifier: AGPL-3.0-or-later' },
    @{ from = 'SPDX-License-Identifier:MPL-2.0';            to = 'SPDX-License-Identifier:AGPL-3.0-or-later'  },
    # Field values (TOML/YAML/Nix-string/JSON/CFF/BibTeX)
    @{ from = 'license = "MPL-2.0"'; to = 'license = "AGPL-3.0-or-later"' },
    @{ from = "license = 'MPL-2.0'"; to = "license = 'AGPL-3.0-or-later'" },
    @{ from = 'license: MPL-2.0';    to = 'license: AGPL-3.0-or-later' },
    @{ from = '"MPL-2.0"';            to = '"AGPL-3.0-or-later"' },
    @{ from = "'MPL-2.0'";            to = "'AGPL-3.0-or-later'" },
    @{ from = '{MPL-2.0}';            to = '{AGPL-3.0-or-later}' },
    # README badge URL fragment (-- because shield URLs escape hyphens)
    @{ from = 'license-PMPL--1.0--or--later-blue'; to = 'license-AGPL--3.0--or--later-blue' },
    # Remaining prose mentions
    @{ from = 'MPL-2.0'; to = 'AGPL-3.0-or-later' }
)

$touched = 0
$skipped = 0
Get-ChildItem -Path $root -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1)
    foreach ($d in $skipDirs) { if ($rel -like "$d\*" -or $rel -eq $d) { $skipped++; return } }
    if ($skipExt -contains $_.Extension.ToLower()) { $skipped++; return }
    if ($rel -eq 'LICENSE') { return }   # hand-rewritten
    if ($rel -eq '.relicense.ps1') { return }

    try {
        $content = Get-Content -Raw -LiteralPath $_.FullName -ErrorAction Stop
    } catch { return }

    if ($null -eq $content) { return }
    $orig = $content
    foreach ($r in $replacements) {
        $content = $content.Replace($r.from, $r.to)
    }
    if ($content -ne $orig) {
        # Preserve original encoding family by re-writing as UTF-8 (no BOM).
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($_.FullName, $content, $utf8NoBom)
        $touched++
    }
}

Write-Output "Touched: $touched"
Write-Output "Skipped: $skipped"
