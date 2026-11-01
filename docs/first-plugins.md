# Next store plugins: Firefox, Telegram, SSH, File Viewer

Plan for workspace Phase 9. Everything is built and tested locally with V2MacDev and a throwaway store
key (`plugin-template/docs/plugin-api.md`, "Local testing"). Nothing is pushed, tagged or signed until
the user says so.

**Decision (2026-11-01):** the store verifies a recipe and Debian delivers the app. A recipe is a plugin with
`api: 2` and a `packages` list. Its archive holds only settings and scripts; `apt` installs the packages and
keeps them updated, so a security fix needs no new tag, CI run or signature. V2Mac tests when Debian moves to a new
major version. "Verified" for a recipe means "V2Mac reviewed the settings and tested a version", not "these exact bytes".

| Order | Plugin | Repo (to be created when the user asks) | Depends on |
|---|---|---|---|
| 0 | Security sources, recipes, automatic updates | `sandbox`, `store`, `plugin-template` | none |
| 1 | Firefox ESR 0.1.0, Chromium 0.3.0 as recipes | `v2mac-firefox`, `v2mac-chromium` | 0 |
| 2 | SSH (stays a plain plugin) | `v2mac-ssh` | base from 0 |
| 3 | File Viewer + template, as a recipe | `v2mac-file-viewer` | 0 |
| 4 | Telegram, as a recipe | `v2mac-telegram` | 0 and spike T0 |

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

**Built in `rootfs/build.sh`:** the root now has `trixie-updates` and `trixie-security` sources, which also fixes
Linux Packages. It needs a sandbox release, and the new base's digest in `store/bases.json` and each `base.txt`.
Firefox's current `base.txt` names `v2mac-base-gui`, which isn't in `bases.json` and would fail store CI.

**Recipes and updates, as built**
- `packages` in `plugin.json`, api 2. Older sandboxes hide these apps. Store CI and `REVIEW.md` check them.
- Install: the settings archive loads as usual, `pkg-install` installs each package into the shared package
  root, and `pkg-link` marks the app so its files sit on that root.
- Update: the helper calls `pkg-upgrade` when the gateway is ready and every two minutes. It answers at once;
  the work runs detached, because the agent answers one request at a time and apps must keep opening.
- A daily check compares against Debian's lists. Any update is applied to a copy of the root, so a failure
  changes nothing and retries about three hours later. The copy swaps in once no app runs on the packages.
- A new base (dpkg's status file changed) makes the root anew from what was asked for, so the packages' copy of
  dpkg's status can't hide the new base's. Upgrading an existing install does this once.
- The VM stays up while an upgrade runs. "Update Debian Apps Now" is in the store's More menu.
- `Scripts/test-recipes.py` runs install, upgrade, waiting for open apps and the rebuild in a real VM.

**Known limits**
- A bad Debian update can't be rolled back, since Debian's archive keeps no old versions in the normal suites.
- Installing a Debian package or recipe still changes the shared root in place, as Linux Packages always has.
- Updates use the first mini VM with a working exit, preferring one that has Debian apps.
- A new base re-downloads every Debian app once.

**Done when:** a sandbox release carries this and `test-recipes.py` passes on it.

## 1. Firefox ESR

The plugin is written and staged, with no commits yet. It has telemetry off, exit-based time zone and
location, and WebRTC limited to the exit address.

**Tasks**
1. It is a recipe now, and `start.sh` warns once when Debian brings a major version other than `tested`. Move to the
   new base and check every pref in `policies.json` against ESR 153, especially
   `privacy.fingerprintingProtection.overrides`.
2. Test in V2MacDev:
   - browser leak tests: exit IP only, no local WebRTC address, exit time zone and location;
   - Persian input, sound, microphone prompt, clipboard, downloads to Shared;
   - reopening after a hard stop, and a second launch being refused.
3. Decide on exit changes after testing. Location is read at launch, so an exit change applies after
   reopening; the app must say so if it stays that way.
4. Release Chromium 0.3.0, now a recipe, on the new base with the same smoke test. Installed copies stay frozen until users
   take that update.
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
- A recipe, since it opens hostile files and needs patched parsers. Packages: `evince` for PDF, and `libreoffice-writer`, `-calc`, `-impress` with `--no-install-recommends`.
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
- After a Debian update, the locked LibreOffice settings still apply.

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
- Recipes install from the root's sources, which don't include backports. Telegram needs either backports added
  for this package alone or a plain plugin with frozen layers: T0 decides. Debian's updates won't solve its age.
- `start.sh` as Chromium's: `flock` on the data folder, plus any Qt setting T0 shows is needed.
- `securityNotes` names the Debian version and that the client doesn't update itself.
- No camera in API v1, so there are no video calls with your own camera. The description says so.

**Done when:** T0 passes, and two mini VMs hold two different accounts on two exits at once.

## Release for each plugin

These need the user's instruction and the user's signature. After that, Debian's updates need neither:

1. Add the project to the workspace `CLAUDE.md` table and `Scripts/clone-all.sh`, with its own `CLAUDE.md`
   and from `plugin-template` (0BSD).
2. Create the repo, tag, let release CI build it, and add `submissions/<id>.json` by PR.
3. Review with `store/REVIEW.md`, then `prepare-index.py --add`, then the user signs and pushes.
4. Update the wiki pages (en, fa, zh, ru) and the site's Secure Sandbox page.
