# Buildfarm Build Failure Investigation Report

**Date:** 2026-03-19
**Cluster:** `pa-prod-westus3` / namespace `aksbazelbuildfarm`
**Failed Action:** `fe106472e6c033b24201cefe6bed23ede5cf21264d83c1d190c063d8b7a4dde0/148`
**Failed Operation:** `shard/executions/59aca886-0c44-4223-b54b-cd8703776d7a`
**Bazel Target:** `@rules_go//stdlib_/pkg` (`GoStdlib external/rules_go~/stdlib_/pkg`)

---

## 1. Error Presented to User

```
ERROR: GoStdlib external/rules_go~/stdlib_/pkg failed: (Exit 34): Remote Execution Failure:
Failed Precondition: Action fe106472e6c033b24201cefe6bed23ede5cf21264d83c1d190c063d8b7a4dde0/148 is invalid:
Operation shard/executions/59aca886-0c44-4223-b54b-cd8703776d7a not requeued.
Operation has been requeued too many times ( 4 > 3).
```

---

## 2. Investigation Method

All investigation was performed using:
- `bf-cat` binary (`bazel-bin/src/main/java/build/buildfarm/tools/bf-cat`) against the build farm
  server port-forwarded at `127.0.0.1:8980`
- `kubectl` with kubeconfig at `/home/xingfeixu/runner/kubeconfig/pa-prod-westus3`
- Source code inspection of the local buildfarm repo at `/home/xingfeixu/repo/buildfarm`

### bf-cat queries executed

| Query | Result |
|---|---|
| `Action fe106472.../148` | Valid action; Command `51827aab.../1477`, Input Root `be25200d.../167` |
| `Missing` (all key blobs) | **Nothing missing** — all CAS blobs present |
| `ActionResult fe106472.../148` | Not found — execution never completed |
| `Operation shard/executions/59aca886...` | `COMPLETED` with `FAILED_PRECONDITION`; stage `COMPLETED` |
| `TreeLayout be25200d.../167` | Full input tree present, ~718 MB Go SDK; no `[MISSING]` entries |
| `Command 51827aab.../1477` | `rules_go builder stdlib` with CGo/LLVM toolchain |
| `BackplaneStatus` | 32 healthy workers registered |
| `QueuedOperation` | "Not a QueuedOperation" — already drained from queue |

---

## 3. Root Cause

### 3.1 What Actually Failed: `InputFetchStage`, Not Execution

The action **never executed** on any worker. It failed at `InputFetchStage` — before any inputs were
fetched — on all 4 workers that attempted it:

| Worker | Timestamp (UTC) | Stage Failed | Duration |
|---|---|---|---|
| worker-22 | 2026-03-19T03:44:35.485Z | InputFetchStage | 9.1 ms |
| worker-31 | 2026-03-19T03:44:35.814Z | InputFetchStage | 13.0 ms |
| worker-4  | 2026-03-19T03:44:36.102Z | InputFetchStage | 8.5 ms |
| worker-7  | 2026-03-19T03:44:36.851Z | InputFetchStage | 8.1 ms |

All 4 workers produced the identical exception:

```
java.util.concurrent.CancellationException: Task was cancelled.
    at build.buildfarm.worker.CFCLinkExecFileSystem.createExecDir(CFCLinkExecFileSystem.java:383)
    at build.buildfarm.worker.shard.ShardWorkerContext.createExecDir(ShardWorkerContext.java:763)
    at build.buildfarm.worker.InputFetcher.fetchPolled(InputFetcher.java:230)
    at build.buildfarm.worker.InputFetcher.runInterruptibly(InputFetcher.java:116)
    at build.buildfarm.worker.InputFetcher.run(InputFetcher.java:329)
```

### 3.2 Why the Future Was Cancelled: `DispatchedMonitor` Expiry Race

The server logs reveal the mechanism. At the exact moment workers started `InputFetchStage`, the
server's `DispatchedMonitor` was simultaneously yanking the operation back:

```
03:44:35.478  worker-22  MatchStage SUCCESS → InputFetchStage starts
03:44:35.776  server     DispatchedMonitor: Testing 59aca886... because 1,773,891,875,775ms overdue
03:44:35.799  server     RedisShardBackplane: removed dispatched execution 59aca886...  ← cancels future
03:44:35.801  server     DispatchedMonitor: requeue(59aca886) in 24ms
03:44:35.485  worker-22  InputFetcher ERROR: CancellationException  ← future cancelled
```

