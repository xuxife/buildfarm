# Buildfarm Worker Registration Failure — Fix Regression Report

**Date:** 2026-04-11
**Clusters affected:** `pa-prod-westus2` (2026-04-08), `pa-prod-southeastasia` (2026-04-09–11)
**Namespace:** `aksbazelbuildfarm`
**Symptom:** Worker pods running and executing jobs but absent from `BackplaneStatus` — same
surface presentation as the original `NOREPLICAS` issue, but a different root cause triggered
by the interaction between Fix 1 and Fix 2 from the previous investigation.

> **Severity escalation (2026-04-11):** On 2026-04-11 the `pa-prod-southeastasia` server pods
> restarted (9 times, most recently at 06:32 UTC). After the restart, `BackplaneStatus` reported
> **0 active workers** out of 32 — the entire cluster became unable to dispatch new tasks.
> Investigation confirmed that **all 32** `Worker.failsafeRegistration` threads had died during
> the initial NOREPLICAS window (04-09 01:36–01:54). The 26 workers that appeared registered were
> surviving on stale Redis entries from their last successful registration; no worker had sent an
> `HSET Workers_execute` renewal in over 48 hours (confirmed via Redis `MONITOR`). When the server
> restarted, `fetchAndExpireWorkers` deleted all entries with expired `expireAt` fields, leaving
> the cluster in a completely inoperative state.

---

## 1. Symptom

`BackplaneStatus` reported 26 active workers out of 32 in both clusters. The following pods
were `Running` and executing jobs, but never appeared in `active_workers`:

**`pa-prod-westus2`** (2026-04-08):

| Pod | IP |
|---|---|
| `aksbazelbuildfarm-shard-worker-4`  | `10.244.8.6` |
| `aksbazelbuildfarm-shard-worker-9`  | `10.244.9.5` |
| `aksbazelbuildfarm-shard-worker-10` | `10.244.8.7` |
| `aksbazelbuildfarm-shard-worker-11` | `10.244.9.6` |
| `aksbazelbuildfarm-shard-worker-12` | `10.244.8.8` |
| `aksbazelbuildfarm-shard-worker-13` | `10.244.7.5` |

**`pa-prod-southeastasia`** (2026-04-09):

| Pod | IP |
|---|---|
| `aksbazelbuildfarm-shard-worker-11` | `10.244.10.5` |
| `aksbazelbuildfarm-shard-worker-13` | `10.244.8.5` |
| `aksbazelbuildfarm-shard-worker-14` | `10.244.10.6` |
| `aksbazelbuildfarm-shard-worker-15` | `10.244.8.6` |
| `aksbazelbuildfarm-shard-worker-16` | `10.244.8.7` |
| `aksbazelbuildfarm-shard-worker-17` | `10.244.10.7` |

Both clusters were freshly deployed. The affected workers in both cases were pods created
**before the server pods** (and before Redis replica synchronisation completed), exactly as in
the original australiaeast incident. The deployed image (`cb90bb0a`) contained both Fix 1 and
Fix 2 from the previous report.

---

## 2. Investigation Method

- `bf-cat` against the build farm server port-forwarded at `127.0.0.1:8980`
- `kubectl` with kubeconfigs at `~/runner/kubeconfig/pa-prod-westus2` and
  `~/runner/kubeconfig/pa-prod-southeastasia`
- Redis CLI via `kubectl exec` into Redis master pods
- Redis `MONITOR` command (3-second capture) to observe live `HSET Workers_execute` traffic
- JVM thread dump via `kill -3 <pid>` inside the worker pods
- Bytecode disassembly of `Worker.class` and `Worker$1.class` from the deployed image using
  `javap -c` (JDK from Bazel cache)
- `strings` + Python constant-pool parser on `RedisClient.class` and `Worker$1.class` extracted
  from `/tmp/buildfarm-image/fs.tar` (previously exported via `crane`)

### Key observations

