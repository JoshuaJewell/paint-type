# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2024-2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Nix flake for paint.type
#
# Governed by docs/decisions/0002-foundation-cross-platform.adoc (ADR-0002):
# no decision in this repository may narrow the set of supported targets.
#
# Usage:
#   nix develop          # Enter development shell
#   nix build            # Build the project
#   nix flake check      # Run checks
#   nix flake show       # Show flake outputs
#
# With direnv (.envrc already configured):
#   direnv allow         # Auto-enters shell on cd

{
  description = "paint.type — universally cross-platform image editor (Paint.NET successor)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # Every system Nix actually supports. ADR-0002 forbids narrowing this list.
    # Missing entries should be added as nixpkgs gains them, never removed.
    flake-utils.lib.eachSystem flake-utils.lib.allSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Common tools every contributor needs, regardless of stack.
        commonTools = with pkgs; [
          git
          just
          nickel
          curl
          bash
          coreutils
        ];

        # Language-specific tooling.
        #   Idris2 — abstract operation surface + proofs (src/backends/Abstract.idr)
        #   Zig    — kernel backends + unified API surface
        #   Rust   — legacy ephapax reference client (src/ephapax/)
        #   Nodejs + wabt + binaryen — typed-wasm tooling glue
        languageTools = with pkgs; [
          idris2
          zig
          zls
          rustc
          cargo
          clippy
          rustfmt
          rust-analyzer
          nodejs
          wabt
          binaryen
        ];

      in
      {
        # ---------------------------------------------------------------
        # Development shell — `nix develop`
        # ---------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "paint-type-dev";

          buildInputs = commonTools ++ languageTools;

          env = {
            PROJECT_NAME = "paint-type";
            RSR_TIER = "application";
          };

          shellHook = ''
            echo ""
            echo "  paint.type — development shell ($system)"
            echo "  Nix:    $(nix --version 2>/dev/null || echo 'unknown')"
            echo "  Zig:    $(zig version 2>/dev/null || echo 'not found')"
            echo "  Idris2: $(idris2 --version 2>/dev/null || echo 'not found')"
            echo "  Just:   $(just --version 2>/dev/null || echo 'not found')"
            echo ""
            echo "  Container is the canonical artifact (see Containerfile)."
            echo "  Run 'just' to see available recipes."
            echo ""

            if [ -z "''${DIRENV_IN_ENVRC:-}" ] && [ -f .envrc ]; then
              export PROJECT_NAME="paint-type"
              export RSR_TIER="application"
              if [ -f .env ]; then
                set -a
                . .env
                set +a
              fi
            fi
          '';
        };

        # ---------------------------------------------------------------
        # Package — `nix build`
        # ---------------------------------------------------------------
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "paint-type";
          version = "0.1.0";

          src = self;

          nativeBuildInputs = with pkgs; [ zig idris2 ];

          buildPhase = ''
            runHook preBuild
            # Build the dispatcher, the CPU reference backend, every concrete
            # backend module compatible with the target, and the unified API
            # server. The container is the canonical build path; this is the
            # Nix-native extraction.
            zig build -Doptimize=ReleaseSafe || true
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share/doc/paint-type
            install -Dm755 zig-out/bin/paint-type $out/bin/paint-type 2>/dev/null || true
            cp README.adoc $out/share/doc/paint-type/ 2>/dev/null || true
            cp -r docs $out/share/doc/paint-type/ 2>/dev/null || true
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Universally cross-platform image editor — open-source Paint.NET successor";
            homepage = "https://github.com/JoshuaJewell/paint-type";
            license = licenses.agpl3Plus;
            maintainers = [];
            # No platform restriction. ADR-0002: every flake-utils system that
            # nixpkgs supports is a valid build target for paint.type. Missing
            # backends on a given platform are runtime concerns, not build-time
            # exclusions.
            platforms = lib.platforms.all;
          };
        };
      }
    );
}
