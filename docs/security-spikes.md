# Security spikes (SECURITY-PLAN S4.8, S4.9)

S4.9 was built on 2026-11-07 as proposed, for any window app opened with a file (the user's choice); the
details are in `PLAN.md` §5 "Safe View". S4.8 is still a spike.

## S4.9 — File Viewer Safe View (review F22)

**Today.** File Viewer asks for one permission, `shared`. `sandbox.sh gui` mounts the whole Shared folder
(`/exchange/<id>`, virtiofs) read-write at `/root/Shared`, and the app joins the mini VM's network
(`--network container:vm-<id>`), so it has whatever exit that mini VM has. `start.sh` opens a picker on
Shared. `soffice --view` and the locked LibreOffice settings stop macros and link updates, but a document
exploit runs as the app: it can read or change every file in Shared and send them through the exit.

**What is already there to build on.**
- Permissions are optional per install: the install sheet has "Install Without These", so `shared` can
  become the advanced choice with no new UI.
- The Shared folder is already a per-mini-VM virtiofs share, so the helper can place one file in the VM
  without a new transport.
- `start.sh` already opens `$1` directly when it is given.

**Proposal (Safe View is what you get unless you grant Shared).**
1. **One file in, read-only.** The stub app (`~/Applications/V2Mac Sandbox/File Viewer — <vm>.app`) declares
   PDF and Office document types and takes "Open With" or a drop. The helper copies that file to
   `/exchange/<id>/.view-<token>/<name>` (hidden, made per launch, deleted when the app closes), and
   `sandbox.sh gui` mounts only that file, read-only, at `/root/<name>`, and passes it as `$1`. Without
   `shared`, nothing else of the Shared folder is mounted.
2. **Offline.** For an app launched with a file to view, `gui` uses `--network none` instead of the mini VM's
   network. This is independent of the mini VM's exit. File Viewer needs no sound, which is the only part of
   `gui` that uses that network.
3. **In-memory profile.** This is already the case (`HOME=/tmp/viewer`).
4. **Shared as advanced.** The `shared` permission stays and is explained as "open any file in Shared, read
   and write; a bad file could read the others". The picker loop runs only when Shared is mounted.

**Acceptance test** (the review's own): a harmless fixture, run with the viewer's rights in Safe View, tries
to read a second file placed in Shared, write into Shared, and open a TCP connection and a DNS lookup. All
four must fail. With `shared` granted, the read must succeed and the network must follow the mini VM's exit.

**Size.** M: stub document types and the open event (`SandboxStub`), a file field on the stub's pty-socket
line, the helper's copy and cleanup, `gui`'s mount and network choice, `start.sh`, the plugin text, and the
fixture test. The plugin template's API doesn't change (`$1` already exists).

**Open choice.** Should Safe View be a property of File Viewer only (a `"view": true` field in plugin.json),
or apply to any gui app opened with a file? Recommendation: any app opened with a file. It needs no new
manifest field, and opening an untrusted file offline is the safe default everywhere.

## S4.8 — Chromium's own sandbox (review F09)

(Results from the VM below.)
