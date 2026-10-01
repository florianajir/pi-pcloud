#!/usr/bin/env python3
"""The assistant's two Forgejo repositories, kept in step with its volume.

Run by openclaw-sync.timer, never by the agent: the agent has no git, no
shell and no network, and the Forgejo token is mounted into nothing but the
throwaway container this starts. Three passes:

- Memory: each person's workspace is committed and pushed to its own branch
  of assistant-memory, directly - edits the owner makes on that branch in
  Forgejo are merged back, and win where both sides touched the same lines.
- Knowledge: the knowledge repository's main is checked out read-only beside
  the workspaces, where the agents' memory search indexes it.
- Proposals: whatever an agent wrote under knowledge-proposals/ in its
  workspace becomes one pull request per person, opened and then updated by an
  AGit push (refs/for/main), against a main nobody but the owner can push to.

The git directories live outside the workspaces, so nothing an agent writes -
a hook, a config, a filter - is ever executed by this script's git, which also
runs with hooks disabled. Idempotent; a pass with nothing new pushes nothing.
"""

import json
import re
import subprocess
import sys
from datetime import UTC, datetime

import pilib
from pilib import log, resolve_data_location_path

CONTAINER = "pi-openclaw"
FORGEJO = "pi-forgejo"
HELPER = "pi-openclaw-sync"
BOT = "assistant"
MEMORY_REPO = "assistant-memory"
KNOWLEDGE_REPO = "knowledge"
STATE = "/state"
GIT_DIRS = f"{STATE}/sync"
KNOWLEDGE_CLONE = f"{GIT_DIRS}/knowledge"
KNOWLEDGE_VIEW = f"{STATE}/knowledge"
PROPOSALS_DIR = "knowledge-proposals"
# Never copied into a proposal: repository machinery, not knowledge.
PROPOSAL_EXCLUDES = (".git", ".forgejo", ".gitea", ".github")


def docker(*args, input_text=None, check=False):
    return subprocess.run(["docker", *args], input=input_text, capture_output=True, text=True, check=check)


class Git:
    """git inside the helper container, with nothing a work tree can steer."""

    def __init__(self, host_name):
        self.base = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "safe.directory=*",
            "-c", f"user.name={BOT.capitalize()}",
            "-c", f"user.email={BOT}@{host_name}",
            # Read at use time from the mounted file, so the token is in no
            # URL, no .git/config and no argv.
            "-c", "credential.helper=",
            "-c", "credential.helper=!f() { echo username=" + BOT
            + '; printf "password=%s\\n" "$(cat /run/forgejo_token)"; }; f',
        ]  # fmt: skip

    def run(self, *args, env=None, input_text=None):
        cmd = ["exec", "-i"]
        for key, value in (env or {}).items():
            cmd += ["-e", f"{key}={value}"]
        return docker(*cmd, HELPER, "git", *self.base, *args, input_text=input_text)

    def ok(self, *args, env=None):
        return self.run(*args, env=env).returncode == 0


def shell(script, *args):
    return docker("exec", HELPER, "sh", "-c", script, "sh", *args)


def start_helper(image, volume, token_file):
    docker("rm", "-f", HELPER)
    proc = docker(
        "run", "-d", "--rm", "--name", HELPER, "--network", "assistant",
        "--user", "1000:1000", "--read-only", "--tmpfs", "/tmp:mode=1777",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "-e", "HOME=/tmp",
        "-v", f"{volume}:{STATE}", "-v", f"{token_file}:/run/forgejo_token:ro",
        "--entrypoint", "sleep", image, "900",
    )  # fmt: skip
    if proc.returncode != 0:
        pilib.die(f"could not start the sync container: {proc.stderr.strip()}")


