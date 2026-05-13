# GoStdlib Action Requeue Failure — Debug Report

**Date:** 2026-04-17
**Cluster:** `pa-prod-australiaeast`
**Symptom:** `GoStdlib external/rules_go~/stdlib_/pkg` fails with Exit 34:
```
Failed Precondition: Action d8354af2.../148 is invalid:
Operation shard/executions/f574c4f2-... not requeued.
Operation has been requeued too many times ( 4 > 3).
```

---

## 1. Debug 命令流程

### 1.1 确认集群状态

```bash
# BackplaneStatus — worker 注册数和队列状态
bf-cat 127.0.0.1:8980 shard BackplaneStatus

# 找到问题 Operation 的状态
bf-cat 127.0.0.1:8980 shard \
  Operation shard/executions/f574c4f2-0992-4ba8-b12d-4f3eabbbf3b0
```

**结果：** 32/32 worker 全部注册。Operation 状态 COMPLETED / FAILED_PRECONDITION，
错误信息为 "requeued too many times (4 > 3)"。

### 1.2 拆解 Action 内容

```bash
# 看 Action 定义
bf-cat 127.0.0.1:8980 shard \
  Action d8354af2bc973706fa87a9fafdc68e0c654990ce1e2eed8462b2ddae83ba238e/148

# 看 Command（命令行参数、环境变量）
bf-cat 127.0.0.1:8980 shard \
  Command 51827aab64e5dad341187fdbc9b3986e4eb56702f319a18f770b4a3c5cc46c54/1477

# 看 Input Root 的目录树（带权重）
bf-cat 127.0.0.1:8980 shard \
  TreeLayout 5a23de55696b308fc223c18fa8c09980d5da7c8961502178ef8bfa59cfadc160/167
```

**结果：**
- Command：`builder stdlib -sdk external/rules_go~~go_sdk... -gcflags ''`，输出目录
  `k8-fastbuild-ST-.../stdlib_/pkg`
- 环境变量：`CGO_ENABLED=1`，包含 `CGO_CFLAGS`/`CGO_LDFLAGS`（引用 LLVM toolchain）
- Input tree 包含完整 LLVM toolchain（clang 188MB、lld 125MB 等）+ 整个 Go SDK

### 1.3 检查 CAS 中 blob 是否存在

```bash
# 检查 Action blob 本身
bf-cat 127.0.0.1:8980 shard \
  Missing d8354af2bc973706fa87a9fafdc68e0c654990ce1e2eed8462b2ddae83ba238e/148

# 提取 input tree 所有 blob digest，批量检查
bf-cat 127.0.0.1:8980 shard \
  TreeLayout 5a23de55696b308fc223c18fa8c09980d5da7c8961502178ef8bfa59cfadc160/167 \
  | grep -oE '[0-9a-f]{64}/[0-9]+' | sort -u > /tmp/action_blobs.txt

bf-cat 127.0.0.1:8980 shard \
  Missing $(cat /tmp/action_blobs.txt | tr '\n' ' ')
```

**结果：** Server 端 CAS 所有 blob 均存在，`Missing` 无输出。

### 1.4 检查 worker 端 "did not contain" 报错

```bash
# 从 server 日志提取 worker 报告 missing 的 blob
kubectl -n aksbazelbuildfarm logs -l name=aksbazelbuildfarm-server --since=60m \
  | grep "did not contain" \
  | grep -oE '[0-9a-f]{64}/[0-9]+' | sort -u > /tmp/missing_in_workers.txt

# 与 action input 取交集
comm -12 <(sort /tmp/action_blobs.txt) <(sort /tmp/missing_in_workers.txt)
```

**结果：** 交集为 0。Worker 端 miss 的 blob 与这个 GoStdlib action 无关。

### 1.5 读取 stdout / stderr

```bash
bf-cat 127.0.0.1:8980 shard \
  File shard/executions/e8ee3c8a-0e0a-490e-8ab9-f12ae0e45896/streams/stdout
bf-cat 127.0.0.1:8980 shard \
  File shard/executions/e8ee3c8a-0e0a-490e-8ab9-f12ae0e45896/streams/stderr
```

**结果：** 两者均为空。Action 从未产生输出。

### 1.6 找到其他失败 operation，查看 Operations 列表

```bash
# 列出所有 operation，过滤出 requeue 相关的
bf-cat 127.0.0.1:8980 shard Operations | grep -B20 "too many times"
```

**结果：** 同一个 action hash `d8354af2` 有 4 个 operation（f574c4f2、e8ee3c8a、d1c257ca、8162d56b），
全部 FAILED_PRECONDITION。

关键发现：**每个 operation 的 ExecutionMetadata 里没有 `Worker:` 字段**——
说明 operation 从未被 worker 真正执行，只是被 DispatchedMonitor 判定超时后 requeue。

### 1.7 对比成功的同类 Action

```bash
# 找成功的 GoStdlib operation
bf-cat 127.0.0.1:8980 shard Operations | grep -B5 -A5 "stdlib_/pkg"

# 对比两个 action 的 Command
bf-cat 127.0.0.1:8980 shard \
  Action 9eb0e44017e9dd95159536759658a33ba88f4f0aa910f3965f4ca0297403fc8d/148

bf-cat 127.0.0.1:8980 shard \
  Command 3eac04fda348d98cd77252606b0c5d290b9c66f71e6fd34afb643b37f7699607/778
```

**结果对比：**

