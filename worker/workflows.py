"""Workflow definitions for the Worker Versioning demo.

This is the file you edit to trigger the demo. Change ``GREETING`` below (or
anything else in here), push to ``main``, and the GitHub Actions workflow
builds a new image, rolls out a *new* Worker Deployment Version in minikube,
and makes it Current -- without disturbing runs already in flight.

Two workflows, two versioning behaviors:

* ``GreetingWorkflow`` is PINNED. A run that started on Build ID ``abc1234``
  keeps executing on ``abc1234`` for its entire life, even after a newer
  version becomes Current. Safe for workflows whose code you change
  incompatibly.
* ``HealthCheckWorkflow`` is AUTO_UPGRADE. In-flight runs move to whatever
  version is Current at their next workflow task. Safe for workflows you only
  ever change in compatible ways.
"""

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy, VersioningBehavior

with workflow.unsafe.imports_passed_through():
    from activities import compose_greeting, record_result

# ---------------------------------------------------------------------------
# Edit me to produce a new workflow version, then `git push`.
GREETING = "Hello"
# ---------------------------------------------------------------------------


@workflow.defn(versioning_behavior=VersioningBehavior.PINNED)
class GreetingWorkflow:
    """A deliberately long-lived workflow, pinned to the version that started it.

    It greets, then parks on a signal so you have time to deploy a new version
    and watch this run stay on the old one.
    """

    def __init__(self) -> None:
        self._approved = False
        self._log: list[str] = []

    @workflow.run
    async def run(self, name: str) -> dict:
        greeting = await workflow.execute_activity(
            compose_greeting,
            args=[GREETING, name],
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=3),
        )
        self._log.append(greeting)

        # Park here until signalled (or 30 minutes pass). This is the window in
        # which you deploy a new version and observe that this run does not move.
        await workflow.wait_condition(
            lambda: self._approved, timeout=timedelta(minutes=30)
        )

        summary = await workflow.execute_activity(
            record_result,
            args=[greeting],
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=3),
        )
        return {"greeting": greeting, "recorded_by": summary}

    @workflow.signal
    def approve(self) -> None:
        """Release the workflow from its wait so it can finish."""
        self._approved = True

    @workflow.query
    def progress(self) -> list[str]:
        return self._log


@workflow.defn(versioning_behavior=VersioningBehavior.AUTO_UPGRADE)
class HealthCheckWorkflow:
    """A short poll loop that follows the Current version as it changes."""

    @workflow.run
    async def run(self, iterations: int = 20) -> list[str]:
        results: list[str] = []
        for i in range(iterations):
            results.append(
                await workflow.execute_activity(
                    compose_greeting,
                    args=[f"{GREETING} (check {i + 1})", "health"],
                    start_to_close_timeout=timedelta(seconds=10),
                )
            )
            await workflow.sleep(timedelta(seconds=15))
        return results
