# GoStdLib InputFetch Failure Investigation

**Date**: 2026-04-17  
**Cluster**: `pa-prod-australiaeast` / namespace `aksbazelbuildfarm`  
**Trigger commit**: `cbdc432612d` — [golang][1.25.9] bump toolchain version  
**Failed action**: `d8354af2bc973706fa87a9fafdc68e0c654990ce1e2eed8462b2ddae83ba238e/148`

---

## Symptom

After bumping Go **1.25.8 → 1.25.9**, `aksbuilder.sh build -w devinfraservices/e2e/e2e-ssl` fails:

```
GoStdlib external/rules_go~/stdlib_/pkg failed: (Exit 34): Remote Execution Failure:
Failed Precondition: Action d8354af2.../148 is invalid:
Operation has been requeued too many times ( 4 > 3).
```

---

## Confirmed Facts

| Item | Status |
|------|--------|
| GoStdLib action has **no ActionCache hit** | ✅ confirmed |
| All input blobs **exist in CAS** (no missing blobs) | ✅ confirmed (`bf-cat Missing` returns empty) |
| Worker requeued **4 times**, each failing | ✅ confirmed |
| **Go 1.25.8** GoStdLib action has **remote cache hit** → succeeds immediately | ✅ confirmed |
| **Go 1.25.9** GoStdLib action is a **brand-new digest**, never succeeded on buildfarm | ✅ confirmed |
| Without `--extra_toolchains`, GoStdLib uses system gcc → different action digest (`1a00761f`) → has cache hit → succeeds | ✅ confirmed |
| With `--extra_toolchains=@llvm_toolchain//:all` (added by aksbuilder), GoStdLib uses LLVM → new digest `d8354af2` → no cache → triggers InputFetch | ✅ confirmed |
| Failure occurs in **InputFetchStage**, not ExecuteActionStage | ✅ confirmed (worker log) |
| First failure takes **~60s** (inputFetchDeadline); all subsequent failures take **~12ms** | ✅ confirmed |

---

## GoStdLib Action Details

Queried via `bf-cat` against australia buildfarm (port-forwarded to `127.0.0.1:8980`).

### Why `--extra_toolchains` matters

`--extra_toolchains=@llvm_toolchain//:all` causes GoStdLib to switch from system gcc to the
hermetic LLVM toolchain. This changes:
- `CC` → `external/toolchains_llvm~~llvm~llvm_toolchain/bin/cc_wrapper.sh`
- `CGO_LDFLAGS` → uses `lld`, `libunwind.a`, etc.
- Input root → adds **141 MB of LLVM binaries** (clang-cpp 188 MB, clang 181 MB, …)

Total input root size: **~702 MB** (561 MB Go SDK sources + 141 MB LLVM toolchain).

Because the action digest changed, it has never been executed on buildfarm before — no
ActionCache result exists — so every build must execute it from scratch.

---

## Root Cause: `DirectoryEntryCFC.fetchers` stale future bug

### The bug

`DirectoryEntryCFC` uses a Guava `Cache` to deduplicate concurrent directory-fetch requests:

```java
// DirectoryEntryCFC.java line 69
private final Cache<Digest, ListenableFuture<Void>> fetchers = CacheBuilder.newBuilder().build();
```

When a fetch **succeeds**, the entry is invalidated (line 248 inside `add()`):
```java
fetchers.invalidate(digest);
return immediateFuture(result);
```

When a fetch **fails or is cancelled**, the `catchingAsync` error handler only removes the
directory from disk — it **never calls `fetchers.invalidate(digest)`**:

```java
// BEFORE FIX — missing invalidate on failure path
catchingAsync(limited, Throwable.class, e -> {
    Directories.remove(path, fileStore);        // cleans up disk
    return immediateFailedFuture(e);            // but leaves stale future in fetchers!
}, service);
```

Result: a **cancelled/failed future is permanently stuck in `fetchers`**.  
Every subsequent call to `putDirectory(digest, ...)` retrieves the stale future via
`fetchers.get(digest, ...)` (the loader is NOT called if the key already exists), wraps it in
a new `transformAsync`, and returns a future that is already cancelled — causing
`fetchedFuture.get()` in `CFCLinkExecFileSystem.createExecDir` (line 383) to throw
`CancellationException` within ~12 ms.

### Full failure chain

