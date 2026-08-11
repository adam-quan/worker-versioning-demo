# Temporal Worker Versioning, driven by GitHub Actions

A simple Temporal Python application that shows the integration of Temporal Worker Versioning and Github Actions. The whole loop:

> **push a workflow change → GitHub Actions builds it → a new Worker Deployment Version appears in minikube → new executions move to it → executions already running finish on the old version.**

---

## What's here

| Path | What it is |
|---|---|
| [worker/workflows.py](worker/workflows.py) | The workflows. **Edit this to trigger the demo.** |
| [worker/run_worker.py](worker/run_worker.py) | Worker entrypoint — where versioning is configured |
| [worker/starter.py](worker/starter.py) | CLI to start / signal / inspect workflows |
| [k8s/temporal-server.yaml](k8s/temporal-server.yaml) | A Temporal dev server for minikube |
| [k8s/worker-deployment.template.yaml](k8s/worker-deployment.template.yaml) | One K8s Deployment per Build ID |
| [scripts/progressive-rollout.sh](scripts/progressive-rollout.sh) | **Staged ramp with health gates and rollback. What CI runs.** |
| [scripts/deploy-version.sh](scripts/deploy-version.sh) | Straight to 100% — the unguarded manual path |
| [scripts/common.sh](scripts/common.sh) | Shared helpers: build, deploy, query the server |
| [scripts/port-forward.sh](scripts/port-forward.sh) | Reach the in-cluster server from your machine |
| [scripts/cleanup-drained.sh](scripts/cleanup-drained.sh) | Retire versions nothing is pinned to any more — pods *and* server-side version |
| [scripts/status.sh](scripts/status.sh) | Temporal's view and Kubernetes' view, side by side |
| [.github/workflows/deploy-worker-version.yml](.github/workflows/deploy-worker-version.yml) | The CI pipeline |

## How the versioning works

Three pieces have to agree on one string — the **Build ID**:

1. **CI** derives it from the commit: `git rev-parse --short=7 HEAD`.
2. **The image** bakes it in as `TEMPORAL_BUILD_ID` (a Docker `ARG`).
3. **The worker** registers with it, in [run_worker.py](worker/run_worker.py):

```python
worker = Worker(
    client,
    task_queue=TASK_QUEUE,
    workflows=[GreetingWorkflow, HealthCheckWorkflow],
    activities=[compose_greeting, record_result],
    deployment_config=WorkerDeploymentConfig(
        version=WorkerDeploymentVersion(
            deployment_name=DEPLOYMENT_NAME,   # "versioning-greeting-worker"
            build_id=BUILD_ID,                 # "a1b2c3d"
        ),
        use_worker_versioning=True,
    ),
)
```

Because the Build ID comes from the commit SHA, "what code is version `a1b2c3d`
running?" is answered by `git show a1b2c3d`.

Each workflow declares how it behaves when a newer version becomes Current:

```python
@workflow.defn(versioning_behavior=VersioningBehavior.PINNED)
class GreetingWorkflow: ...        # stays on its original version, forever

@workflow.defn(versioning_behavior=VersioningBehavior.AUTO_UPGRADE)
class HealthCheckWorkflow: ...     # moves to the new Current version
```