def sync_memory(git, remote, person):
    agent = person["agent"]
    env = {"GIT_DIR": f"{GIT_DIRS}/memory/{agent}.git", "GIT_WORK_TREE": f"{STATE}/workspaces/{agent}"}
    if shell('[ -d "$1" ]', env["GIT_WORK_TREE"]).returncode != 0:
        return
    if shell('[ -d "$1" ]', env["GIT_DIR"]).returncode != 0:
        shell('mkdir -p "$(dirname "$1")"', env["GIT_DIR"])
        if not git.ok("init", "-q", "-b", agent, env=env):
            log(f"WARNING: could not initialise the memory repository of {agent}")
            return
    git.run("remote", "remove", "origin", env=env)
    git.run("remote", "add", "origin", remote, env=env)

    git.run("add", "-A", env=env)
    if not git.ok("diff", "--cached", "--quiet", env=env):
        stamp = f"{datetime.now(UTC):%Y-%m-%d %H:%M} UTC"
        git.run("commit", "-q", "-m", f"memory: {person['name']}, {stamp}", env=env)

    if git.ok("fetch", "-q", "origin", f"+refs/heads/{agent}:refs/remotes/origin/{agent}", env=env):
        if not git.ok("rev-parse", "-q", "--verify", "HEAD", env=env):
            git.run("reset", "-q", f"origin/{agent}", env=env)
        elif not git.ok("merge-base", "--is-ancestor", f"origin/{agent}", "HEAD", env=env) and not git.ok(
            "merge", "-q", "--no-edit", "-X", "theirs", f"origin/{agent}", env=env
        ):
            git.run("merge", "--abort", env=env)
            log(f"WARNING: {agent}'s memory and its Forgejo branch conflict; resolve it there, nothing was pushed")
            return
    if not git.ok("rev-parse", "-q", "--verify", "HEAD", env=env):
        return
    push = git.run("push", "-q", "origin", f"HEAD:refs/heads/{agent}", env=env)
    if push.returncode != 0:
        log(f"WARNING: pushing {agent}'s memory failed: {push.stderr.strip()[-300:]}")


def sync_knowledge(git, remote):
    if shell('[ -d "$1/.git" ]', KNOWLEDGE_CLONE).returncode != 0:
        shell('mkdir -p "$1"', GIT_DIRS)
        clone = git.run("clone", "-q", remote, KNOWLEDGE_CLONE)
        if clone.returncode != 0:
            log(f"WARNING: cloning the knowledge base failed: {clone.stderr.strip()[-300:]}")
            return False
    if not git.ok("-C", KNOWLEDGE_CLONE, "fetch", "-q", "--prune", "origin"):
        log("WARNING: fetching the knowledge base failed")
        return False

    # A fresh export, swapped in whole, so the agents never index a half
    # checkout - and deleted files really disappear from their view.
    head = git.run("-C", KNOWLEDGE_CLONE, "rev-parse", "origin/main").stdout.strip()
    exported = shell('cat "$1/.exported" 2>/dev/null', KNOWLEDGE_VIEW).stdout.strip()
    if head and head != exported:
        script = """
            set -e
            rm -rf "$2.new" && mkdir -p "$2.new"
            git -C "$1" -c safe.directory='*' archive origin/main | tar -x -C "$2.new"
            printf '%s\\n' "$3" > "$2.new/.exported"
            rm -rf "$2" && mv "$2.new" "$2"
        """
        proc = shell(script, KNOWLEDGE_CLONE, KNOWLEDGE_VIEW, head)
        if proc.returncode != 0:
            log(f"WARNING: exporting the knowledge base failed: {proc.stderr.strip()[-300:]}")
        else:
            log(f"The agents now read knowledge base {head[:10]}")
    return True


def settle_finished_proposal(owner, agent, source):
    """Empty an agent's proposals once its pull request is merged or closed.

    Left in place, a merged proposal would be compared with a main the owner
    may have edited during review, and reopened as a pull request reverting
    those edits. The number comes from the AGit push's own output.
    """
    marker = f"{GIT_DIRS}/proposal-{agent}.pr"
    number = shell('cat "$1" 2>/dev/null', marker).stdout.strip()
    if not number.isdigit():
        return
    proc = shell(
        'curl -fsS -H "Authorization: token $(cat /run/forgejo_token)" "$1"',
        f"http://forgejo:3000/api/v1/repos/{owner}/{KNOWLEDGE_REPO}/pulls/{number}",
    )
    try:
        pull = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return
    if pull.get("state") != "closed":
        return
    shell('rm -rf "$1" "$2" "$3"', source, marker, f"{GIT_DIRS}/proposal-{agent}.tree")
    log(f"{agent}'s proposal #{number} was {'merged' if pull.get('merged') else 'closed'}; emptied its folder")


