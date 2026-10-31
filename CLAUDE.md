# CLAUDE.md (sandbox)

Everything of the Secure Sandbox that V2Mac downloads on demand: the helper app ("V2Mac Sandbox"),
the Swift VM agent and its protocol, the kernel config, the Debian rootfs and the base images.
Plan and every decision: `docs/PLAN.md` (read the section before changing what it describes).

- V2Mac.app holds no sandbox code beyond the entry sheet, the download and the link (`PLAN.md` §1–2).
  Anything else belongs here.
- SwiftPM; `V2MacCore` comes by path from `../app/Packages/V2MacCore`. CI checks the app out at the
  pinned tag beside this repo. Link message types live in the app package; change both together.
- Releases are independent of V2Mac's: every V2Mac takes the newest sandbox whose signed `pin.json` has its
  `SandboxLink.version`. Bump that version only for a link change neither side can absorb, and release the
  sandbox first (`docs/PLAN.md`, "Versions"). The sandbox repo needs the app's `UPDATE_SIGNING_KEY` secret.
- The VM has no network device and never sees server configs or keys.
- Kernel: own minimal config from the kernel.org LTS; rootfs: Debian 13 arm64 via `mmdebstrap`
  with `SOURCE_DATE_EPOCH`, packages only from Debian's signed archive.
- Testing follows `../app/CLAUDE.md`: dev build only, never touch the installed V2Mac or its core.
- On GitHub as `v2macapp/v2mac-sandbox` (private). Push when the user asks or CI needs to see it.
- `app.lock`: the app commit or tag CI checks out beside this repo. Bump it with every link change.
- Build: `Scripts/build-agent.sh`, `build-kernel.sh`, `build-rootfs.sh` (Docker, arm64; `PROXY=` for a
  download proxy), then `build-helper.sh` and `package.sh <url of files.json>` (per-file zips, patches from
  `out/patches/` and `files.json` into `out/release/`, plus `out/pin.json`). `make-patches.sh` is CI's (D2).
  Tag `vX.Y.Z` to release (`.github/workflows/release.yml`). `spikes/` is M0's throwaway code.