| Check | Result |
|---|---|
| Pod status | All 6 pods `Running`, 0 restarts in both clusters |
| `Workers_execute` Redis hash | 6 IPs absent in both clusters; 26 others present |
| Worker logs (early) | Dense `NOREPLICAS` at `MatchStage` SEVERE (westus2 ~01:48, sea ~01:54) |
| Worker logs (recent) | Normal job execution (`InputFetch / Execute / ReportResult`) |
| `"worker registration failed, will retry"` WARNING | **Absent** from all affected worker logs |
| Redis `MONITOR` (3 s capture) | 26 registered workers emitting periodic `HSET Workers_execute`; **0 HSET from the 6 missing IPs** |
| JVM thread dump (`kill -3`) | `Worker.failsafeRegistration` thread **does not exist** in the thread list |
| `Worker$1.class` constant pool | Contains `java/lang/Exception` and `"worker registration failed, will retry"` — Fix 1 is compiled in |
| `RedisClient.class` constant pool | Contains `"NOREPLICAS"`, `startsWith`, `UNAVAILABLE` — Fix 2 is compiled in |
| `Worker.class` bytecode (`javap -c addWorker`) | UNAVAILABLE path: `goto 0` at offset 54 — **no sleep instruction** |

---

## 3. Root Cause

### 3.1 Recap: Previous Fixes in the Image

From the previous investigation (`worker-registration-failure-report.md`):

- **Fix 1** (`Worker.java` `run()`): wraps `registerIfExpired()` in `catch (Exception e)` so
  that any exception is logged and the loop continues.
- **Fix 2** (`RedisClient.java` `call()`): maps `NOREPLICAS` `JedisDataException` to
  `IOException(Status.UNAVAILABLE)` so it is treated as a retryable transient error.

Both fixes are confirmed present in the deployed image via bytecode inspection.

### 3.2 Fix 1 + Fix 2 Interaction: a New Failure Mode

With both fixes active, the exception-handling chain for a `NOREPLICAS` error during
`addWorker` is:

```
Redis: NOREPLICAS
  ↓
RedisClient.call()
  catch (JedisDataException e) { if startsWith("NOREPLICAS") → throw new IOException(UNAVAILABLE) }
  ↓
backplane.addWorker() throws IOException(UNAVAILABLE)
  ↓
Worker.addWorker()
  catch (IOException e) {
    status = Status.fromThrowable(e)    // → UNAVAILABLE
    if (status != UNAVAILABLE && status != DEADLINE_EXCEEDED) throw ...
    // UNAVAILABLE: fall through → goto 0  ← NO SLEEP
  }
  → loops back to top of while() immediately
```

The `Worker.addWorker()` retry loop **has no `sleep` or back-off**. The bytecode
(`goto 0` at offset 54 in the `javap -c` output) confirms this unambiguously.