| | 失败的 action (`d8354af2`) | 成功的 action (`9eb0e440`) |
|---|---|---|
| 输出目录 | `k8-fastbuild-ST-...` | `k8-opt-exec-ST-...` |
| `CGO_ENABLED` | `1` | `0` |
| `-package runtime/cgo` | ✅ 有 | ❌ 无 |
| CGO_CFLAGS / CGO_LDFLAGS | 有（依赖 LLVM toolchain） | 无 |
| Input tree 大小 | **4252.6 MB** | **118.8 MB** |

### 1.8 计算 input 总大小

```bash
bf-cat 127.0.0.1:8980 shard \
  TreeLayout 5a23de55696b308fc223c18fa8c09980d5da7c8961502178ef8bfa59cfadc160/167 \
  | grep -oE '[0-9]+/[0-9]+' \
  | awk -F'/' '{sum += $2} END {printf "Total: %.1f MB\n", sum/1024/1024}'
```

**结果：** 4252.6 MB（成功版本仅 118.8 MB）。

---

## 2. 根本原因

### 2.1 错误判断链

最初的错误信息 `MISSING blobs/d8354af2.../148` 容易误导——看起来像是 action blob 在 CAS 中丢失。
但实际上：

1. **`Subject: blobs/...` 是 buildfarm 的错误信息格式**，不代表该 blob 真正 missing。
   `Missing` 命令直接检查确认 blob 存在。

2. **`did not contain` warning** 看起来像是 worker CAS miss 导致 InputFetch 失败，
   但交集分析显示这些 miss 的 blob 和 GoStdlib action 无关。

3. **stdout/stderr 为空 + Operations 里无 `Worker:` 字段** 是关键线索：
   action 从来没有被任何 worker 拿到并执行。

4. **真正原因：dispatch timeout**。Operation 被 dispatch 到某个 worker，但该 worker
   在 `dispatchingTimeoutMillis=60000`（60秒）内没有开始 poll 汇报进度（因为 InputFetch
   4.2 GB 的数据远超 60 秒），server 的 DispatchedMonitor 认为 worker 已失联，
   将 operation requeue。重复 4 次后超过 `maxRequeueAttempts=3` 上限，
   以 FAILED_PRECONDITION 终止。

### 2.2 为什么 InputFetch 这么慢

失败的 action 是 **fastbuild + CGO_ENABLED=1** 的 GoStdlib，input tree 包含：

- 完整 LLVM toolchain：`clang` (188MB)、`lld` (125MB)、`clangd` (65MB)、
  `asm` (9.3MB)、`compile` (25MB)、`link` (10MB) 等
- 完整 Go SDK source tree：`src/` (574MB)
- 完整 Go SDK tools：`bin/go` (15MB)、`bin/gofmt` (7.5MB) 等

总计 **4.2 GB**。Worker 需要从 server CAS 下载这些数据到本地（若本地 CAS 无缓存），
60 秒内无法完成。

成功的 action（`9eb0e440`）是 **opt-exec + CGO_ENABLED=0**，不需要 LLVM toolchain，
input 仅 118.8 MB，可以在 60 秒内完成 InputFetch。

---

## 3. 可能的修复方向

### 3.1 增大 dispatching timeout（临时缓解）

在 buildfarm server 配置中调大 `dispatchingTimeoutMillis`：

```yaml
backplane:
  dispatchingTimeoutMillis: 300000  # 5 分钟，当前为 60000（60秒）
```

这允许 worker 有更多时间完成 InputFetch，再开始 poll。
副作用：挂死的 worker 需要更久才会被检测到。

### 3.2 启用 InputFetch keepalive（根本修复）

让 worker 在 InputFetch 阶段也发 keepalive，防止 DispatchedMonitor 误判。
需要修改 buildfarm 代码，在 InputFetch 期间定期更新 dispatching timeout。

### 3.3 查明为何 fastbuild GoStdlib 依赖完整 LLVM toolchain（建议调查）

正常情况下 `GoStdlib` 不应该把 LLVM toolchain 放进 input tree。
可能的原因：
- `rules_go` 或 `toolchains_llvm` 的配置把 C toolchain 加入了 Go stdlib 的依赖
- `CGO_ENABLED=1` 的 GoStdlib 确实需要 C compiler，但可以通过配置
  只包含 `cc_wrapper.sh` 而非整个 toolchain binary

建议检查 Bazel 的 `cquery` 输出确认依赖来源：
```bash
bazel cquery 'deps(@rules_go//stdlib:go_stdlib)' --output=build | grep llvm
```

---

## 4. Key bf-cat 命令速查

| 目的 | 命令 |
|---|---|
| 查 BackplaneStatus（worker 数、队列大小） | `bf-cat <host> <instance> BackplaneStatus` |
| 查 Operation 状态 | `bf-cat <host> <instance> Operation <name>` |
| 查所有 Operations（含失败详情） | `bf-cat <host> <instance> Operations` |
| 查 Action 定义（command + input root） | `bf-cat <host> <instance> Action <digest/size>` |
| 查 Command（参数 + 环境变量） | `bf-cat <host> <instance> Command <digest/size>` |
| 查 Input Tree（带大小权重）| `bf-cat <host> <instance> TreeLayout <digest/size>` |
| 检查 blob 是否在 CAS 中存在 | `bf-cat <host> <instance> Missing <digest/size> ...` |
| 读取 stdout / stderr | `bf-cat <host> <instance> File <stream-path>` |
| 查 ActionResult（缓存结果） | `bf-cat <host> <instance> ActionResult <digest/size>` |
| 查 Worker 执行统计 | `bf-cat <worker-host:port> "" WorkerProfile` |
