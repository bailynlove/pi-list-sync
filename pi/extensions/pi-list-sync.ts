/**
 * pi-list-sync — after a session ends, ship the pi tool list + skill list.
 *
 * Spawns `sync.sh push-if-changed` detached, so it never slows pi's exit and
 * never blocks. That script exits immediately when nothing changed, so the
 * cost of a no-op session is one local rsync and one `git ls-remote`.
 *
 * Config (env, both optional):
 *   PI_LIST_ROOT  checkout of your list repo   default ~/my-awesome-pi-list
 *   PI_LIST_REPO  git URL to clone it from, if the checkout is missing
 *
 * Only armed on the machine that ran `sync.sh hook` (the .hook marker), so a
 * fleet that installs this package stays silent everywhere else.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const root = process.env.PI_LIST_ROOT ?? join(homedir(), "my-awesome-pi-list");
	const repo = process.env.PI_LIST_REPO ?? "";
	const log = join(homedir(), ".pi-sync.log");
	const present = existsSync(join(root, "sync.sh"));

	if (present && !existsSync(join(root, ".hook"))) return;
	if (!present && !repo) return;

	const body = `{
  if [ ! -f "$0/sync.sh" ]; then
    git clone -q --depth 1 -- "$1" "$0" || exit 0
  fi
  [ -f "$0/.hook" ] || exit 0
  exec bash "$0/sync.sh" push-if-changed
} >>"$2" 2>&1`;

	pi.on("session_shutdown", () => {
		try {
			// $0 = root, $1 = repo url, $2 = log; detached so pi exits whenever it wants
			const child = spawn("bash", ["-c", body, root, repo, log], {
				detached: true,
				stdio: "ignore",
			});
			child.on("error", () => {}); // missing bash must not crash pi
			child.unref();
		} catch {
			// never let a sync failure touch the session
		}
	});
}
