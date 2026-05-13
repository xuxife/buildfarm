# Buildfarm Worker Registration Failure Investigation Report

**Date:** 2026-03-30
**Cluster:** `pa-prod-australiaeast` / namespace `aksbazelbuildfarm`
**Symptom:** 5 worker pods running and executing tasks but absent from `BackplaneStatus`

---

## 1. Symptom

`BackplaneStatus` reported 27 active workers out of 32 worker pods. The following 5 pods were
`Running` and executing jobs, but never appeared in `active_workers`:

| Pod | IP |
|---|---|
| `aksbazelbuildfarm-shard-worker-4`  | `10.244.15.6` |
| `aksbazelbuildfarm-shard-worker-11` | `10.244.15.7` |
| `aksbazelbuildfarm-shard-worker-12` | `10.244.17.5` |
| `aksbazelbuildfarm-shard-worker-13` | `10.244.17.6` |
| `aksbazelbuildfarm-shard-worker-14` | `10.244.15.8` |

Confirmed via:

```bash
kubectl -n aksbazelbuildfarm get pod -l name=aksbazelbuildfarm-shard-worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' \
  | grep -v -f <(bf-cat 127.0.0.1:8980 "" BackplaneStatus \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
```

---

## 2. Investigation Method

All investigation was performed using:
- `bf-cat` binary (`bazel-bin/src/main/java/build/buildfarm/tools/bf-cat`) against the build farm
  server port-forwarded at `127.0.0.1:8980`
- `kubectl` with kubeconfig at `~/runner/kubeconfig/pa-prod-australiaeast`
- Redis CLI via `kubectl exec` into `redis-ha-server-1` (confirmed master)
- Source code inspection of the local buildfarm repo at `~/repo/buildfarm`

### Key observations

| Check | Result |
|---|---|
| Pod status | All 5 pods `Running`, 0 restarts, `AGE` ~26h |
| Pod events | None |
| `Workers_execute` Redis hash (master) | 5 IPs **absent**; 27 other workers present |
| Worker logs (recent) | Successfully executing `InputFetch / Execute / ReportResult` pipelines |
| Worker logs (earliest) | Dense `NOREPLICAS` errors at `01:46:26Z` |
| Normal worker logs | Same `RedisShardSubscription failed to subscribe` noise — not correlated with missing registration |

---

## 3. Root Cause

### 3.1 Timeline at Deployment

The cluster was freshly deployed on 2026-03-29. Pod creation timestamps show:

| Time (UTC) | Event |
|---|---|
| `01:28:59` | `worker-12` created (first worker pod) |
| `01:34:09` – `01:37:50` | `worker-4`, `worker-11`, `worker-13`, `worker-14` created |
| **`01:39:19`** | **`aksbazelbuildfarm-server` pods created** |
| `01:39:02` – onward | Remaining worker pods created; all register successfully |

The 5 affected workers started **before the server was ready**, and also during a window when the
Redis cluster had not yet finished replica synchronisation.

### 3.2 `NOREPLICAS` During Startup

The very first log lines of all 5 affected workers (e.g. `worker-4` from `01:46:26Z`) show a wall
of identical errors:

```
redis.clients.jedis.exceptions.JedisDataException: NOREPLICAS Not enough good replicas to write.
    at redis.clients.jedis.Protocol.processError(Protocol.java:110)
    ...
    at build.buildfarm.common.redis.RedisQueue.poll(RedisQueue.java:148)
    at build.buildfarm.instance.shard.RedisShardBackplane.dispatchOperation(...)
    at build.buildfarm.worker.shard.ShardWorkerContext.matchInterruptible(...)
    at build.buildfarm.worker.MatchStage.iterate(MatchStage.java:159)
```

Redis was rejecting all writes because replicas were not yet in sync — a transient condition lasting
roughly the first 12 minutes after the workers started.

### 3.3 How `NOREPLICAS` Kills the Registration Thread

