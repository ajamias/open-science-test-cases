#!/usr/bin/env bash
set -euo pipefail

# Focused reproducer for the broken clone path on this cluster's VM storage.
#
# test-vm-storage.sh defaults to SOURCE_MODE=registry because cloning a golden
# image does not work on pure-fb-nfsv4, and the failure is silent: the
# DataVolume never reports Failed, it retry-loops forever. That matters well
# beyond these tests, because cloning is the path the console's
# "Create VirtualMachine -> from template" button takes, so provisioning a VM
# through the UI on the default StorageClass hangs with nothing surfaced to the
# user.
#
# This script isolates that one claim — "can this StorageClass clone a volume?"
# — and runs it four ways so the evidence points at a specific layer:
#
#   control   registry import into the same StorageClass, no cloning involved
#   csi       a bare PVC-to-PVC CSI clone, with CDI entirely out of the picture
#   smart     a CDI clone, letting CDI pick its strategy from the StorageProfile
#   copy      a CDI clone, forced down the host-assisted path with an annotation
#   snapshot  a CDI clone, forced through a VolumeSnapshot — CDI's third strategy,
#             and the one that is a candidate workaround rather than a repeat of
#             the same failure, since it never asks the driver to clone
#
# No VM is ever booted — this is about the disk, and skipping the boot keeps a
# failing run to a few minutes.
#
# The script asserts that cloning *works*. On a cluster with the bug it fails,
# and the failure, with the driver's own error attached, is the demonstration.
# On a cluster where the CSI configuration has been fixed it passes, so the same
# file doubles as the check that the fix landed.
#
# Everything it learns is also written to an evidence file suitable for attaching
# to a bug report; the path is printed at the end.

NAMESPACE="${NAMESPACE:-${PROJECT:-mm-test}}"
PREFIX="${PREFIX:-clone-test}"

SRC_DV="${PREFIX}-source"      # control: registry import, and the clone source
CSI_PVC="${PREFIX}-csi"        # bare CSI clone of SRC_DV, no CDI
SMART_DV="${PREFIX}-smart"     # CDI clone, CDI picks the strategy
COPY_DV="${PREFIX}-copy"       # CDI clone, forced host-assisted
SNAP_DV="${PREFIX}-snapshot"   # CDI clone, forced through a VolumeSnapshot

# Which phases to run, in order. Trim it to re-test one layer without paying for
# the others, e.g. PHASES=control,csi for a two-minute answer on the CSI driver,
# or PHASES=control,snapshot to test just the candidate workaround.
PHASES="${PHASES:-control,csi,smart,copy,snapshot}"

# What gets cloned:
#   imported   — clone the disk the control phase just imported (self-contained)
#   datasource — clone an SSP golden image, which is literally what the console
#                does; needs the DataSource to be Ready and read access to it
CLONE_SOURCE="${CLONE_SOURCE:-imported}"
DATA_SOURCE="${DATA_SOURCE:-fedora}"
DATA_SOURCE_NS="${DATA_SOURCE_NS:-openshift-virtualization-os-images}"

# Defaults match test-vm-storage.sh so a failure here is the same failure that
# test would hit with SOURCE_MODE=datasource. For a faster smoke run:
#   IMAGE_URL=docker://quay.io/kubevirt/cirros-container-disk-demo DISK_SIZE=1Gi
IMAGE_URL="${IMAGE_URL:-docker://quay.io/containerdisks/fedora:41}"
DISK_SIZE="${DISK_SIZE:-10Gi}"

# Empty means "let CDI pick from the StorageProfile", which is what a real user
# gets and what the console does. Set it to pin the test to one class.
STORAGE_CLASS="${STORAGE_CLASS:-}"

IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-900}"
IMPORT_STALL="${IMPORT_STALL:-240}"
CLONE_TIMEOUT="${CLONE_TIMEOUT:-600}"
# A broken clone does not set phase=Failed, it retry-loops, so the only signal
# is that nothing is moving. Lower than the import stall limit because a clone
# that has not moved in three minutes on this cluster never will.
CLONE_STALL="${CLONE_STALL:-180}"
PVC_CLONE_WAIT="${PVC_CLONE_WAIT:-120}"   # bare CSI clone: the driver answers fast
POLL_INTERVAL="${POLL_INTERVAL:-5}"

KEEP_RESOURCES="${KEEP_RESOURCES:-0}"     # 1 leaves the disks behind for poking at
# Cleanup waits for the disks to actually disappear rather than just requesting
# deletion, because the next run refuses to start while they linger.
CLEANUP_WAIT="${CLEANUP_WAIT:-180}"

# Kept after the run, unlike everything else, because this is the thing worth
# attaching to a bug.
EVIDENCE="${EVIDENCE_FILE:-/tmp/${PREFIX}-evidence-$(date +%Y%m%d-%H%M%S).log}"

# Everything below runs as the logged-in user, with no system:admin
# impersonation, so the result is a claim about what a real project user hits.

WORKDIR=""
SRC_PVC_UID=""
PASSED=0
FAILED=0
SKIPPED=0

