#!/usr/bin/env bats
#
# Runs hooks/command against stubbed `buildkite-agent` and `curl` binaries.
#
# Build the fake GraphQL response with `job`, `idle_agent` and `overflow_job`;
# the curl stub serves it. The buildkite-agent stub records the queue variables
# and the file it was asked to upload.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  : >"${WORK}/jobs" >"${WORK}/agents" >"${WORK}/overflow"

  cat >"${WORK}/bin/buildkite-agent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pipeline upload")
    env | grep -E '^(QUEUE_OVERFLOW_QUEUE|LARGE_Q|SMALL_Q)=' | sort >"${WORK}/uploaded_env"
    cp "$3" "${WORK}/uploaded.yml" ;;
  "meta-data set") echo "$3=$4" >>"${WORK}/meta" ;;
  annotate*) cat >>"${WORK}/annotation" ;;
esac
EOF

  cat >"${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "${WORK}/curl_fail" ]] && exit 22
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--data-binary" ]] && printf '%s' "$2" >"${WORK}/request.json"
  shift
done
if [[ -f "${WORK}/response.json" ]]; then
  cat "${WORK}/response.json"
else
  jq -n --slurpfile jobs "${WORK}/jobs" --slurpfile agents "${WORK}/agents" \
    --slurpfile of "${WORK}/overflow" --slurpfile req "${WORK}/request.json" '
    ($req[0].variables | to_entries | map(select(.key | startswith("of")))) as $ofs
    | {data: {organization: (
        {primaryJobs: {edges: [$jobs[] | {node: .}]},
         idleAgents: {edges: [$agents[] | {node: .}]}}
        + ($ofs | map({key, value: {edges: [
            .value[0] as $rule | $of[] | select("queue=" + .clusterQueue.key == $rule) | {node: .}]}})
           | from_entries))}}'
fi
EOF
  chmod +x "${WORK}/bin/"*

  export WORK
  export PATH="${WORK}/bin:${PATH}"
  export BUILDKITE_ORGANIZATION_SLUG=acme
  export BUILDKITE_BRANCH=feature/x
  export BUILDKITE_PULL_REQUEST=42 # a ready (non-draft) PR, so the PR-only defaults allow overflow
  unset BUILDKITE_PULL_REQUEST_DRAFT
  export QUEUE_OVERFLOW_API_TOKEN=test-token
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIMARY_QUEUE=self-hosted
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE=hosted
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE="${ROOT}/tests/fixtures/pipeline.yml"
  unset BUILDKITE_CLUSTER_ID
}

teardown() { rm -rf "${WORK}"; }

cq() { jq -nc --arg k "$1" '{key: $k, cluster: {uuid: "c1"}}'; }

# job PRIORITY [tag ...]: a scheduled job on the primary queue
job() {
  local p="$1"
  shift
  jq -nc --argjson p "$p" --argjson q "$(cq self-hosted)" '
    {priority: {number: $p}, agentQueryRules: (["queue=self-hosted"] + $ARGS.positional), clusterQueue: $q}' \
    --args "$@" >>"${WORK}/jobs"
}
jobs_n() { # COUNT PRIORITY [tag ...]
  local n="$1" i
  shift
  for ((i = 0; i < n; i++)); do job "$@"; done
}

# idle_agent [tag ...]: a connected, idle agent on the primary queue
idle_agent() {
  jq -nc --argjson q "$(cq self-hosted)" '
    {connectionState: "connected", metaData: (["queue=self-hosted"] + $ARGS.positional), clusterQueue: $q}' \
    --args "$@" >>"${WORK}/agents"
}

# overflow_job QUEUE: a job already scheduled or running on an overflow queue
overflow_job() { jq -nc --argjson q "$(cq "$1")" '{clusterQueue: $q}' >>"${WORK}/overflow"; }

run_hook() { run bash "${ROOT}/hooks/command"; }
queue_of() { grep "^$1=" "${WORK}/uploaded_env" | cut -d= -f2; }

# Noise that should never be counted: other queues, disconnected agents.
add_noise() {
  jq -nc --argjson q "$(cq other)" '{priority: {number: 100}, agentQueryRules: ["queue=other"], clusterQueue: $q}' >>"${WORK}/jobs"
  jq -nc --argjson q "$(cq other)" '{connectionState: "connected", metaData: ["queue=other"], clusterQueue: $q}' >>"${WORK}/agents"
  jq -nc --argjson q "$(cq self-hosted)" '{connectionState: "disconnected", metaData: ["queue=self-hosted"], clusterQueue: $q}' >>"${WORK}/agents"
}

use_routes() {
  unset BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE="${ROOT}/tests/fixtures/routes.yml"
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_0_QUEUE_VARIABLE=LARGE_Q
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_0_OVERFLOW_QUEUE=hosted-large
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_0_MATCH_TAGS_0=size=large
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_1_QUEUE_VARIABLE=SMALL_Q
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_1_OVERFLOW_QUEUE=hosted-small
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_1_MATCH_TAGS_0=size=small
}

# --- single route ---------------------------------------------------------------

