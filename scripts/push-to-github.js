#!/usr/bin/env node
/**
 * Pushes this working tree to GitHub as one commit using the git data API.
 *
 * Exists because the `git` binary on this machine is an Xcode shim and is
 * unusable until the Xcode licence is accepted. `gh` talks to the REST API
 * directly, so it does not care.
 *
 *   node scripts/push-to-github.js <owner/repo> [commit message]
 */
"use strict";

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const REPO = process.argv[2];
const MESSAGE = process.argv[3] || "Initial commit";
if (!REPO) {
  console.error("usage: push-to-github.js <owner/repo> [message]");
  process.exit(1);
}

const ROOT = path.resolve(__dirname, "..");
const SKIP_DIRS = new Set([".git", ".build", "node_modules", "dist/.tmp"]);
const SKIP_FILES = new Set([".DS_Store"]);

function gh(args, input) {
  return execFileSync("gh", args, {
    input,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function api(endpoint, method, body) {
  const args = ["api", endpoint];
  if (method) args.push("-X", method);
  if (body !== undefined) args.push("--input", "-");
  return JSON.parse(gh(args, body === undefined ? undefined : JSON.stringify(body)));
}

// ---------------------------------------------------------------- collect

const files = [];
(function walk(dir, rel) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_FILES.has(entry.name)) continue;
    const abs = path.join(dir, entry.name);
    const r = rel ? rel + "/" + entry.name : entry.name;
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name) || SKIP_DIRS.has(r)) continue;
      walk(abs, r);
    } else {
      files.push({ path: r, abs, mode: (fs.statSync(abs).mode & 0o111) ? "100755" : "100644" });
    }
  }
})(ROOT, "");

console.log(`collected ${files.length} files`);

// ---------------------------------------------------------------- repo

let repo;
try {
  repo = api(`repos/${REPO}`);
  console.log(`repo exists: ${repo.full_name}`);
} catch {
  console.log(`creating ${REPO}`);
  gh([
    "repo", "create", REPO,
    "--public",
    "--description",
    "cs-OS — a native macOS terminal running real Linux in a lightweight VM. Liquid Glass UI, sub-second boot.",
    "--homepage", "https://chopstickshq.com/cs-os/",
  ]);
  repo = api(`repos/${REPO}`);
}

const branch = repo.default_branch || "main";

// The git data API refuses to create blobs in a repo with no commits at all
// ("Git Repository is empty", HTTP 409). The contents API does work there, so
// seed one file to bring the repo into existence, then proceed normally.
let repoEmpty = false;
try {
  api(`repos/${REPO}/git/ref/heads/${branch}`);
} catch {
  repoEmpty = true;
}
if (repoEmpty) {
  console.log("repo has no commits — seeding via contents API");
  api(`repos/${REPO}/contents/.gitignore`, "PUT", {
    message: "Seed repository",
    branch,
    content: Buffer.from(".build/\ndist/\n.DS_Store\n").toString("base64"),
  });
}

// ---------------------------------------------------------------- blobs

const tree = [];
for (const f of files) {
  const content = fs.readFileSync(f.abs);
  const blob = api(`repos/${REPO}/git/blobs`, "POST", {
    content: content.toString("base64"),
    encoding: "base64",
  });
  tree.push({ path: f.path, mode: f.mode, type: "blob", sha: blob.sha });
  process.stdout.write(".");
}
console.log(`\nuploaded ${tree.length} blobs`);

// ---------------------------------------------------------------- commit

let parents = [];
let baseTree;
try {
  const ref = api(`repos/${REPO}/git/ref/heads/${branch}`);
  parents = [ref.object.sha];
  baseTree = api(`repos/${REPO}/git/commits/${ref.object.sha}`).tree.sha;
} catch {
  console.log("empty repo — creating root commit");
}

const treeBody = { tree };
if (baseTree) treeBody.base_tree = baseTree;
const newTree = api(`repos/${REPO}/git/trees`, "POST", treeBody);

const commit = api(`repos/${REPO}/git/commits`, "POST", {
  message: MESSAGE,
  tree: newTree.sha,
  parents,
});

try {
  api(`repos/${REPO}/git/refs/heads/${branch}`, "PATCH", { sha: commit.sha, force: true });
} catch {
  api(`repos/${REPO}/git/refs`, "POST", { ref: `refs/heads/${branch}`, sha: commit.sha });
}

console.log(`committed ${commit.sha.slice(0, 7)} to ${branch}`);
console.log(`https://github.com/${REPO}`);
