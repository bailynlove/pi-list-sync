import assert from "node:assert/strict";
import { test } from "node:test";
import childProcess, { spawnSync } from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import extension from "../pi/extensions/pi-list-sync.ts";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
function sandbox(t) {
  const dir = mkdtempSync(join(tmpdir(), "pi-list-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function run(command, args, options = {}) {
  return spawnSync(command, args, { encoding: "utf8", ...options });
}
function ok(result) {
  assert.equal(result.status, 0, result.stderr + result.stdout);
  return result.stdout;
}

test("code checkout refuses all snapshot operations without modifying the tree", (t) => {
  const dir = sandbox(t);
  cpSync(join(root, "sync.sh"), join(dir, "sync.sh"));
  writeFileSync(join(dir, ".code-only"), "public code\n");
  for (const command of ["save", "push", "push-if-changed", "apply", "pull", "hook", "auto", "bootstrap"]) {
    const result = run("bash", [join(dir, "sync.sh"), command]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /code-only package/);
  }
  for (const name of ["pi", "library", ".hook", ".lock.d"]) assert.equal(existsSync(join(dir, name)), false);
});

test("snapshot redacts models, skips caches and instructions, and blocks a skill credential", (t) => {
  const dir = sandbox(t);
  const repo = join(dir, "snapshot");
  const pi = join(dir, "agent");
  const lib = join(dir, "agents");
  mkdirSync(repo);
  mkdirSync(join(pi, "extensions"), { recursive: true });
  mkdirSync(join(pi, "skills"));
  mkdirSync(join(lib, "skills", "example", "__pycache__"), { recursive: true });
  cpSync(join(root, "sync.sh"), join(repo, "sync.sh"));
  cpSync(join(root, "brief.py"), join(repo, "brief.py"));
  writeFileSync(join(repo, "README.md"), "# private snapshot\n");
  writeFileSync(join(repo, ".gitignore"), ".lock.d/\n.hook\nhosts.txt\n");
  writeFileSync(join(pi, "AGENTS.md"), "local instructions\n");
  writeFileSync(join(pi, "auth.json"), "not collected\n");
  writeFileSync(join(pi, "models.json"), JSON.stringify({ providers: { example: { apiKey: "private-example-value", baseUrl: "https://example.invalid" } } }));
  writeFileSync(join(lib, "skills", "example", "SKILL.md"), "---\nname: example\ndescription: Example skill.\n---\n");
  writeFileSync(join(lib, "skills", "example", "__pycache__", "code.pyc"), "bytecode");
  writeFileSync(join(pi, "extensions", "cache.pyc"), "bytecode");
  const env = { ...process.env, PI_AGENT_DIR: pi, AGENTS_DIR: lib };
  ok(run("git", ["init", "-q", "-b", "main", repo]));
  ok(run("git", ["-C", repo, "config", "user.name", "Example"]));
  ok(run("git", ["-C", repo, "config", "user.email", "example@example.invalid"]));
  ok(run("bash", [join(repo, "sync.sh"), "save"], { env }));
  const models = JSON.parse(readFileSync(join(repo, "pi", "models.json"), "utf8"));
  assert.equal(models.providers.example.apiKey, undefined);
  assert.equal(models.providers.example.baseUrl, "https://example.invalid");
  for (const name of ["pi/AGENTS.md", "pi/auth.json", "pi/extensions/cache.pyc", "library/skills/example/__pycache__"]) {
    assert.equal(existsSync(join(repo, name)), false, name);
  }
  assert.match(readFileSync(join(repo, "README.md"), "utf8"), /Skills brief/);
  writeFileSync(join(lib, "skills", "example", "secret.txt"), "sk-" + "A".repeat(32));
  const blocked = run("bash", [join(repo, "sync.sh"), "push"], { env });
  assert.notEqual(blocked.status, 0);
  assert.match(blocked.stderr, /refusing to commit/);
  assert.notEqual(run("git", ["-C", repo, "rev-parse", "--verify", "HEAD"]).status, 0);
});

test("extension stays unarmed by default and passes paths as arguments on shutdown", (t) => {
  const dir = sandbox(t);
  const snapshot = join(dir, "snapshot with 'quotes'");
  mkdirSync(snapshot);
  writeFileSync(join(snapshot, "sync.sh"), "unused");
  const previous = { root: process.env.PI_LIST_ROOT, repo: process.env.PI_LIST_REPO };
  process.env.PI_LIST_ROOT = snapshot;
  delete process.env.PI_LIST_REPO;
  t.after(() => {
    for (const [name, value] of [["PI_LIST_ROOT", previous.root], ["PI_LIST_REPO", previous.repo]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    t.mock.restoreAll();
    syncBuiltinESMExports();
  });
  const handlers = new Map();
  const api = { on: (event, handler) => handlers.set(event, handler) };
  extension(api);
  assert.equal(handlers.size, 0);
  writeFileSync(join(snapshot, ".hook"), "");
  let invocation;
  let detached = false;
  const child = new EventEmitter();
  child.unref = () => { detached = true; };
  t.mock.method(childProcess, "spawn", (...args) => { invocation = args; return child; });
  syncBuiltinESMExports();
  extension(api);
  assert.equal(handlers.size, 1);
  handlers.get("session_shutdown")();
  assert.equal(invocation[0], "bash");
  assert.equal(invocation[1][2], snapshot);
  assert.equal(invocation[2].detached, true);
  assert.equal(detached, true);
  assert.doesNotThrow(() => child.emit("error", new Error("missing bash")));
});

test("npm tarball uses the exact code-only allowlist", (t) => {
  const dir = sandbox(t);
  const result = ok(run("npm", ["pack", "--dry-run", "--ignore-scripts", "--json", "--cache", dir], { cwd: root }));
  const files = JSON.parse(result)[0].files.map((entry) => entry.path).sort();
  assert.deepEqual(files, [".code-only", "LICENSE", "README.md", "brief.py", "hosts.example.txt", "package.json", "pi/extensions/pi-list-sync.ts", "sync.sh"].sort());
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  assert.equal(manifest.repository.url, "git+https://github.com/bailynlove/pi-list-sync.git");
  const ignored = ["hosts.txt", ".hook", "library/skills/example/SKILL.md", "pi/settings.json", "pi/mcp.json", "pi/models.json", "pi/skills.txt", "pi/extensions/private.ts"];
  for (const path of ignored) ok(run("git", ["check-ignore", "--no-index", "-q", path], { cwd: root }));
});
