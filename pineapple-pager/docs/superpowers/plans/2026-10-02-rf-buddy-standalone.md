# RF-BUDDY v1.1 — Standalone Payload Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make RF-BUDDY a fully independent payload that works on the real Pager: it must find its tools, own the screen and buttons while running, beep on its own, offer its own remote viewer, and never read, write, kill, or reconfigure anything belonging to DEFCON Defense or any other payload.

**Why (on-device findings, 2026-10-02):**
- The Pager starts payloads with **no exported PATH**. Bash gives the script a default PATH internally, but children (the Go binary) inherit none, so `exec("_pineap")` failed: `exec: "_pineap": executable file not found in $PATH`.
- The stock UI process `pineapple` keeps drawing over the framebuffer, so RF-BUDDY's screen never appeared.
- `LOG`, `RINGTONE`, `VIBRATE`, `ERROR_DIALOG` (and `PINEAPPLE_*`) are HTTP calls to the stock UI (`HAK5_API_POST` → `/tmp/api.sock`, owned by `pineapple`). They hang while `pineapple` is frozen. `_pineap` talks to `pineapd` via `/tmp/pineap_sock` and is unaffected.
- The buzzer is exposed directly: `/sys/class/leds/buzzer/{brightness,max_brightness=255,frequency (currently 523),volume (currently 0)}`.
- While `pineapple` is frozen, the stock Virtual Pager (:1471) hangs.
- RF-BUDDY v1.0 interfered with DEFCON Defense: it overwrote `/pineapple/ui/defcon-ui-bridge.js` and `index.html` (with the older 4.3.1 bridge), served on DEFCON's port 1472, ran `killall hcitool`, and deploy.sh moved/replaced DEFCON Defense (downgrading the device's 4.20 to 4.9). DEFCON 4.20 lives on branch `claude/defcon-defense-exit-bug-f83441` at `src/user/general/DEFCON_DEFENSE`.

**Independence rules (bind every task):**
- RF-BUDDY files live only in `src/user/defcon/RF-BUDDY/` (installed `/root/payloads/user/defcon/RF-BUDDY/`). Runtime state only in `/tmp/rf_buddy*` and `/root/loot/rf_buddy/`.
- Never touch: `/pineapple/ui/*`, any other payload directory, DEFCON loot, port 1472/1473, `killall`/`pkill` of shared tool names.
- Remote viewer: RF-BUDDY's own page on **port 1474**.
- The only shared-system actions allowed, all reverted on every exit path: freeze/resume the stock `pineapple` process; `_pineap EXAMINE CHANNEL/CANCEL`; exclusive grab of `/dev/input/event0` (released when the fd closes); buzzer pulses with saved/restored `frequency` and `volume`.
- No hak5 API commands (`LOG`, `ERROR_DIALOG`, `RINGTONE`, `VIBRATE`, `PINEAPPLE_*`, …) between freezing and resuming `pineapple`.
- In this branch, DEFCON Defense returns to exactly main's state (`src/user/general/DEFCON_DEFENSE`); moving it is that payload's own future work.

Commands run from `pineapple-pager/`; `UI` = `src/user/defcon/RF-BUDDY/ui`. Go: `cd UI && go test -mod=vendor -race ./...` and MIPS vet `CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go vet -mod=vendor ./...`. Full suite: `bash tests/run_tests.sh` → `ALL TESTS PASSED`. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never contact the device (172.16.52.1); deployment is done by the controller after review.

---

### Task A: Return DEFCON Defense to main's layout

- [ ] `git mv src/user/defcon/DEFCON-DEFENSE src/user/general/DEFCON_DEFENSE`, then restore every DEFCON-related file and path to main: `git checkout main -- src/user/general/DEFCON_DEFENSE tests/test_rf_guard.sh tests/test_unified_payload.sh`.
- [ ] `build.sh`: restore the DEFCON block to main's lines (`cp -R "$HERE/src/user/general/DEFCON_DEFENSE" "$OUT/user/general/"`, the pcap lib copy, `ui/build.sh` → `$OUT/user/general/DEFCON_DEFENSE/defcon-ui`, `rm -rf …/ui`, `chmod 755 …/defcon-ui`). Keep `"$OUT/user/defcon"` in the mkdir list. RF-BUDDY block: keep, but **delete** the line copying DEFCON's `virtual-pager-bridge.js` into RF-BUDDY.
- [ ] `tests/test_build.sh`: DEFCON paths back to `user/general/DEFCON_DEFENSE` (as on main); remove the `[ ! -e "$OUT/user/general/DEFCON_DEFENSE" ]` assertion and the "RF-BUDDY reuses the DEFCON-DEFENSE Virtual Pager bridge" assertion and the `user/defcon/RF-BUDDY/virtual-pager-bridge.js` file-list entry; add `[ ! -e "$OUT/user/defcon/RF-BUDDY/virtual-pager-bridge.js" ]` asserted ("RF-BUDDY ships no shared bridge").
- [ ] `tests/test_package.sh`: DEFCON assertion back to `./user/general/DEFCON_DEFENSE/defcon-ui`.
- [ ] `README.md`: DEFCON paths/names back to main's wording (`user/general/DEFCON_DEFENSE`, `` `DEFCON_DEFENSE` ``); RF-BUDDY row/section stay.
- [ ] Verify `git diff main -- src/user/general/DEFCON_DEFENSE` is empty; full suite passes; commit `revert(pager): keep DEFCON Defense at user/general as on main`.