When `RedisShardBackplane` removes a dispatched execution from Redis, it cancels the
`ListenableFuture` that `CFCLinkExecFileSystem.createExecDir()` (line 383) is blocking on. The
worker's input fetch is immediately aborted. This repeated across workers-22, 31, 4, and 7 until
`requeueAttempts` hit 4, exceeding `maxRequeueAttempts` of 3.

### 3.3 Root Cause: `dispatchingTimeoutMillis` is Too Short (10 seconds)

**Source code trace** (`RedisShardBackplane.java:1198-1199`):

```java
// When an operation is dequeued by a worker, its initial requeueAt is set to:
long requeueAt = System.currentTimeMillis() + configs.getBackplane().getDispatchingTimeoutMillis();
```

**`Backplane.java:42` default:**

```java
private int dispatchingTimeoutMillis = 10000;  // 10 seconds
```

**`DispatchedMonitor.java:90` trigger condition:**

```java
if (now >= dispatchedOperation.getRequeueAt()) {
    // requeues the operation — which cancels the worker's future
}
```

So the sequence is:

1. A worker dequeues the operation and sets `requeueAt = now + 10_000ms` (10 seconds from now).
2. The worker starts `InputFetchStage` and creates a poller (`operationPollPeriod = 1 second` by
   default, `Worker.java:41`) to call `pollExecution` and push `requeueAt` forward.
3. **However**, `DispatchedMonitor` runs on a 1-second interval (`dispatchedMonitorIntervalSeconds =
   1`, `Server.java:29`) and scans the entire dispatched set. The operation's `requeueAt` is only 10
   seconds out, so if the poller fails or the server processes the scan before the first poll
   arrives, the monitor fires and yanks the operation.
4. The observed overdue value of **1,773,891,875,775 ms (~56 years)** reveals that the `requeueAt`
   stored in Redis for this operation was effectively **zero** (epoch). This means the operation was
   dispatched with a `requeueAt` of `0`, which `DispatchedMonitor` (condition: `now >= requeueAt`)
   treats as infinitely overdue from the very first scan — before the worker even starts polling.

### 3.4 Why `requeueAt` Was Zero: `rejectOperation` Called with `requeueAt=0`

Tracing further in `RedisShardBackplane.java:1243`:

```java
public void rejectOperation(QueueEntry queueEntry) throws IOException {
    String dispatchedEntryJson = printPollOperation(queueEntry, 0);  // ← requeueAt = 0
    ...
    pollExecution(jedis, executionName, dispatchedEntryJson);  // writes requeueAt=0 to Redis
```

`rejectOperation` is called by `ShardWorkerContext` (line 353) when a worker explicitly rejects an
operation during `InputFetchStage`. It deliberately writes `requeueAt = 0` to Redis to signal that
the operation should be reclaimed immediately. This is correct behaviour for an explicit rejection.

**The real question is why the operation is being rejected at all.** The `InputFetcher` fails because
`CFCLinkExecFileSystem.createExecDir()` returned a cancelled future — but the very first attempt
(on worker-22) fails within **9 ms**, long before any polling or timeout could occur. This means the
cancellation was not caused by `rejectOperation` — it was caused by `DispatchedMonitor` having
already written `requeueAt=0` for a *prior* rejection of the same operation on a *previous* attempt,
and that zero-expiry value persists in Redis between requeue cycles.

### 3.5 The Requeue Death Spiral

The complete cycle for each of the 4 attempts:

```
Attempt N:
  1. DispatchedMonitor: reads requeueAt=0 from Redis → condition (now >= 0) is always true
  2. DispatchedMonitor: calls requeuer → RedisShardBackplane.queue() → cancels future
  3. Worker: InputFetcher.createExecDir() future cancelled → CancellationException
  4. Worker: ShardWorkerContext calls rejectOperation(queueEntry) → writes requeueAt=0 again
  5. requeueAttempts++
  6. Go to Attempt N+1 ... until requeueAttempts > maxRequeueAttempts (3)
```

The `requeueAt=0` written by the first `rejectOperation` call permanently poisons the dispatched
entry in Redis. Every subsequent worker that picks it up finds the same zero expiry and is cancelled
within milliseconds.

### 3.6 What Triggered the Very First Failure