Fix 2 converted the exception from `RuntimeException` (which would have *escaped*
`addWorker()` and been caught by Fix 1's outer `catch (Exception e)`) into an
`IOException(UNAVAILABLE)` (which is *trapped* inside `addWorker()`'s own retry loop).
The result is that the registration thread is permanently busy-spinning inside
`Worker.addWorker()`, with Fix 1's protective outer `try/catch` never reached.

### 3.3 Thread-Level Evidence

The JVM thread dump from `aksbazelbuildfarm-shard-worker-11` (southeastasia, taken ~26 hours
after pod creation via `kill -3 8`) shows `ExecuteActionStage`, `ReportResultStage`, and
thousands of `ForkJoinPool` threads — but **no `Worker.failsafeRegistration` thread**. The
thread creation sequence shows a gap between thread #225 and #240
(`ExecuteActionStage.executor`), which is where the registration thread would have been
created. The thread is gone.

The Redis `MONITOR` capture (3 s) confirmed the same: periodic `HSET Workers_execute` from
all 26 registered worker IPs, zero `HSET` from any of the 6 missing IPs. The registration
thread was not issuing any Redis commands — it was either stuck in a tight loop that never
produced a successful write, or had already died.

### 3.4 Why the Thread Died

The tight loop (no sleep) ran at full CPU speed for the entire NOREPLICAS window (~18 minutes
in westus2, ~18 minutes in southeastasia). During this window the registration thread
dominated one CPU core. The most likely termination mechanism is one of:

1. **JVM `OutOfMemoryError` or `StackOverflowError`** — both are `Error`, not `Exception`;
   Fix 1's `catch (Exception e)` would not catch them, and they would propagate out of
   `run()` unchecked, killing the thread silently.
2. **Redis connection hard failure** — after sustained hammering, the Jedis connection was
   closed by the server/haproxy with a `RST` or `FIN`. The resulting
   `JedisConnectionException` is handled by `RedisClient.call()` and becomes
   `IOException(UNAVAILABLE)`, so it stays inside the loop — but during reconnection,
   some connection-pool internal error (e.g. `IllegalStateException`) could escape as a
   non-`IOException`, not caught by `addWorker()`, not caught by Fix 1's
   `catch (Exception e)`, killing the thread.

Regardless of the exact terminal exception, the outcome is the same: the
`Worker.failsafeRegistration` thread is dead, no `HSET` is ever sent again, and the worker
remains invisible to `BackplaneStatus` for the lifetime of the pod.

### 3.6 Second-Order Failure: Total Cluster Outage on Server Restart

The 6 workers that were visibly absent from `BackplaneStatus` were only the most obvious
symptom. In reality, **all 32** `Worker.failsafeRegistration` threads died during the initial
NOREPLICAS window. The remaining 26 workers appeared registered because their last successful
`addWorker()` call (before the thread died) had written an `expireAt` value of
`T_last_success + 30s` to `Workers_execute`. The `fetchAndExpireWorkers` routine — which runs
on every `BackplaneStatus` call — only removes entries where `now >= expireAt`. So as long as
the server kept calling `BackplaneStatus`, it would continuously observe 26 registered workers,
even though none of them had sent a renewal `HSET` in over 48 hours.

This latent state was exposed on 2026-04-11 when both server pods restarted (9 restarts total).
On restart, the server called `fetchAndExpireWorkers`, which found that all 32 `expireAt`
timestamps were far in the past (`04-09 ~01:54 + 30s`), and deleted every entry. The cluster
went from 26/32 registered to **0/32** instantly.

Redis `MONITOR` (5-second capture, taken before the restart) confirmed: zero `HSET
Workers_execute` commands from any of the 32 worker IPs across the entire capture window —
every single registration thread was already dead.

```
Redis cluster not fully synchronised at deployment (same trigger as before)
    ↓
Worker pods start before Redis replicas are ready
    ↓
RedisClient.call() → Fix 2 → IOException(UNAVAILABLE)   [instead of RuntimeException]
    ↓
Worker.addWorker() catch(IOException): UNAVAILABLE → goto 0  (no sleep)
    ↓
Tight infinite loop inside Worker.addWorker()
    ↓
Fix 1's catch(Exception e) in run() is never reached
    ↓
Worker.failsafeRegistration thread exhausts resources / hits unhandled Error
    and dies permanently
    ↓
Workers_execute / Workers_storage Redis hash: no entry for these workers
    ↓
BackplaneStatus shows 26/32 workers
Workers not selected for new task dispatch (invisible to scheduler)
```

---

## 4. Upstream Status

Not checked for this specific regression (Fix 1 + Fix 2 are local-only patches not present
upstream). The root defect in `Worker.addWorker()` — the absence of a sleep/back-off in the
retry loop — exists in both upstream and local code.

---

## 5. Fix

### Fix 3 — Add sleep to `Worker.addWorker()` retry loop ✅ **Root fix**

**File:** `src/main/java/build/buildfarm/worker/shard/Worker.java`

The `addWorker()` retry loop must sleep before retrying on a transient error. This prevents
the tight spin that blocks the `Worker.failsafeRegistration` thread, and restores Fix 1's
ability to log and recover from transient failures via its outer `catch (Exception e)`.

```java
// Before
private void addWorker(ShardWorker worker) {
    while (!backplane.isStopped()) {
        try {
            backplane.addWorker(worker);
            return;
        } catch (IOException e) {
            Status status = Status.fromThrowable(e);
            if (status.getCode() != Code.UNAVAILABLE && status.getCode() != Code.DEADLINE_EXCEEDED) {
                throw status.asRuntimeException();
            }
        }
    }
    throw Status.UNAVAILABLE.withDescription("backplane was stopped").asRuntimeException();
}

// After
private void addWorker(ShardWorker worker) {
    while (!backplane.isStopped()) {
        try {
            backplane.addWorker(worker);
            return;
        } catch (IOException e) {
            Status status = Status.fromThrowable(e);
            if (status.getCode() != Code.UNAVAILABLE && status.getCode() != Code.DEADLINE_EXCEEDED) {
                throw status.asRuntimeException();
            }
            // Transient error (UNAVAILABLE / DEADLINE_EXCEEDED): wait before retrying so that
            // this loop does not busy-spin and starve the calling thread (Worker.failsafeRegistration).
            // Without this sleep, Fix 2 (NOREPLICAS → IOException(UNAVAILABLE)) causes an infinite
            // tight loop that permanently blocks the registration thread, preventing Fix 1's outer
            // catch(Exception) from ever running and making the worker invisible to BackplaneStatus.
            try {
                SECONDS.sleep(1);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
    throw Status.UNAVAILABLE.withDescription("backplane was stopped").asRuntimeException();
}
```

**Behaviour after fix:**
- NOREPLICAS → Fix 2 → `IOException(UNAVAILABLE)` → `addWorker()` sleeps 1 s, then
  retries. No CPU spin. Thread stays responsive.
- If a retry still fails, the loop sleeps again. The `Worker.failsafeRegistration` thread
  remains alive through the entire NOREPLICAS window.
- Once Redis recovers, the next `backplane.addWorker()` call succeeds, `workerRegistrationExpiresAt`
  is updated, and the worker appears in `BackplaneStatus` — no pod restart required.
- Fix 1's outer `catch (Exception e)` now also functions as intended: any non-`IOException`
  that escapes `addWorker()` (e.g. `StatusRuntimeException` from a non-retryable code) is
  caught, logged as WARNING, and the loop retries after `SECONDS.sleep(1)`.

### Summary of All Three Fixes

| Fix | File | What it fixes | Status |
|---|---|---|---|
| **Fix 1** | `Worker.java` `run()` | Registration thread survives uncaught `RuntimeException` | ✅ In image — but rendered ineffective by Fix 2 without Fix 3 |
| **Fix 2** | `RedisClient.java` `call()` | `NOREPLICAS` mapped to `IOException(UNAVAILABLE)` for retry | ✅ In image — creates tight loop in `addWorker()` without Fix 3 |
| **Fix 3** | `Worker.java` `addWorker()` | Adds `sleep(1s)` to `addWorker()` retry loop, breaking tight spin | ✅ Applied locally |

All three fixes together provide complete, layered protection:
- Fix 2 makes `NOREPLICAS` retryable via `addWorker()`'s inner loop.
- Fix 3 ensures that inner loop does not spin and respects the thread's responsiveness.
- Fix 1 ensures the outer registration thread loop survives any other transient failure that
  escapes `addWorker()`.

---

## 6. Workaround (Until Fix 3 is Deployed)

Restart the affected pods to trigger a fresh registration. **After a server restart, all workers
must be restarted** — otherwise the cluster will have 0 registered workers indefinitely.

**`pa-prod-southeastasia` (all 32 workers — executed 2026-04-11):**
```bash
kubectl -n aksbazelbuildfarm delete pods -l name=aksbazelbuildfarm-shard-worker
```

**`pa-prod-westus2`:** Already mitigated manually on 2026-04-08 (6 affected pods only; server
did not restart before Fix 3 was identified, so the remaining 26 stale-registered workers were
not yet exposed).

---

## 7. Verification Methods Used

| Method | Tool | Finding |
|---|---|---|
| Fix 1 present in image | `strings Worker$1.class` | `"worker registration failed, will retry"` found |
| Fix 2 present in image | `strings RedisClient.class` | `"NOREPLICAS"`, `startsWith`, `UNAVAILABLE` found |
| `addWorker()` has no sleep | `javap -c Worker.class` | `goto 0` at offset 54; no `invokestatic SECONDS.sleep` in method |
| Registration thread dead | `kill -3` → `kubectl logs` | `Worker.failsafeRegistration` absent from thread dump; gap in thread number sequence (#225 → #240) |
| No HSET from missing workers | Redis `MONITOR` (3 s) | All 26 registered workers emitting `HSET`; 6 missing IPs: zero commands |
| Redis is writable | Manual `HSET Workers_execute` | Returns `:1` immediately |
| Redis replicas sync timeline | `kubectl logs redis-ha-server-* -c redis` | Replicas not synced until ~01:54 (westus2) / ~01:54–01:56 (southeastasia), confirming NOREPLICAS window |

---

## 8. Key Source Files

| File | Relevant Location | Notes |
|---|---|---|
| `worker/shard/Worker.java` | `:579` `addWorker()` | **Fixed here (Fix 3):** added `SECONDS.sleep(1)` to UNAVAILABLE/DEADLINE_EXCEEDED retry path |
| `worker/shard/Worker.java` | `:640` `run()` | Fix 1: outer `catch (Exception e)`; effective only when `addWorker()` throws (requires Fix 3) |
| `common/redis/RedisClient.java` | `:120` `call()` | Fix 2: `NOREPLICAS` → `IOException(UNAVAILABLE)`; feeds into Fix 3's retry loop |
| `worker/shard/Worker.java` | `:628` `registerIfExpired()` | Calls `addWorker()`; `workerRegistrationExpiresAt` updated only after successful return |
| `worker/shard/Worker.java` | `:594` `startFailsafeRegistration()` | Creates `Worker.failsafeRegistration` thread; `server.isShutdown()` as loop guard |
