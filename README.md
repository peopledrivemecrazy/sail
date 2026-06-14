# sail

Stand up a pre-baked, **self-hosted GitHub Actions runner** on your own Debian
box (Proxmox LXC, VM, or mini-PC) in two steps. Bake the image once (all the CI
utils included), attach it to a repo or org with a single **one-time token**, and
the workflows in that repo run on your own hardware.

No stored secrets, no env keys, no PAT — the only credential is the ephemeral
registration token GitHub gives you, pasted once and consumed.

## Why self-host a runner

Self-hosted runners are a first-class GitHub Actions feature. Reasons to run one
on your own box:

- **Your own hardware** — control cost and CPU/RAM, or reuse a machine you
  already keep on 24×7.
- **Access to local resources** — jobs that need something only reachable from
  your own network (an internal service, a homelab box, a device, a NAS).
- **Heavy or custom toolchains** — pre-install big dependencies once instead of
  on every run.
- **Browser / E2E testing** — sail bakes Xvfb + Playwright's Chromium so
  headed-browser tests run on a display-less server.

## How it works

```
┌──────────────────────────────────────────────┐
│     bake.sh: build the image, no secrets     │
└───────────────────────┬──────────────────────┘
                        ▼
┌──────────────────────────────────────────────┐
│         register.sh: one-time token          │
└───────────────────────┬──────────────────────┘
                        ▼
┌──────────────────────────────────────────────┐
│ self-hosted runner: Node + Xvfb + Playwright │
└───────────────────────┬──────────────────────┘
                        ▼
┌──────────────────────────────────────────────┐
│        outbound connection to GitHub         │
└───────────────────────┬──────────────────────┘
                        ▼
┌──────────────────────────────────────────────┐
│      GitHub delivers your workflow yml       │
└───────────────────────┬──────────────────────┘
                        ▼
┌──────────────────────────────────────────────┐
│          runs on your own hardware           │
└──────────────────────────────────────────────┘
```

The runner uses GitHub's pull model: it makes an outbound connection to GitHub
and waits for jobs — GitHub doesn't connect back, so it needs no inbound ports
(standard for any self-hosted runner). Your "test set" is just a workflow yml
committed to a repo; GitHub delivers it to the runner.

## The two-step model (the whole UX)

**1. Bake** — turn a fresh Debian box into the generic image. No secrets.

```bash
sudo ./bake.sh                 # runner agent + Node + pnpm + git + Xvfb + Playwright/Chromium
sudo ./bake.sh --no-browser    # lean image (skip the browser layer)
```

On Proxmox, snapshot the container afterwards so future clones are instant:

```bash
pct template <ctid>            # on the host
```

**2. Register** — attach the image to a repo or org with a one-time token.

```bash
sudo ./register.sh --repo owner/name --labels self-hosted,my-runner,linux
sudo ./register.sh --org  your-org   --labels self-hosted,linux
```

Get the token from **Settings → Actions → Runners → New self-hosted runner**
(repo) or **Org Settings → Actions → Runners** (org). It's short-lived and
single-use. Omit `--token` and you'll be prompted (so it never hits your shell
history). Re-point at a different repo later by re-running `register` with a
fresh token — the baked image never changes.

> **Org-level is the "one runner, many repos" sweet spot:** register once to the
> org and every repo in it can target the runner by label.

## Deliver a test set

Copy [`examples/browser-canary.yml`](examples/browser-canary.yml) into a repo at
`.github/workflows/`, set `runs-on:` to your label, and replace the run command
with your test. Commit it — GitHub delivers it to the sail runner. The image
already provides Node, pnpm, git, a preset `DISPLAY=:99`, and Playwright's
Chromium, so a headed browser (`headless:false`) works with no setup steps.

## On Proxmox, start to finish

```bash
# host: make the box (passwordless root, onboot=1 autostart)
CTID=9001 ./create-lxc.sh
pct enter 9001

# inside: copy sail in (scp/clone), then:
sudo ./bake.sh
sudo ./register.sh --org your-org --labels self-hosted,linux
```

Autostart is two layers: Proxmox `onboot=1` brings the container up with the
host; systemd inside brings the runner + Xvfb up with the container.

## Verify

```bash
sail status                          # runner service + xvfb health
curl -fsSL https://api.ipify.org     # the box's public IP, as a sanity check
```

The runner should read **Idle/online** in the repo/org runner list. Dispatch a
workflow and watch it land:

```bash
gh workflow run <your-workflow>.yml && gh run watch
```

## Security

- Runs as a dedicated **non-root** user; keep this box free of deploy/cloud creds.
- One purpose per label; don't reuse the runner for unrelated build/deploy.
- **Never run untrusted PR code on a self-hosted runner.** In the repo/org:
  Settings → Actions → *Fork pull request workflows* → "Require approval for all
  outside collaborators." Single most important hardening step.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `bake.sh` | the box | Build the generic image (no secrets) |
| `register.sh` | the box | Attach to a repo/org with a one-time token |
| `sail` | the box | `sail bake` / `sail register` / `sail status` |
| `create-lxc.sh` | Proxmox host | Make a Debian LXC (passwordless, onboot=1) |
| `examples/browser-canary.yml` | your repo | A test-set workflow to copy and edit |