# The emoji the other scripts use did not survive a round trip through this
# repo, so these are plain words on purpose.
pass() { log "  PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { log "  FAIL  $1"; FAILED=$((FAILED + 1)); }
warn() { log "  WARN  $1"; }
note() { log "  note  $1"; }
skip() { log "  SKIP  $1"; SKIPPED=$((SKIPPED + 1)); }

# Everything the verdict is based on goes to stdout and to the evidence file.
log() { printf '%s\n' "$*" | tee -a "${EVIDENCE}"; }

# Run a command and file its output as evidence under a label. Never fatal: a
# missing object is itself information, and this is all diagnostics.
evcmd() { # evcmd <label> <command...>
  local label="$1"; shift
  {
    echo ""
    echo "--- ${label} ---"
    "$@" 2>&1 | sed 's/^/  /' || true
  } | tee -a "${EVIDENCE}"
}

# Outcome of each phase, for the summary table and the verdict.
RESULT_CONTROL="not run"
RESULT_CSI="not run"
RESULT_SMART="not run"
RESULT_COPY="not run"
RESULT_SNAPSHOT="not run"
SNAPSHOT_USABLE=0

has_phase() { printf '%s' ",${PHASES}," | grep -q ",$1,"; }

cleanup() {
  echo ""
  echo "=== Cleaning up resources ==="
  if [ "${KEEP_RESOURCES}" = "1" ]; then
    echo "KEEP_RESOURCES=1, leaving the disks in place. Delete with:"
    echo "  oc delete dv ${SRC_DV} ${SMART_DV} ${COPY_DV} ${SNAP_DV} -n ${NAMESPACE} --ignore-not-found"
    echo "  oc delete pvc ${CSI_PVC} -n ${NAMESPACE} --ignore-not-found"
    [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
    echo ""
    echo "Evidence written to ${EVIDENCE}"
    echo "Done!"
    return
  fi

  # DataVolumes own their PVCs, so deleting the DV reclaims the disk. The bare
  # CSI clone has no DataVolume above it and is deleted directly.
  oc delete dv "${SRC_DV}" "${SMART_DV}" "${COPY_DV}" "${SNAP_DV}" -n "${NAMESPACE}" \
    --ignore-not-found --wait=false 2>/dev/null || true
  oc delete pvc "${CSI_PVC}" -n "${NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

  # A host-assisted clone's source pod carries no ownerReferences, so deleting
  # the DataVolume does not reclaim it. Left behind, it holds pvc-protection on
  # the source disk and the next run collides with a PVC stuck Terminating.
  # The label pins the deletion to this run's source disk specifically.
  # A graceful delete is not enough: the pod's container has already exited and
  # the node cannot unmount the NFS volume, so it sits Terminating and keeps
  # holding the PVC. Force is the remedy, and it is safe here — the clone is
  # over and nothing is still writing.
  if [ -n "${SRC_PVC_UID}" ]; then
    local src_pod_sel="cdi.kubevirt.io/hostAssistedSourcePodCloneSource=${SRC_PVC_UID}"
    oc delete pod -n "${NAMESPACE}" -l "${src_pod_sel}" \
      --ignore-not-found --wait=false 2>/dev/null || true
    sleep 5
    if [ -n "$(oc get pods -n "${NAMESPACE}" -l "${src_pod_sel}" -o name 2>/dev/null || echo "")" ]; then
      echo "Clone source pod did not exit; forcing it out so the disk can be released."
      # Note the cost: forcing a pod whose volume the node never unmounted
      # leaves the VolumeAttachment behind, and its attacher finalizer then
      # blocks the PV from being reclaimed. The namespace comes back clean but
      # the volume leaks, and only a cluster admin can clear it.
      SRC_PV="$(oc get pvc "${SRC_DV}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")"
      oc delete pod -n "${NAMESPACE}" -l "${src_pod_sel}" \
        --ignore-not-found --force --grace-period=0 2>/dev/null || true
      if [ -n "${SRC_PV}" ]; then
        echo "WARN  forcing the pod can orphan the VolumeAttachment for pv/${SRC_PV},"
        echo "      leaving it stuck in Released rather than being reclaimed. Check,"
        echo "      and ask a cluster admin to clear it if it is still there:"
        echo "        oc get pv ${SRC_PV}"
        echo "        oc get volumeattachment | grep ${SRC_PV}"
      fi
    fi
  fi

  # Wait for the disks to actually go, so a back-to-back run starts clean.
  echo "Waiting up to ${CLEANUP_WAIT}s for the disks to be released..."
  local deadline remaining="" name
  deadline=$(( $(date +%s) + CLEANUP_WAIT ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    remaining=""
    for name in "${SRC_DV}" "${SMART_DV}" "${COPY_DV}" "${SNAP_DV}" "${CSI_PVC}"; do
      if oc get pvc "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        remaining="${remaining} ${name}"
      fi
    done
    [ -z "${remaining}" ] && break
    sleep 5
  done

  if [ -n "${remaining}" ]; then
    echo "WARN  still present after ${CLEANUP_WAIT}s:${remaining}"
    echo "      A PVC stuck Terminating is usually pinned by a dead CDI worker pod."
    echo "      Check, and force it out if the container has already exited:"
    echo "        oc get pvc -n ${NAMESPACE} | grep ${PREFIX}"
    echo "        oc get pods -n ${NAMESPACE} | grep -E 'source-pod|importer|cdi-upload'"
    echo "        oc delete pod <pod> -n ${NAMESPACE} --force --grace-period=0"
    echo "      The next run refuses to start until these are gone."
  else
    echo "All disks released."
  fi

  [ -n "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  echo ""
  echo "Evidence written to ${EVIDENCE}"
  echo "Done!"
}

if [ "${CLONE_SOURCE}" = "datasource" ]; then
  SOURCE_DESC="DataSource ${DATA_SOURCE_NS}/${DATA_SOURCE}"
else
  SOURCE_DESC="a disk imported from ${IMAGE_URL}"
fi

log "========================================="
log "  VM Storage Clone Test"
log "  Cluster:    $(oc whoami --show-server 2>/dev/null || echo unknown)"
log "  User:       $(oc whoami 2>/dev/null || echo unknown)"
log "  Namespace:  ${NAMESPACE}"
log "  Phases:     ${PHASES}"
log "  Cloning:    ${SOURCE_DESC}"
log "  Disk size:  ${DISK_SIZE}"
log "========================================="

echo ""
echo "=== 0. Preflight ==="

if ! command -v oc >/dev/null 2>&1; then
  echo "FAIL Required binary 'oc' not found in PATH."
  exit 1
fi

oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
  echo "FAIL Namespace ${NAMESPACE} not found."
  exit 1
}
echo "namespace ${NAMESPACE}: present"

case "${CLONE_SOURCE}" in
  imported)
    if ! has_phase control; then
      echo "FAIL CLONE_SOURCE=imported needs the 'control' phase to create the source disk."
      echo "   Either add control to PHASES or use CLONE_SOURCE=datasource."
      exit 1
    fi
    ;;
  datasource)
    DS_READY="$(oc get datasource "${DATA_SOURCE}" -n "${DATA_SOURCE_NS}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
    if [ "${DS_READY}" != "True" ]; then
      echo "FAIL DataSource ${DATA_SOURCE_NS}/${DATA_SOURCE} is not Ready (got '${DS_READY:-not found}')."
      echo "   Available boot sources:"
      oc get datasource -n "${DATA_SOURCE_NS}" 2>/dev/null | sed 's/^/     /' || true
      exit 1
    fi
    echo "datasource ${DATA_SOURCE}: Ready"
    # Cloning across namespaces needs create on datavolumes/source in the source
    # namespace. Checking now keeps an RBAC denial from being mistaken for the
    # storage bug four minutes from here.
    if [ "$(oc auth can-i create datavolumes/source -n "${DATA_SOURCE_NS}" 2>/dev/null || echo no)" != "yes" ]; then
      echo "FAIL Cannot create datavolumes/source in ${DATA_SOURCE_NS} as $(oc whoami)."
      echo "   A cross-namespace clone is denied before it reaches the storage layer,"
      echo "   so this run could not tell you anything about the driver."
      echo "   Use CLONE_SOURCE=imported, which clones within ${NAMESPACE}."
      exit 1
    fi
    echo "clone permission on ${DATA_SOURCE_NS}: yes"
    ;;
  *)
    echo "FAIL CLONE_SOURCE must be 'imported' or 'datasource' (got '${CLONE_SOURCE}')."
    exit 1
    ;;
esac

# Silently reusing a disk from a previous run would make a stale success look
# like a fresh one. A PVC still Terminating counts: CDI will adopt it and the
# DataVolume ends up bound to the old volume, reporting no phase at all.
for name in "${SRC_DV}" "${SMART_DV}" "${COPY_DV}" "${SNAP_DV}"; do
  if oc get dv "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "FAIL Leftover dv/${name} from a previous run exists in ${NAMESPACE}. Remove it first:"
    echo "   oc delete dv ${SRC_DV} ${SMART_DV} ${COPY_DV} ${SNAP_DV} -n ${NAMESPACE} --ignore-not-found"
    exit 1
  fi
done
for name in "${SRC_DV}" "${SMART_DV}" "${COPY_DV}" "${SNAP_DV}" "${CSI_PVC}"; do
  PVC_STATE="$(oc get pvc "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  if [ -n "${PVC_STATE}" ]; then
    if [ -n "$(oc get pvc "${name}" -n "${NAMESPACE}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")" ]; then
      echo "FAIL pvc/${name} from a previous run is still Terminating in ${NAMESPACE}."
      echo "   It is almost certainly pinned by a dead CDI worker pod holding pvc-protection:"
      echo "     oc get pods -n ${NAMESPACE} | grep -E 'source-pod|importer|cdi-upload'"
      echo "     oc delete pod <pod> -n ${NAMESPACE} --force --grace-period=0"
    else
      echo "FAIL Leftover pvc/${name} (${PVC_STATE}) from a previous run exists in ${NAMESPACE}:"
      echo "     oc delete pvc ${name} -n ${NAMESPACE} --ignore-not-found"
    fi
    exit 1
  fi
done
echo "no leftover objects from a previous run"

trap cleanup EXIT

WORKDIR="$(mktemp -d "/tmp/${PREFIX}.XXXXXX")"
mkdir -p "${WORKDIR}/logs"

# ---------------------------------------------------------------------------
# What the cluster claims about this storage, before anything is created. The
# mismatch between what the StorageProfile advertises and what the driver will
# actually do is the heart of the bug, so it is recorded up front.
# ---------------------------------------------------------------------------

echo ""
echo "=== 1. What the cluster says about this storage ==="

EFFECTIVE_SC="${STORAGE_CLASS}"
if [ -z "${EFFECTIVE_SC}" ]; then
  # CDI prefers the virt default when one is annotated, and falls back to the
  # cluster default. Resolved here for reporting only — the manifests below
  # still leave storageClassName unset so the test follows the same path a real
  # user does, and the class actually used is read back off the PVC.
  EFFECTIVE_SC="$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubevirt\.io/is-default-virt-class=="true")].metadata.name}' 2>/dev/null || echo "")"
  if [ -z "${EFFECTIVE_SC}" ]; then
    EFFECTIVE_SC="$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")"
  fi