`Worker.java` starts a `failsafeRegistration` background thread that is supposed to call
`addWorker()` every 10 seconds for the lifetime of the process:

```java
// Worker.java:594  startFailsafeRegistration()
void registerIfExpired() {
    long now = System.currentTimeMillis();
    if (now >= workerRegistrationExpiresAt ...) {
        addWorker(nextRegistration(now));             // ← throws on NOREPLICAS
        workerRegistrationExpiresAt = nextInterval(now); // ← never reached
    }
}

@Override
public void run() {
    try {
        while (server != null && !server.isShutdown()) {
            registerIfExpired();   // ← uncaught RuntimeException escapes here
            SECONDS.sleep(1);
        }
    } catch (InterruptedException e) {
        // ignore
    }
    // thread exits — never restarts
}
```

`addWorker()` calls `backplane.addWorker()` → `RedisClient.call()`. Inside `RedisClient.call()`,
`JedisDataException` with message `"NOREPLICAS..."` is **not** handled by any of the existing
catch blocks:

```java
// RedisClient.java:116
} catch (JedisDataException e) {
    if (e.getMessage().startsWith(MISCONF_RESPONSE)) {    // "MISCONF" — not matched
        throw new JedisMisconfigurationException(e.getMessage());
    }
    throw e;   // ← NOREPLICAS re-thrown as-is (RuntimeException)
}
```

`Worker.addWorker()` only catches `IOException`:

```java
// Worker.java:579
private void addWorker(ShardWorker worker) {
    while (!backplane.isStopped()) {
        try {
            backplane.addWorker(worker);
            return;
        } catch (IOException e) { ... }  // JedisDataException is not IOException
    }
}
```

The uncaught `JedisDataException` (a `RuntimeException`) propagates up through `registerIfExpired()`
and out of the thread's `run()` method. The `failsafeRegistration` thread **terminates permanently**.

Because `workerRegistrationExpiresAt` is initialised to `0` and is only updated *after* a successful
`addWorker()` call, the worker would have retried immediately on the next loop iteration — but the
thread is already dead.

### 3.4 Why the Workers Can Still Execute Jobs

The `failsafeRegistration` thread controls only the `Workers_execute` / `Workers_storage` Redis hash
entries. Task dispatch uses a separate Redis queue (`dispatchOperation`), which the workers can still
read from independently. The workers are invisible to `BackplaneStatus` and to the scheduler's worker
selection logic, but can still dequeue and execute operations that were already in the queue.

### 3.5 Complete Causal Chain

```
Redis cluster not fully synchronised at deployment
    ↓
Worker pods start before Redis replicas are ready
    ↓
RedisClient.call() → JedisDataException("NOREPLICAS Not enough good replicas to write.")
    ↓
Not caught as IOException — propagates as RuntimeException
    ↓
Worker.failsafeRegistration thread's run() exits with uncaught exception
    ↓
No re-registration ever attempted again (thread is dead)
    ↓
Workers_execute / Workers_storage Redis hash: no entry for these 5 workers
    ↓
BackplaneStatus shows 27/32 workers
Workers not selected for new task dispatch (invisible to scheduler)
```

---

## 4. Upstream Status

The upstream `buildfarm/buildfarm` `main` branch (checked 2026-03-30, 270 commits ahead of local)
has **not fixed this issue**. Both `Worker.java` and `RedisClient.java` are identical to the local
version in the relevant sections.

---

## 5. Fix

Two complementary changes were applied locally.

### Fix 1 — Prevent registration thread from dying on transient errors ✅ **Root fix**

**File:** `src/main/java/build/buildfarm/worker/shard/Worker.java`

Wrap `registerIfExpired()` in an inner try/catch so that any exception (including unchecked
`RuntimeException`) is logged and the loop continues. The thread will retry every second until
`addWorker()` succeeds and `workerRegistrationExpiresAt` is updated.

