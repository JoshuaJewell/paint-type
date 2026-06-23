#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Manifest File Verification Script
# Verifies that all directories have required AI-MANIFEST and README.adoc files
#
# Usage: ./verify-manifests.sh [DIRECTORY]
#
# If no directory specified, uses current directory.

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"

if [ ! -d "$REPO_ROOT" ]; then
    echo "Error: Directory does not exist: $REPO_ROOT"
    exit 1
fi

REPO_ROOT=$(realpath "$REPO_ROOT")

MISSING_MANIFESTS=0
MISSING_READMES=0
TOTAL_DIRS=0
COMPLIANT_DIRS=0

echo "=== Manifest File Verification ==="
echo "Repository: $REPO_ROOT"
echo ""

# Find all directories (excluding skipped ones)
while IFS= read -r -d $'\0' dir; do
    # Skip directories that should not have manifests
    # Note: .github is NOT skipped because its subdirectories need manifests
    dir_name=$(basename "$dir")
    case "$dir_name" in
        .git) continue ;;
        .machine_readable) continue ;;
        node_modules) continue ;;
        .DS_Store) continue ;;
        __pycache__) continue ;;
        .egg-info) continue ;;
        .mypy_cache) continue ;;
        .pytest_cache) continue ;;
        .tox) continue ;;
        .nox) continue ;;
        .cache) continue ;;
        .local) continue ;;
        build) continue ;;
        dist) continue ;;
        target) continue ;;
        .idea) continue ;;
        .vscode) continue ;;
        *.swp) continue ;;
        *.tmp) continue ;;
        .zig-cache) continue ;;
    esac
    
    # Calculate depth
    # Normalize dir to absolute path
    dir_abs=$(realpath "$dir")
    relative_path="${dir_abs#$REPO_ROOT/}"
    if [ "$relative_path" = "$dir_abs" ] || [ "$relative_path" = "" ] || [ "$relative_path" = "." ]; then
        # This is the repo root
        depth=0
    else
        # Count path components (not slashes)
        # For "src" -> depth 1, "src/bridges" -> depth 2, etc.
        depth=$(echo "$relative_path" | tr '/' '\n' | grep -v '^$' | wc -l)
    fi
    
    TOTAL_DIRS=$((TOTAL_DIRS + 1))
    
    # Determine expected manifest filename
    if [ "$depth" = "0" ]; then
        expected_manifest="$dir/0-AI-MANIFEST.a2ml"
    else
        expected_manifest="$dir/0.${depth}-AI-MANIFEST.a2ml"
    fi
    
    expected_readme="$dir/README.adoc"
    
    # Check manifest exists
    if [ ! -f "$expected_manifest" ]; then
        echo "::error file=$expected_manifest::Missing AI-MANIFEST: $expected_manifest"
        MISSING_MANIFESTS=$((MISSING_MANIFESTS + 1))
    else
        echo "✓ Manifest: $expected_manifest"
    fi
    
    # Check README exists (skip root if it has README.md)
    if [ "$depth" = "0" ]; then
        # Root can have either README.adoc or README.md
        if [ ! -f "$expected_readme" ] && [ ! -f "$dir/README.md" ]; then
            echo "::error file=$expected_readme::Missing README: $expected_readme (or README.md)"
            MISSING_READMES=$((MISSING_READMES + 1))
        else
            echo "✓ README: $expected_readme or README.md"
        fi
    else
        if [ ! -f "$expected_readme" ]; then
            echo "::error file=$expected_readme::Missing README.adoc: $expected_readme"
            MISSING_READMES=$((MISSING_READMES + 1))
        else
            echo "✓ README: $expected_readme"
        fi
    fi
    
    # Count compliant directories
    if [ -f "$expected_manifest" ]; then
        if [ "$depth" = "0" ]; then
            if [ -f "$expected_readme" ] || [ -f "$dir/README.md" ]; then
                COMPLIANT_DIRS=$((COMPLIANT_DIRS + 1))
            fi
        else
            if [ -f "$expected_readme" ]; then
                COMPLIANT_DIRS=$((COMPLIANT_DIRS + 1))
            fi
        fi
    fi
    
done < <(find "$REPO_ROOT" -type d -print0)

echo ""
echo "=== Verification Summary ==="
echo "Total directories: $TOTAL_DIRS"
echo "Compliant directories: $COMPLIANT_DIRS"
echo "Missing manifests: $MISSING_MANIFESTS"
echo "Missing READMEs: $MISSING_READMES"
echo ""

# Fail if any are missing
if [ "$MISSING_MANIFESTS" -gt 0 ] || [ "$MISSING_READMES" -gt 0 ]; then
    echo "❌ Manifest file verification FAILED"
    echo "Missing $MISSING_MANIFESTS manifest files and $MISSING_READMES README files"
    exit 1
else
    echo "✅ All directories have required manifest files!"
    exit 0
fi
