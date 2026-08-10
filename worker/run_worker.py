"""Worker entrypoint -- this is where Worker Versioning is wired up.

The only thing that distinguishes one deployed version from the next is the
``TEMPORAL_BUILD_ID`` environment variable, which CI sets to the Git commit
that produced the image. Everything else about the process is identical.

Registering with ``use_worker_versioning=True`` means this worker will only be
handed tasks that the server has routed to *its* Build ID -- it will not
silently pick up work meant for another version.
"""

import asyncio
import logging
import os
import signal
from datetime import timedelta

from temporalio.client import Client
from temporalio.common import WorkerDeploymentVersion
from temporalio.worker import Worker, WorkerDeploymentConfig

from activities import compose_greeting, record_result
from workflows import GreetingWorkflow, HealthCheckWorkflow

TEMPORAL_ADDRESS = os.environ.get("TEMPORAL_ADDRESS", "localhost:7233")
TEMPORAL_NAMESPACE = os.environ.get("TEMPORAL_NAMESPACE", "default")
TASK_QUEUE = os.environ.get("TEMPORAL_TASK_QUEUE", "greeting-tq")
DEPLOYMENT_NAME = os.environ.get("TEMPORAL_DEPLOYMENT_NAME", "greeting-worker")
BUILD_ID = os.environ.get("TEMPORAL_BUILD_ID")


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [build=" + (BUILD_ID or "-") + "] %(message)s",
    )
    log = logging.getLogger("worker")

    if not BUILD_ID:
        raise SystemExit(
            "TEMPORAL_BUILD_ID must be set. CI sets it to the short Git SHA; "
            "locally, export it yourself (e.g. TEMPORAL_BUILD_ID=dev-1)."
        )

    client = await Client.connect(TEMPORAL_ADDRESS, namespace=TEMPORAL_NAMESPACE)

    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[GreetingWorkflow, HealthCheckWorkflow],
        activities=[compose_greeting, record_result],
        deployment_config=WorkerDeploymentConfig(
            version=WorkerDeploymentVersion(
                deployment_name=DEPLOYMENT_NAME,
                build_id=BUILD_ID,
            ),
            # Opt this worker into version-aware task routing. Without it the
            # worker is "unversioned" and competes for every task on the queue.
            use_worker_versioning=True,
        ),
        # Let in-flight activities finish when Kubernetes sends SIGTERM.
        graceful_shutdown_timeout=timedelta(seconds=30),
    )

    # Kubernetes stops pods with SIGTERM; translate that into a clean worker
    # shutdown so old versions drain instead of dropping tasks.
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    log.info(
        "starting worker: deployment=%s build=%s task_queue=%s -> %s",
        DEPLOYMENT_NAME,
        BUILD_ID,
        TASK_QUEUE,
        TEMPORAL_ADDRESS,
    )
    async with worker:
        await stop.wait()
    log.info("worker stopped")


if __name__ == "__main__":
    asyncio.run(main())
