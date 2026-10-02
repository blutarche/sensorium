# Sensorium verification map

This directory is the maintained source for verifying what a person sees and does in Sensorium's two macOS apps. Read the index, then use the matching feature file as the recipe. `../SKILL.md` defines the tiers, helpers and safety rules every recipe assumes.

## Baseline preconditions

- Working directory is the repository root. Every Bash call that runs a helper has `dangerouslyDisableSandbox: true`.
- `.claude/skills/verify-sensorium/scripts/doctor.sh` ran in this session and its verdict says `renders and loopback: OK to run`.
- The installed `/Applications/Sensorium Host.app` and any process doctor tags `REPO BUILD` that this run did not start are left alone.
- A smoke step runs only when the task approves an opt-in integration test and doctor says `preconditions met`.

## Driving conventions

- Renders: `scripts/render.sh <label> <file.png> ...` with the exact files the recipe names. One render run covers every feature: after the first, check further files with `scripts/render.sh --check <evidence-dir> <file.png> ...` instead of rendering again.
- Look at each named PNG with the Read tool. A file that exists but shows the wrong words or layout is a failure.
- Loopback: `scripts/loopback.sh <label>`. Smokes: the script named in the recipe, then `scripts/keep-smoke-evidence.sh <smoke> <label>`.
- Treat file names and log strings as literal. They come from `Scripts/render-ui-previews.swift`, the smoke scripts, and the apps' own logs.

## Proof and skip reporting

- Name the tier for every claim: render, loopback, unit runner, or smoke.
- For a flow, cite the before and after states, not only the end state.
- A smoke proof cites its log lines and the unchanged display inventory, not only `PASS`.
- Report an entry point that could not be driven with the command tried and the unmet precondition. Never count a render as proof of a live action.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior, then exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-sensorium`, `Gotchas`. The driving section starts with `Preconditions:` and pairs each user action with an exact command and observable result.

## Features

- [Your Machines window](./your-machines.md) covers the viewer's list of paired machines, connecting, and renaming.
- [Pairing](./pairing.md) covers the host's pairing code and the viewer's add-a-machine flow.
- [Host setup window](./host-setup-window.md) covers the host's window: readiness, permissions, Tailscale, paired machines, last session.
- [Host screen session](./host-screen-session.md) covers seeing and controlling a host's own screen, the on-host indicator, ask-first, and display mode restore.
- [Session chrome](./session-chrome.md) covers what the viewer draws over a live session: status overlays, HUD, shortcut strip, refusal banners.
