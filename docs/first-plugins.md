# Next store plugins: Firefox, Telegram, SSH, File Viewer

Plan for workspace Phase 9. Everything is built and tested locally with V2MacDev and a throwaway store
key (`plugin-template/docs/plugin-api.md`, "Local testing"). Nothing is pushed, tagged or signed until
the user says so.

| Order | Plugin | Repo (to be created when the user asks) | Depends on | Sandbox change |
|---|---|---|---|---|
| 0 | Security updates in the base | `sandbox` | none | New base and release |
| 1 | Firefox ESR 0.1.0, Chromium 0.3.0 rebuild | `v2mac-firefox`, `v2mac-chromium` | 0 | None |
| 2 | SSH | `v2mac-ssh` | 0 | None |
| 3 | File Viewer + template | `v2mac-file-viewer` | 0 | None |
| 4 | Telegram | `v2mac-telegram` | 0 and spike T0 | None |

## 0. Security updates in the base (do this first)

**Problem.** `rootfs/build.sh` gives mmdebstrap only `trixie`, so `apt-get install` in a plugin's
`Containerfile` doesn't see `trixie-security`. Debian's versions for arm64 on 2026-11-01:

| Package | `trixie` | `trixie-security` |
|---|---|---|
| `firefox-esr` | 140.15.0esr | 153.6.0esr |
| `chromium` | 150.0.7871.181 | 156.0.8078.73 |
| `libreoffice-writer` | 25.2.3-2+deb13u6 | 25.2.3-2+deb13u8 |

Chromium 0.2.0 in the store and Linux Packages installs probably have this gap too. Check the version
inside the released Chromium archive to confirm.

**Tasks**
1. Add `deb http://deb.debian.org/debian-security trixie-security main` and `trixie-updates` as
   mmdebstrap sources in `rootfs/build.sh`. This fixes the root, every later base, plugin builds and
   Linux Packages together.
2. Build the base locally and confirm `apt-cache policy firefox-esr` picks the security version.
3. Release the sandbox when the user says; release CI adds the base to `bases.json`. Add the digest to
   `store/bases.json`.
4. Point each plugin's `base.txt` at it. Firefox's current `base.txt` names `v2mac-base-gui`, which
   isn't in `bases.json` and would fail store CI.

**Keeping plugins patched.** A plugin stays frozen at the versions it was built with. Rebuild and
resubmit Firefox, Chromium and File Viewer monthly, and sooner for a critical Debian advisory. Rebuild
the others when Debian patches them. The 60-day index-expiry issue is the backstop, not the schedule.

**Done when:** a plugin built on the new base contains the `trixie-security` version.

## 1. Firefox ESR

The plugin is written and staged, with no commits yet. It has telemetry off, exit-based time zone and
location, and WebRTC limited to the exit address.

**Tasks**
1. Move to the new base. It will now install ESR 153, so re-check every pref in `policies.json` against
   that version, especially `privacy.fingerprintingProtection.overrides`.
2. Test in V2MacDev:
   - browser leak tests: exit IP only, no local WebRTC address, exit time zone and location;
   - Persian input, sound, microphone prompt, clipboard, downloads to Shared;
   - reopening after a hard stop, and a second launch being refused.
3. Decide on exit changes after testing. Location is read at launch, so an exit change applies after
   reopening; the app must say so if it stays that way.
4. Rebuild Chromium as 0.3.0 on the new base with the same smoke test.
5. After the user's go-ahead: first commit, create the repo, tag, store PR, `REVIEW.md`. Add the
   "Private browsing" template with `prepare-index.py --template private-browsing "Private browsing" firefox`.

**Done when:** every test passes on a release build from the real store, and on a second Mac.

## 2. SSH

Every mini VM has a built-in Terminal and the root already includes `openssh-client`, but that Terminal
gets no permissions. So this plugin's whole value is using the Mac's ssh-agent keys through the mini
VM's exit. Keep it that small. A separate Terminal plugin isn't needed.

**Design**
- `display: pty`, permission `ssh-agent` only. The `Containerfile` adds only `start.sh`.
- `start.sh` lists the `Host` entries of `~/.ssh/config`, asks for a host or `user@host`, runs `ssh`, and
  returns to the prompt on exit. An empty answer gives a plain shell, for editing the config.
- Force `-o ForwardAgent=no` on every connection, so a remote server can't use the Mac's keys.
- `known_hosts` and `config` live in the mini VM's home; on a Disposable VM they vanish with it, which
  the first prompt states.