@test "stays on primary when queue is short" {
  jobs_n 2 0
  add_noise
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  diff -q "${WORK}/uploaded.yml" "${BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE}"
}

@test "overflows when more than threshold jobs are ahead" {
  jobs_n 7 0
  add_noise
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
  grep -qx "queue-overflow:QUEUE_OVERFLOW_QUEUE=hosted" "${WORK}/meta"
}

@test "idle agents reduce jobs ahead" {
  jobs_n 7 0
  idle_agent
  idle_agent
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"2 idle agent(s), 5 effectively ahead"* ]]
}

@test "lower priority jobs don't count as ahead" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY=80
  jobs_n 2 80
  jobs_n 8 -10
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"2 job(s) at priority >= 80"* ]]
}

@test "priority-env overrides priority" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY_ENV=MY_PRIORITY
  export MY_PRIORITY=100
  jobs_n 8 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"0 job(s) at priority >= 100"* ]]
}

@test "builds below min-priority never overflow" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY=-10
  jobs_n 10 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"below min-priority"* ]]
  [ ! -f "${WORK}/request.json" ]
}

@test "skip-branches keeps matching branches on primary" {
  export BUILDKITE_BRANCH=renovate/golang-1.x
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES_0="dependabot/*"
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES_1="renovate/*"
  jobs_n 10 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"matches skip-branches 'renovate/*'"* ]]
  [ ! -f "${WORK}/request.json" ]
}

@test "skip-branches can match fork PR branches (owner:branch)" {
  export BUILDKITE_BRANCH=someone:fix-typo
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES_0="renovate/*"
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES_1="*:*"
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"matches skip-branches '*:*'"* ]]
}

@test "skip-draft-prs keeps draft PR builds on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_DRAFT_PRS=true
  export BUILDKITE_PULL_REQUEST=42
  export BUILDKITE_PULL_REQUEST_DRAFT=true
  jobs_n 10 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"pull request 42 is a draft"* ]]
  [ ! -f "${WORK}/request.json" ]
}

@test "skip-draft-prs ignores the draft flag on non-PR builds" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_DRAFT_PRS=true
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=false
  export BUILDKITE_PULL_REQUEST=false
  export BUILDKITE_PULL_REQUEST_DRAFT=true
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "draft PRs overflow when skip-draft-prs is false" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_DRAFT_PRS=false
  export BUILDKITE_PULL_REQUEST=42
  export BUILDKITE_PULL_REQUEST_DRAFT=true
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "skip-draft-prs doesn't affect ready PRs" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_DRAFT_PRS=true
  export BUILDKITE_PULL_REQUEST=42
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "pull-requests-only keeps branch builds on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=true
  export BUILDKITE_PULL_REQUEST=false
  jobs_n 10 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"not a pull request (pull-requests-only)"* ]]
  [ ! -f "${WORK}/request.json" ]
}

@test "pull-requests-only treats a missing PR variable as not a PR" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=true
  unset BUILDKITE_PULL_REQUEST
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
}

@test "pull-requests-only lets PR builds overflow" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=true
  export BUILDKITE_PULL_REQUEST=42
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "pull-requests-only and skip-draft-prs combine" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=true
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_DRAFT_PRS=true
  export BUILDKITE_PULL_REQUEST=42
  export BUILDKITE_PULL_REQUEST_DRAFT=true
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"is a draft"* ]]
}

@test "by default only ready PRs overflow: branch builds stay" {
  export BUILDKITE_PULL_REQUEST=false
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"pull-requests-only"* ]]
}

@test "by default only ready PRs overflow: drafts stay" {
  export BUILDKITE_PULL_REQUEST_DRAFT=true
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"is a draft"* ]]
}

@test "pull-requests-only false lets branch builds overflow" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PULL_REQUESTS_ONLY=false
  export BUILDKITE_PULL_REQUEST=false
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "skip-branches doesn't affect other branches" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES="renovate/*"
  jobs_n 10 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "custom threshold" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_THRESHOLD=1
  jobs_n 2 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "max-overflow-jobs cap keeps build on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_MAX_OVERFLOW_JOBS=3
  jobs_n 8 0
  overflow_job hosted
  overflow_job hosted
  overflow_job hosted
  overflow_job elsewhere
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"already has 3 job(s)"* ]]
}

@test "max-overflow-jobs under cap still overflows" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_MAX_OVERFLOW_JOBS=3
  jobs_n 8 0
  overflow_job hosted
  overflow_job hosted
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
}

@test "dry run never overflows" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_DRY_RUN=true
  jobs_n 8 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  grep -q "would have used hosted" "${WORK}/annotation"
  grep -q "dry run" "${WORK}/annotation"
}

@test "API failure stays on primary" {
  touch "${WORK}/curl_fail"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
}

@test "GraphQL errors stay on primary" {
  echo '{"errors":[{"message":"nope"}]}' >"${WORK}/response.json"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
}

@test "missing token stays on primary without calling the API" {
  unset QUEUE_OVERFLOW_API_TOKEN
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [ ! -f "${WORK}/request.json" ]
}

