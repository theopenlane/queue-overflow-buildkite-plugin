# Queue Overflow Buildkite Plugin

Overflow Buildkite jobs to another queue when the primary queue backs up.

The plugin runs as your pipeline upload step. Before uploading, it asks the
Buildkite GraphQL API how many jobs are waiting on your primary queue. If too
many are ahead of this build, steps that opted in are sent to an overflow queue
instead. The overflow queue can be a Buildkite hosted queue, another self-hosted
pool, or any other queue key.

- **Priority-aware.** Only waiting jobs with priority greater than or equal to
  this build's count as "ahead", because lower-priority jobs get dispatched
  later anyway. Idle agents on the primary queue are subtracted.
- **Opt-in per step.** Only steps whose `queue` is set from the plugin's
  variable can move. Everything else stays where it is.
- **Capped.** `max-overflow-jobs` stops overflowing once the overflow queue is
  already busy, so a bad day on the primary queue can't run up an unbounded
  bill.
- **Fails safe.** A missing token, an API error or a timeout keeps the build on
  the primary queue. The plugin is never the reason a build fails.

The decision is made once, at upload time. Steps uploaded behind long
`depends_on` chains are routed based on the queue as it looked when the build
started.

## Example

Replace the upload step in your pipeline settings with:

```yaml
steps:
  - label: ":pipeline: Pipeline upload"
    plugins:
      - theopenlane/queue-overflow#v1.0.0:
          primary-queue: self-hosted-linux
          overflow-queue: hosted-linux-large
          pipeline: .buildkite/pipeline.yml
          threshold: 5
          max-overflow-jobs: 10
```

Then, in `.buildkite/pipeline.yml`, point the steps that are allowed to move at
the queue variable. Give it a default so the pipeline still works without the
plugin:

```yaml
env:
  QUEUE_OVERFLOW_QUEUE: ${QUEUE_OVERFLOW_QUEUE:-self-hosted-linux}

steps:
  - label: ":test_tube: tests"
    command: make test
    agents:
      queue: $QUEUE_OVERFLOW_QUEUE   # may overflow
      size: large

  - label: ":rocket: deploy"
    command: make deploy
    agents:
      queue: self-hosted-linux       # always self-hosted
```

The plugin always exports `QUEUE_OVERFLOW_QUEUE` before uploading: the primary
queue normally, the overflow queue when it overflows.

### Tags the overflow agents don't have

If opted-in steps target tags only your primary agents carry (for example
`size: large`), those jobs would never match an agent on the overflow queue.
List the tags in `strip-tags`, and the plugin removes them from opted-in steps
when it overflows:

```yaml
      - theopenlane/queue-overflow#v1.0.0:
          primary-queue: self-hosted-linux
          overflow-queue: hosted-linux-large
          strip-tags: [size]
```

Only block-style `agents:` maps are rewritten. Steps written as
`agents: { queue: ... }` or as a list of `key=value` strings are left as they
are.

### Builds that should never overflow

These can be combined:

- `skip-branches`: branch glob patterns. Matching builds always stay on the
  primary queue, and the API isn't called.
- `pull-requests-only` (default `true`): builds of other branches stay on the
  primary queue. Pull requests, tag builds and the pipeline's default branch
  (`BUILDKITE_PIPELINE_DEFAULT_BRANCH`, e.g. `main`) may still overflow. Set it
  to `false` to let every branch overflow.
- `skip-draft-prs` (default `true`): draft pull request builds stay on the
  primary queue (Buildkite sets `BUILDKITE_PULL_REQUEST_DRAFT=true` on them).
- `min-priority`: builds below this priority always stay on the primary queue.

```yaml
      - theopenlane/queue-overflow#v1.0.0:
          primary-queue: self-hosted-linux
          overflow-queue: hosted-linux-large
          skip-branches:
            - "renovate/*"
            - "dependabot/*"
            - "*:*"            # fork PRs: Buildkite names their branches owner:branch
```

With the defaults, ready (non-draft) pull requests, tag builds and the default
branch can overflow. To keep the default branch or tags on the primary queue
too, add them to `skip-branches`.

### Priority

The plugin can't see the priority your pipeline will assign, so tell it. Use
`priority` for a fixed value, or `priority-env` to read it from an environment
variable when the hook runs. For example, the variable could be set by a
repository `pre-command` hook:

```yaml
      - theopenlane/queue-overflow#v1.0.0:
          primary-queue: self-hosted-linux
          overflow-queue: hosted-linux-large
          priority-env: MY_BUILD_PRIORITY
          min-priority: 0   # e.g. builds at priority -10 never overflow
```

### Different overflow queues per agent size (routes)

When the primary queue has agents of different sizes (or workloads), use
`routes`. Each route is its own decision, with its own queue variable and
overflow queue. `match-tags` limits what a route counts to the agents carrying
those tags and the waiting jobs that could run on them, so large steps overflow
when the large agents are backed up, regardless of how busy the small ones are.

A waiting job counts toward a route when, for every match-tag, it asks for that
value, asks for any value (`size=*`), or doesn't ask for that key at all. A job
with no `size` can run on any agent, so it counts toward both routes. An idle
agent only counts when it carries every match-tag.

