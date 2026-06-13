import os
import subprocess
import pytest


@pytest.fixture(scope="session", autouse=True)
def compose_stack():
    compose_file = os.environ.get("COMPOSE_FILE", "docker-compose.saga.test.yaml")
    compose_cmd = ["docker", "compose", "-f", compose_file]

    subprocess.run(
        [*compose_cmd, "up", "-d", "--build", "--wait"],
        check=True,
        timeout=300,
    )

    yield

    subprocess.run(
        [*compose_cmd, "down", "-v"],
        check=True,
        timeout=120,
    )