`PINNED` is the safe default: you can change the workflow's code however you
like, because runs in flight never see the change. `AUTO_UPGRADE` is for
workflows you only ever change in [deterministically compatible](https://docs.temporal.io/workflow-definition#deterministic-constraints)
ways.

### Why a new K8s Deployment per version, not a rolling update

`scripts/deploy-version.sh` creates `worker-<build-id>` as a **new** Deployment
and leaves existing ones alone. A rolling update would terminate the old pods —
which are exactly the workers that pinned executions still need. Old versions
are removed later, by `cleanup-drained.sh`, only once Temporal reports them
`drained` (no open execution is pinned to them).

---

## Prerequisites

`minikube`, `kubectl`, `docker`, `envsubst` (`brew install gettext`), and
Python 3.9+. The Temporal CLI is **not** required on your machine — the scripts
run it inside the server pod via `kubectl exec`.

## Quickstart

```bash
# 1. minikube + a Temporal dev server inside it
./scripts/bootstrap.sh

# 2. Build and deploy the first version, and make it Current
./scripts/deploy-version.sh v1
```

Then, in a second terminal, forward the server to your machine and leave it
running — the Web UI lands on <http://localhost:8233> and gRPC on `localhost:7233`
(the SDK default, so no `TEMPORAL_ADDRESS` is needed):

```bash
./scripts/port-forward.sh
```

To drive workflows from your laptop:

```bash
pip install -r worker/requirements.txt
```

> Use `port-forward`, not `minikube service --url`: on minikube's `docker`
> driver the node IP isn't routable from the host, and `minikube service`
> blocks holding a tunnel open.

## The demo

**1. Start a long-running workflow on v1.** It greets, then parks on a signal.

```bash
cd worker && python starter.py greeting Alice
# started greeting-8eb8dd74
```

**2. Change the workflow.** In [worker/workflows.py](worker/workflows.py):

```python
GREETING = "Howdy"   # was "Hello"
```

**3. Ship it.**

```bash
git commit -am "change greeting" && git push
```

GitHub Actions builds `worker-versioning-demo:<sha>`, applies `worker-<sha>`,
waits for those pods to poll, then ramps traffic onto the new version in
stages — checking its health at each one — before promoting it to Current. See
[Progressive rollout](#progressive-rollout) below.

NOTE that you can pass custom push options to control the deployment behavor, 
by supplying the pipeline inputs:

```bash
  STRATEGY="${{ github.event.inputs.strategy }}"
  STEPS="${{ github.event.inputs.steps }}"
  BAKE="${{ github.event.inputs.bake_seconds }}"
  MAX_FAILURES="${{ github.event.inputs.max_failures }}"
```

So, if you want to perform an immdiate rollout, without ramping, you can run this instead:

```bash
git commit -am "change greeting" && git push -o strategy="immediate"
```

You can also tell the remote sever to skip running the pipeline:

```bash
git push -o ci.skip
```

Without github actions, you can the script locally to do the same thing:

```bash
./scripts/progressive-rollout.sh v2 --bake 15
```

**4. Watch what happened.**

```bash
./scripts/status.sh
```

A *new* workflow gets the new code:

```bash
python starter.py greeting Bob
python starter.py status greeting-<id>
#   progress: ['Howdy, Bob! (served by build v2)']
```

The *old* workflow, still parked, finishes on the version it started on — old
greeting, old build — even though v2 is now Current:

```bash
python starter.py approve greeting-8eb8dd74
# result: {'greeting': 'Hello, Alice! (served by build v1)', 'recorded_by': 'v1'}
```

Without worker versioning, the old workflow run would have picked
up the new code mid-execution and risked a non-determinism error.

**5. Retire the old version** once nothing is pinned to it:

```bash
./scripts/cleanup-drained.sh --dry-run
./scripts/cleanup-drained.sh
```

`v1` reports `draining` while Alice's workflow is open, and `drained` once it
completes. Only then is it retired, and retiring it means **both** halves:

1. its Kubernetes Deployment `worker-v1` is deleted, and
2. the `versioning-greeting-worker:v1` Worker Deployment Version record is
   deleted from the Temporal server.

The order is forced by the server, which refuses to delete a version that still
has active pollers — so the pods have to go first. The server then keeps poller
information for about five minutes after the last worker process exits, so the
script retries the version delete for up to `--wait` seconds (default 420):

```bash
./scripts/cleanup-drained.sh --wait 0    # never block; finish next run
```

With `--wait 0` the pods are deleted and the version is left on the server; the
next run deletes it, having found it as a version with no Deployment behind it.
Either way cleanup converges, so a version that outlives one run is reported
rather than treated as a failure.

Drainage itself is evaluated on a timer, not instantly, so expect roughly a
minute between the last pinned workflow closing and the status flipping. The
demo server shortens that interval on purpose — see the `--dynamic-config-value`
flags in [k8s/temporal-server.yaml](k8s/temporal-server.yaml), which you should
*not* carry into production.

NOTE that we performed a cleanup from the Temporal server too. Without doing that, 
the Temporal server automaticaly garbage collect drained versions too. When you 
reach the maximum number of registered versions (e.g., 100 versions) in a worker 
deployment, Temporal server checks the oldest drained version. If that version 
has had no active pollers for the last 5 minutes, the server automatically deletes it.

If you use the Temporal Worker Controller, it automatically detects deprecated versions, 
scales them down, and cleans up the associated Kubernetes deployment resources once 
they are drained.


## Progressive rollout

CI does **not** flip 100% of traffic onto a new version in one move. It walks
the Ramping Version up through a series of percentages, pausing at each to
check the new version's health, and only promotes it to Current once every
step has passed:

```
deploy (0%) ──▶ 5% ──▶ 25% ──▶ 50% ──▶ Current (100%)
                 │      │       │
                 └──────┴───────┴── health gate; a failure rolls back
```

```bash
./scripts/progressive-rollout.sh v2                          # 5,25,50 then promote
./scripts/progressive-rollout.sh v2 --steps 10,50 --bake 120
./scripts/deploy-version.sh v2                               # skip the gates, go straight to 100%
```

At each step [progressive-rollout.sh](scripts/progressive-rollout.sh) checks
three things, then either continues or rolls back:

1. every pod of the new version is ready, and none has restarted;
2. the version is still registered and polling;
3. no more than `--max-failures` (default 0) of the executions the server
   routed to it have **Failed** or been **Terminated**.

That third check is the one worth understanding. It counts real routed traffic
using the `TemporalWorkerDeploymentVersion` search attribute that the server
stamps on every execution:

```
TemporalWorkerDeploymentVersion='versioning-greeting-worker:a1b2c3d' AND ExecutionStatus='Failed'
```

So the gate measures the new code actually failing in production, not just
whether its container started.

**Rolling back deletes the ramp**, which sends new executions straight back to
the old Current version. It deliberately does *not* delete the bad version's
pods: executions that already started on it are pinned to it and still need
those workers. Retire them later with `cleanup-drained.sh`, once Temporal
reports the version `drained`.

Tune the rollout with `--steps`, `--bake` (seconds to observe per step) and
`--max-failures`; the same three are `workflow_dispatch` inputs on the CI job,
along with a `strategy` choice of `progressive` (default) or `immediate`. Reach
for `immediate` when you are rolling *forward* off a version you already know
is bad and don't want to wait out the gates.

---

## Running this for real

**The runner has to reach your cluster.** minikube lives on your machine, so the
CI job uses `runs-on: self-hosted`. Register a runner on the same machine:

```bash
# from your repo: Settings → Actions → Runners → New self-hosted runner
./config.sh --url https://github.com/<you>/<repo> --token <token>
./run.sh
```

It needs `minikube`, `kubectl`, `docker` and `envsubst` on its `PATH`, and
minikube already started (`./scripts/bootstrap.sh`).

If you'd rather use GitHub-hosted runners, the shape of the pipeline is
unchanged — swap the two environment-specific steps: push the image to a real
registry instead of `minikube docker-env`, and point `kubectl` at a cluster the
runner can reach.

**Moving to Temporal Cloud / a real cluster:**

- Drop [k8s/temporal-server.yaml](k8s/temporal-server.yaml) and set
  `TEMPORAL_ADDRESS` to your endpoint, plus mTLS or API-key credentials from a
  Kubernetes Secret.
- Replace the `kubectl exec` trick in the scripts with a real `temporal` CLI on
  the runner, configured against that endpoint.
- Everything else — one Deployment per Build ID, wait for pollers, promote,
  clean up drained versions — carries over as is.

## Notes and caveats

- The in-cluster Temporal server is a **dev server** (single pod, SQLite on a
  PVC). Fine for a demo; use the Helm chart or Temporal Cloud for anything real.
- `set-current-version` is deliberately run **without** `--allow-no-pollers`.
  If the new pods aren't actually polling, the promotion fails and traffic stays
  on the previous version.
- The CI job uses a `concurrency` group so two pushes can't race to change
  routing at the same time.
- Pinned versions accumulate if you never clean them up, in Kubernetes *and* on
  the server. `cleanup-drained.sh` is safe to run on a schedule and is
  idempotent: deleting an already-absent version succeeds, and anything it
  cannot finish this run it finishes on the next one. For a scheduled job,
  `--wait 0` keeps it from blocking on poller timeouts.

## Cleanup

```bash
kubectl delete namespace temporal-versioning-demo
minikube stop
minikube delete --all --purge
```
