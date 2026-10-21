#!/usr/bin/env bats
#
# Runs hooks/command against stubbed `buildkite-agent` and `curl` binaries.
# The curl stub returns tests/tmp/response.json (built by `respond`); the
# buildkite-agent stub records the env and file it was asked to upload.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"

  cat >"${WORK}/bin/buildkite-agent" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pipeline upload")
    echo "${QUEUE_OVERFLOW_QUEUE:-<unset>}" >"${WORK}/uploaded_queue"
    cp "$3" "${WORK}/uploaded.yml" ;;
  "meta-data set") echo "$3=$4" >>"${WORK}/meta" ;;
  annotate*) cat >>"${WORK}/annotation" ;;
esac
EOF

  cat >"${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "${WORK}/curl_fail" ]] && exit 22
printf '%s\n' "$@" >"${WORK}/curl_args"
cat "${WORK}/response.json"
EOF
  chmod +x "${WORK}/bin/"*

  export WORK
  export PATH="${WORK}/bin:${PATH}"
  export BUILDKITE_ORGANIZATION_SLUG=acme
  export QUEUE_OVERFLOW_API_TOKEN=test-token
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIMARY_QUEUE=self-hosted
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE=hosted
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE="${ROOT}/tests/fixtures/pipeline.yml"
  unset BUILDKITE_CLUSTER_ID
}

teardown() { rm -rf "${WORK}"; }

# respond "<priorities of scheduled primary jobs>" <idle primary agents> [jobs on overflow]
respond() {
  local priorities="$1" idle="$2" overflow="${3:-0}"
  jq -n --arg p "${priorities}" --argjson idle "${idle}" --argjson of "${overflow}" '
    def q($k): {key: $k, cluster: {uuid: "c1"}};
    {data: {organization: {
      primaryJobs: {edges: [$p | split(",")[] | select(. != "") | tonumber
        | {node: {priority: {number: .}, clusterQueue: q("self-hosted")}}]},
      idleAgents: {edges: (
        [range($idle) | {node: {connectionState: "connected", metaData: [], clusterQueue: q("self-hosted")}}]
        + [{node: {connectionState: "connected", metaData: [], clusterQueue: q("other")}}]
        + [{node: {connectionState: "disconnected", metaData: [], clusterQueue: q("self-hosted")}}])},
      overflowJobs: {edges: [range($of) | {node: {clusterQueue: q("hosted")}}]}
    }}}' >"${WORK}/response.json"
}

run_hook() { run bash "${ROOT}/hooks/command"; }
uploaded_queue() { cat "${WORK}/uploaded_queue"; }

@test "stays on primary when queue is short" {
  respond "0,0" 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "self-hosted" ]
  diff -q "${WORK}/uploaded.yml" "${BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE}"
}

@test "overflows when more than threshold jobs are ahead" {
  respond "0,0,0,0,0,0,0" 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "hosted" ]
  grep -qx "queue-overflow:QUEUE_OVERFLOW_QUEUE=hosted" "${WORK}/meta"
}

@test "idle agents reduce jobs ahead" {
  respond "0,0,0,0,0,0,0" 2
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"2 idle agent(s), 5 effectively ahead"* ]]
}

@test "lower priority jobs don't count as ahead" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY=80
  respond "80,80,-10,-10,-10,-10,-10,-10,-10,-10" 0
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"2 job(s) at priority >= 80"* ]]
}

@test "priority-env overrides priority" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY=0
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY_ENV=MY_PRIORITY
  export MY_PRIORITY=100
  respond "0,0,0,0,0,0,0,0" 0
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"0 job(s) at priority >= 100"* ]]
}

@test "builds below min-priority never overflow" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PRIORITY=-10
  respond "0,0,0,0,0,0,0,0,0,0" 0
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"below min-priority"* ]]
  [ ! -f "${WORK}/curl_args" ]
}

@test "custom threshold" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_THRESHOLD=1
  respond "0,0" 0
  run_hook
  [ "$(uploaded_queue)" = "hosted" ]
}

@test "max-overflow-jobs cap keeps build on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_MAX_OVERFLOW_JOBS=3
  respond "0,0,0,0,0,0,0,0" 0 3
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"already has 3 job(s)"* ]]
}

@test "max-overflow-jobs under cap still overflows" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_MAX_OVERFLOW_JOBS=3
  respond "0,0,0,0,0,0,0,0" 0 2
  run_hook
  [ "$(uploaded_queue)" = "hosted" ]
}

@test "dry run never overflows" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_DRY_RUN=true
  respond "0,0,0,0,0,0,0,0" 0
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  grep -q "would have used" "${WORK}/annotation"
}

@test "API failure stays on primary" {
  touch "${WORK}/curl_fail"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "self-hosted" ]
}

@test "GraphQL errors stay on primary" {
  echo '{"errors":[{"message":"nope"}]}' >"${WORK}/response.json"
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "self-hosted" ]
}

@test "missing token stays on primary without calling the API" {
  unset QUEUE_OVERFLOW_API_TOKEN
  run_hook
  [ "$status" -eq 0 ]
  [ "$(uploaded_queue)" = "self-hosted" ]
  [ ! -f "${WORK}/curl_args" ]
}

@test "cluster filter ignores the same queue key in other clusters" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_CLUSTER_UUID=c2
  respond "0,0,0,0,0,0,0,0" 0
  run_hook
  [ "$(uploaded_queue)" = "self-hosted" ]
  [[ "$output" == *"0 job(s)"* ]]
}

@test "missing required config fails" {
  unset BUILDKITE_PLUGIN_QUEUE_OVERFLOW_OVERFLOW_QUEUE
  run_hook
  [ "$status" -eq 1 ]
}

@test "strip-tags removes tags only from opted-in steps" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_0=size
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_1=arch
  respond "0,0,0,0,0,0,0,0" 0
  run_hook
  [ "$(uploaded_queue)" = "hosted" ]
  diff "${ROOT}/tests/fixtures/pipeline.stripped.yml" "${WORK}/uploaded.yml"
}

@test "strip-tags is a no-op when staying on primary" {
  export BUILDKITE_PLUGIN_QUEUE_OVERFLOW_STRIP_TAGS_0=size
  respond "" 0
  run_hook
  diff -q "${WORK}/uploaded.yml" "${BUILDKITE_PLUGIN_QUEUE_OVERFLOW_PIPELINE}"
}