### Task B: Go binary — PATH, input grab, buzzer tick, own viewer

Files: `UI/main.go`, `UI/display.go`, new `UI/grab_linux.go`, `UI/grab_other.go`, `UI/buzzer.go`, `UI/viewer.go` (+ tests).

1. **Default PATH.** `func ensurePath()` in main.go: if `os.Getenv("PATH") == ""`, `os.Setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")`. Call first thing in `main()`. Test: with `t.Setenv("PATH", "")`, `ensurePath()` sets the default; a non-empty PATH is left unchanged.
2. **Exclusive buttons.** `grab_linux.go` (`//go:build linux`): `func grabInput(fd int) error` issuing EVIOCGRAB (`_IOW('E', 0x90, int)`; request `0x40044590`, but `0x80044590` when `runtime.GOARCH` is mips/mipsle/mips64/mips64le) via `syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, 1)`. `grab_other.go` (`//go:build !linux`): no-op. In `readButtonDevice`, after opening, call `_ = grabInput(int(f.Fd()))` (best effort; the kernel drops the grab when the fd closes). Test (host): `grabInput(-1)` returns nil on non-Linux; MIPS vet compiles the Linux file.
3. **Buzzer tick (replaces the payload.sh tick loop).** `buzzer.go`: `type Buzzer struct{ dir string; freq, vol int; savedFreq, savedVol string }`; `OpenBuzzer(dir string, freqHz, volume int) (*Buzzer, error)` reads and saves `frequency` and `volume` (error if `brightness` is missing); `(*Buzzer).Beep(d time.Duration)` writes `frequency`=freq, `volume`=vol, `brightness`=`max_brightness` value, sleeps d, writes `brightness`=0; `(*Buzzer).Close()` writes brightness 0 and restores the saved frequency and volume. All writes are plain file writes (no shell). In main.go add flags `--buzzer-dir` (default `/sys/class/leds/buzzer`), `--tick-freq-hz` (default 2000), `--tick-volume` (default 128), and a `ticker` goroutine (joined by the existing `workers` WaitGroup) that each loop reads the current interval from an atomic value set by the main loop (`view.TickInterval(engine.Snapshot())`), beeps 30 ms when interval > 0, then sleeps the interval (or 250 ms when 0), honouring ctx. `defer buzzer.Close()` registered so it runs after workers are joined. Remove the `--tick-file` flag and `tickWriter` (update tests accordingly). If `OpenBuzzer` fails, run without a tick (log the reason in session.txt as `buzzer: <err>`). Tests with a temp dir containing fake `brightness`, `max_brightness` (255), `frequency` (523), `volume` (0): Beep leaves brightness 0 and sets freq/vol; Close restores 523/0.
4. **Own viewer page on :1474.** Change the `--virtual-listen` default to `:1474`. In `display.go` `mirror.handler`, add `GET /` serving a self-contained HTML page (no external assets): title "RF-BUDDY", an `<img>` that long-polls `/screen.png?wait=1&rev=<etag>` (same contract as the existing endpoint; on error retry after 1 s), scaled to fit width, and six buttons (UP, DOWN, LEFT, RIGHT, B, A — B left of A) that `POST /button?name=<X>`; keyboard arrows/Enter/Escape map to the same. Keep `/screen.png`, `/button`, `/health` unchanged. Test: `GET /` returns 200, `Content-Type: text/html`, and the body contains `/screen.png` and `/button`.
- [ ] TDD each item; Go `-race` tests + MIPS vet + `bash UI/build.sh "$TMPDIR/rf-buddy-ui"` pass; previews still render (9). One commit per item.

### Task C: payload.sh — exported PATH, stock-UI freeze, no shared resources

