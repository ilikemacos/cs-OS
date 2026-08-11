#!/usr/bin/env node
/**
 * Builds the cs-OS project page for chopstickshq.com.
 *
 * The site has no shared stylesheet — every page inlines its own <style>. So
 * rather than reimplement the design system (and drift from it), this lifts the
 * style block verbatim from an existing project page and pours cs-OS content
 * into the same class vocabulary: .hero / .sec / .card / .curl / .btn / .pill.
 *
 *   node scripts/build-site-page.js <site-root> [out-path]
 */
"use strict";

const fs = require("fs");
const path = require("path");

const SITE = process.argv[2];
if (!SITE) {
  console.error("usage: build-site-page.js <site-root> [out-path]");
  process.exit(1);
}
const OUT = process.argv[3] || path.join(SITE, "cs-os", "index.html");
const TEMPLATE = path.join(SITE, "fathom", "index.html");

const src = fs.readFileSync(TEMPLATE, "utf8");
const styleMatch = src.match(/<style>([\s\S]*?)<\/style>/);
if (!styleMatch) throw new Error("no <style> block found in " + TEMPLATE);
const STYLE = styleMatch[1];

// The theme bootstrap script the other pages run before paint.
const themeBoot = (src.match(/<script>([\s\S]*?)<\/script>/) || [, ""])[1];