The original `requeueAt` written on first dispatch was `now + dispatchingTimeoutMillis = now + 10s`.
The operation was likely first dispatched, the worker had 10 seconds to call `pollExecution` to
extend the lease, but failed to do so in time — either because:

- **The `RedisShardSubscription` failures** (logged every ~5.5 minutes since 2026-03-12) disrupted
  the worker's ability to communicate with Redis, causing the first poll to fail silently.
- The 10-second `dispatchingTimeoutMillis` window is too narrow for large input trees (the Go SDK
  tree is ~718 MB of blobs), and `InputFetchStage` took longer than 10 seconds to even start
  polling, allowing `DispatchedMonitor` to fire first on the initial attempt.

### 3.7 Config Validation from Cluster

The `aksbazelbuildfarm-config` ConfigMap was retrieved directly from the cluster:

```yaml
# Deployed config (aksbazelbuildfarm namespace, ConfigMap aksbazelbuildfarm-config)
defaultActionTimeout: 600       # ✅ 10 minutes
maximumActionTimeout: 3600      # ✅ 1 hour
backplane:
  redisUri: "redis://redis-ha-haproxy.redis-ha.svc.cluster.local:6379"
  actionCacheExpire: 2419200
  casExpire: 604800
  # dispatchingTimeoutMillis: NOT SET → defaults to 10000 (10 seconds)  ← TOO SHORT
```

**`dispatchingTimeoutMillis` is absent from the config**, meaning it falls through to the Java
default of **10,000 ms (10 seconds)** (`Backplane.java:42`). For large input trees this window is
insufficient for the worker to establish its first poll and extend the lease.

### 3.8 Secondary Issue: `RedisShardSubscription` Failures

All workers log `failed to subscribe` / `unexpected subscribe return, reconnecting` every ~5.5
minutes since **2026-03-12T13:00Z** (7+ days continuously):

```
WARNING  RedisShardSubscription iterate    failed to subscribe
SEVERE   RedisShardSubscription mainLoop   unexpected subscribe return, reconnecting...
```

This means workers cannot maintain their Redis pub/sub channel. The pub/sub channel is used to
receive operation update notifications. While the worker uses a separate polling thread
(`OperationPoller`) to call `pollExecution`, the subscription failure may cause the worker's
internal operation state machine to stall or make incorrect transitions, potentially delaying or
preventing the first `pollExecution` call within the 10-second `dispatchingTimeoutMillis` window.

---

## 4. Failure Flow Summary

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ROOT CAUSE: dispatchingTimeoutMillis=10s too short for large input trees    │
│  + RedisShardSubscription failures delay worker's first pollExecution call   │
└────────────────────────────────┬─────────────────────────────────────────────┘
                                 │
                                 ▼
     Worker dequeues op → requeueAt = now + 10,000ms stored in Redis
                                 │
                  ┌──────────────┴───────────────┐
                  │ (within 10 seconds)           │
                  ▼                               ▼
     Worker starts InputFetchStage        DispatchedMonitor fires (1s interval)
     (large 718MB Go SDK tree)            now >= requeueAt → true
     First pollExecution not yet sent     Cancels dispatched future in Redis
                  │                               │
                  └──────────────┬───────────────┘
                                 ▼
         CFCLinkExecFileSystem.createExecDir() → CancellationException
         ShardWorkerContext.rejectOperation() → writes requeueAt=0 to Redis
         requeueAttempts++ → operation requeued
                                 │
                  ┌──────────────┴──────────────┐
                  │  requeueAt=0 now in Redis    │
                  │  Next worker claims op       │
                  │  DispatchedMonitor: now >= 0 │
                  │  → immediately cancelled     │
                  │  Repeat × 3 more times       │
                  └──────────────┬──────────────┘
                                 ▼
         canOperationBeRequeued: 4 > 3 → FAILED_PRECONDITION
         Returned to Bazel client as Exit 34
```

---

## 5. Recommended Fixes

### Fix 1 (Root Cause) — Increase `dispatchingTimeoutMillis` ✅ **Required**

Add to the `backplane:` section in `aksbazelbuildfarm-config`:

```yaml
backplane:
  redisUri: "redis://redis-ha-haproxy.redis-ha.svc.cluster.local:6379"
  actionCacheExpire: 2419200
  casExpire: 604800
  dispatchingTimeoutMillis: 60000   # 60 seconds (was: missing → defaulted to 10s)