@test "cluster filter ignores the same queue key in other clusters" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_CLUSTER_UUID=c2
  jobs_n 8 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "self-hosted" ]
  [[ "$output" == *"0 job(s)"* ]]
}

@test "strip-tags removes tags only from opted-in steps" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_0=size
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_1=arch
  jobs_n 8 0
  run_hook
  [ "$(queue_of QUEUE_OVERFLOW_QUEUE)" = "hosted" ]
  diff "${ROOT}/tests/fixtures/pipeline.stripped.yml" "${WORK}/uploaded.yml"
}

@test "strip-tags is a no-op when staying on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_0=size
  run_hook
  diff -q "${WORK}/uploaded.yml" "${BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE}"
}

# --- routes -----------------------------------------------------------------------

@test "routes count only jobs and agents with their match-tags" {
  use_routes
  jobs_n 8 0 size=large
  jobs_n 2 0 size=small
  idle_agent size=small
  run_hook
  [ "$status" -eq 0 ]
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
  [ "$(queue_of SMALL_Q)" = "self-hosted" ]
  [[ "$output" == *"8 job(s) at priority >= 0 waiting on self-hosted [size=large], 0 idle agent(s)"* ]]
  [[ "$output" == *"2 job(s) at priority >= 0 waiting on self-hosted [size=small], 1 idle agent(s)"* ]]
}

@test "routes can both overflow to different queues" {
  use_routes
  jobs_n 7 0 size=large
  jobs_n 7 0 size=small
  run_hook
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
  [ "$(queue_of SMALL_Q)" = "hosted-small" ]
  grep -qx "queue-overflow:LARGE_Q=hosted-large" "${WORK}/meta"
  grep -qx "queue-overflow:SMALL_Q=hosted-small" "${WORK}/meta"
}

@test "jobs that ask for a different value of any match-tag don't count" {
  use_routes
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_0_MATCH_TAGS_1=arch=arm64
  jobs_n 8 0 size=large arch=amd64
  run_hook
  [ "$(queue_of LARGE_Q)" = "self-hosted" ]
  [[ "$output" == *"0 job(s) at priority >= 0 waiting on self-hosted [size=large,arch=arm64]"* ]]
}

@test "jobs without the tag compete for every route" {
  use_routes
  jobs_n 4 0
  jobs_n 3 0 size=large
  jobs_n 1 0 size=small
  run_hook
  [[ "$output" == *"7 job(s) at priority >= 0 waiting on self-hosted [size=large]"* ]]
  [[ "$output" == *"5 job(s) at priority >= 0 waiting on self-hosted [size=small]"* ]]
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
  [ "$(queue_of SMALL_Q)" = "self-hosted" ]
}

@test "jobs asking for any value (key=*) compete" {
  use_routes
  jobs_n 7 0 "size=*"
  run_hook
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
  [ "$(queue_of SMALL_Q)" = "hosted-small" ]
}

@test "idle agents only count when they carry every match-tag" {
  use_routes
  jobs_n 7 0 size=large
  idle_agent
  idle_agent size=small
  idle_agent size=large
  run_hook
  [[ "$output" == *"waiting on self-hosted [size=large], 1 idle agent(s), 6 effectively ahead"* ]]
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
}

@test "routes have their own thresholds and caps" {
  use_routes
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_0_THRESHOLD=20
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_1_MAX_OVERFLOW_JOBS=1
  jobs_n 8 0 size=large
  jobs_n 8 0 size=small
  overflow_job hosted-small
  run_hook
  [ "$(queue_of LARGE_Q)" = "self-hosted" ]
  [ "$(queue_of SMALL_Q)" = "self-hosted" ]
  [[ "$output" == *"threshold 20"* ]]
  [[ "$output" == *"hosted-small already has 1 job(s)"* ]]
}

@test "routes strip tags only from their own steps" {
  use_routes
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_0=size
  jobs_n 8 0 size=large
  run_hook
  [ "$(queue_of LARGE_Q)" = "hosted-large" ]
  [ "$(queue_of SMALL_Q)" = "self-hosted" ]
  diff "${ROOT}/tests/fixtures/routes.large-stripped.yml" "${WORK}/uploaded.yml"
}

@test "skip-branches applies to every route" {
  use_routes
  export BUILDKITE_BRANCH=renovate/foo
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_SKIP_BRANCHES_0="renovate/*"
  jobs_n 8 0 size=large
  jobs_n 8 0 size=small
  run_hook
  [ "$(queue_of LARGE_Q)" = "self-hosted" ]
  [ "$(queue_of SMALL_Q)" = "self-hosted" ]
}

# --- configuration errors -------------------------------------------------------

@test "missing overflow-queue fails" {
  unset BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"overflow-queue is required"* ]]
}

@test "invalid queue-variable fails" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_QUEUE_VARIABLE=hosted-large
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid environment variable name"* ]]
}

@test "overflow-queue and routes together fails" {
  use_routes
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE=hosted
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"not both"* ]]
}

@test "duplicate route variable fails" {
  use_routes
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_ROUTES_1_QUEUE_VARIABLE=LARGE_Q
  run_hook
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one route"* ]]
}
