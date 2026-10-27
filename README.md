# pi-list-sync

Sync Pi's tool configuration and skills from one pushing machine to your servers.
The extension runs a detached sync on `session_shutdown`; it adds no model tools.

**Two repositories, two jobs:** this public repository contains reusable code.
Your separate **private snapshot repository** contains personal configuration.
Never publish the snapshot repository to npm.

## Install

Requires Node.js 22.19+, Pi, Git, Bash, Python 3 and rsync on the pushing machine.
Servers need SSH access, Bash, Python 3, tar and an existing Pi installation.
Package commands use `pi update --extensions`, not operating-system provisioning.

```sh
git clone https://github.com/bailynlove/pi-list-sync.git "$HOME/pi-list-sync-code"
pi install "$HOME/pi-list-sync-code"
```

Restart Pi after installation. Once published to npm, you can instead use
`pi install npm:pi-list-sync`. Do not load both the package and a standalone copy
of `pi-list-sync.ts`, or two hooks will run.

## Set up a private snapshot repository

First create an **empty private** repository on your Git host. On the machine
that should push, create its checkout separately:

```sh
mkdir -p "$HOME/my-awesome-pi-list"
cd "$HOME/my-awesome-pi-list"
git init -b main
git remote add origin YOUR_PRIVATE_GIT_URL
cp "$HOME/pi-list-sync-code/sync.sh" "$HOME/pi-list-sync-code/brief.py" .
cp "$HOME/pi-list-sync-code/hosts.example.txt" hosts.txt
printf '# private pi snapshot\n' > README.md
printf 'hosts.txt\n.hook\n.lock.d/\n__pycache__/\n*.pyc\n.DS_Store\n' > .gitignore
```

Replace `YOUR_PRIVATE_GIT_URL`, then edit `hosts.txt`: one SSH alias per line.
Configure those aliases and credentials locally in `~/.ssh/config`; do not
commit them. Use one designated pushing machine, not concurrent writers.

For an existing private snapshot repository, keep its configuration and Git
history; back up and replace only `sync.sh` and `brief.py`. Do not copy the public
package's `.code-only` marker or `package.json` into it. If its old
`package.json` advertised it as a Pi package, remove that manifest and install
this code-only package instead.

Before saving, review the settings and skills you intend to store, including
local paths, MCP environment variables and any vendored code licenses:

```sh
cd "$HOME/my-awesome-pi-list"
bash sync.sh save
git status --short
# Inspect the snapshot files locally; never paste credentials into an issue.
bash sync.sh push
bash sync.sh hook
```

`push` saves, commits and pushes to the private Git repository, then sends a tar
archive over SSH to each host's `~/.pi-list` and runs `apply`. The servers do not
need Git-host credentials for this SSH delivery. Check `~/.pi-sync.log` after
automatic syncs. Remove the local `.hook` file to disable the session-end hook.

The public package checkout (including npm installs) contains a `.code-only`
marker: its sync script refuses to run there. Its Git ignore list and npm file
allowlist provide additional protection against accidentally packaging snapshots.
These are safeguards, not a substitute for reviewing what you publish.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `PI_LIST_ROOT` | `~/my-awesome-pi-list` | Separate private snapshot checkout |
| `PI_LIST_REPO` | unset | Optional private Git URL to clone if the checkout is absent |
| `PI_AGENT_DIR` | `~/.pi/agent` | Pi configuration source/destination |
| `AGENTS_DIR` | `~/.agents` | Shared skills library source/destination |

For a non-default checkout, export `PI_LIST_ROOT` in the environment that starts
Pi. `PI_LIST_REPO` is optional; omitting it avoids any automatic clone.
The `.hook` marker is local and excluded from SSH delivery, so receiving machines
do not become pushing machines. A missing checkout is not automatically armed.

## What is synced

- `settings.json` (including package declarations) and `mcp.json`.
- Local extensions, local skills, shared `~/.agents/skills`, and exposed skill links.
- A redacted `models.json`. Existing destination model configurations are kept.
- A collapsed skill-description table in the **private** snapshot's README.

Not collected: `AGENTS.md`, `auth.json`, sessions, trust files, Pi's npm directory,
model-store/web-search/cache credentials, Git directories or Python bytecode.
**Do not put secrets in skills or extensions.** Redaction only handles known
fields in `models.json`; MCP/settings files and arbitrary skill content may still
contain secrets. The pre-commit scan is heuristic and can reject harmless
examples; it is not a complete credential detector. Keep snapshots private.

## Applying changes and limitations

`bash sync.sh apply` applies a local snapshot; `bash sync.sh pull` first pulls its
Git origin. Do not run either in this public package checkout.

Apply overwrites destination settings, MCP config and matching extension/skill
files. Back up receiver configuration first. MCP commands using nonexistent
absolute paths are skipped. Other local paths and package references are not
rewritten across operating systems. Package installation can fail offline;
review the log and rerun `pi update --extensions` when connectivity returns.

Removed source files disappear from future snapshots, and stale exposed skill
links are removed on receivers. Receiver extension/library directories are
overlaid, not fully pruned: extra old files may remain. Changing an exposed skill
from a local directory to a library link needs manual review on the receiver.
Git history retains old snapshots. Making a formerly public repository private
does not retract existing clones or cached copies.

## Development and release

```sh
npm test
npm pack --dry-run --ignore-scripts
# Review the package contents, then deliberately publish:
npm publish --access public
```

No private snapshot, host list, personal inventory or real configuration is
included in this package. Publishing does not upload your separate private repo.