def propose(git, owner, person):
    agent = person["agent"]
    source = f"{STATE}/workspaces/{agent}/{PROPOSALS_DIR}"
    settle_finished_proposal(owner, agent, source)
    # Regular files only: -type f skips symlinks, so a proposal cannot point
    # the copy at anything outside the workspace.
    script = r"""
        cd "$1" 2>/dev/null || exit 0
        find . -type f | while IFS= read -r path; do
            case "${path#./}" in .git/*|.git|.forgejo/*|.gitea/*|.github/*) continue ;; esac
            mkdir -p "$2/$(dirname "$path")" && cp -- "$path" "$2/$path"
        done
    """
    if not git.ok("-C", KNOWLEDGE_CLONE, "checkout", "-q", "-f", "-B", f"proposal-{agent}", "origin/main"):
        return
    git.run("-C", KNOWLEDGE_CLONE, "clean", "-q", "-fdx")
    shell(script, source, KNOWLEDGE_CLONE)
    git.run("-C", KNOWLEDGE_CLONE, "add", "-A")
    if git.ok("-C", KNOWLEDGE_CLONE, "diff", "--cached", "--quiet", "origin/main"):
        git.run("-C", KNOWLEDGE_CLONE, "checkout", "-q", "-f", "--detach", "origin/main")
        return
    # The same files as last pass make the same tree; pushing it again would
    # add a force-push to the pull request's timeline every quarter hour.
    tree_marker = f"{GIT_DIRS}/proposal-{agent}.tree"
    tree = git.run("-C", KNOWLEDGE_CLONE, "write-tree").stdout.strip()
    if tree and tree == shell('cat "$1" 2>/dev/null', tree_marker).stdout.strip():
        git.run("-C", KNOWLEDGE_CLONE, "checkout", "-q", "-f", "--detach", "origin/main")
        return
    title = f"Knowledge proposal from {person['name']}"
    git.run("-C", KNOWLEDGE_CLONE, "commit", "-q", "-m", title)
    # Same topic every time, so a revised proposal updates its open pull
    # request rather than opening another; force-push because each revision
    # is rebuilt on the current main.
    push = git.run(
        # Not -q: the pull request's URL arrives on the remote's own output.
        "-C", KNOWLEDGE_CLONE, "push", "origin", "HEAD:refs/for/main",
        "-o", f"topic=assistant-{agent}", "-o", f"title={title}",
        "-o", f"description=Written by {person['name']}'s assistant from its {PROPOSALS_DIR}/ folder. "
        "Merging is the only way it reaches what every agent reads.",
        "-o", "force-push=true",
    )  # fmt: skip
    if push.returncode != 0:
        log(f"WARNING: opening {agent}'s proposal failed: {push.stderr.strip()[-300:]}")
    else:
        shell('printf "%s\\n" "$2" > "$1"', tree_marker, tree)
        match = re.search(rf"/{KNOWLEDGE_REPO}/pulls/(\d+)", push.stderr)
        if match:
            shell('printf "%s\\n" "$2" > "$1"', f"{GIT_DIRS}/proposal-{agent}.pr", match.group(1))
        log(f"Pushed {agent}'s knowledge proposal" + (f" (#{match.group(1)})" if match else ""))
    git.run("-C", KNOWLEDGE_CLONE, "checkout", "-q", "-f", "--detach", "origin/main")


def main():
    data_dir = resolve_data_location_path() / "openclaw"
    token_file = data_dir / "secrets" / "forgejo_token"
    owner_file = data_dir / "forgejo-provisioned"
    if not (pilib.container_is_running(CONTAINER) and pilib.container_is_running(FORGEJO)):
        log("OpenClaw or Forgejo is not running; nothing to sync")
        return
    if not (token_file.is_file() and owner_file.is_file()):
        log("Forgejo is not provisioned for the assistant yet (scripts/openclaw-bootstrap.py)")
        return
    owner = owner_file.read_text(encoding="utf-8").strip()
    try:
        people = json.loads((data_dir / "people.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        people = []

    image = docker("inspect", "--format", "{{.Config.Image}}", CONTAINER).stdout.strip()
    volume = docker(
        "inspect", "--format",
        '{{range .Mounts}}{{if eq .Destination "/home/node/.openclaw"}}{{.Name}}{{end}}{{end}}', CONTAINER,
    ).stdout.strip()  # fmt: skip
    if not image or not volume:
        pilib.die(f"cannot read the image or the state volume of {CONTAINER}")

    host_name = pilib.get_env_value("HOST_NAME") or "pi.lan"
    git = Git(host_name)
    start_helper(image, volume, token_file)
    try:
        for person in people:
            sync_memory(git, f"http://forgejo:3000/{owner}/{MEMORY_REPO}.git", person)
        if sync_knowledge(git, f"http://forgejo:3000/{owner}/{KNOWLEDGE_REPO}.git"):
            for person in people:
                propose(git, owner, person)
    finally:
        docker("rm", "-f", HELPER)


if __name__ == "__main__":
    sys.exit(main())
