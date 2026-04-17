# wasix-org LLVM patch inventory — for #119 Phase 1.1 rebase

**Source:** `github.com/wasix-org/llvm-project` @ tag `21.1.203` (published 2025-12-11).
**Base:** upstream `llvm/llvm-project` @ tag `llvmorg-21.1.2`.
**Delta:** 8 commits, 0 commits behind. `main` branch equals `21.1.203` (no unreleased work).
**Target for rebase:** upstream `llvm/llvm-project` @ tag `llvmorg-22.1.0`.

**Headline finding:** the entire wasix-org LLVM patch set is **~55 lines of source changes across 5 files** plus one 29-line release script and one small test deletion. This is dramatically smaller than the "rebase could take 2–5 days" worst case the plan feared. Mechanical `git cherry-pick` on upstream 22.1.0 is the expected happy path; a clean attempt takes hours, not days.

## Patch-by-patch inventory

### 1. `a5d9e371` — TLS model selection without emscripten

**Author:** Zebreus, 2025-05-30
**File:** `llvm/lib/Target/WebAssembly/WebAssemblyISelLowering.cpp` (+1/-3)
**Function touched:** `WebAssemblyTargetLowering::LowerGlobalTLSAddress`

**Capability:** Allows non-emscripten WebAssembly targets (wasix, wasip2 threaded) to use the TLS model declared on the global variable rather than being force-downgraded to `LocalExecTLSModel`. Without this patch, any non-emscripten WASM target is locked into local-exec TLS — which breaks dynamic TLS (the whole point of dylink + pthread).

**Upstream API it depends on:** `Subtarget->getTargetTriple().isOSEmscripten()`, `GV->getThreadLocalMode()`, `GlobalValue::LocalExecTLSModel`. All three are long-stable LLVM APIs. Unlikely to move in 21 → 22.

**22.1.0 risk:** LOW. The change is three lines in one function, removing a ternary. Unless upstream refactored `LowerGlobalTLSAddress` between 21.1.2 and 22.1.0 (very unlikely — this is target-specific WebAssembly code, not a hot area of churn), this applies mechanically.

**Semantic reimplementation:** if the patch fails to apply, the intent is simply "remove the emscripten-only gate on `GV->getThreadLocalMode()`." The two lines to change would be obvious to reapply.

---

### 2. `1bd057001c` — WIP: Remove failing tests

**Author:** Zebreus, WIP commit
**File:** `llvm/test/CodeGen/WebAssembly/tls-local-exec.ll` (+0/-4)

**Capability:** Deletes 4 lines of a test that expected the old "force local-exec" behavior from patch #1. This patch pairs with `a5d9e371` — the test file asserts the behavior the code change modifies.

**Upstream API risk:** NONE — it's a test file.

**22.1.0 risk:** LOW. The test file path is stable. Even if the specific assertions changed in upstream 22, the right move is to re-verify the test suite against our patched behavior rather than force-apply these exact line deletions.

**Semantic reimplementation:** re-run the test, identify whatever assertion fails because of patch #1's new behavior, and either delete that assertion or update it to match.

**"WIP" caveat:** the commit message flags this as work-in-progress. Proper upstream hygiene would add a new test for the non-emscripten path, not just delete the old one. Worth fixing during rebase (add an `.ll` test covering the wasix/wasip2 TLS path).

---

### 3. `992372e67b` — Mark `wasix` as not building components

**Author:** Zebreus, 2025-06-06
**File:** `clang/lib/Driver/ToolChains/WebAssembly.cpp` (+1/-1)
**Function touched:** `TargetBuildsComponents`

**Capability:** Adds `wasix` to the list of WASI OS names that do NOT produce WASM components (the WASIp2 component-model output format). WASIp2+ produces components; legacy `wasi`, `wasip1`, and now `wasix` produce plain modules.

**Upstream API it depends on:** `TargetTriple.getOSName()`, `TargetTriple.isOSWASI()`. Stable.

**22.1.0 risk:** LOW. One-liner condition extension.

**Semantic reimplementation:** add `&& TargetTriple.getOSName() != "wasix"` to the boolean chain.

---

### 4. `40c8e2b330` — Call `__wasm_apply_global_tls_relocs` from `__wasm_init_memory`

**Author:** Arshia Ghafoori, 2025-07-21
**File:** `lld/wasm/Writer.cpp` (+9/-0)
**Function touched:** `Writer::createInitMemoryFunction`