**Tests**
- Agent prompt appears at first use; Deny fails cleanly; agent access ends when the app closes.
- The server sees the exit IP; host key changes are refused; resize and Ctrl-C work.
- The helper's `SSH_AUTH_SOCK` when V2Mac is opened from Finder, with Apple's agent and with a third-party
  agent such as 1Password. `Pty.swift` reads only the helper's own environment, and a third-party
  socket set in a shell profile won't reach it. If that fails, fix it in the helper or document it.
- Exits that block port 22: the error must read as a connection problem, not a key problem.

**Left out of v1:** file transfer (`pty` apps have no Shared), port-forward UI, keys stored in the VM.

**Done when:** a user connects with a Mac key, with an approval prompt, and the server logs the exit IP.

## 3. File Viewer

Opens an untrusted document without running its parser on the Mac.

**Design**
- `display: gui`, permission `shared` only. No sound, microphone or clipboard.
- Packages: `evince` for PDF, and `libreoffice-writer`, `-calc`, `-impress` with `--no-install-recommends`.
  No Java.
- `start.sh` loop: a `zenity` file picker at `~/Shared` (zenity is in the root), then Evince for PDF or
  `soffice --view` for the rest, then back to the picker.
- `HOME` and LibreOffice's `-env:UserInstallation` are under `/tmp`, so nothing a document does to the
  profile survives closing the app.
- Lock LibreOffice in a system-wide `.xcu`: macros off and not user-enablable, no link or OLE updates, no
  remote images, no update check. Confirm the path and settings on Debian's package while building.
- Template `file-viewer` creates a mini VM that holds only this app.

**What it doesn't protect, stated in the description and `securityNotes`**
- `~/Shared` is mounted read-write, so a successful exploit can read and change everything in that mini
  VM's Shared folder. Keep only files to view there. Files it writes are quarantined on the Mac.
- The mini VM still has a network path through its exit, so an exploit could send those files out. The
  Mac's own IP and files stay out of reach. The plugin can't turn this off.

For that reason it's named "File Viewer", not "Safe". A later offline mini VM (a blackhole exit in the
helper) would close the network gap, and a `disposable` field on templates would wipe the whole home.
Both need a sandbox release, so neither is part of v1.

**Tests**
- Test documents with a macro, a remote image and an external link: no macro runs and no request leaves.
- A profile change doesn't survive reopening; the home stays empty apart from Shared.
- PDF, DOCX, XLSX, PPTX and Persian right-to-left text render correctly.
- Measure the download. If LibreOffice's size is too much, ship a PDF-only version first.

**Done when:** those test documents behave as above on a release build.

## 4. Telegram

Highest demand and highest risk. Only `trixie-backports` has it for trixie arm64, at 5.7.2, and `sid` has
the same upstream version, so Debian's copy may be well behind Telegram's.

**Spike T0: decide before making a repo.** Build a local image from backports and check:

| Check | Pass |
|---|---|
| Starts without a GPU under sway's software renderer | Opens every time, no crash loop |
| Login with today's Telegram servers | QR and phone login work, no forced-update block |
| Scrolling chats, playing video and stickers | Usable at 2× on a typical Mac |
| Persian text and input | Correct, including right-to-left |
| Voice call through the exit | Connects both ways on at least two exit types |
| Reopen after a hard stop | Same session, no "already running" error |
| Age of the build | No known unpatched critical flaw in 5.7.2 that isolation doesn't cover |

**If any of the first two or the last fail, drop Telegram.** Debian's archive is the store's rule, and I
didn't find an official arm64 Linux build to use instead. Building from source in CI is too much to
maintain for one app. It stays installable through Linux Packages at the user's own judgement.

**Design if it passes**
- `display: gui`; permissions `clipboard`, `shared`, `sound`, `microphone`.
- In one `RUN`: add the backports source, `apt-get install -t trixie-backports telegram-desktop`, then
  remove the source and apt lists.
- `start.sh` as Chromium's: `flock` on the data folder, plus any Qt setting T0 shows is needed.
- `securityNotes` names the Debian version and that the client doesn't update itself.
- No camera in API v1, so there are no video calls with your own camera. The description says so.

**Done when:** T0 passes, and two mini VMs hold two different accounts on two exits at once.

## Release for each plugin

These need the user's instruction and the user's signature:

1. Add the project to the workspace `CLAUDE.md` table and `Scripts/clone-all.sh`, with its own `CLAUDE.md`
   and from `plugin-template` (0BSD).
2. Create the repo, tag, let release CI build it, and add `submissions/<id>.json` by PR.
3. Review with `store/REVIEW.md`, then `prepare-index.py --add`, then the user signs and pushes.
4. Update the wiki pages (en, fa, zh, ru) and the site's Secure Sandbox page.
