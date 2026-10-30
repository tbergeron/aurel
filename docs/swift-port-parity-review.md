# Swift port parity review

Reviewed October 29, 2026. Findings 1–7 compare behavior present in both the original Atticus UI and this native Aurel port. Findings 8–14 are a subsequent general bug review of the current codebase, including capabilities added in this fork. Deliberately removed features (meetings, Devin, Pi, and custom servers) are excluded from both passes. This document records findings and proposed corrections; application code was not changed by the review.

## Baselines and method

- Original: [SaarthurR/atticus-mac at `207e520c7bab330b13220c3901492568ca2ef271`](https://github.com/SaarthurR/atticus-mac/tree/207e520c7bab330b13220c3901492568ca2ef271).
- Local: branch `native-agents-and-local-models`, HEAD `9a4e5b4`, including the staged, unstaged, and untracked implementation files present during this review.
- The upstream Git tree was checked through GitHub. Its files match the local ancestor `1b2bfda` except the latest two-line Swift read-aloud change and its test additions. The reconstructed upstream `Atticus.swift` was verified against GitHub blob `2ef653e30581f90f9ae60b4c74c1f57060dc9f94`.
- Compared the original HTML/JavaScript screens and bridges with `Box.swift`, `Settings.swift`, `Onboarding.swift`, `Answer.swift`, `Orb.swift`, and the native Agents/shelf implementation in `Aurel.swift`. Also examined the normalized Swift/Python diffs, packaging, tests, and unchanged helper boundaries to distinguish port regressions from intentional differences. After normalizing the rebrand, 267 top-level Python definitions are structurally unchanged; the shared Python helper implementation is largely preserved.
- Used source tracing, compiled Swift model probes, and an offscreen native answer-rendering probe. No application source was changed. Device permissions, real microphone use, real agent accounts, VoiceOver, and interactions with the installed app were not exercised.

## Findings

### 1. [P2] Successful agents are falsely shown as needing a connector

**Status:** fixed in the current source by a concurrent edit during the subsequent general review. All three paths now require a nonempty string. The reproduction below describes the original review snapshot; the updated UI has not been exercised interactively.

**Local:** [Aurel.swift:4610](/Users/anon/Workshop/atticus-mac/Aurel.swift:4610), [Aurel.swift:5026](/Users/anon/Workshop/atticus-mac/Aurel.swift:5026), [Aurel.swift:5534](/Users/anon/Workshop/atticus-mac/Aurel.swift:5534).

The supervisor includes `missingConnector: ""` in an ordinary successful result. The original JavaScript checks whether that string is truthy before displaying a connector warning or button. The native port checks whether the key exists or casts to `String`, which also succeeds for an empty string.

Consequently, an ordinary completed agent can display `Connect in Claude` as its shelf status, a `Needs . Connect it in Claude, then retry.` problem panel in its detail view, and an unnecessary Connect button. This is a UI translation bug; it does not indicate a missing connection.

**Reproduction:** construct `AgentRow(["id": "x", "status": "done", "result": "Finished normally.", "missingConnector": ""])`. The compiled native model returns `Connect in Claude`; both view conditions evaluate true.

**Original:** [agents.html:163](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/agents.html#L163), with the corresponding truthiness guards at lines 242 and 364.

**Correction:** use a single nonempty-string predicate for all three native paths.

### 2. [P2] Editing a saved rule or profile fact and clicking away loses the edit

**Local:** [Settings.swift:499](/Users/anon/Workshop/atticus-mac/Settings.swift:499), [Settings.swift:1118](/Users/anon/Workshop/atticus-mac/Settings.swift:1118), [Settings.swift:1164](/Users/anon/Workshop/atticus-mac/Settings.swift:1164).

The original rule and profile inputs save through DOM `onchange`, which runs when a changed field loses focus. The shared native `Field` invokes its callback only through `.onSubmit`. RuleRow and FactRow hold their edits in local `@State`; neither commits on focus loss or disappearance. They also have no explicit save button.

**Reproduction:** edit an existing rule or About you fact, then click a different Settings section without pressing Return. Reopen Memory: the old saved value remains. This also affects deleting a rule by clearing its text and clicking away.

**Evidence:** source-confirmed missing save path; the live focus transition was not driven on the installed app.

**Original:** [settings.html:736](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/settings.html#L736) and [settings.html:799](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/settings.html#L799).

**Correction:** preserve commit-on-blur for existing rows and suppress duplicate writes when Return already committed the same value.

### 3. [P2] Links inside answer headings and tables cannot be opened

**Local:** [Answer.swift:331](/Users/anon/Workshop/atticus-mac/Answer.swift:331), [Answer.swift:377](/Users/anon/Workshop/atticus-mac/Answer.swift:377).

`inlineText` identifies link runs, but a link becomes actionable only when the renderer collects its rectangles and supplies a `.link` hit target. `para` installs that machinery. The heading renderer and table cells use `WordFade` without a `LinkRects` instance and never register a link target.

The text can therefore look like a link while clicking it falls through to the surrounding answer behavior. This affects both regular answers and the completed-agent card in the box, which share AnswerView. The separate Agents window uses a different renderer.

**Reproduction:** render either `# [Open](https://example.com)` or a Markdown table containing `[Open](https://example.com)` in the box. An offscreen rendering probe found no actionable link for either. A normal paragraph link was a positive control and successfully emitted the `link` message.

**Original:** [orbs.js:931](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/orbs.js#L931) creates actual anchors; heading and table parsing retain them.

**Correction:** share the link-rectangle collection and activation code across paragraph, heading, and table text.

### 4. [P2] Several action controls lost their keyboard/accessibility activation paths

**Local:** [Settings.swift:440](/Users/anon/Workshop/atticus-mac/Settings.swift:440), [Settings.swift:610](/Users/anon/Workshop/atticus-mac/Settings.swift:610), [Onboarding.swift:177](/Users/anon/Workshop/atticus-mac/Onboarding.swift:177), [Box.swift:1211](/Users/anon/Workshop/atticus-mac/Box.swift:1211), [Box.swift:1522](/Users/anon/Workshop/atticus-mac/Box.swift:1522).

The original screens use actual HTML buttons, selects, and anchors. Several native replacements are Text/HStack views with a mouse gesture or a `.boxTarget` callback, without a Button, keyboard focus/activation handling, or an accessibility press action. Examples include Settings `Btn`, the Settings sidebar, onboarding `PillButton`, and the box's choice/action controls. Settings Btn and onboarding PillButton are driven specifically by DragGesture completion.

There is also a concrete missing keyboard flow: the original composer handles ArrowDown by focusing the first choice; the choices card handles ArrowUp/ArrowDown and Return on an expanded picture choice. The port's composer handles numeric selection and previous-question ArrowUp, but does not implement those other transitions, and Choice is not a focusable Button.

**Reproduction to validate with assistive tools:** enable macOS keyboard navigation, attempt to reach and activate Change Shortcut or an onboarding Continue button, and try ArrowDown from an empty composer into a choices card. Test VoiceOver activation of the gesture-only action buttons as well.

**Evidence:** source-confirmed missing native interaction paths; keyboard navigation and VoiceOver were not exercised in the installed app. The native Switch and segmented controls do include explicit accessibility actions, so this finding is limited to the controls above, not all native UI.

**Original:** [ui.html:520](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/ui.html#L520) and [ui.html:1152](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/ui.html#L1152).

**Correction:** keep the current visual styles on real Button/Picker/Toggle controls where practical; add the missing choice-focus behavior and accessible labels/actions for custom hit targets.

### 5. [P2] An unanswered Help Improve card prevents a later choices card from expiring

**Local:** [Box.swift:516](/Users/anon/Workshop/atticus-mac/Box.swift:516).

The choices timeout tests `self.liveCard({ _ in true })?.id == c.id`. `liveCard` returns the first live card across all turns, not the choices card being timed. An earlier Help Improve card can remain when a new turn starts, so that earlier card makes the guard false even though the choices card is still active.

The original timeout checks the specific choices DOM node's `isConnected` status, independent of other cards. In the port, the backend can stop waiting after 110 seconds while the UI still presents the unanswered card. `listen` also does not remove that stale pick, and `respond` continues to route composer input to it.

**Reproduction:** show an Improve card, leave it unanswered, start another turn, and show a pick. The compiled BoxModel probe confirms that the exact expiry guard is false in this state. The full 105-second timeout was not waited out.

**Original:** [ui.html:1168](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/ui.html#L1168).

**Correction:** find the still-live pick by its own ID instead of comparing it with the first arbitrary card.

### 6. [P3] Starting a follow-up changes the previous answer's elapsed time to zero

**Local:** [Box.swift:190](/Users/anon/Workshop/atticus-mac/Box.swift:190), [Box.swift:366](/Users/anon/Workshop/atticus-mac/Box.swift:366).

The elapsed result lives in the model-wide `clockFinal` until a later turn starts. `listen` clears that value. The next `clockBegin` then tries to freeze older turns by calling `clockText(0)`, after the old start, held time, and final string have all been cleared. This stores `0.00 s` in the prior turn.

**Reproduction:** the actual compiled BoxModel displayed `2.00 s` after one answer and stored `0.00 s` for that same answer after the next listen/think sequence. The original leaves each old timer's rendered text intact.

**Original:** [ui.html:717](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/ui.html#L717).

**Correction:** store the completed elapsed string on its Turn when stopping that turn's clock, before clearing shared clock state.

### 7. [P3] The listening orb no longer speeds up with microphone level

**Local:** [Box.swift:96](/Users/anon/Workshop/atticus-mac/Box.swift:96), [Box.swift:298](/Users/anon/Workshop/atticus-mac/Box.swift:298), [Onboarding.swift:293](/Users/anon/Workshop/atticus-mac/Onboarding.swift:293), [Orb.swift:437](/Users/anon/Workshop/atticus-mac/Orb.swift:437).

The level message computes `BoxModel.boost`, and OrbView still multiplies its animation time by its own `boost`. The two values are not connected: `orbBoost` is declared but never assigned, and OrbRep updates only state/running. Consequently OrbView keeps its default boost of 1, while the original loop multiplies by the current microphone-dependent boost. The orb's scale and the dictation wave still react, so this is a smaller animation fidelity regression.

**Evidence:** source-confirmed disconnected property. This does not affect recognition or sending the request.

**Original:** [ui.html:446](https://github.com/SaarthurR/atticus-mac/blob/207e520c7bab330b13220c3901492568ca2ef271/ui/ui.html#L446), with the level update at line 895.

**Correction:** pass the current boost through OrbRep to OrbView.

## Verification and limits

The agent-status, old-timer, and choices-expiry-predicate probes ran against compiled Swift. The link probe rendered the native box in an unshown fixture window, verified a normal paragraph link as a positive control, and found no heading/table activation. It did not click or modify the installed app.

Session evidence is in `/tmp/atticus-parity-review/`: `agent-probe.swift`, `model-probe.swift`, `link-probe.swift`, the original snapshot, normalized diffs, and test logs. These are temporary review artifacts.

- `python3 -m unittest discover -s tests -t .`: **839 tests; 722 passed, 11 failed, 106 skipped** in 713.141 seconds. The rerun had access to Swift caches and loopback fixture servers, with the host UI guard enabled. The earlier restricted run was obstructed by sandbox permissions and is not used as a product verdict.
- Ten failures are native agent fixture compilation failures: the extracted AgentPanels implementation now uses `Dock.show` and `Dock.update`, but `tests/test_agents_native.py` does not supply Dock. They do not establish ten agent behavior bugs; those checks never reached their assertions.
- The remaining failure was a live-worker fixture missing the new `endWhenQuiet` dependencies. An unrelated concurrent edit to `Aurel.swift` and its test harness arrived during the run. That edit was inspected and the finding references were updated. A focused recheck compiled the updated fixture successfully, then skipped its execution under the host UI guard (1 test, 1 skipped). Its live behavior remains unverified.
- The suite's full-application Swift typecheck passed. The 106 skips include guarded native/window-driving checks; these paths are not validated by the passing count.
- Compared **81 orb frames** against the original JavaScript: nine states, sizes 20/32/64, and times 0/1.25/9. Point sets and line geometry agree within `1e-6`. Three time-zero frames differ in ordering of equal/nearly equal-depth dots, so this is geometry validation, not a claim of pixel-identical compositing. The separate missing microphone-speed connection in finding 7 remains.

The existing tests do not cover the specific regressions above. Passing model and source checks should not be taken as proof of interactive parity.

## General bug review

This pass examined the current native UI, Swift process/model lifecycle, Python routing and tool execution, agents, dictation/audio, persistence, routines, browser/accessibility helpers, and installation/update paths. These findings do not depend on a difference from upstream. Concurrent edits were preserved, and the new findings were checked again against the latest available source before being recorded. Severity denotes user impact, not an implementation order.

### 8. [P2] The installer always skips migration of existing Atticus data

**Local:** [build.sh:69](/Users/anon/Workshop/atticus-mac/build.sh:69), [build.sh:82](/Users/anon/Workshop/atticus-mac/build.sh:82).

The installer creates `~/.config/aurel` before the migration conditional, which requires that same destination not to exist. Consequently, upgrading an existing Atticus installation never moves its settings, chats, models, and other saved data into Aurel. Later cleanup retires the old app and routine jobs, while the new app starts with an empty configuration. The old data remains on disk, so this is a broken upgrade rather than deletion of the original data. The updater's early `AUREL_NO_RESTART` exit also precedes migration.

**Reproduction:** execute the exact directory-creation and migration statements under a temporary HOME containing only `.config/atticus/settings.json`. The old settings remain, but `.config/aurel/settings.json` does not exist.

**Correction:** migrate before creating the destination and before the updater's early exit. Handle an existing destination without overwriting either folder's data, and retire old jobs only after a successful migration.

**Acceptance checks:** upgrade a temporary legacy configuration containing representative settings, chats, models, and routines; verify the new app's paths contain them. Also cover a preexisting populated Aurel configuration and the updater environment.

### 9. [P2] An unrecognized typing destination silently types into the current app

**Local:** [aurel.py:510](/Users/anon/Workshop/atticus-mac/aurel.py:510).

For `type "…" in AppName`, `route_line` treats `app_named(AppName) == None` like a match with the front app. It skips opening the named destination and calls the native `--type` command against the current cursor instead. A failed app lookup can therefore insert potentially private text into an unrelated message or document and still report success. A numbered field can likewise be applied to the original app's controls.

**Reproduction:** with the front app `Messages`, make `app_named("MissingApp")` return `None`, then route `type "private note" in MissingApp`. The isolated probe invoked native typing, never attempted to open the requested app, and returned `Typed “private note”.` Native typing itself was mocked, so no real application received text.

**Correction:** resolve an explicit destination before taking action. If it cannot be resolved, return control to the full request handler or ask for clarification; do not use the current app's cursor or field map.

**Acceptance checks:** an unknown explicit destination causes no typing, field operation, or success response. Keep coverage for a recognized current app and a recognized different app.

### 10. [P2] A failed update build cannot be retried through Check for Updates

**Local:** [Aurel.swift:6136](/Users/anon/Workshop/atticus-mac/Aurel.swift:6136).

The updater pulls upstream before building. If that build fails, the repository has already advanced to the upstream revision while the installed executable remains old. On the next check, `git merge-base --is-ancestor '@{u}' HEAD` succeeds and exits before the build, reporting `Up to date`. Repairing a transient build problem does not let the user retry installation of the downloaded update through the updater.

**Reproduction:** run the exact updater shell script against temporary local Git repositories and a fixture build script. The first check pulls the update and returns exit 6 for build failure. After making the build succeed, the second check returns exit 0 without running it: the total build-attempt count remains one. No real remote or installed app was modified.

**Correction:** distinguish a fetched source revision from a successfully installed revision, or retain a pending-build marker that permits retrying at the same HEAD. Preserve the existing protection against rebuilding indefinitely when a checkout is ahead of upstream.

**Acceptance checks:** fail the first build after a pull, repair the fixture without adding another commit, then check again. The second check must build and report success; a subsequent check should report up to date.

### 11. [P2] The local model's idle timer can stop it during an active foreground request

**Local:** [Aurel.swift:697](/Users/anon/Workshop/atticus-mac/Aurel.swift:697), [Aurel.swift:721](/Users/anon/Workshop/atticus-mac/Aurel.swift:721), [Aurel.swift:1008](/Users/anon/Workshop/atticus-mac/Aurel.swift:1008), [Settings.swift:674](/Users/anon/Workshop/atticus-mac/Settings.swift:674).

`py` obtains the local server address when starting a foreground worker. `LocalAI.ensure` resets a timer at that point, and the timer calls `stop()` after the configured interval regardless of in-flight requests. Python's subsequent model calls do not update this timer or hold an active-request lease. With the supported one-minute setting, a long generation or multistep foreground ask can therefore lose its server while still working. This is not idle time. The concurrent local-agent keepalive applies to running agent rows and does not protect ordinary foreground requests.

**Reproduction:** compile the actual LocalAI implementation with a temporary fake model/server, accelerate the idle interval to 0.6 seconds, and make a request whose server response takes one second. The request reaches the server, the timer stops it, and the request fails. This demonstrates lifecycle behavior; it does not benchmark a real model or require a downloaded model.

**Correction:** suspend idle unload while a foreground request is active, including multistep execution, and start the idle interval after its completion or cancellation. Account for overlapping requests.

**Acceptance checks:** a foreground request remains successful beyond the configured idle interval; the server unloads after the final request has been idle for that interval. Cover cancellation and overlapping foreground/agent work.

### 12. [P2] The local tool loop executes additional commands after its deadline

**Local:** [aurel.py:5558](/Users/anon/Workshop/atticus-mac/aurel.py:5558).

`local_loop` checks its deadline only at the beginning of each model iteration. It then executes every returned tool call, using a fresh 120-second subprocess timeout for each command. It never rechecks the deadline between tools or after waiting for command approval. A request can therefore keep performing side effects after its stated time budget has expired, then eventually claim it stopped for taking too long. This applies to foreground local requests and the local-agent caller of the same loop.

**Reproduction:** use a fake monotonic clock with a foreground deadline of 180 seconds. Model inference consumes 100 seconds; the first of two approved tools consumes another 81 seconds, within its individual timeout. The probe still starts the second tool at time 181, and only afterward returns `That took too long, so I stopped. Please try again.` Both tools were mocks.

**Correction:** check the remaining budget before each tool and again after approval. Bound model and subprocess waits by that remaining budget, and stop the batch when it expires.

**Acceptance checks:** when the first tool consumes the remaining budget, the next tool must not run. Expiry while awaiting approval must also prevent execution. Verify that an in-flight subprocess cannot extend past the intended bounded wait merely because its default timeout is longer.

### 13. [P2] Local dictation cleanup discards the text before the cursor

**Local:** [aurel.py:6607](/Users/anon/Workshop/atticus-mac/aurel.py:6607), [Aurel.swift:3687](/Users/anon/Workshop/atticus-mac/Aurel.swift:3687).

The native dictation worker sends `text before cursor + NUL + transcript`. The Local branch of `dictate_cleanup_wait` keeps only the transcript and discards the preceding text. In contrast, the Claude branch includes up to 600 characters of cursor context in its cleanup prompt. On the default Local client, cleanup consequently cannot use nearby names or spelling context that the native app already collected.

**Reproduction:** send `The project is named Qwertyx.\0um deploy the project today` through the Local branch and capture the model request. `Qwertyx` is absent from the request. The probe establishes input loss, not a claim that a particular real model will produce a specific incorrect spelling.

**Correction:** pass bounded cursor context into local cleanup as contextual data, keeping the transcript separate and preserving dictionary hints and output validation.

**Acceptance checks:** a unique nearby name appears in both clients' cleanup requests, context is limited to the intended 600-character suffix, and context never becomes part of the dictated output by construction.

### 14. [P2] A saved Siri voice can be replaced with a voice in another language

**Local:** [Aurel.swift:895](/Users/anon/Workshop/atticus-mac/Aurel.swift:895).

The read-aloud policy tries the saved voice for the answer's language, then the saved English voice. Siri voices can be present in macOS's saved selections while absent from the enumerated voices usable by name. When the current language has such a Siri selection, the loop falls through to English and explicitly selects that voice, overriding the system's appropriate default. A German answer can thus be read using English Tessa despite a saved German Siri selection. The earlier parity pass excluded this latest upstream change from port-regression attribution; it remains a defect in the current general review.

**Reproduction:** run the actual policy with a saved German Siri identifier and a saved English Tessa voice, with only Tessa enumerated. For both OS-version inputs 26 and 27, the compiled probe selects `Tessa (Enhanced)`. No audio was played.

**Correction:** when the current language's saved selection is Siri, preserve the system-default voice path before considering the English fallback. Retain an explicit voice override selected in Aurel.

**Acceptance checks:** the German-Siri fixture selects the system-default sentinel for both supported policy branches; an English answer still selects Tessa. Preserve explicit overrides and existing behavior for unavailable non-Siri voices.

## General review verification and limits

- The five Python/install/update reproductions ran in `/tmp/aurel-general-review/probes.py` and were rerun against the latest Python and updater source. External actions were mocked; installer statements used a temporary HOME; updater checks used local fixture Git repositories. Results are in `probe-results.json`.
- The idle-timer and voice-policy reproductions compiled Swift fixtures. The idle fixture used the current LocalAI source with a temporary loopback server and accelerated timer. The voice fixture used fake available/saved voices. Results are in `idle-result.txt` and `voice-result.txt` in the same temporary directory.
- A focused run of local execution, agents, routines, profiles, chats, dictation, calendar, background helpers, accessibility helpers, universal commands, and updater tests ran **264 tests: 247 passed, 1 failed, 16 skipped** in 54.381 seconds. The failure was `LocalTests.test_bigger_asks_can_go_to_claude`. Concurrent routing edits were landing during this review; the failure's cause is not established. It subsequently passed alone, and the entire current `tests.test_local` module passed (**12 tests**). The combined run is therefore recorded as failed, not retroactively counted as green or promoted into an additional product finding.
- The host UI guard remained enabled. It blocked some native/application-driving checks and raised SkipTest exceptions in two fixture background threads. Those paths were not validated by the passing assertions. No real application was typed into, no audio was played, and no production model, account, calendar, or installation was modified by these probes.
- The earlier full-suite results above belong to the earlier review snapshot. The full suite was not rerun after all concurrent edits. This is a source review with targeted reproductions, not exhaustive proof that the remaining code is bug-free.

Suggested correction order: address migration and wrong-app typing first (8–9), then update recovery and local execution lifecycle (10–12), followed by dictation and voice context (13–14). Findings 2–7 remain pending from the earlier comparison; finding 1 is fixed in source as noted above.

## CPU and memory optimization review

Reviewed the current working tree after the bug review. These are optimization proposals, not implemented changes. Concurrent fixes and app relaunches continued during inspection, so earlier bug statuses above should not be treated as the current implementation status. Prioritize eliminating redundant work while retaining existing response times, model capabilities, and visible animation quality.

### A. Filter the agent queue before recounting running tasks — highest priority

**Source:** [aurel.py:4706](/Users/anon/Workshop/atticus-mac/aurel.py:4706), [aurel.py:5021](/Users/anon/Workshop/atticus-mac/aurel.py:5021).

`Agents.drain` sorts every saved agent, then calls `self.running()` for each row before checking whether it is queued. `running()` scans every row again. With no queued tasks and an accumulated history of completed agents, this is quadratic work on every supervisor tick; the service sleeps only 150 ms between ticks. It also holds the supervisor lock during that work.

**Minimal proposal:** filter to queued rows before sorting and iterating. Keep the existing capacity check before starting each queued task, preserving its current behavior as starts change the running count. This removes the repeated history scans when there is nothing to start.

**Evidence:** an isolated probe called the actual routine on synthetic completed-agent histories. At 1,000 completed agents, original CPU time was approximately 125–228 ms per call across two runs; the filtered candidate took 0.084 ms in the comparison run. At 3,000 completed agents, the comparison was approximately 1,580 ms versus 0.156 ms. These are fixture timings under current machine load, not measurements of the user's history or whole-app speedups. The candidate and original produced identical start sequences and resulting rows in 250 seeded queue fixtures with mixed task statuses. Production code was unchanged.

**Validation before shipping:** retain the existing agent tests and cover empty queues, queued tasks mixed with large finished histories, capacity occupied by running/needs-you/waiting-screen tasks, and failed starts. Confirm that commands remain responsive while the supervisor maintains a large history.

### B. Avoid rendering an identical orb frame under Reduce Motion

**Source:** [Orb.swift:455](/Users/anon/Workshop/atticus-mac/Orb.swift:455), [Box.swift:785](/Users/anon/Workshop/atticus-mac/Box.swift:785).

The orb's display-link callback skips advancing time under Reduce Motion but still regenerates its geometry, allocates a bitmap context, renders the image, and replaces layer contents every display frame. Main-box orb instances pass `m.visible` as `running`, so a visible box with Reduce Motion can repeatedly render an identical image. Onboarding already disables its orb's `running` flag under Reduce Motion.

**Proposal:** render once when state, size, scale, or frozen time changes, and suspend display-link notifications while the image is static. Resume immediately when animation becomes appropriate. Keep the existing visible-animation rate. Also check visibility/occlusion lifecycle handling so retained views do not animate when their windows cannot be seen. The main box already pauses on its normal hide path; this is not a claim that all hidden box orbs currently run.

**Evidence:** source-confirmed redundant static rendering. A compiled 64-point, 2× orb raster probe measured approximately 0.6–1.0 ms per image across the tested states, illustrating why avoiding identical renders matters. It did not measure installed-app frame callbacks. Apple's [display-link pause API](https://developer.apple.com/documentation/quartzcore/cadisplaylink/ispaused) suspends target notifications.

**Validation before shipping:** compare static images before/after, test changing state while Reduce Motion is enabled, and toggle Reduce Motion while the box is open. Verify smooth resume and unchanged geometry/timing with normal animation enabled.

### C. Skip unchanged published values in Settings and onboarding

**Source:** [Aurel.swift:5685](/Users/anon/Workshop/atticus-mac/Aurel.swift:5685), [Aurel.swift:6457](/Users/anon/Workshop/atticus-mac/Aurel.swift:6457), [Settings.swift:131](/Users/anon/Workshop/atticus-mac/Settings.swift:131), [Onboarding.swift:110](/Users/anon/Workshop/atticus-mac/Onboarding.swift:110).

Settings polls every 1.5 seconds and assigns permissions, microphones, shortcut state, and model status to published properties even when those values are unchanged. Onboarding polls modifier keys 20 times per second and, on its Try page, assigns the same `held` string repeatedly; its permission updates also republish unchanged data. This creates unnecessary observable-object notifications and opportunities for view recomputation.

**Proposal:** compare normalized incoming values with the current property before assigning. Compare microphone IDs/names and relevant status fields explicitly rather than introducing a general caching framework. Pause window-specific polling while minimized/hidden, refresh immediately when shown, and keep the current poll rate while visible. Modifier-key events can replace the dedicated key polling if the shortcut recorder and global-key behavior are preserved.

**Validation before shipping:** repeated identical inputs should emit no additional model-change notifications; real permission, device, download-progress, and modifier changes must still appear promptly. Test returning from System Settings and restoring a minimized window. CPU savings are not yet measured.

### D. Suspend unnecessary idle polling and deduplicate metadata writes

**Source:** [Aurel.swift:4134](/Users/anon/Workshop/atticus-mac/Aurel.swift:4134), [Aurel.swift:4491](/Users/anon/Workshop/atticus-mac/Aurel.swift:4491), [aurel.py:4864](/Users/anon/Workshop/atticus-mac/aurel.py:4864), [aurel.py:4887](/Users/anon/Workshop/atticus-mac/aurel.py:4887), [aurel.py:4712](/Users/anon/Workshop/atticus-mac/aurel.py:4712).

The native agent controller wakes every 100 ms even with no rows. The Python supervisor wakes every 150 ms, re-reads the paused preference, scans pending handoffs, and drains the queue; even an idle history receives this maintenance. Metadata handling also rewrites the tools snapshot and appends full metadata events for unchanged responses. Polling backs off to 60 seconds for nonempty stable server lists, but empty/pending lists can continue on the two-second path.

**Proposal:** after fixing A, use existing IPC/state changes to arm native UI maintenance only while needed. Use file notifications to wake idle supervisor maintenance for pending handoffs and changed files, with a conservative recovery fallback. Keep the current active-task cadence until latency is measured. Compare metadata snapshots before rewriting files or logging another full copy; retain changed metadata and lightweight diagnostic heartbeats as appropriate.

**Validation before shipping:** measure idle wakeups with no agents and with only historical rows. Confirm immediate new-task dispatch, approval detection, routine delivery, crash/handoff recovery, shelf fade behavior, and prompt updates after editing chats or named agents. Simply increasing every polling interval is not the proposed optimization, because that would introduce latency. Savings remain unmeasured and this is more involved than A–C.

### E. Bound the cache of old equation images

**Source:** [Answer.swift:119](/Users/anon/Workshop/atticus-mac/Answer.swift:119).

`MathCache.shared.images` retains each distinct rendered formula/size/color combination for the lifetime of the app, with no eviction or memory-pressure handling. A long math-heavy session can therefore retain images no visible answer uses.

**Proposal:** keep images needed by visible answers readily available and make older reusable images evictable using a bounded, costed cache. Apple's [NSCache cost limit](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit) supports eviction but is a soft limit; use an explicit bounded policy if a strict maximum is required. Choose the budget from measured formula-heavy sessions rather than an arbitrary small limit that causes rerendering churn.

**Validation before shipping:** memory should stabilize while cycling through many distinct old answers; visible formulas and scrolling must not repeatedly rerender. Evicted historical formulas may need regeneration when reopened, so this proposal needs a cache-hit/latency check before claiming no performance impact. Expected savings depend on equation use and are not yet measured.

### Measurements, tradeoffs, and changes not recommended yet

- Read-only process snapshots showed approximately **28–46 MiB RSS for the native app**, **10–12 MiB for its speech helper**, and **2.8–3.2 GiB for llama-server**. The app relaunched between observations and workload was uncontrolled. These are process RSS snapshots, not total attributable GPU/unified-memory use, peak allocations, or an idle CPU baseline. They indicate that model residency dominates the observed memory footprint.
- Reducing the model, shrinking context capacity, dropping the second prompt-cache slot, or unloading models sooner can reduce memory, but can also affect quality, supported task length, cache reuse, or the next request's latency. They do not meet the requested no-performance-loss criterion without further workload testing. Keep those settings unchanged for the first optimization pass.
- A reusable orb bitmap-context experiment produced pixel-identical results for 108 frames, but its timing benefit was inconsistent: approximately 0.65/0.62, 0.63/0.63, and 0.98/0.61 ms per image for original/reused contexts. It is not prioritized over avoiding redundant renders entirely.
- Temporary evidence: `/tmp/aurel-performance-review/queue_probe.py`, `queue-results.json`, and the compiled `orb.swift` fixture. No app, configuration, or model files were changed. No whole-app before/after energy claim is made.

Recommended first implementation pass: A, B, and the equality guards in C. Then measure idle/active CPU, wakeups, resident memory, first-token latency, and frame pacing before deciding whether D or E warrants further changes.