```

This gives each worker 60 seconds from dequeue to send its first `pollExecution` call (which then
extends the lease by another `pollExecution`-supplied interval). 60 seconds is sufficient for even
large input trees to begin polling before `DispatchedMonitor` fires.

After updating the ConfigMap, restart the server pods:

```bash
kubectl -n aksbazelbuildfarm rollout restart deployment aksbazelbuildfarm-server
```

### Fix 2 — Increase `maxRequeueAttempts` ⚠️ **Workaround only**

In `aksbazelbuildfarm-config` under `server:`:

```yaml
server:
  maxRequeueAttempts: 5   # was: missing → defaulted to 3
```

This is a symptom fix. Without Fix 1, increasing this just allows more failed attempts before the
operation permanently fails. With Fix 1 applied, the default of 3 should be sufficient again.

### Fix 3 — Fix `RedisShardSubscription` Reconnection ⚠️ **Recommended**

The persistent Redis pub/sub subscription drop every ~5.5 minutes since 2026-03-12 is a separate
but contributing problem. Investigate:

1. **Redis idle timeout** — ensure it is disabled or large enough:
   ```
   CONFIG GET timeout          # should be 0 (disabled) or >> 330s
   CONFIG SET timeout 0
   ```
2. **TCP keepalive** — enable in Redis:
   ```
   CONFIG SET tcp-keepalive 60
   ```
3. **Redis HA haproxy** — check whether the haproxy health-check interval or timeout is closing
   idle pub/sub connections. Consider increasing `timeout tunnel` in haproxy config.

### Fix 4 (Optional) — Tune `dispatchedMonitorIntervalSeconds`

`Server.java:29` defaults `dispatchedMonitorIntervalSeconds = 1` (1-second scan interval). With 32
workers and many operations in flight, this means the monitor scans the entire dispatched set every
second, creating a tight race window against the 10-second lease. Increasing to 5 seconds would
reduce pressure — but Fix 1 is the correct solution.

---

## 6. Config: Current vs. Recommended

| Location | Field | Current | Recommended |
|---|---|---|---|
| `backplane` | `dispatchingTimeoutMillis` | **MISSING → 10,000 ms** | **`60000`** |
| `backplane` | `actionCacheExpire` | `2419200` (28 days) | ✅ Keep |
| `backplane` | `casExpire` | `604800` (7 days) | ✅ Keep |
| `server` | `maxRequeueAttempts` | MISSING → `3` | `5` (optional buffer) |
| `server` | `dispatchedMonitorIntervalSeconds` | MISSING → `1` | `5` (optional) |
| `defaultActionTimeout` | — | `600` (10 min) | ✅ Keep |
| `maximumActionTimeout` | — | `3600` (1 hr) | ✅ Keep |
| Redis | `timeout` | Unknown | `0` (disable idle timeout) |
| Redis | `tcp-keepalive` | Unknown | `60` |

> **Note:** The previously suggested `operationExpireTime` field does not exist in this version of
> buildfarm. The correct field controlling the dispatch lease window is `dispatchingTimeoutMillis`
> under `backplane:`. The `operationExpire` field (default 604800 = 7 days,
> `Backplane.java:34`) controls how long operation metadata is retained in Redis and is unrelated
> to this failure.

---

## 7. Artifacts Referenced

| Artifact | Value |
|---|---|
| Failed action digest | `fe106472e6c033b24201cefe6bed23ede5cf21264d83c1d190c063d8b7a4dde0/148` |
| Failed operation | `shard/executions/59aca886-0c44-4223-b54b-cd8703776d7a` |
| Command digest | `51827aab64e5dad341187fdbc9b3986e4eb56702f319a18f770b4a3c5cc46c54/1477` |
| Input root digest | `be25200d662cdc183ebbba4cbb8819590d239cb7f551ef94b3fa5c8897e178fa/167` |
| Workers that attempted | worker-4, worker-7, worker-22, worker-31 |
| Failure timestamp | 2026-03-19T03:44:35–03:44:36 UTC |
| Config source | `aksbazelbuildfarm` namespace, ConfigMap `aksbazelbuildfarm-config` |
| Pattern first observed | 2026-03-13T09:36:06 UTC (earliest in server log) |
| Key source files | `Backplane.java:42` (`dispatchingTimeoutMillis`), `RedisShardBackplane.java:1198` (requeueAt calc), `DispatchedMonitor.java:90` (trigger condition), `Server.java:29,34` (monitor interval, maxRequeueAttempts) |