const page = `<!DOCTYPE html>
<html lang="en">
<head>
<script>${themeBoot}</script>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cs-OS — real Linux on macOS · Chopsticks HQ</title>
<meta name="description" content="cs-OS runs real Linux on macOS in a lightweight VM — actual kernel, actual package manager, sub-second boot. Native Swift, no Electron, no sudo.">
<meta name="keywords" content="cs-OS, Linux on macOS, macOS terminal, Containerization, Apple silicon, Alpine, microVM, Chopsticks HQ">
<link rel="canonical" href="https://chopstickshq.com/cs-os/">
<meta property="og:title" content="cs-OS — real Linux on macOS">
<meta property="og:description" content="A native macOS terminal running real Linux in a lightweight VM. Sub-second boot, no Electron, no sudo.">
<meta property="og:url" content="https://chopstickshq.com/cs-os/">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="cs-OS — real Linux on macOS">
<meta name="twitter:description" content="Real Linux in a lightweight VM, in a native macOS terminal.">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>${STYLE}</style>
</head>
<body>
  <div class="app">
    <nav>
      <a class="nav-logo" href="/">Chopsticks HQ <span>· cs-OS</span></a>
      <div class="nav-mid">
        <a class="nav-link" href="/">HQ</a>
        <a class="nav-link" href="/rnitro/">rNitro</a>
        <a class="nav-link" href="/fathom/">Fathom</a>
        <a class="nav-link" href="/chopsticks-ai/">chopsticksAI</a>
        <a class="nav-link" href="#features">Features</a>
        <a class="nav-link" href="#install">Install</a>
        <a class="nav-link" href="#specs">Specs</a>
        <a class="nav-link" href="#changelog">Changelog</a>
      </div>
      <div class="nav-right">
        <a class="btn btn-outline btn-sm" href="/csos/">csOS (web)</a>
        <a class="btn btn-primary btn-sm" href="#install">Install</a>
      </div>
    </nav>

    <header class="hero">
      <div class="wrap">
        <div class="hero-grid">
          <div>
            <div class="kicker">macOS 26 · Apple silicon</div>
            <h1>cs-OS <span class="dim">— real Linux,<br>natively</span></h1>
            <p class="hero-lead">
              A native macOS terminal that runs actual Linux — real kernel, real
              <span class="mono">/proc</span>, real package manager — in a lightweight VM
              that boots in about a second. Not an emulator, not a shell wrapper,
              not Electron.
            </p>

            <pre class="curl" id="install-cmd" title="Click to copy">curl -fsSL https://chopstickshq.com/cs-os.sh | sh</pre>

            <p class="hero-meta">
              <span class="pill"><span class="pill-dot"></span>v0.1.0 · not yet released</span>
              &nbsp;·&nbsp; ~140 MB installed &nbsp;·&nbsp; no sudo &nbsp;·&nbsp; no Xcode
            </p>

            <div class="hero-actions">
              <a class="btn btn-primary" href="#install">How to install</a>
              <a class="btn btn-outline" href="#specs">Requirements</a>
            </div>
          </div>

          <div>
            <div class="preview">
              <div class="preview-head">
                <span class="preview-badge">alpine</span>
                <span class="preview-sub">cs-OS — session 1</span>
              </div>
              <div class="preview-body">
<pre class="mono" style="margin:0;font-size:.72rem;line-height:1.8;white-space:pre;overflow-x:auto">~ $ uname -sr
Linux 6.14.9
~ $ head -1 /etc/os-release
NAME="Alpine Linux"
~ $ apk add ripgrep
(1/1) Installing ripgrep (14.1.1-r0)
OK: 12 MiB in 16 packages
~ $ nproc &amp;&amp; free -m | head -2
2
       total  used  free
Mem:    1024   118   906
~ $ █</pre>
              </div>
            </div>
          </div>
        </div>
      </div>
    </header>

    <section class="sec" id="features">
      <div class="wrap">
        <div class="kicker">What it is</div>
        <h2>Real Linux, not an approximation</h2>
        <p class="sec-lead">
          macOS cannot load Linux binaries — there is no <span class="mono">binfmt_misc</span>,
          no WSL1-style translation layer. So cs-OS does the honest thing and runs a real
          kernel in a real VM, using Apple's Containerization framework.
        </p>
        <div class="grid grid-2">
          <article class="card">
            <div class="card-ico">▮</div>
            <h3>One microVM per tab</h3>
            <p>Every session is an OCI image in its own lightweight VM. Namespaces, cgroups
            and <span class="mono">apk</span>/<span class="mono">apt</span> all work, because
            none of it is being faked.</p>
          </article>
          <article class="card">
            <div class="card-ico">⚡</div>
            <h3>Sub-second boot</h3>
            <p>An optimized kernel and a minimal init get you to a prompt faster than most
            terminal emulators open a tab.</p>
          </article>
          <article class="card">
            <div class="card-ico">⌘</div>
            <h3>Bring your own distro</h3>
            <p>Alpine by default. Debian, Ubuntu and Fedora are one click away — anything with
            an OCI image works, pulled on demand.</p>
          </article>
          <article class="card">
            <div class="card-ico">◆</div>
            <h3>Glass where it belongs</h3>
            <p>Liquid Glass chrome and tabs. The text grid itself stays opaque and cheap to
            composite, so output never stutters behind a blur.</p>
          </article>
        </div>
      </div>
    </section>

    <section class="sec sec-tight" id="install">
      <div class="wrap">
        <div class="kicker">Install</div>
        <h2>One line, no password</h2>
        <pre class="curl" id="install-cmd-2" title="Click to copy">curl -fsSL https://chopstickshq.com/cs-os.sh | sh</pre>
        <div class="steps">
          <div class="step">
            <div class="name">1 · Checks your Mac</div>
            <p>Apple silicon and macOS 26 or later. Stops with a clear reason if not.</p>
          </div>
          <div class="step">
            <div class="name">2 · Verifies the download</div>
            <p>SHA-256 checked against the release manifest before anything is unpacked.</p>
          </div>
          <div class="step">
            <div class="name">3 · Installs the app</div>
            <p>Into <span class="mono">/Applications</span>, or <span class="mono">~/Applications</span>
            if that isn't writable. It never asks for a password.</p>
          </div>
        </div>
        <p class="note">
          <strong>No sudo. No Xcode. No toolchain.</strong> The script only ever downloads a
          prebuilt, checksum-verified app. Uninstall is
          <span class="mono">rm -rf /Applications/cs-OS.app</span>.
        </p>
      </div>
    </section>

    <section class="sec" id="specs">
      <div class="wrap">
        <div class="kicker">Specs</div>
        <h2>Requirements &amp; size</h2>
        <div class="grid grid-2">
          <article class="card">
            <h3>Requirements</h3>
            <table class="compare">
              <tbody>
                <tr><td>macOS</td><td class="mono">26.0 or later</td></tr>
                <tr><td>Chip</td><td class="mono">Apple silicon only</td></tr>
                <tr><td>Disk</td><td class="mono">~140 MB</td></tr>
                <tr><td>Memory</td><td class="mono">1 GB per session</td></tr>
                <tr><td>Network</td><td class="mono">first launch only</td></tr>
              </tbody>
            </table>
          </article>
          <article class="card">
            <h3>Where the megabytes go</h3>
            <table class="compare">
              <tbody>
                <tr><td>Linux kernel</td><td class="mono">~40 MB</td></tr>
                <tr><td>Guest init</td><td class="mono">~30 MB</td></tr>
                <tr><td>csos binary</td><td class="mono">~70 MB</td></tr>
                <tr><td>Font &amp; icon</td><td class="mono">~1.5 MB</td></tr>
                <tr><td>Base image</td><td class="mono">+3.5 MB</td></tr>
              </tbody>
            </table>
          </article>
        </div>
        <p class="note">
          No root filesystem is bundled — images are pulled on demand, so the download stays
          the same size no matter which distro you end up living in.
        </p>
      </div>
    </section>

    <section class="sec sec-tight" id="changelog">
      <div class="wrap">
        <div class="kicker">Changelog</div>
        <h2>Releases</h2>
        <div class="steps">
          <div class="step">
            <div class="name">v0.1.0 — unreleased</div>
            <p>Containerization-backed sessions, one microVM per tab. Liquid Glass tab strip and
            window chrome. SwiftTerm rendering with xterm-256color and full scrollback. Alpine
            by default, with Debian, Ubuntu and Fedora presets. One-line installer with
            SHA-256 verification.</p>
          </div>
        </div>
      </div>
    </section>

    <footer class="wrap foot">
      <div>© ChopsticksHQ 2026</div>
      <div class="foot-links">
        <a href="/">HQ</a>
        <a href="/about/">About</a>
        <a href="/disclaimer/">Disclaimer</a>
        <a href="/rnitro/">rNitro</a>
        <a href="/fathom/">Fathom</a>
        <a href="/csos/">csOS (web)</a>
        <a href="/cs-os.sh">install script</a>
      </div>
    </footer>
  </div>

  <div class="toast" id="toast">Copied</div>
  <script src="/js/clipboard.js"></script>
  <script>
    function toast(msg) {
      const t = document.getElementById('toast');
      if (!t) return;
      t.textContent = msg;
      t.classList.add('show');
      setTimeout(() => t.classList.remove('show'), 2200);
    }
  </script>
</body>
</html>
`;

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, page);
console.log("wrote " + OUT + " (" + page.length + " bytes)");