```
GoStdLib action d8354af2.../148 — no ActionCache hit, must execute
  → Worker 1 dispatched
    → InputFetchStage → createExecDir()
      → linkDirectory() → fileCache.putDirectory(Go SDK dir digest)
        → DirectoryEntryCFC.putDirectory()
          → fetchers.get(digest, loader)   ← loader called: new future F created
            → fetch() → downloads ~561 MB Go SDK source tree
    → 60 s: inputFetchDeadline expires → InputFetch thread interrupted
      → fetch() interrupted → future F ends as CANCELLED
      → catchingAsync: Directories.remove() called, but fetchers NOT invalidated
      → fetchers[digest] = stale CANCELLED future F   ← BUG
    → Worker 1 fails, operation requeued (requeueAttempts = 1)

  → Worker 2 dispatched (same operation)
    → InputFetchStage → createExecDir()
      → linkDirectory() → fileCache.putDirectory(same digest)
        → DirectoryEntryCFC.putDirectory()
          → fetchers.get(digest, loader)   ← loader NOT called (key exists!)
            → returns stale CANCELLED future F immediately
        → fetchedFuture = transformAsync(F, ...)  → already cancelled
    → fetchedFuture.get() throws CancellationException in ~12 ms
    → Worker 2 fails, operation requeued (requeueAttempts = 2)

  → Workers 3, 4, 5: same pattern, ~12 ms each
  → requeueAttempts (4) > maxRequeueAttempts (3) → FAILED_PRECONDITION
```

### Worker log evidence

```
2026-04-16T18:03:47.135Z  FINE    InputFetchStage::iterate(shard/executions/b88a4b3a...): 1/1
2026-04-16T18:03:47.145Z  WARNING InputFetcher run
    error while fetching inputs: shard/executions/b88a4b3a...
    java.util.concurrent.CancellationException: Task was cancelled.
      at AbstractFuture.cancellationExceptionWithCause(AbstractFuture.java:1021)
      at AbstractFuture.getDoneValue(AbstractFuture.java:288)
      at AbstractFutureState.blockingGet(AbstractFutureState.java:254)
      at AbstractFuture.get(AbstractFuture.java:253)
      at CFCLinkExecFileSystem.createExecDir(CFCLinkExecFileSystem.java:383)
      at InputFetcher.fetchPolled(InputFetcher.java:230)
2026-04-16T18:03:47.148Z  FINE    InputFetchStage::iterate: 12.413ms Failure
```

~12 ms — no download was attempted. The future was already cancelled.

---

## Fix

### Code fix (`DirectoryEntryCFC.java`) — **already applied**

Add `fetchers.invalidate(digest)` to the failure path in `add()`:

```java
// AFTER FIX
catchingAsync(limited, Throwable.class, e -> {
    // Invalidate the stale future so subsequent attempts can retry the real fetch.
    fetchers.invalidate(digest);
    try {
        Directories.remove(path, fileStore);
    } catch (IOException removeException) {
        e.addSuppressed(removeException);
    }
    return immediateFailedFuture(e);
}, service);
```

### Config fix (`values.yaml`) — **already applied**

Increase `inputFetchDeadline` from the default 60 s to 600 s so the first download of
702 MB has enough time to complete and populate the ActionCache:

```yaml
config:
  worker:
    inputFetchDeadline: 600   # seconds; default was 60
```

---

## Immediate remediation steps

1. **Restart worker pods** — clears the in-memory `fetchers` cache on all workers, removing
   the stale cancelled future so the next attempt can actually download the inputs.

2. **Apply the configmap change** (`inputFetchDeadline: 600`) — ensures the first
   download (702 MB) has 10 minutes to complete rather than timing out at 60 s.

3. **Re-run aksbuilder** — once GoStdLib builds successfully even once, the ActionResult is
   written to the ActionCache and all subsequent builds get an instant cache hit.

---

## Why plain `bazel build` (without aksbuilder flags) succeeds

| Flag | Plain `bazel build` | aksbuilder |
|------|---------------------|------------|
| `--extra_toolchains` | none | `@llvm_toolchain//:all` |
| `--extra_execution_platforms` | none | `@io_bazel_rules_go//go/toolchain:linux_amd64` |
| GoStdLib toolchain | system gcc | hermetic LLVM |
| GoStdLib action digest | `1a00761f.../148` (has cache hit) | `d8354af2.../148` (no cache hit) |

Without `--extra_toolchains`, GoStdLib uses system gcc → old digest with existing
ActionCache entry → instant cache hit → InputFetch never triggered → bug never hit.