Edit `src/user/defcon/RF-BUDDY/payload.sh`, `tests/test_rf_buddy_payload.sh`.

1. Near the top (after the CONFIG block): `export PATH="${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"` plus a comment that the Pager starts payloads without an exported PATH.
2. CONFIG: remove `TICK_RINGTONE`; add `TICK_FREQ_HZ=2000` and `TICK_VOLUME=60` (comment: buzzer pitch and loudness for the lock-on tick, 0-100); pass `--tick-freq-hz` and `--tick-volume`; remove `--tick-file`.
3. Delete `install_virtual_pager_bridge`, `UI_BRIDGE_SOURCE`, `tick_once`, `tick_loop`, `TICK_FILE`, `TICK_PID`, and the `killall`/`hcitool` lines in cleanup (the Go binary stops its own hcitool with SIGINT and scan-disable).
4. Stock UI freeze (own implementation, own names):
   - `stock_ui_freeze()`: `pids="$(pidof pineapple 2>/dev/null)"`; if empty return 0; `kill -STOP $pids` (on failure return 1); `FROZEN_PIDS="$pids"`.
   - `stock_ui_resume()`: if `FROZEN_PIDS` non-empty, `kill -CONT $FROZEN_PIDS`, clear it; then if `pidof pineapple` finds nothing and `/etc/init.d/pineapplepager` exists, start it. Idempotent.
   - In `rf_buddy_main`: after `LOG` (the last hak5 API call), start the UI in the background with `--ready-file`, wait up to 5 s (poll every 0.05 s) for the ready file while the UI is alive, then `stock_ui_freeze`. Then `wait` for the UI.
   - Cleanup order (EXIT/INT/TERM/HUP and normal return): stop/reap the UI (bounded: TERM, then after 3 s KILL), **then** `stock_ui_resume` immediately, then `release_channel`, remove run files, release the lock. No hak5 API command is called between freeze and resume.
5. Tests: stub `pidof` (prints a fake pid when `FAKE_PINEAPPLE_PID` is set) and `kill` (records `KILL\t$*`, delegating real signals for numeric pids other than the fake one); assert a full run with the fake UI records `KILL -STOP <fakepid>` after the UI wrote its ready file and `KILL -CONT <fakepid>` before `PINEAP EXAMINE CANCEL`; assert no `LOG`/`ERROR_DIALOG` call is recorded between the STOP and CONT lines; assert the fake UI saw a non-empty PATH (fake UI writes `PATH=$PATH`) even when the payload is run with `env -i` (keeping only the test's stub-function exports needed); assert payload.sh contains no `pineapple/ui`, `bridge`, `killall`, `1472`, or `RINGTONE`. Update the fake UI to write the ready file. Keep the existing lock/refusal/cleanup assertions (adjusted for removed tick/killall).
- [ ] TDD; full suite passes; commit.

### Task D: deploy.sh — install RF-BUDDY only

1. Stream only `library/user/defcon/RF-BUDDY` (guard: that dir and `rf-buddy-ui` must exist). Remote: stage to `user/defcon/RF-BUDDY.new`, back up an existing `user/defcon/RF-BUDDY` to `<backup root>/<ts>/RF-BUDDY`, swap in, `chmod 755 rf-buddy-ui`, `mkdir -p user/defcon` first. Register `user/defcon` via the existing `payloads.@directories[0].payloaddir` logic. Remove all `general/DEFCON_DEFENSE` handling and any reference to other payloads.
2. Tests: update `tests/test_deploy.sh` (library fixture with only RF-BUDDY; execution test asserts a pre-existing `user/general/DEFCON_DEFENSE` and `user/defcon/OTHER` are untouched byte-for-byte; RF-BUDDY backup created; uci registered once). Assert the remote script contains no `DEFCON`.
3. README Install text: deploy installs RF-BUDDY only.
- [ ] TDD; full suite passes; commit.

### Task E: Docs

Update `docs/superpowers/specs/2026-10-01-rf-buddy-design.md` (layout: DEFCON stays at user/general; independence rules; PATH export; stock-UI freeze/resume and input grab; buzzer tick with TICK_FREQ_HZ/TICK_VOLUME; viewer at http://172.16.52.1:1474; stock Virtual Pager unavailable while RF-BUDDY runs; deploy installs RF-BUDDY only), `src/user/defcon/RF-BUDDY/README.md` (viewer URL, tick settings, "while RF-BUDDY runs the stock menu and Virtual Pager are paused; they return when you press B"), root `README.md` RF-BUDDY section accordingly. Commit.
