#!/usr/bin/env bash
# Rebuild the buildfarm worker base image to pick up the latest Ubuntu Noble
# apt security updates, push it to our internal ACR as a multi-arch manifest
# list, then update MODULE.bazel's `ubuntu_noble` oci.pull() with the new tag
# and digest.
#
# Why this exists:
#   The upstream `bazelbuild/buildfarm-worker-base:noble` image is updated only
#   occasionally. Our `Dockerfile.worker-base` runs `apt-get upgrade -y` at
#   build time, so re-running this script is the way we pull in OS-level CVE
#   fixes for the worker. Re-run any time a new Ubuntu CVE comes in.
#
# Requirements:
#   - docker buildx (with a builder that can do linux/amd64 + linux/arm64)
#   - `az acr login -n aksdevinfraprodmsftprod` already done
#   - run from anywhere; the script is location-independent
#
# Usage:
#   container/rebuild-worker-base.sh                 # auto-tag YYYYMMDD.0
#   container/rebuild-worker-base.sh noble-20260513.1   # explicit tag
#   DRY_RUN=1 container/rebuild-worker-base.sh       # build only, no push, no MODULE.bazel edit

set -euo pipefail

REGISTRY="aksdevinfraprodmsftprod.azurecr.io"
IMAGE_REPO="bazelbuild/buildfarm-worker-base"
PLATFORMS="linux/amd64,linux/arm64"

# ---- locate repo + Dockerfile ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile.worker-base"
MODULE_BAZEL="$REPO_ROOT/MODULE.bazel"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "error: $DOCKERFILE not found" >&2
  exit 1
fi
if [[ ! -f "$MODULE_BAZEL" ]]; then
  echo "error: $MODULE_BAZEL not found" >&2
  exit 1
fi

# ---- pick a tag ----
if [[ $# -ge 1 ]]; then
  TAG="$1"
else
  # Find the next free noble-YYYYMMDD.N for today.
  DATE="$(date -u +%Y%m%d)"
  N=0
  while true; do
    CANDIDATE="noble-${DATE}.${N}"
    if ! docker buildx imagetools inspect \
           "${REGISTRY}/${IMAGE_REPO}:${CANDIDATE}" >/dev/null 2>&1; then
      TAG="$CANDIDATE"
      break
    fi
    N=$((N + 1))
  done
fi

FULL_REF="${REGISTRY}/${IMAGE_REPO}:${TAG}"
echo "==> building $FULL_REF for $PLATFORMS"

# ---- buildx ----
BUILD_ARGS=(
  buildx build
  --platform "$PLATFORMS"
  -f "$DOCKERFILE"
  -t "$FULL_REF"
  --provenance=false
  --sbom=false
  # Always pull the latest upstream base and skip the layer cache, otherwise
  # buildx will happily reuse the cached `RUN apt-get update && apt-get
  # upgrade` layer from the previous run and the resulting image will be
  # byte-identical to the previous one (i.e. no Ubuntu CVE patches picked up).
  --pull
  --no-cache
)
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "==> DRY_RUN=1, building without --push"
  BUILD_ARGS+=(--load=false)
else
  BUILD_ARGS+=(--push)
fi

docker "${BUILD_ARGS[@]}" "$SCRIPT_DIR"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "==> DRY_RUN=1, skipping digest fetch and MODULE.bazel update"
  exit 0
fi

# ---- get the manifest-list digest ----
echo "==> fetching manifest-list digest"
# `docker buildx imagetools inspect --raw <ref>` prints the raw manifest-list
# JSON. The digest of that manifest list is the sha256 of those bytes -- which
# is exactly what oci.pull() needs in MODULE.bazel.
RAW_INSPECT="$(docker buildx imagetools inspect --raw "$FULL_REF")" || {
  echo "error: failed to inspect $FULL_REF after push" >&2
  exit 1
}
DIGEST="sha256:$(printf '%s' "$RAW_INSPECT" | sha256sum | awk '{print $1}')"
if [[ -z "${DIGEST#sha256:}" ]]; then
  echo "error: could not compute manifest-list digest" >&2
  exit 1
fi
echo "    digest = $DIGEST"
echo "    tag    = $TAG"

# ---- update MODULE.bazel ----
# We patch the `ubuntu_noble` oci.pull() block. It looks like:
#
#   oci.pull(
#       name = "ubuntu_noble",
#       digest = "sha256:...",
#       image = "aksdevinfraprodmsftprod.azurecr.io/bazelbuild/buildfarm-worker-base:noble-YYYYMMDD.N",
#       platforms = [...],
#   )
#
# Use a python one-liner because GNU sed multi-line replacement is painful.
echo "==> updating MODULE.bazel ubuntu_noble pull"
python3 - "$MODULE_BAZEL" "$DIGEST" "$FULL_REF" <<'PY'
import re, sys, pathlib
path, digest, full_ref = sys.argv[1], sys.argv[2], sys.argv[3]
src = pathlib.Path(path).read_text()

pattern = re.compile(
    r'(oci\.pull\(\s*\n\s*name\s*=\s*"ubuntu_noble",[^\n]*\n)'  # 1: header (allow trailing comment)
    r'(\s*digest\s*=\s*")[^"]*(",\s*\n)'                       # 2: digest pre / 3: digest post
    r'(\s*image\s*=\s*")[^"]*(",\s*\n)',                       # 4: image pre  / 5: image post
    re.MULTILINE,
)

def repl(m):
    return (m.group(1)
            + m.group(2) + digest    + m.group(3)
            + m.group(4) + full_ref  + m.group(5))

new, n = pattern.subn(repl, src, count=1)
if n != 1:
    sys.stderr.write("error: did not find a single ubuntu_noble oci.pull block to patch\n")
    sys.exit(1)
pathlib.Path(path).write_text(new)
print("    patched MODULE.bazel")
PY

echo
echo "==> done. Diff:"
git -C "$REPO_ROOT" --no-pager diff -- MODULE.bazel || true
echo
echo "Next steps:"
echo "  1. Bump container/BUILD oci_push remote_tags (e.g. 2.15.0.\$(date -u +%Y%m%d).0)"
echo "  2. bazel build //container:buildfarm-worker  # smoke check"
echo "  3. bazel run //container:push-worker-image && bazel run //container:push-server-image"
echo "  4. git add MODULE.bazel container/BUILD && git commit"
