// SPDX-License-Identifier: AGPL-3.0-or-later
//
// INV-1a — decode() totality. The .ptype decoder's documented contract is
// "every malformed input maps to a typed DecodeError — decode never panics on
// bad data". This target asserts that property over arbitrary bytes: libFuzzer
// flags any panic, abort, or OOM as a crash. We deliberately ignore the
// Ok/Err result — only the *absence of a crash* is under test here.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = ptype_format::decode(data);
});
