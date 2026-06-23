# Audit: UnboundedAllocation False Positive in src/host/src/main.rs

**Date:** 2026-06-07  
**Severity:** Critical (false positive)  
**File:** `src/host/src/main.rs`  
**Status:** False Positive - Compile-time bounded

## Finding

Panic-attack reports: `Potential unbounded allocation pattern detected in main.rs`

## Analysis

There are two potential allocation points in this file:

### 1. Runtime: `std::fs::read_to_string(&path)` (line 58)

**Status: ✅ FIXED**

This is **NOT** unbounded. The code performs a file size check **before** the read:

```rust
let meta = std::fs::metadata(&path)?;  // line 49
if meta.len() > max_bytes {              // lines 51-56
    return Err(...);
}
let html = std::fs::read_to_string(&path)?;  // line 58 - AFTER size check
```

- `max_bytes` defaults to 10 MiB (`PT_UI_FILE_MAX_BYTES_DEFAULT`)
- The check prevents any file larger than the limit from being read
- This closes the unbounded allocation vulnerability

### 2. Compile-time: `include_str!("../../ui/index.html")` (line 70)

**Status: ✅ FALSE POSITIVE**

This is a **compile-time** string inclusion, not a runtime allocation. The file:
- Is embedded into the binary at compile time
- Current size: 6,780 bytes (verified: `ls -la src/ui/index.html`)
- Cannot change at runtime
- Is subject to compiler limits (Rust has compile-time memory limits)

## Recommendation

This finding should be **suppressed** as a false positive. The actual vulnerability (unbounded runtime allocation) was fixed in PR #50. The compile-time inclusion is not a security concern.

## Evidence

```bash
$ ls -la src/ui/index.html
-rw-r--r-- 1 user group 6780 Jun  7 09:04 src/ui/index.html

$ grep -A5 -B5 "PT_UI_FILE_MAX_BYTES" src/host/src/main.rs
const PT_UI_FILE_MAX_BYTES_DEFAULT: u64 = 10 * 1024 * 1024;
match std::env::var("PT_UI_FILE") {
    Ok(path) => {
        let max_bytes: u64 = std::env::var("PT_UI_FILE_MAX_BYTES")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(PT_UI_FILE_MAX_BYTES_DEFAULT);
        let meta = std::fs::metadata(&path)?;
        if meta.len() > max_bytes {
            return Err(...);
        }
```