fi

if [ -n "${EFFECTIVE_SC}" ]; then
  PROVISIONER="$(oc get sc "${EFFECTIVE_SC}" -o jsonpath='{.provisioner}' 2>/dev/null || echo "")"
  BINDING_MODE="$(oc get sc "${EFFECTIVE_SC}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")"
  CLONE_STRATEGY="$(oc get storageprofile "${EFFECTIVE_SC}" -o jsonpath='{.status.cloneStrategy}' 2>/dev/null || echo "")"
  # Whether the strategy was configured or merely defaulted decides where the
  # fix goes: spec is something a human set, status-only is CDI's own guess.
  SPEC_STRATEGY="$(oc get storageprofile "${EFFECTIVE_SC}" -o jsonpath='{.spec.cloneStrategy}' 2>/dev/null || echo "")"
  SNAPSHOT_CLASS="$(oc get storageprofile "${EFFECTIVE_SC}" -o jsonpath='{.status.snapshotClass}' 2>/dev/null || echo "")"
  SP_ARGOCD="$(oc get storageprofile "${EFFECTIVE_SC}" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || echo "")"
  log "  StorageClass:            ${EFFECTIVE_SC}${STORAGE_CLASS:+ (pinned)}"
  log "  provisioner:             ${PROVISIONER:-unknown}"
  log "  volumeBindingMode:       ${BINDING_MODE:-Immediate}"
  log "  StorageProfile strategy: ${CLONE_STRATEGY:-<unset>}${SPEC_STRATEGY:+ (set in spec)}"
  if [ -z "${SPEC_STRATEGY}" ] && [ -n "${CLONE_STRATEGY}" ]; then
    log "                           (spec.cloneStrategy is unset — this is CDI's default)"
  fi
  log "  snapshotClass:           ${SNAPSHOT_CLASS:-<none>}"
  if [ "${CLONE_STRATEGY}" = "csi-clone" ]; then
    note "the profile advertises csi-clone, so CDI will ask the driver to clone"
  fi
  if [ -n "${SP_ARGOCD}" ]; then
    note "this StorageProfile is managed by ArgoCD (${SP_ARGOCD})"
  fi