```java
// Before
@Override
public void run() {
    try {
        while (server != null && !server.isShutdown()) {
            registerIfExpired();
            SECONDS.sleep(1);
        }
    } catch (InterruptedException e) {
        // ignore
    }
}

// After
@Override
public void run() {
    try {
        while (server != null && !server.isShutdown()) {
            try {
                registerIfExpired();
            } catch (Exception e) {
                log.log(Level.WARNING, "worker registration failed, will retry", e);
            }
            SECONDS.sleep(1);
        }
    } catch (InterruptedException e) {
        // ignore
    }
}
```

**Behaviour after fix:** When Redis is temporarily unavailable, the registration thread logs a
WARNING and retries every second. As soon as Redis stabilises, the next iteration succeeds,
`workerRegistrationExpiresAt` is set, and the worker appears in `BackplaneStatus` — no pod restart
required.

### Fix 2 — Map `NOREPLICAS` to `UNAVAILABLE` ✅ **Defence-in-depth**

**File:** `src/main/java/build/buildfarm/common/redis/RedisClient.java`

Treat `NOREPLICAS` the same way as `MISCONF`: convert it to `IOException(UNAVAILABLE)` so it is
recognised as a retryable transient error throughout the codebase (e.g. in `Worker.addWorker()`'s
existing retry loop).

```java
// Before
} catch (JedisDataException e) {
    if (e.getMessage().startsWith(MISCONF_RESPONSE)) {
        throw new JedisMisconfigurationException(e.getMessage());
    }
    throw e;
}

// After
} catch (JedisDataException e) {
    if (e.getMessage().startsWith(MISCONF_RESPONSE)) {
        throw new JedisMisconfigurationException(e.getMessage());
    }
    if (e.getMessage().startsWith("NOREPLICAS")) {
        throw new IOException(Status.UNAVAILABLE.withCause(e).asException());
    }
    throw e;
}
```

**Behaviour after fix:** `NOREPLICAS` is now an `IOException` with status `UNAVAILABLE`. The
existing retry loop in `Worker.addWorker()` (which already retries on `UNAVAILABLE` and
`DEADLINE_EXCEEDED`) will retry registration without needing Fix 1 to catch it. Fix 1 and Fix 2
together provide two independent layers of protection.

---

## 6. Workaround (Until Fix is Deployed)

Restart the affected pods to trigger a fresh registration:

```bash
for pod in aksbazelbuildfarm-shard-worker-4 \
           aksbazelbuildfarm-shard-worker-11 \
           aksbazelbuildfarm-shard-worker-12 \
           aksbazelbuildfarm-shard-worker-13 \
           aksbazelbuildfarm-shard-worker-14; do
  kubectl -n aksbazelbuildfarm delete pod $pod
done
```

---

## 7. Key Source Files

| File | Relevant Location | Notes |
|---|---|---|
| `worker/shard/Worker.java` | `:579` `addWorker()` | Catches only `IOException`, not `RuntimeException` |
| `worker/shard/Worker.java` | `:594` `startFailsafeRegistration()` | Registration thread; `workerRegistrationExpiresAt` init to `0` |
| `worker/shard/Worker.java` | `:640` `run()` | Only catches `InterruptedException` — **fixed here** |
| `common/redis/RedisClient.java` | `:116` `call()` | `NOREPLICAS` not mapped to `UNAVAILABLE` — **fixed here** |
| `instance/shard/RedisShardBackplane.java` | `:618` `addWorker()` | Writes `Workers_execute` / `Workers_storage` hash via `RedisHashMap.insert()` |
| `common/redis/RedisHashMap.java` | `:63` `insert()` | Plain `HSET` — no TTL; expiry is application-side via `expireAt` field |
| `instance/shard/RedisShardBackplane.java` | `:859` `fetchAndExpireWorkers()` | Reads and garbage-collects expired entries on each `BackplaneStatus` call |