```yaml
      - theopenlane/queue-overflow#v1.0.0:
          primary-queue: self-hosted-linux
          strip-tags: [size]          # default for every route
          routes:
            - queue-variable: LARGE_OVERFLOW_QUEUE
              overflow-queue: hosted-linux-large
              match-tags: [size=large]
              max-overflow-jobs: 10
            - queue-variable: SMALL_OVERFLOW_QUEUE
              overflow-queue: hosted-linux-small
              match-tags: [size=small]
              threshold: 10
```

```yaml
env:
  LARGE_OVERFLOW_QUEUE: ${LARGE_OVERFLOW_QUEUE:-self-hosted-linux}
  SMALL_OVERFLOW_QUEUE: ${SMALL_OVERFLOW_QUEUE:-self-hosted-linux}

steps:
  - label: ":test_tube: tests"
    agents:
      queue: $LARGE_OVERFLOW_QUEUE
      size: large
  - label: ":lint-roller: lint"
    agents:
      queue: $SMALL_OVERFLOW_QUEUE
      size: small
```

Routes inherit `threshold`, `max-overflow-jobs` and `strip-tags` from the top
level unless they set their own. `skip-branches`, `min-priority` and `dry-run`
apply to every route. Use either `routes` or the top-level `overflow-queue`,
not both.

### Trying it safely

Set `dry-run: true` first. The plugin makes its decision and annotates the
build with what it would have done, but always uploads to the primary queue.

## API token

The plugin makes one read-only call to the Buildkite GraphQL API, so it needs
an API access token with GraphQL access enabled. It doesn't use the REST API.
API tokens belong to a user, so create the token on a dedicated bot user with
read-only access to every pipeline that runs on the primary queue: jobs from
pipelines the user can't see aren't counted.

Store the token as a
[Buildkite secret](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets)
and expose it to the upload step under the name given by `api-token-env`
(default `QUEUE_OVERFLOW_API_TOKEN`):

```yaml
steps:
  - label: ":pipeline: Pipeline upload"
    secrets:
      - QUEUE_OVERFLOW_API_TOKEN
    plugins:
      - theopenlane/queue-overflow#v1.0.0:
          # ...
```

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `primary-queue` (required) | | Queue key opted-in steps normally run on. |
| `pipeline` | `.buildkite/pipeline.yml` | Pipeline file to upload. |
| `overflow-queue` | | Queue key to overflow to. Required unless `routes` is set. |
| `queue-variable` | `QUEUE_OVERFLOW_QUEUE` | Variable opted-in steps use as their queue. |
| `match-tags` | `[]` | Only count idle agents with all of these `key=value` tags, and waiting jobs that could run on them. |
| `routes` | | List of routes, each with `queue-variable`, `overflow-queue` (both required), `match-tags`, `strip-tags`, `threshold` and `max-overflow-jobs`. |
| `threshold` | `5` | Overflow when more than this many jobs are effectively ahead. |
| `max-overflow-jobs` | `0` (no cap) | Don't overflow when the overflow queue already has this many scheduled or running jobs. |
| `strip-tags` | `[]` | Agent tags to remove from opted-in steps when overflowing. |
| `skip-branches` | `[]` | Branch glob patterns that never overflow. |
| `skip-draft-prs` | `true` | Draft pull request builds never overflow. |
| `pull-requests-only` | `true` | Builds of other branches never overflow. Pull requests, tags and the default branch still may. |
| `priority` | `0` | This build's priority. |
| `priority-env` | | Variable to read this build's priority from. Overrides `priority` when set. |
| `min-priority` | `0` | Builds below this priority never overflow. |
| `api-token-env` | `QUEUE_OVERFLOW_API_TOKEN` | Variable holding the API token. |
| `cluster-uuid` | `$BUILDKITE_CLUSTER_ID` | Only count jobs and agents in this cluster. Queue keys are unique per cluster, so set this if the same key exists in more than one. |
| `timeout` | `10` | Seconds to wait for the API before staying on the primary queue. |
| `dry-run` | `false` | Decide and annotate, but always use the primary queue. |

Each run sets the build meta-data key `queue-overflow:<queue-variable>` to the
queue each route chose, and adds one annotation explaining every decision.

Invalid configuration (for example a missing `overflow-queue`) fails the step.
Everything else that goes wrong keeps the build on the primary queue.

## How "ahead" is counted

For each route:

```
ahead     = scheduled jobs on primary-queue that could run on an agent with
            the match-tags, and priority >= this build's priority
effective = ahead - idle connected agents on primary-queue with all match-tags
overflow if effective > threshold
        and the branch doesn't match skip-branches
        and it is a PR, a tag or the default branch (unless pull-requests-only is false)
        and it isn't a draft PR (unless skip-draft-prs is false)
        and this build's priority >= min-priority
        and (max-overflow-jobs is 0 or jobs on overflow-queue < max-overflow-jobs)
```

The API call looks at up to 500 waiting jobs and 500 agents.

## Requirements

`bash`, `curl` and `jq` on the agent that runs the upload step.

## Developing

```bash
task install   # shellcheck via Homebrew
task ci        # shellcheck, plugin lint, and tests (same as CI)
```

Or run them individually with `task shellcheck`, `task lint` and `task test`.

## License

Apache 2.0. See [LICENSE](LICENSE).