else
  warn "No default StorageClass resolved; CDI will still pick one. Set STORAGE_CLASS to pin it."
  PROVISIONER=""
  BINDING_MODE=""
  CLONE_STRATEGY=""
  SPEC_STRATEGY=""
  SNAPSHOT_CLASS=""
  SP_ARGOCD=""
fi

# Whether the CSI driver itself admits to supporting cloning. A driver that does
# not implement CLONE_VOLUME has no business being given a csi-clone strategy.
evcmd "CSIDriver objects" oc get csidriver
if [ -n "${EFFECTIVE_SC}" ]; then
  evcmd "StorageProfile ${EFFECTIVE_SC}" oc get storageprofile "${EFFECTIVE_SC}" -o yaml
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

WORKER_RE='importer|cdi-upload|clone-source|source-pod'

# CDI's worker pods carry the real error; the PVC events usually only say it is
# waiting. They are also short-lived and get recreated on every retry, so their
# logs are pulled on every poll rather than once at the end, keyed by pod name
# so a restart loop leaves one file per generation.
snapshot_workers() {
  local ns pod name namespaces=("${NAMESPACE}")
  # A cross-namespace clone runs its source pod in the golden-image namespace;
  # a same-namespace one does not, and scanning there would only pull in pods
  # belonging to someone else's clone.
  if [ "${CLONE_SOURCE}" = "datasource" ] && [ "${DATA_SOURCE_NS}" != "${NAMESPACE}" ]; then
    namespaces+=("${DATA_SOURCE_NS}")
  fi
  for ns in "${namespaces[@]}"; do
    for pod in $(oc get pods -n "${ns}" -o name 2>/dev/null | grep -E "${WORKER_RE}" || true); do
      name="${pod##*/}"
      oc logs "${pod}" -n "${ns}" --tail=40 > "${WORKDIR}/logs/${ns}_${name}.log" 2>/dev/null || true
      oc logs "${pod}" -n "${ns}" --previous --tail=40 \
        > "${WORKDIR}/logs/${ns}_${name}.previous.log" 2>/dev/null || true
      oc get "${pod}" -n "${ns}" \
        -o jsonpath='{.metadata.name}{" phase="}{.status.phase}{" restarts="}{.status.containerStatuses[0].restartCount}{"\n"}' \
        >> "${WORKDIR}/pods-seen.txt" 2>/dev/null || true
    done
  done
}

DV_PHASE=""
DV_PROGRESS=""
DV_RESULT=""
DV_RESTARTS=0

# A clone that keeps restarting is not stalled — progress genuinely changes, it
# just keeps going back to the beginning. Give up after this many restarts
# rather than letting the stall timer be reset forever by a loop.
MAX_RESTARTS="${MAX_RESTARTS:-2}"

# Wait on a DataVolume, treating "no movement" and "moving in circles" as
# results in their own right.
# Sets DV_RESULT to Succeeded | Failed | Stalled | RetryLoop | Timeout.
wait_for_dv() { # wait_for_dv <name> <timeout> <stall>
  local name="$1" timeout="$2" stall="$3"
  local last_state="" last_change deadline state pct last_pct=""
  last_change=$(date +%s)
  deadline=$(( $(date +%s) + timeout ))
  DV_RESULT=""
  DV_PHASE=""
  DV_PROGRESS=""
  DV_RESTARTS=0

  while [ "$(date +%s)" -lt "${deadline}" ]; do
    DV_PHASE="$(oc get dv "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    case "${DV_PHASE}" in
      Succeeded) DV_RESULT="Succeeded"; break ;;
      Failed)    DV_RESULT="Failed";    break ;;
    esac
    DV_PROGRESS="$(oc get dv "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")"
    snapshot_workers
    echo "  phase=${DV_PHASE:-<none>} progress=${DV_PROGRESS:-n/a}"

    # Progress running backwards means the transfer started over. CDI reports
    # it as a percentage string, or N/A before any data moves.
    pct="$(printf '%s' "${DV_PROGRESS}" | tr -d '%')"
    if printf '%s' "${pct}" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
      if [ -n "${last_pct}" ] && awk -v a="${pct}" -v b="${last_pct}" 'BEGIN{exit !(a < b)}'; then
        DV_RESTARTS=$((DV_RESTARTS + 1))
        echo "  progress went ${last_pct}% -> ${pct}% — the clone restarted (${DV_RESTARTS}/${MAX_RESTARTS})"
        if [ "${DV_RESTARTS}" -ge "${MAX_RESTARTS}" ]; then
          DV_RESULT="RetryLoop"
          break
        fi
      fi
      # Only numeric readings become the baseline; "N/A" is not a position to
      # have fallen back from.
      last_pct="${pct}"
    fi

    state="${DV_PHASE}/${DV_PROGRESS}"
    if [ "${state}" != "${last_state}" ]; then
      last_state="${state}"
      last_change=$(date +%s)
    elif [ $(( $(date +%s) - last_change )) -ge "${stall}" ]; then
      echo "  no progress for ${stall}s — treating as stalled"
      DV_RESULT="Stalled"
      break
    fi
    sleep "${POLL_INTERVAL}"
  done
  [ -n "${DV_RESULT}" ] || DV_RESULT="Timeout"
  snapshot_workers
}

