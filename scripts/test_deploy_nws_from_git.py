#!/usr/bin/env python3
"""Exercise the real Compose helpers without sudo, Docker, Git, or network access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(os.environ.get("DEPLOY_WRAPPER", Path(__file__).with_name("deploy_nws_from_git.sh")))


class ComposeCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nws deploy test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "compose.json"
        self.base_env = self.root / "base env"
        self.local_env = self.root / "local env"
        self.base_env.write_text("DEPLOY_TEST_VALUE=base\n")
        self.local_env.write_text("DEPLOY_TEST_VALUE='local override'\n")
        self.make_command("sudo", '#!/bin/sh\nexec env "$@"\n')
        self.make_command("docker-compose", """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["COMPOSE_LOG"]).write_text(json.dumps({
    "args": sys.argv[1:], "value": os.environ["DEPLOY_TEST_VALUE"]
}))
sys.exit(int(os.environ.get("COMPOSE_EXIT", "0")))
""")
        source = WRAPPER.read_text()
        self.helpers = source[source.index("run_compose_command() {"):source.index("\nbuild_flag() {")]

    def make_command(self, name, content):
        command = self.bin / name
        command.write_text(content)
        command.chmod(0o755)

    def run_helper(self, invocation, exit_code=0):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   IAC_DIR=str(self.root), COMPOSE_ENV_FILE=str(self.base_env),
                   COMPOSE_ENV_LOCAL_FILE=str(self.local_env), COMPOSE_LOG=str(self.log),
                   COMPOSE_EXIT=str(exit_code))
        script = 'set -eu\ninfo() { :; }\n' + self.helpers + '\n' + invocation
        return subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)

    def assert_forwarded(self, expected):
        self.assertEqual(json.loads(self.log.read_text()), {
            "args": expected, "value": "local override"
        })

    def test_recreate_forwards_all_flags_and_service(self):
        result = self.run_helper('run_compose_command "docker-compose up -d --no-deps --force-recreate nwsalerts"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_forwarded(["up", "-d", "--no-deps", "--force-recreate", "nwsalerts"])

    def test_pull_forwards_both_services_through_retry_helper(self):
        result = self.run_helper('run_compose_command_allow_failure "docker-compose pull nwsalerts nwsalerts-schema"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_forwarded(["pull", "nwsalerts", "nwsalerts-schema"])

    def test_normal_failure_stops_deployment(self):
        result = self.run_helper('run_compose_command "docker-compose up -d nwsalerts"; echo UNREACHABLE', 23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertNotIn("UNREACHABLE", result.stdout)

    def test_pull_failure_can_be_handled_by_retry_loop(self):
        result = self.run_helper('if run_compose_command_allow_failure "docker-compose pull nwsalerts"; then echo UNEXPECTED; else echo "retry:$?"; fi', 23)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "retry:23")
        self.assert_forwarded(["pull", "nwsalerts"])


if __name__ == "__main__":
    unittest.main()
