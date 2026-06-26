#!/usr/bin/env bash
set -euo pipefail

# Patch PDBs that currently have maxUnavailable=50% and disruptionsAllowed=0,
# and provide deterministic rollback back to original maxUnavailable,
# unhealthyPodEvictionPolicy, and Flux reconcile annotation values.
#
# Suggested prod usage:
#
# 1. Prepare (capture targets from live cluster):
#    ./pdb_disruption_patch.sh prepare --context cft-demo-01-aks
#
# 2. Safe preview (validate patches without applying):
#    ./pdb_disruption_patch.sh apply --run-dir runs/20260626-161407 --dry-run --context cft-demo-01-aks
#
# 3. Live apply (patch targets with auto-rollback on failure):
#    ./pdb_disruption_patch.sh apply --run-dir runs/20260626-161407 --context cft-demo-01-aks --auto-revert-on-failure --yes
#
# 4. Revert (restore original maxUnavailable, unhealthyPodEvictionPolicy,
#    and Flux reconcile annotation):
#    ./pdb_disruption_patch.sh revert --run-dir runs/20260626-161407 --context cft-demo-01-aks --yes

usage() {
  cat <<'EOF'
Usage:
  ./pdb_disruption_patch.sh prepare [--run-dir <dir>] [--context <kube-context>]
  ./pdb_disruption_patch.sh apply --run-dir <dir> [--dry-run] [--yes] [--context <kube-context>] [--auto-revert-on-failure]
  ./pdb_disruption_patch.sh revert --run-dir <dir> [--yes] [--context <kube-context>]
  ./pdb_disruption_patch.sh status [--run-dir <dir>] [--context <kube-context>]

Actions:
  prepare   Build target list + backup data in a run directory.
  apply     Patch targets from run directory to spec.maxUnavailable=1,
            spec.unhealthyPodEvictionPolicy=AlwaysAllow, and
            metadata.annotations[kustomize.toolkit.fluxcd.io/reconcile]=disabled.
  revert    Restore original spec.maxUnavailable,
            spec.unhealthyPodEvictionPolicy, and Flux reconcile annotation from backup.
  status    Show current status for targets.

Notes:
  - Target filter is strict: status.disruptionsAllowed < 1 at prepare time,
    and spec.maxUnavailable is < 100% (numeric or percentage string).
  - Revert restores maxUnavailable, unhealthyPodEvictionPolicy,
    and annotation kustomize.toolkit.fluxcd.io/reconcile.
  - Non-dry-run apply/revert requires interactive confirmation unless --yes is set.
  - --context enforces current kube context to avoid wrong-cluster changes.
  - --auto-revert-on-failure (apply only) reverts successfully patched PDBs if any apply fails.
  - --dry-run on apply validates patches against API server without changing resources.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_DIR="$ROOT_DIR/runs"
ACTION="${1:-}"
shift || true

RUN_DIR=""
DRY_RUN="false"
YES="false"
REQUIRED_CONTEXT=""
AUTO_REVERT_ON_FAILURE="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      if [[ $# -lt 2 ]]; then
        echo "--run-dir requires a value" >&2
        exit 1
      fi
      RUN_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --yes)
      YES="true"
      shift
      ;;
    --context)
      if [[ $# -lt 2 ]]; then
        echo "--context requires a value" >&2
        exit 1
      fi
      REQUIRED_CONTEXT="$2"
      shift 2
      ;;
    --auto-revert-on-failure)
      AUTO_REVERT_ON_FAILURE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  usage
  exit 1
fi

require_cmd kubectl
require_cmd jq

single_line() {
  echo "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

current_context() {
  kubectl config current-context 2>/dev/null || true
}

enforce_context_guard() {
  if [[ -z "$REQUIRED_CONTEXT" ]]; then
    return
  fi

  local current
  current="$(current_context)"
  if [[ -z "$current" ]]; then
    echo "Unable to determine current kube context" >&2
    exit 1
  fi

  if [[ "$current" != "$REQUIRED_CONTEXT" ]]; then
    echo "Kube context guard failed: current=$current expected=$REQUIRED_CONTEXT" >&2
    exit 1
  fi
}

confirm_non_dry_run() {
  local action="$1"
  local count="$2"
  local targets_file="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi

  if [[ "$YES" == "true" ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Non-interactive terminal detected; use --yes to proceed with $action" >&2
    exit 1
  fi

  local current
  current="$(current_context)"
  echo "About to run: $action"
  echo "Context: ${current:-<unknown>}"
  echo "Targets: $count"
  echo "Targets file: $targets_file"
  printf "Type yes to continue: "

  local response
  read -r response
  if [[ "$response" != "yes" ]]; then
    echo "Cancelled by user"
    exit 1
  fi
}

revert_one_target() {
  local ns="$1"
  local name="$2"
  local orig="$3"
  local orig_policy="$4"
  local orig_flux_reconcile="$5"

  local payload
  payload=$(jq -cn --argjson m "$orig" --argjson p "$orig_policy" --argjson a "$orig_flux_reconcile" '{spec:{maxUnavailable:$m,unhealthyPodEvictionPolicy:$p},metadata:{annotations:{"kustomize.toolkit.fluxcd.io/reconcile":$a}}}')
  kubectl patch pdb "$name" -n "$ns" --type merge -p "$payload" 2>&1
}

prepare() {
  enforce_context_guard

  local dir
  if [[ -n "$RUN_DIR" ]]; then
    dir="$RUN_DIR"
  else
    mkdir -p "$RUNS_DIR"
    dir="$RUNS_DIR/$(timestamp)"
  fi

  mkdir -p "$dir"

  local targets_file="$dir/targets.jsonl"
  local backup_file="$dir/pdb_all_before.json"

  kubectl get pdb -A -o json > "$backup_file"

  jq -c '
    def max_unavailable_lt_100pct:
      (
        (.spec.maxUnavailable | type) == "number"
        and .spec.maxUnavailable < 100
      )
      or
      (
        (.spec.maxUnavailable | type) == "string"
        and (.spec.maxUnavailable | test("%$"))
        and ((.spec.maxUnavailable | rtrimstr("%") | tonumber) < 100)
      )
      or
      (
        (.spec.maxUnavailable | type) == "string"
        and (.spec.maxUnavailable | test("^[0-9]+$"))
        and ((.spec.maxUnavailable | tonumber) < 100)
      );
    .items[]
    | select(max_unavailable_lt_100pct and .status.disruptionsAllowed < 1)
    | {
        namespace: .metadata.namespace,
        name: .metadata.name,
        origMaxUnavailable: .spec.maxUnavailable,
        origUnhealthyPodEvictionPolicy: (if (.spec | has("unhealthyPodEvictionPolicy")) then .spec.unhealthyPodEvictionPolicy else null end),
      origFluxReconcileAnnotation: (.metadata.annotations["kustomize.toolkit.fluxcd.io/reconcile"] // null),
        disruptionsAllowedAtPrepare: .status.disruptionsAllowed
      }
  ' "$backup_file" > "$targets_file"

  local count
  count=$(wc -l < "$targets_file" | tr -d ' ')
  echo "Run directory: $dir"
  echo "Targets captured: $count"
  echo "Targets file: $targets_file"
}

apply_patch_targets() {
  enforce_context_guard

  if [[ -z "$RUN_DIR" ]]; then
    echo "--run-dir is required for apply" >&2
    exit 1
  fi

  local targets_file="$RUN_DIR/targets.jsonl"
  if [[ ! -f "$targets_file" ]]; then
    echo "Targets file not found: $targets_file" >&2
    exit 1
  fi

  local count
  count=$(wc -l < "$targets_file" | tr -d ' ')
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run apply for $count targets from $targets_file"
  else
    echo "Applying patch to $count targets from $targets_file"
  fi

  confirm_non_dry_run "apply" "$count" "$targets_file"

  local result_file success_file failure_file
  result_file="$RUN_DIR/apply_results.tsv"
  success_file="$RUN_DIR/apply_success.jsonl"
  failure_file="$RUN_DIR/apply_failed.jsonl"
  : > "$result_file"
  : > "$success_file"
  : > "$failure_file"

  local line ns name payload patch_out processed failed
  processed=0
  failed=0
  echo -e "RESULT\tNAMESPACE\tNAME\tTARGET\tAPI_RESPONSE"
  echo -e "RESULT\tNAMESPACE\tNAME\tTARGET\tAPI_RESPONSE" >> "$result_file"
  while IFS= read -r line; do
    ns=$(echo "$line" | jq -r '.namespace')
    name=$(echo "$line" | jq -r '.name')
    payload='{"spec":{"maxUnavailable":1,"unhealthyPodEvictionPolicy":"AlwaysAllow"},"metadata":{"annotations":{"kustomize.toolkit.fluxcd.io/reconcile":"disabled"}}}'
    if [[ "$DRY_RUN" == "true" ]]; then
      if patch_out=$(kubectl patch pdb "$name" -n "$ns" --type merge -p "$payload" --dry-run=server 2>&1); then
        patch_out=$(single_line "$patch_out")
        echo -e "OK\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out"
        echo -e "OK\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out" >> "$result_file"
      else
        patch_out=$(single_line "$patch_out")
        echo -e "ERROR\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out"
        echo -e "ERROR\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out" >> "$result_file"
        echo "$line" >> "$failure_file"
        failed=$((failed + 1))
      fi
    else
      if patch_out=$(kubectl patch pdb "$name" -n "$ns" --type merge -p "$payload" 2>&1); then
        patch_out=$(single_line "$patch_out")
        echo -e "OK\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out"
        echo -e "OK\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out" >> "$result_file"
        echo "$line" >> "$success_file"
      else
        patch_out=$(single_line "$patch_out")
        echo -e "ERROR\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out"
        echo -e "ERROR\t$ns\t$name\tmaxUnavailable=1,unhealthyPodEvictionPolicy=AlwaysAllow,fluxReconcile=disabled\t$patch_out" >> "$result_file"
        echo "$line" >> "$failure_file"
        failed=$((failed + 1))
      fi
    fi
    processed=$((processed + 1))
  done < "$targets_file"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run apply complete (no resources changed)"
  else
    echo "Patch apply complete"
  fi
  echo "Processed: $processed, Failed: $failed"
  echo "Results log: $result_file"
  if [[ -s "$failure_file" ]]; then
    echo "Failed targets file: $failure_file"
  fi

  if [[ "$DRY_RUN" != "true" && "$failed" -gt 0 && "$AUTO_REVERT_ON_FAILURE" == "true" ]]; then
    local reverted_ok reverted_failed revert_out orig orig_policy orig_flux_reconcile
    reverted_ok=0
    reverted_failed=0
    echo "Apply had failures; auto-reverting successful apply targets"
    while IFS= read -r line; do
      ns=$(echo "$line" | jq -r '.namespace')
      name=$(echo "$line" | jq -r '.name')
      orig=$(echo "$line" | jq -c '.origMaxUnavailable')
      orig_policy=$(echo "$line" | jq -c '.origUnhealthyPodEvictionPolicy')
      orig_flux_reconcile=$(echo "$line" | jq -c '.origFluxReconcileAnnotation')
      if revert_out=$(revert_one_target "$ns" "$name" "$orig" "$orig_policy" "$orig_flux_reconcile"); then
        reverted_ok=$((reverted_ok + 1))
      else
        reverted_failed=$((reverted_failed + 1))
      fi
    done < "$success_file"
    echo "Auto-revert summary: reverted_ok=$reverted_ok reverted_failed=$reverted_failed"
  fi

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

revert_targets() {
  enforce_context_guard

  if [[ -z "$RUN_DIR" ]]; then
    echo "--run-dir is required for revert" >&2
    exit 1
  fi

  local targets_file="$RUN_DIR/targets.jsonl"
  if [[ ! -f "$targets_file" ]]; then
    echo "Targets file not found: $targets_file" >&2
    exit 1
  fi

  local count
  count=$(wc -l < "$targets_file" | tr -d ' ')
  echo "Reverting $count targets from $targets_file"
  confirm_non_dry_run "revert" "$count" "$targets_file"

  local result_file failure_file
  result_file="$RUN_DIR/revert_results.tsv"
  failure_file="$RUN_DIR/revert_failed.jsonl"
  : > "$result_file"
  : > "$failure_file"

  local line ns name orig orig_policy orig_flux_reconcile payload patch_out processed failed
  processed=0
  failed=0
  echo -e "RESULT\tNAMESPACE\tNAME\tTARGET\tAPI_RESPONSE"
  echo -e "RESULT\tNAMESPACE\tNAME\tTARGET\tAPI_RESPONSE" >> "$result_file"
  while IFS= read -r line; do
    ns=$(echo "$line" | jq -r '.namespace')
    name=$(echo "$line" | jq -r '.name')
    orig=$(echo "$line" | jq -c '.origMaxUnavailable')
    orig_policy=$(echo "$line" | jq -c '.origUnhealthyPodEvictionPolicy')
    orig_flux_reconcile=$(echo "$line" | jq -c '.origFluxReconcileAnnotation')
    if patch_out=$(revert_one_target "$ns" "$name" "$orig" "$orig_policy" "$orig_flux_reconcile"); then
      patch_out=$(single_line "$patch_out")
      echo -e "OK\t$ns\t$name\tmaxUnavailable=$(echo "$orig" | tr -d '"'),unhealthyPodEvictionPolicy=$(echo "$orig_policy" | tr -d '"'),fluxReconcileAnnotation=$(echo "$orig_flux_reconcile" | tr -d '"')\t$patch_out"
      echo -e "OK\t$ns\t$name\tmaxUnavailable=$(echo "$orig" | tr -d '"'),unhealthyPodEvictionPolicy=$(echo "$orig_policy" | tr -d '"'),fluxReconcileAnnotation=$(echo "$orig_flux_reconcile" | tr -d '"')\t$patch_out" >> "$result_file"
    else
      patch_out=$(single_line "$patch_out")
      echo -e "ERROR\t$ns\t$name\tmaxUnavailable=$(echo "$orig" | tr -d '"'),unhealthyPodEvictionPolicy=$(echo "$orig_policy" | tr -d '"'),fluxReconcileAnnotation=$(echo "$orig_flux_reconcile" | tr -d '"')\t$patch_out"
      echo -e "ERROR\t$ns\t$name\tmaxUnavailable=$(echo "$orig" | tr -d '"'),unhealthyPodEvictionPolicy=$(echo "$orig_policy" | tr -d '"'),fluxReconcileAnnotation=$(echo "$orig_flux_reconcile" | tr -d '"')\t$patch_out" >> "$result_file"
      echo "$line" >> "$failure_file"
      failed=$((failed + 1))
    fi
    processed=$((processed + 1))
  done < "$targets_file"

  echo "Revert complete"
  echo "Processed: $processed, Failed: $failed"
  echo "Results log: $result_file"
  if [[ -s "$failure_file" ]]; then
    echo "Failed targets file: $failure_file"
  fi
  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

status_targets() {
  enforce_context_guard

  local targets_file
  if [[ -n "$RUN_DIR" ]]; then
    targets_file="$RUN_DIR/targets.jsonl"
    if [[ ! -f "$targets_file" ]]; then
      echo "Targets file not found: $targets_file" >&2
      exit 1
    fi
  else
    echo "--run-dir not provided, generating ephemeral target list from live cluster"
    local tmp
    tmp=$(mktemp)
    kubectl get pdb -A -o json \
      | jq -c '
          def max_unavailable_lt_100pct:
            (
              (.spec.maxUnavailable | type) == "number"
              and .spec.maxUnavailable < 100
            )
            or
            (
              (.spec.maxUnavailable | type) == "string"
              and (.spec.maxUnavailable | test("%$"))
              and ((.spec.maxUnavailable | rtrimstr("%") | tonumber) < 100)
            )
            or
            (
              (.spec.maxUnavailable | type) == "string"
              and (.spec.maxUnavailable | test("^[0-9]+$"))
              and ((.spec.maxUnavailable | tonumber) < 100)
            );
          .items[]
          | select(max_unavailable_lt_100pct and .status.disruptionsAllowed < 1)
          | {namespace:.metadata.namespace,name:.metadata.name,origMaxUnavailable:.spec.maxUnavailable}
        ' \
      > "$tmp"
    targets_file="$tmp"
  fi

  local line ns name
  echo -e "NAMESPACE\tNAME\tMAX_UNAVAILABLE\tUNHEALTHY_POD_EVICTION_POLICY\tALLOWED_DISRUPTIONS"
  while IFS= read -r line; do
    ns=$(echo "$line" | jq -r '.namespace')
    name=$(echo "$line" | jq -r '.name')
    kubectl get pdb "$name" -n "$ns" -o json \
      | jq -r '[.metadata.namespace,.metadata.name,((.spec.maxUnavailable|tostring)//"N/A"),(.spec.unhealthyPodEvictionPolicy // "<unset>"),(.status.disruptionsAllowed|tostring)] | @tsv'
  done < "$targets_file"
}

case "$ACTION" in
  prepare)
    prepare
    ;;
  apply)
    apply_patch_targets
    ;;
  revert)
    revert_targets
    ;;
  status)
    status_targets
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage
    exit 1
    ;;
esac