# Everything known about a disk that did not come up.
dump_dv_evidence() { # dump_dv_evidence <dv name>
  local name="$1" f digest
  evcmd "DataVolume ${name} conditions" oc get dv "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
  evcmd "PVC ${name} annotations" oc get pvc "${name}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations}'
  evcmd "PVC ${name} events" bash -c \
    "oc describe pvc '${name}' -n '${NAMESPACE}' | sed -n '/Events:/,\$p'"

  if [ -s "${WORKDIR}/pods-seen.txt" ]; then
    evcmd "CDI worker pods seen during the wait" sort -u "${WORKDIR}/pods-seen.txt"
  fi
  # A retry loop produces one log file per generation, all saying the same
  # thing. Report each distinct body once, attributed to the pod it came from,
  # so the interesting line is not buried under copies of itself.
  local seen="${WORKDIR}/seen-digests.txt"
  : > "${seen}"
  for f in "${WORKDIR}"/logs/*.log; do
    [ -s "${f}" ] || continue
    digest="$(cksum < "${f}" | awk '{print $1}')"
    if grep -qx "${digest}" "${seen}"; then continue; fi
    echo "${digest}" >> "${seen}"
    evcmd "worker log $(basename "${f}" .log)" cat "${f}"
  done
}

# Reset the per-phase worker capture so one phase's logs are not reported under
# the next phase's heading.
reset_worker_capture() {
  rm -f "${WORKDIR}/pods-seen.txt"
  rm -f "${WORKDIR}"/logs/*.log 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# control — registry import. No cloning. If this fails, the StorageClass is
# broken for VM disks generally and nothing further would be interpretable.
# ---------------------------------------------------------------------------

SOURCE_PVC=""

if has_phase control; then
  echo ""
  echo "=== 2. control: registry import (no cloning involved) ==="
  reset_worker_capture

  {
    echo "apiVersion: cdi.kubevirt.io/v1beta1"
    echo "kind: DataVolume"
    echo "metadata:"
    echo "  name: ${SRC_DV}"
    echo "  namespace: ${NAMESPACE}"
    echo "spec:"
    echo "  source:"
    echo "    registry:"
    echo "      url: ${IMAGE_URL}"
    # node pull reuses the kubelet's registry credentials and trust, so the
    # importer needs no pull secret of its own.
    echo "      pullMethod: node"
    echo "  storage:"
    if [ -n "${STORAGE_CLASS}" ]; then
      echo "    storageClassName: ${STORAGE_CLASS}"
    fi
    echo "    resources:"
    echo "      requests:"
    echo "        storage: ${DISK_SIZE}"
  } > "${WORKDIR}/source-dv.yaml"

  oc apply -n "${NAMESPACE}" -f "${WORKDIR}/source-dv.yaml"
  echo "Waiting up to ${IMPORT_TIMEOUT}s for the import (stall limit ${IMPORT_STALL}s)..."
  wait_for_dv "${SRC_DV}" "${IMPORT_TIMEOUT}" "${IMPORT_STALL}"

  if [ "${DV_RESULT}" = "Succeeded" ]; then
    SOURCE_PVC="${SRC_DV}"
    RESULT_CONTROL="Succeeded"
    pass "Registry import into this StorageClass works (the class itself is fine)"
  else
    RESULT_CONTROL="${DV_RESULT}"
    fail "Registry import into this StorageClass works (import ${DV_RESULT} in phase ${DV_PHASE:-<none>})"
    dump_dv_evidence "${SRC_DV}"
    log ""
    log "The control phase failed, so this run says nothing about cloning — the"
    log "StorageClass cannot even take a plain imported disk. Fix that first."
    exit 1
  fi

  # Read back what CDI actually chose, which is what the clone phases must match.
  SRC_SC="$(oc get pvc "${SOURCE_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")"
  SRC_MODES="$(oc get pvc "${SOURCE_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || echo "")"
  SRC_VOLMODE="$(oc get pvc "${SOURCE_PVC}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeMode}' 2>/dev/null || echo "")"
  SRC_CAPACITY="$(oc get pvc "${SOURCE_PVC}" -n "${NAMESPACE}" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "${DISK_SIZE}")"
  # Host-assisted clone source pods are labelled with this, and cleanup needs it
  # to tell this run's orphans from anyone else's.
  SRC_PVC_UID="$(oc get pvc "${SOURCE_PVC}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"
  log ""
  log "  source PVC:   ${SOURCE_PVC}"
  log "  storageClass: ${SRC_SC}"
  log "  accessModes:  ${SRC_MODES}"
  log "  volumeMode:   ${SRC_VOLMODE}"
  log "  capacity:     ${SRC_CAPACITY}"
else
  skip "control: registry import (not in PHASES)"
  SRC_SC="${STORAGE_CLASS}"
  SRC_MODES="ReadWriteMany"
  SRC_VOLMODE="Filesystem"
  SRC_CAPACITY="${DISK_SIZE}"
fi

# ---------------------------------------------------------------------------
# csi — a bare PVC with dataSource pointing at the source PVC. No CDI, no
# DataVolume, no importer pod: just the external-provisioner asking the driver
# to clone. If this fails the fault is unambiguously in the CSI driver.
# ---------------------------------------------------------------------------

if has_phase csi; then
  echo ""
  echo "=== 3. csi: bare PVC-to-PVC clone, CDI not involved ==="

  if [ "${CLONE_SOURCE}" != "imported" ] || [ -z "${SOURCE_PVC}" ]; then
    skip "csi: needs a same-namespace source PVC (CLONE_SOURCE=imported)"
    RESULT_CSI="skipped"
  else
    {
      echo "apiVersion: v1"
      echo "kind: PersistentVolumeClaim"
      echo "metadata:"
      echo "  name: ${CSI_PVC}"
      echo "  namespace: ${NAMESPACE}"
      echo "spec:"
      if [ -n "${SRC_SC}" ]; then
        echo "  storageClassName: ${SRC_SC}"
      fi
      echo "  dataSource:"
      echo "    kind: PersistentVolumeClaim"
      echo "    name: ${SOURCE_PVC}"
      echo "  accessModes:"
      for mode in ${SRC_MODES}; do
        echo "  - ${mode}"
      done
      if [ -n "${SRC_VOLMODE}" ]; then
        echo "  volumeMode: ${SRC_VOLMODE}"
      fi
      echo "  resources:"
      echo "    requests:"
      echo "      storage: ${SRC_CAPACITY}"
    } > "${WORKDIR}/csi-pvc.yaml"

    oc apply -n "${NAMESPACE}" -f "${WORKDIR}/csi-pvc.yaml"
    echo "Waiting up to ${PVC_CLONE_WAIT}s for the clone to bind..."

    # Events are selected by UID, not name: a previous run's PVC of the same
    # name leaves its events in the namespace for about an hour, and matching
    # on name would attribute them to this one.
    CSI_UID="$(oc get pvc "${CSI_PVC}" -n "${NAMESPACE}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")"

    CSI_PHASE=""
    CSI_EVENT=""
    CSI_DEADLINE=$(( $(date +%s) + PVC_CLONE_WAIT ))
    while [ "$(date +%s)" -lt "${CSI_DEADLINE}" ]; do
      CSI_PHASE="$(oc get pvc "${CSI_PVC}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
      [ "${CSI_PHASE}" = "Bound" ] && break
      # The provisioner reports its refusal as an event, not a PVC condition, so
      # that is the thing to watch. It arrives within a few seconds.
      CSI_EVENT="$(oc get events -n "${NAMESPACE}" \
        --field-selector "involvedObject.kind=PersistentVolumeClaim,involvedObject.uid=${CSI_UID}" \
        -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null \
        | grep -i 'failed\|error\|unsupported\|unimplemented' | head -5 || true)"
      if [ -n "${CSI_EVENT}" ]; then
        echo "  provisioner reported a failure"
        break
      fi
      echo "  phase=${CSI_PHASE:-<none>}"
      sleep "${POLL_INTERVAL}"
    done

    # On a WaitForFirstConsumer class an unconsumed PVC stays Pending by design
    # and the provisioner is never asked to clone, so a silent Pending here
    # proves nothing. Only a refusal event is evidence.
    SRC_BINDING="$(oc get sc "${SRC_SC}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo "")"

    if [ "${CSI_PHASE}" = "Bound" ]; then
      RESULT_CSI="Bound"
      pass "CSI driver clones a volume (bare PVC dataSource bound)"
    elif [ "${SRC_BINDING}" = "WaitForFirstConsumer" ] && [ -z "${CSI_EVENT}" ]; then
      RESULT_CSI="inconclusive"
      skip "CSI driver clones a volume (${SRC_SC} is WaitForFirstConsumer, so an"
      log "        unconsumed clone stays Pending whether or not the driver can clone;"
      log "        the CDI phases below exercise the same call with a consumer attached)"
    else
      RESULT_CSI="${CSI_EVENT:+ProvisioningFailed}"
      RESULT_CSI="${RESULT_CSI:-Pending}"
      fail "CSI driver clones a volume (PVC ${CSI_PHASE:-<none>} after ${PVC_CLONE_WAIT}s)"
      if [ -n "${CSI_EVENT}" ]; then
        log ""
        log "  driver said:"
        printf '%s\n' "${CSI_EVENT}" | sed 's/^/    /' | tee -a "${EVIDENCE}"
      fi
      evcmd "PVC ${CSI_PVC} events" bash -c \
        "oc describe pvc '${CSI_PVC}' -n '${NAMESPACE}' | sed -n '/Events:/,\$p'"
    fi
  fi
else
  skip "csi: bare PVC-to-PVC clone (not in PHASES)"
fi

# ---------------------------------------------------------------------------
# Shared manifest builder for the two CDI clone phases. The only difference
# between them is the cloneType annotation.
# ---------------------------------------------------------------------------

write_clone_dv() { # write_clone_dv <name> <file> [cloneType]
  local name="$1" file="$2" clone_type="${3:-}"
  {
    echo "apiVersion: cdi.kubevirt.io/v1beta1"
    echo "kind: DataVolume"
    echo "metadata:"
    echo "  name: ${name}"
    echo "  namespace: ${NAMESPACE}"
    if [ -n "${clone_type}" ]; then
      echo "  annotations:"
      echo "    cdi.kubevirt.io/cloneType: ${clone_type}"
    fi
    echo "spec:"
    if [ "${CLONE_SOURCE}" = "datasource" ]; then
      echo "  sourceRef:"
      echo "    kind: DataSource"
      echo "    name: ${DATA_SOURCE}"
      echo "    namespace: ${DATA_SOURCE_NS}"
    else
      echo "  source:"
      echo "    pvc:"
      echo "      namespace: ${NAMESPACE}"
      echo "      name: ${SOURCE_PVC}"
    fi
    echo "  storage:"
    if [ -n "${STORAGE_CLASS}" ]; then
      echo "    storageClassName: ${STORAGE_CLASS}"
    fi
    echo "    resources:"
    echo "      requests:"
    echo "        storage: ${DISK_SIZE}"
  } > "${file}"
}

# A DataVolume reporting Succeeded is CDI's claim, not evidence. Check the disk
# it was supposed to produce actually exists, is bound, and is not short of the
# source — a clone that "succeeds" into an unusable PVC would otherwise be
# reported as a working path.
verify_clone_target() { # verify_clone_target <dv name> <label>
  local name="$1" label="$2" phase capacity modes
  phase="$(oc get pvc "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  capacity="$(oc get pvc "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "")"
  modes="$(oc get pvc "${name}" -n "${NAMESPACE}" -o jsonpath='{.spec.accessModes[*]}' 2>/dev/null || echo "")"

  if [ "${phase}" != "Bound" ]; then
    fail "${label} produced a usable disk (target PVC is ${phase:-missing}, not Bound)"
    return 1
  fi
  log "        target PVC ${name}: Bound, ${capacity:-unknown}, ${modes:-unknown}"

  # Compare against the source in bytes, since CDI and the driver report sizes
  # in different units (10Gi vs 11381663335).
  if [ -n "${SRC_CAPACITY}" ] && [ -n "${capacity}" ]; then
    if ! awk -v t="${capacity}" -v s="${SRC_CAPACITY}" '
      function bytes(v,   n, u, m) {
        n = v; sub(/[A-Za-z]+$/, "", n); u = v; sub(/^[0-9.]+/, "", u)
        m = 1
        if (u == "Ki") m = 1024;          else if (u == "Mi") m = 1024^2
        else if (u == "Gi") m = 1024^3;   else if (u == "Ti") m = 1024^4
        else if (u == "K")  m = 1000;     else if (u == "M")  m = 1000^2
        else if (u == "G")  m = 1000^3;   else if (u == "T")  m = 1000^4
        return n * m
      }
      BEGIN { exit !(bytes(t) >= bytes(s)) }'; then
      warn "target disk ${capacity} is smaller than the source ${SRC_CAPACITY}"
    fi
  fi
  return 0
}

# What CDI decided to do, which is only visible once the target PVC exists.
report_clone_type() { # report_clone_type <dv name>
  local chosen
  chosen="$(oc get pvc "$1" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.annotations.cdi\.kubevirt\.io/cloneType}' 2>/dev/null || echo "")"
  if [ -n "${chosen}" ]; then
    note "CDI chose cloneType=${chosen}"
  fi
}

# ---------------------------------------------------------------------------
# smart — a CDI clone with no hints, so CDI picks its strategy from the
# StorageProfile. This is exactly what the console's "create VM from template"
# does, which is why its failure mode matters outside these tests.
# ---------------------------------------------------------------------------

if has_phase smart; then
  echo ""
  echo "=== 4. smart: CDI clone, CDI picks the strategy ==="
  reset_worker_capture

  write_clone_dv "${SMART_DV}" "${WORKDIR}/smart-dv.yaml"
  oc apply -n "${NAMESPACE}" -f "${WORKDIR}/smart-dv.yaml"
  echo "Waiting up to ${CLONE_TIMEOUT}s for the clone (stall limit ${CLONE_STALL}s)..."
  sleep "${POLL_INTERVAL}"
  report_clone_type "${SMART_DV}"
  wait_for_dv "${SMART_DV}" "${CLONE_TIMEOUT}" "${CLONE_STALL}"

  RESULT_SMART="${DV_RESULT}"
  if [ "${DV_RESULT}" = "Succeeded" ]; then
    pass "CDI clones a disk using its own chosen strategy"
    verify_clone_target "${SMART_DV}" "CDI's chosen strategy" || true
  else
    fail "CDI clones a disk using its own chosen strategy (${DV_RESULT} in phase ${DV_PHASE:-<none>})"
    report_clone_type "${SMART_DV}"
    dump_dv_evidence "${SMART_DV}"
  fi
else
  skip "smart: CDI clone with the default strategy (not in PHASES)"
fi

# ---------------------------------------------------------------------------
# copy — force the host-assisted path, which does not ask the driver to clone
# at all: CDI stands up a source pod and an upload server and streams the data
# through. It is the fallback CDI is supposed to have when csi-clone is
# unavailable, so whether it works decides if this is one bug or two.
# ---------------------------------------------------------------------------

if has_phase copy; then
  echo ""
  echo "=== 5. copy: CDI clone forced down the host-assisted path ==="
  reset_worker_capture

  write_clone_dv "${COPY_DV}" "${WORKDIR}/copy-dv.yaml" "copy"
  oc apply -n "${NAMESPACE}" -f "${WORKDIR}/copy-dv.yaml"
  echo "Waiting up to ${CLONE_TIMEOUT}s for the clone (stall limit ${CLONE_STALL}s)..."
  sleep "${POLL_INTERVAL}"
  report_clone_type "${COPY_DV}"
  wait_for_dv "${COPY_DV}" "${CLONE_TIMEOUT}" "${CLONE_STALL}"

  RESULT_COPY="${DV_RESULT}"
  if [ "${DV_RESULT}" = "Succeeded" ]; then
    pass "CDI clones a disk host-assisted (the fallback path works)"
    verify_clone_target "${COPY_DV}" "The host-assisted path" || true
  else
    fail "CDI clones a disk host-assisted (${DV_RESULT} in phase ${DV_PHASE:-<none>})"
    if [ "${DV_RESULT}" = "RetryLoop" ]; then
      note "the transfer reached a non-zero percentage and then restarted from 0"
      note "${DV_RESTARTS} restarts observed — it is looping, not slowly succeeding"
    fi
    # A host-assisted clone that keeps restarting burns through worker pods, so
    # the count of distinct pods seen is the retry loop made visible.
    if [ -s "${WORKDIR}/pods-seen.txt" ]; then
      GENERATIONS="$(awk '{print $1}' "${WORKDIR}/pods-seen.txt" | sort -u | wc -l | tr -d ' ')"
      if [ "${GENERATIONS}" -gt 1 ]; then
        note "${GENERATIONS} distinct CDI worker pods during one clone — it is restarting, not progressing"
      fi
    fi
    dump_dv_evidence "${COPY_DV}"
  fi
else
  skip "copy: forced host-assisted CDI clone (not in PHASES)"
fi

# ---------------------------------------------------------------------------
# snapshot — CDI's third strategy: take a VolumeSnapshot of the source and
# create the target from it. It never issues a clone call, so a driver that
# cannot clone but can snapshot will serve it. If this is the one that works,
# the whole problem is a one-line StorageProfile change rather than a driver
# fix, which is a very different conversation to have with the storage owner.
# ---------------------------------------------------------------------------

if has_phase snapshot; then
  echo ""
  echo "=== 6. snapshot: CDI clone forced through a VolumeSnapshot ==="

  if [ -z "${SNAPSHOT_CLASS}" ]; then
    skip "snapshot: StorageProfile ${EFFECTIVE_SC} reports no snapshotClass, so"
    log "        CDI has no snapshot path available on this storage"
    RESULT_SNAPSHOT="unavailable"
  else
    reset_worker_capture
    note "using VolumeSnapshotClass ${SNAPSHOT_CLASS}"

    write_clone_dv "${SNAP_DV}" "${WORKDIR}/snapshot-dv.yaml" "snapshot"
    oc apply -n "${NAMESPACE}" -f "${WORKDIR}/snapshot-dv.yaml"
    echo "Waiting up to ${CLONE_TIMEOUT}s for the clone (stall limit ${CLONE_STALL}s)..."
    sleep "${POLL_INTERVAL}"
    report_clone_type "${SNAP_DV}"
    wait_for_dv "${SNAP_DV}" "${CLONE_TIMEOUT}" "${CLONE_STALL}"

    RESULT_SNAPSHOT="${DV_RESULT}"
    if [ "${DV_RESULT}" = "Succeeded" ]; then
      pass "CDI clones a disk via VolumeSnapshot"
      if verify_clone_target "${SNAP_DV}" "The snapshot path"; then
        SNAPSHOT_USABLE=1
      fi
    else
      fail "CDI clones a disk via VolumeSnapshot (${DV_RESULT} in phase ${DV_PHASE:-<none>})"
      evcmd "VolumeSnapshots in ${NAMESPACE}" oc get volumesnapshot -n "${NAMESPACE}"
      dump_dv_evidence "${SNAP_DV}"
    fi
  fi
else
  skip "snapshot: CDI clone via VolumeSnapshot (not in PHASES)"
fi

# ---------------------------------------------------------------------------
# Diagnosis — match the collected output against the signatures of the known
# failure so the verdict names a cause rather than just a phase that did not
# finish.
# ---------------------------------------------------------------------------

echo ""
echo "=== 7. Diagnosis ==="

# How many clone strategies were actually exercised, so the verdict can tell
# "every clone path worked" from "no clone path was tried".
CLONES_RUN=0
for r in "${RESULT_CSI}" "${RESULT_SMART}" "${RESULT_COPY}" "${RESULT_SNAPSHOT}"; do
  case "${r}" in
    "not run"|skipped|unavailable|inconclusive) ;;
    *) CLONES_RUN=$((CLONES_RUN + 1)) ;;
  esac
done

matched() { grep -qi -- "$1" "${EVIDENCE}" 2>/dev/null; }

SIGNATURES=0

if matched "not supported for FlashBlade" || matched "cloning is not supported"; then
  log "  * The CSI driver refuses to clone: it answered the clone call with"
  log "    'volume cloning is not supported'. No amount of CDI retrying fixes that."
  SIGNATURES=$((SIGNATURES + 1))
fi
if matched "code = Unimplemented"; then
  log "  * The driver returned gRPC Unimplemented for the clone call, i.e. the"
  log "    CLONE_VOLUME capability is not implemented by this backend."
  SIGNATURES=$((SIGNATURES + 1))
fi
if matched "error unarchiving to /data"; then
  log "  * The host-assisted fallback died untarring onto the target"
  log "    ('error unarchiving to /data'), so the fallback is broken too."
  SIGNATURES=$((SIGNATURES + 1))
fi
if [ "${RESULT_COPY}" = "RetryLoop" ]; then
  log "  * The host-assisted fallback transfers part of the disk, dies, and starts"
  log "    over. It never reports Failed, so nothing surfaces to the user — the"
  log "    clone just never finishes."
  SIGNATURES=$((SIGNATURES + 1))
fi
if matched "forbidden"; then
  log "  * Something in the run was denied by RBAC — check the evidence before"
  log "    attributing the failure to storage."
  SIGNATURES=$((SIGNATURES + 1))
fi

case "${RESULT_CSI}" in
  Bound|"not run"|skipped|inconclusive) CSI_REFUSED=0 ;;
  *)                                    CSI_REFUSED=1 ;;
esac

if [ "${CLONE_STRATEGY}" = "csi-clone" ] && [ "${CSI_REFUSED}" = "1" ]; then
  log "  * Misconfiguration: StorageProfile ${EFFECTIVE_SC} advertises"
  log "    cloneStrategy=csi-clone while the driver cannot serve it, so CDI keeps"
  log "    choosing a strategy that can never succeed."
  if [ -z "${SPEC_STRATEGY}" ]; then
    log "    spec.cloneStrategy is unset, so csi-clone is CDI's own default for this"
    log "    provisioner — setting it explicitly is what overrides that."
  fi
  SIGNATURES=$((SIGNATURES + 1))
fi

# The most useful thing this test can report: a strategy that does work.
if [ "${RESULT_SNAPSHOT}" = "Succeeded" ] && [ "${SNAPSHOT_USABLE}" = "1" ] && [ "${FAILED}" -gt 0 ]; then
  log ""
  log "  WORKAROUND FOUND: the snapshot strategy completed on this same storage."
  log "  Pinning the StorageProfile to it should restore cloning, and with it the"
  log "  console's create-VM-from-template path, without touching the CSI driver:"
  log ""
  log "    spec:"
  log "      cloneStrategy: snapshot"
  log ""
  log "  on storageprofile/${EFFECTIVE_SC}."
  if [ -n "${SP_ARGOCD}" ]; then
    log "  That profile is ArgoCD-managed (${SP_ARGOCD}),"
    log "  so make the change in the GitOps repo — an edit on the cluster is reverted."
  fi
fi

if [ "${SIGNATURES}" -eq 0 ]; then
  if [ "${FAILED}" -eq 0 ]; then
    log "  Nothing to diagnose — no phase failed."
  else
    log "  No known failure signature matched. The evidence file has the raw output;"
    log "  this may be a different problem than the documented one."
  fi
fi

echo ""
log "========================================="
log "  Clone test results"
log "  control (registry import):  ${RESULT_CONTROL}"
log "  csi     (bare PVC clone):   ${RESULT_CSI}"
log "  smart   (CDI, auto):        ${RESULT_SMART}"
log "  copy    (CDI, host-assist): ${RESULT_COPY}"
log "  snapshot (CDI, via snapshot): ${RESULT_SNAPSHOT}"
log "  ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
log "========================================="

if [ "${FAILED}" -eq 0 ] && [ "${CLONES_RUN}" -eq 0 ]; then
  log ""
  log "  No clone strategy was actually exercised, so this run says nothing about"
  log "  cloning. Re-run with the clone phases in PHASES."
elif [ "${FAILED}" -eq 0 ]; then
  log ""
  log "  Every clone strategy tried here worked on ${EFFECTIVE_SC:-this StorageClass}."
  if [ "${CLONES_RUN}" -lt 4 ]; then
    log "  Note that only ${CLONES_RUN} of the 4 clone strategies ran; the full set is"
    log "  PHASES=control,csi,smart,copy,snapshot."
  fi
  log "  If cloning was previously broken here, this is what a fix looks like:"
  log "  test-vm-storage.sh can be re-run with SOURCE_MODE=datasource, and the"
  log "  console's 'Create VirtualMachine from template' path should work again."
else
  log ""
  log "  ISSUE REPRODUCED: cloning is broken on ${EFFECTIVE_SC:-this StorageClass}."
  if [ "${RESULT_CONTROL}" = "Succeeded" ]; then
    log "  The same StorageClass imported a disk successfully in the control phase,"
    log "  so the class is serving VM disks fine and the fault is in the clone path"
    log "  specifically."
  fi
  log ""
  log "  Why it is worth fixing rather than working around: cloning a golden image"
  log "  is what the console's 'Create VirtualMachine -> from template' button does,"
  log "  so this hangs VM provisioning through the UI with no error shown to the"
  log "  user. The DataVolume never reports Failed, it retry-loops indefinitely."
  log ""
  log "  Attach ${EVIDENCE} to the report."
  exit 1
fi