**Capability:** After initializing each TLS segment in `__wasm_init_memory`, emits a CALL opcode to `__wasm_apply_global_tls_relocs` (an existing upstream synthetic function). This is what makes TLS relocations actually get applied for the main module at init time, rather than waiting for `__wasm_init_tls` per-thread.

**Upstream APIs it depends on:**
- `ctx.arg.sharedMemory`, `ctx.sym.applyGlobalTLSRelocs`, `s->isTLS()` — all lld-wasm internals
- `ctx.sym.applyGlobalTLSRelocs->getFunctionIndex()` — assumes the synthetic function exists
- `WASM_OPCODE_CALL` — stable WASM opcode constant

**Key upstream dependency:** `createApplyGlobalTLSRelocationsFunction` (which populates `ctx.sym.applyGlobalTLSRelocs`) is **upstream-owned** code that already exists in lld-wasm — patch #5 updates its comment but does not define it. We rely on it continuing to exist in 22.1.0.

**22.1.0 risk:** MEDIUM. The lld-wasm Writer has seen active development; the `ctx.sym.*` field may have been renamed or the insertion point (inside createInitMemoryFunction's TLS segment loop) may have moved. A line-for-line cherry-pick may fail.

**Semantic reimplementation:** after the upstream TLS-segment init code in `createInitMemoryFunction`, emit a CALL to `applyGlobalTLSRelocs`'s function index. The exact `ctx.sym.*` accessor may need updating. This is ~10 lines of engineering work.

---

### 5. `15bfaa58f3` — Cleanup: comment + remove redundant sharedMemory check

**Author:** Arshia Ghafoori, 2025-07-22
**File:** `lld/wasm/Writer.cpp` (+3/-4)

**Capability:** (a) updates the doc comment on `createApplyGlobalTLSRelocationsFunction` to reflect that it can now be called after `__tls_base` init (not only from `__wasm_init_tls`); (b) drops the `ctx.arg.sharedMemory &&` guard that patch #4 added — the TLS reloc call is always safe after TLS init runs, shared memory or not.

**22.1.0 risk:** LOW. Pure cleanup on top of patch #4. If #4 applies mechanically, so does #5.

**Semantic reimplementation:** trivial — rewrite the comment and remove the `sharedMemory` conjunct.

---

### 6. `5542292a50` — Build libunwind for WASM

**Author:** Arshia Ghafoori, 2025-07-21
**Files:** `libunwind/src/assembly.h` (+7/-0), `libunwind/src/config.h` (+1/-1)

**Capability:** Two minimal libunwind portability fixes so the runtime can be built for `wasm32` targets:
1. In `assembly.h`: short-circuit all the ELF/MachO/PPC/etc. assembler directives behind `#ifdef __wasm__` (they don't apply to WASM, which has no executable-stack or function-alias concepts). Defines `NO_EXEC_STACK_DIRECTIVE` to empty.
2. In `config.h`: extend the "no dllexport needed" condition to include `!defined(__wasm__)`.

**Commit title is self-deprecating ("weird, it should already do that out of the box")** — suggests this is a workaround that upstream libunwind may have fixed independently between 21.1.2 and 22.1.0. Worth checking before rebasing.

**22.1.0 risk:** LOW-MEDIUM. If upstream libunwind already handles `__wasm__` in 22, this patch becomes redundant or needs to be trimmed. If not, it applies cleanly (the surrounding code is very stable — ELF/MachO macros don't churn).

**Semantic reimplementation:** trivial. The shape of the patch is "gate non-WASM-applicable assembler directives behind `#ifdef __wasm__`" — three minutes of engineering if the mechanical apply fails.

---

### 7. `077c6c637a` — Export `__wasm_apply_tls_relocs` for dynamic linker

**Author:** Arshia Ghafoori, 2025-08-05
**File:** `lld/wasm/Writer.cpp` (+3/-2)
**Function touched:** `Writer::createSyntheticInitFunctions`

**Capability:** Changes the visibility of the `__wasm_apply_tls_relocs` synthetic function from `HIDDEN` to `DEFAULT | EXPORTED`. This is what allows a dynamic linker (our wasmer runtime) to look up and call that function on a just-mapped shared-object WASM module to apply its TLS relocations.

Note: this is a **different symbol from patch #4's `applyGlobalTLSRelocs`**:
- `__wasm_apply_tls_relocs` (patch #7, per-module) — exported so dynamic linker can call it for each .so module loaded.
- `__wasm_apply_global_tls_relocs` (patch #4, main-module) — called internally by `__wasm_init_memory`.

The Wasmer blog post on dylink-wasix ("we had to create our own fork of LLVM") is specifically referring to *these* patches (#4, #5, #7).

**Upstream APIs it depends on:**
- `symtab->addSyntheticFunction`, `WASM_SYMBOL_VISIBILITY_DEFAULT`, `WASM_SYMBOL_EXPORTED` — standard lld-wasm symbol table APIs. Stable.

**22.1.0 risk:** LOW-MEDIUM. Same general concern as patch #4: lld-wasm's Writer has seen churn. The specific symbol addition call may have moved or been refactored.

**Semantic reimplementation:** when creating the `__wasm_apply_tls_relocs` synthetic function, OR the visibility bits to include `EXPORTED`. Regardless of surrounding refactors, this is one conceptual change.

---

### 8. `63389e3816` — Add `wasix-release.sh` build script

**Author:** Arshia Ghafoori
**File:** `wasix-release.sh` (+29 new file)

**Capability:** 29-line shell script for building minimal LLVM releases consumable by wasixcc. Not LLVM source — purely build orchestration.

**22.1.0 risk:** ZERO. It's a new file in the repo root. Cannot conflict.

**Semantic reimplementation:** not needed — we may not even want this patch in our fork (our build orchestration lives in `github.com/jmfirth/clang-wasix/build.sh` already).

---

## Rebase plan implications

### Attempt order (smallest blast radius first)

1. **#6 libunwind** — if upstream 22 already has `__wasm__` support, drop it entirely; otherwise apply cleanly.
2. **#3 `TargetBuildsComponents`** — one-liner, extremely unlikely to conflict.
3. **#1 TLS model** — small, localized, low churn area.
4. **#2 test deletion** — pairs with #1.
5. **#4 → #5 → #7 lld-wasm Writer.cpp triad** — the risky group. All three touch `Writer.cpp`. If any fails, the other two likely fail too (surrounding context changed). Handle as a unit.
6. **#8 wasix-release.sh** — skip. Our `build.sh` already does this job.

### Expected outcomes (calibrated)

- **Best case (60-70% likely):** All 7 source patches apply cleanly via `git am --3way` on upstream 22.1.0. Total rebase time: an afternoon. The "2-5 day HIGH RISK" sub-phase in the plan was worst-case.
- **Typical case (25-35%):** 1-2 patches (likely in the Writer.cpp triad) need 3-way resolution because the insertion point shifted. Semantic reimplementation is straightforward because the intent is documented here. Total: 1-2 days.
- **Worst case (<10%):** lld-wasm Writer has been significantly refactored in 22. The TLS-reloc wiring has to be redesigned. Plan's 5-10 day semantic-reimplementation budget kicks in. The inventory above is still the spec — we know what the behavior needs to be.

### Escalation trigger

Per `feedback_patch_forward_never_downgrade.md`: if the Writer.cpp triad genuinely can't be reimplemented on 22's lld-wasm without deeper expertise than we have, escalate rather than subset or downgrade. The options in that case: (1) recruit LLVM help, (2) contribute upstream to wasix-org asking for a 22.x port, (3) pause #119.

## Open questions to verify before attempting mechanical rebase

1. **Does upstream LLVM 22.1.0 still have `createApplyGlobalTLSRelocationsFunction` in `lld/wasm/Writer.cpp`?** If it was renamed or removed, patch #4 has to redirect. (Check: grep the 22.1.0 file.)
2. **Does upstream LLVM 22.1.0 already include the libunwind `__wasm__` workarounds?** If yes, patch #6 is a no-op. (Check: diff `libunwind/src/assembly.h` between 21.1.2 and 22.1.0.)
3. **Does `ctx.sym.applyGlobalTLSRelocs` field name persist in 22.1.0?** Patch #4 references it; if the struct was refactored, reference has to update.

All three are 5-minute lookups in the upstream repo. Doing them *before* starting the cherry-pick loop avoids wasted attempts.

## Inventory metadata

- **Author of inventory:** Claude (session 2026-04-16, post-Phase-0 close-out)
- **Inventory method:** GitHub API compare `llvmorg-21.1.2...21.1.203` + raw `.patch` fetch per SHA
- **Source patches stored:** `/Users/jfirth/projects/ai/projects/firebox-forks/wasix-patches-21.1.203/*.patch`
- **Intended use:** spec for Phase 1.1.3–1.1.4 rebase work. This doc survives regardless of whether mechanical cherry-pick succeeds — it *is* the semantic definition of what our 22.1.0 fork must do.
