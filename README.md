<p align="center"><img src="docs/banner.png" alt="Aurel. Your whole Mac, one sentence away." width="100%"></p>

<p align="center">
  Hold <kbd>⌃ control</kbd> <kbd>⌥ option</kbd> <kbd>space</kbd>, say what you need, let go.<br>
  Aurel moves your windows, finds your files, reads your screen and gets it done.
</p>


<p align="center">
  <b>🧠 Learns as you use it</b> &nbsp;·&nbsp; <b>⚡ Fast</b> &nbsp;·&nbsp; <b>🔑 No API key</b> &nbsp;·&nbsp; <b>Free and open source</b>
</p>

## Quick install

```
curl -fsSL https://raw.githubusercontent.com/tbergeron/aurel/main/install.sh | bash
```

Needs macOS 26. Aurel runs a free AI model on your Mac and downloads it for you; Claude Code is optional. [Full install steps](#install)

## What it does

- **Learns.** Ask for something new once and it works out the steps. Ask again and it runs in a blink, with no AI.
- **Instant commands.** Opens apps, moves windows, plays music and searches the web with no AI at all.
- **Sees your screen.** Ask about anything on screen. Ask "where do I click?" and it points at the spot.
- **Draws to explain.** "Explain this and draw it" builds a labeled diagram on your screen.
- **Dictate anywhere.** Hold fn, talk, let go. Your words land in any text field, cleaned up.
- **Hands-free.** Turn on Settings → General → Wake word, then just say "Aurel". Keep talking after each answer; the box stays up while you work and only ✕ closes it.
- **Background agents.** Big jobs run behind your apps while you keep working.
- **Remembers you.** Say "remember…" and every ask after that knows it.
- **Runs on your Mac.** A local model by default: free, private, offline. Claude if you want it.
- **Private and safe.** Your voice stays on your Mac. Deletes, sends and purchases ask first.

> **On Windows?** [@FindlayHi](https://github.com/FindlayHi) built **[Atticus for Windows](https://github.com/FindlayHi/atticus-windows)**, with integrations for Home Assistant, Jellyfin, Immich and more.

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-1d1d1f?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-1d1d1f?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="Claude" src="https://img.shields.io/badge/Claude_Haiku-1d1d1f?style=for-the-badge&logo=anthropic&logoColor=white">
  <img alt="Cost" src="https://img.shields.io/badge/~0.18%C2%A2_per_ask-1d1d1f?style=for-the-badge">
</p>

<br>

https://github.com/user-attachments/assets/26822ad2-6281-477d-b676-2f490a4a207b

<br>

## Just ask

| You say | Aurel |
|---|---|
| *"Code on my big screen, Chrome and Terminal on the laptop."* | Arranges three windows across two displays. |
| *"Open Spotify."* · *"Terminal on the left."* | Runs instantly, with no AI at all. |
| *"Find my notes about the Tokyo trip."* | Searches your files by what's inside them, opens the match on your other screen. |
| *"What's wrong with this code?"* | Looks at your screen and answers in a line. |
| *"Reply to this. Thursday works, send me a time."* | Reads the email on screen and writes the reply. Insert puts it at your cursor. It never sends. |
| *"Move my dentist appointment to 4."* | Shows the old and new time on a card and moves it when you approve. Adding is immediate; moving or deleting asks first. |
| *"Tell the agent in my terminal to also run the tests."* | Types it into that window in the background while you keep working. If it can't confirm the send, it leaves the text there and asks for the window. |
| *"Find me a desk lamp under $30 on Amazon."* | Works in Chrome behind your apps; a live mini screen shows it. |
| *"Where do I turn on Night Shift?"* | A ring lights up the exact spot on your screen (Show me where). |
| *"Summarize this article in three bullets."* | Reads the page for you. |
| *"Play my late night coding playlist on Spotify."* | Plays it in a second, no clicks. Any song, artist or playlist. |
| *"When I say focus mode, close Slack and open my to-do list."* | Remembers it. Next time, two words do it all. |

<p align="center"><img src="docs/demo.gif" alt="Aurel arranging windows across two screens" width="820"></p>

## Hands-free

Turn on **Wake word: say "Aurel"** in Settings → General (off by default). Say "Aurel" or "hey Aurel", wait for Listening…, then ask. Speech is recognized on your Mac only. After each answer it listens again quietly, with a small "Listening..." beside the timer; start talking and your words fill the bubble. Clicking other apps never closes a hands-free chat, so you can keep working while it does things for you. ✕ or Esc ends it, and a chat nobody talks to fades after about 90 seconds unless you moved or resized the box. The hotkey always takes over. While the wake word is on, macOS shows the orange mic dot.

While Aurel works, the line next to ✕ minimizes the box to a small bar with its live steps. Hover and click the line to bring it back.

## Safe by default

Safe mode runs the AI's commands in Claude Code's sandbox, so they can only write to a scratch folder. Before anything deletes, sends, buys or changes a file, Aurel asks you first. <code>rm</code>, <code>sudo</code>, disk tools and shutdown are always blocked. Every exact command is in the ask log. Apple's on-device speech turns your voice into text, and audio never leaves your Mac.

<details>
<summary><b>How the shortcut and the box work</b></summary>
<br>

Choose **Hold to talk** or **Press to toggle** in Settings → General → Shortcut behavior. Hold mode sends when you release. Toggle mode starts on the first press and sends on the second; pauses keep listening. Pressing the shortcut while Aurel answers stops it; during spoken playback it stops the voice. Esc cancels listening without sending. Toggle recordings reach a review screen after 60 seconds, rather than sending automatically. Closing the overlay or pausing Aurel stops its microphone, workers and voice.

Click any answer to copy it, including earlier answers still shown in the box. Click your request to edit and ask again, or press ↑ in an empty typing box to recall the latest request. The overlay stays within your display when resized and respects Reduce Motion. While Aurel works in a covered window, another Space, or another display, a live mini screen shows that window; the steps below show the action. The finished view stays until the next ask, typing, or a click on it. Click it to open that exact window. The preview stays on your Mac, is never sent to the AI or saved, and stops streaming when the task ends. Without Screen Recording permission, the same card shows the app icon and window title.

Apple's final transcript confirms each voice request before AI tools or learned shortcuts run. AI reasoning can start during a pause, but its tools wait for confirmation. If speech finalization takes too long, Aurel offers the partial text for review. Instant commands still skip the AI entirely. Supported built-in commands run mid-sentence, before you send. Learned shortcuts wait for confirmed words.

When Aurel acts but can't see the result, it says so ("…but I couldn't confirm the result") and doesn't learn that shortcut. Try again checks what already happened before it acts again.

</details>

## Dictate anywhere

Hold fn to talk. Double-tap to lock. In any text field, hold the fn (🌐) key, speak, then let go. Double-tap it to lock dictation on for hands-free talking; an orange ring circles the pill, and one more press inserts. fn is the shortcut until you record another in Settings → Dictation (a key combo, an F-key, or a modifier chord like fn+Control); a shortcut you already set stays. If macOS's "Press 🌐 key to" setting opens emoji, switches input source or starts Apple dictation, Settings and setup show "Set Press 🌐 key to Do Nothing" with a button to Keyboard settings. fn with another key (fn+Delete, fn+←) stays that key's shortcut. While you talk, a small pill shows a sound wave. The Dictation tab shows your words today and all time, time saved, sessions, your dictionary and history. **Verbatim** types Apple's on-device transcript with no AI. **Clean up** makes one quick AI pass that keeps your words, fixes words it clearly misheard ("talk it and it' type" becomes "talk to it and it'll type"), and drops the slips: "um" and "you know" go, "scratch that" removes the thought before it, "four, actually five" leaves five, a spoken list becomes a list, and "new line" or "question mark" become formatting. It types what you dictate and never answers or acts on it. To spell names and terms it uses your Dictionary and the text just before your cursor. It starts while you talk, so the text lands soon after you let go; if the AI's version adds or drops too much, Aurel types your words with only the obvious fillers removed. Highlight text first and Clean up tidies that text in place. Esc cancels. When the words land, the pill turns into a green check and fades. With no text field selected, it says "Nothing selected to insert — saved to History." Dictation never leaves your words on the clipboard: if a field only takes a paste, Aurel borrows the clipboard for that one paste and puts back what you had copied. If the field changes or Aurel can't confirm the words landed, it saves them to Dictation History and says "Saved to History" instead of typing twice; with History off, the words stay in the pill.

**Faster speech and other languages.** Aurel runs Apple's speech in English (US). For faster, more accurate dictation, or for other languages, pick **Parakeet** in Settings → Dictation → Speech model. It runs NVIDIA's Parakeet on your Mac ([FluidAudio](https://github.com/FluidInference/FluidAudio)), so audio never leaves your Mac. A short sentence turns into text in about a tenth of a second, even on an M1, and a voice detector skips silence and noise so they never turn into words. Four models, each pinned to an exact, checksum-verified download: **Multilingual** (469 MB, the default), **Most accurate** (613 MB, just as fast) and **Light** (213 MB, on the graphics chip, so slower on older Macs), all with 25 European languages detected automatically, and **English** (451 MB). Models live in `~/Library/Application Support/FluidAudio/Models/`. The wake word still uses Apple's English model.

**Words that fit.** Dictated words fit where they land: a space before them unless one is there, lowercase in the middle of a sentence, a capital after a period or a new line, and no period when the sentence goes on after the cursor. "I", acronyms, names like iPhone and your Dictionary words keep their case. Apps that hide their text get the words as heard.

**Type as I talk.** Turn it on in Settings → Dictation (Verbatim only) and your words go in at each pause while you keep talking. Words already typed are never changed; letting go types the rest.

**Free memory after** (Settings → General) unloads the speech and AI models when idle: 1, 5 (the default) or 15 minutes, an hour, or never. They load again the next time you talk. To time the speech models on your Mac: `tests/evals/speech_bench.sh <audio file>`.

## Point at your screen

This is how you show Aurel something; [Draw on screen](#draw-on-screen) is how Aurel shows you. Click the pointer button, **Point at your screen**, next to the mic in the ask box. The cursor becomes a crosshair and the box says "Click, circle or scribble on anything, then ask". Mark the spot, then type or say your question and send. Another stroke near the mark replaces it; move away and your clicks reach your apps again, with the mark still showing. Aurel's own box and cards always take their clicks, so you can type while pointing. Click the pointer button again to stop or to mark somewhere else. A small picture of what you marked waits in the box; its × removes it, and Esc clears everything. Aurel gets a crop of that spot with your question, and the mark stays until you send. While a mark is waiting, instant commands and early thinking wait too.

## Draw on screen

Ask where to click or how to do something and Aurel shows you instead of only telling you: it draws boxes, circles, arrows and labels over your screen, with a pointer that moves to each spot. It goes one step at a time and moves on when you click the highlighted spot, change that value, or say "next".

Ask it to explain something and draw it ("explain the Pythagorean theorem and draw it on my screen") and the drawing builds up like a whiteboard: each step adds to the last, and a card in the opposite corner keeps every caption so far. It moves through the steps by itself. It works from what you have open: with a video, page or problem on screen, it marks up that figure and uses its numbers, unless you ask for a fresh example. Drawings go on the screen where you asked (the one with the Aurel box) unless you name another. Worked examples and practice problems are written line by line in large text on one panel, readable from your chair on a laptop or a monitor.

The drawing stays while you keep asking about it, and Aurel can add to it; it changes only when an answer draws something new. Click any mark (a box, an arrow, a label, a line of text) to select it, then ask "how does this work?": like Point at your screen, the question carries that mark and a picture of it. While a drawing is up, the Aurel box moves out of its way and comes back when it's gone. Close the card or press Esc to clear it. Steps are spoken only when Read answers aloud is on. The drawings never take focus, and clicks pass through everywhere except on a mark. Turn it off in Settings → General → Draw on screen to show you.

## Model choice

In Settings → Intelligence, choose **Cheapest**, **Balanced** (the default) or **Most capable**. Cheapest keeps every ask and new agent on Haiku. Balanced keeps questions and quick commands on Haiku and gives real work to your work model; if a task turns multi-step, fails, or ends without a confirmed result, it continues once on the work model. Most capable uses the work model for every AI ask and agent. Instant commands skip the AI in every mode. **Work model** picks Sonnet or Opus; Opus is stronger and uses more of your plan.


## The local model

Aurel thinks with a model that runs on your Mac, chosen in Settings → Intelligence → **Local** (the default). Click **Download** once and Aurel fetches [llama.cpp](https://github.com/ggml-org/llama.cpp) and the model, checks both against pinned checksums, and runs them itself. You install nothing, and your asks never leave your Mac. Files live in `~/.config/aurel/llm/`; the model loads when you talk and unloads after 10 idle minutes.

- **Gemma 4 E4B** (5.2 GB, the default) fits 16 GB Macs.
- **Qwen 3.6 35B** (22.1 GB) is much stronger at long tasks and needs 32 GB of memory.

Commands the instant patterns don't catch go to the model once: it picks one action ("go down a little" → scroll down a bit, "click the second result" → that link) and Aurel does it, in about a second on an M1. Anything bigger runs step by step with the same helpers and safety check Claude uses. `python3 tests/evals/local_router_bench.py <server>` scores a model on 42 spoken commands; on an M1, Gemma 4 E4B got 38 right with a median of 1.3 s.

Clean up dictation uses the local model too. Background agents and routines still need Claude Code. To send only bigger asks to Claude, set **Bigger asks** to Claude.

## Agents

Ask for something big ("find me USB-C hubs") and Aurel hands it to a background agent. A chip shows up in the corner while you keep working. The box, the dictation pill, the chips and the done card show up on the display your mouse is on. Hover it to see the live steps and a mini screen of the work. To change course, just talk: "tell the hub agent to check HDMI too" steers the running agent instead of starting a new one. When it finishes, a card shows the result once you stop typing. During a call or screen share, you get a quiet notification instead. If an agent needs a permission or a connector, it asks on its chip, then carries on. Turn on agents and their connectors in Settings → Agents (or the setup step).

A long ask in the box moves to an agent by itself, with no card, and agents Aurel offers start right away. To move one sooner, press ⌃⌥↩ from any app while it runs.

Agents work behind you. Their clicks, typing, scrolling and keys go straight to the app they work in, so your pointer, your front app, your windows and your Space stay where they are. Web work happens in the agent's own browser window, in your signed-in profile; your tabs are left alone, and the window closes when the task ends. If an agent's process stops mid-task, Aurel restarts it once and it picks up where it was. When an agent asks to do something, **Always allow for this task** approves that same kind of action until the task ends; the next task asks again.

### Named agents

Say “make an agent called Researcher that finds sources and writes a short brief” to save reusable instructions, then “ask Researcher to…” to start it. Saved agents can include a folder or files and can be listed, renamed, or deleted by voice or in the Agents view.

Background agents currently require Claude Code. With the local model, asks run in the box instead.

### Chats

Plain questions and answers can be saved in the Agents window: switch to **Chats** at the top. Chats keep only answers, never actions or agent tasks, stay on your Mac, can be renamed, and are never sent back to the AI. Turn saving off in Settings → Memory → Learning → Save chats.

## Install

You need:
- **macOS 26** or later (Aurel uses Apple's new on-device speech)
- **Optional, instead of the local model:** a paid Claude plan (Pro or Max) and [Claude Code](https://claude.com/claude-code). Pick one in setup (“Change provider”) or Settings → Intelligence.
- Apple's command line tools: `xcode-select --install`
- Accessibility permission enables native clicks, scrolling, menus, keys, dragging and field typing.

Paste this in Terminal:

```
curl -fsSL https://raw.githubusercontent.com/tbergeron/aurel/main/install.sh | bash
```

It checks your Mac, downloads Aurel to `~/.aurel`, builds `~/Applications/Aurel.app`, and opens it. Aurel starts at login and updates itself from there (turn that off in Settings → About & Updates).

### Nix

On macOS with Nix flakes enabled:

```bash
nix run github:tbergeron/aurel
```

The flake installs its packaged Aurel version, so macOS 26+ and Apple's command line tools are still required. Run that command again to update. `nix profile add github:tbergeron/aurel` installs an `aurel` launcher; update it with `nix profile upgrade aurel`, then run `aurel`. Nix installations show this update path in Settings instead of using Aurel's Git updater.

Working on the code instead? Clone the repo anywhere and run `./build.sh` after each change. A Devbox environment is included for Python regression tests; run `devbox shell`, then `devbox run test`.

The first launch opens a setup window. It checks your AI plan, then asks for each macOS permission.
After that, Aurel lives in the menu bar. Open it from Spotlight (⌘Space, "Aurel") for Settings: shortcut, voice, model, privacy, memory and history. Settings and setup follow your Mac's light or dark appearance.
If you sign out of your AI client later, the setup window comes back by itself.
To see it again: `defaults delete com.aurel.app onboarded`, then restart the app.

Test: `python3 aurel.py --selftest` on macOS, plus `python3 -m unittest discover -s tests -v` for offline regressions. After building, `~/Applications/Aurel.app/Contents/MacOS/Aurel --selftest` checks native transcript matching without opening the app. Node, when installed, also checks `ui/web.js`. The box, Settings and setup are checked through their models with no window open; `AUREL_ALLOW_HOST_UI=1 python3 -m tests.shoot_native settings` (or `onboarding`, `box`) screenshots each scene for a look.

Remove: `launchctl bootout gui/$(id -u)/com.aurel.app`, then delete `~/Applications/Aurel.app`, `~/.aurel`, `~/.config/aurel` (your settings and history) and `~/Library/LaunchAgents/com.aurel.app.plist`.

## Watch for me

Say "tell me when Codex is done" or "watch this page until it says shipped". Aurel sets it up once, then checks every 5 seconds on your Mac with no AI, so waiting is free. When it fires you get a notification, and it runs a follow-up if you asked for one. A window must stay open on this desktop (covered is fine). Coding agents like Codex are watched through their own log, with no screen at all. Say "stop watching" to cancel.

## Routines

Say "every weekday at 8, summarize my calendar" or "every 30 minutes, check my inbox". Aurel saves a routine and macOS wakes it on time, so it costs nothing while it waits. Each run starts a background agent on Cheapest unless you chose another mode, and you get a notification with the result. Runs are skipped while Aurel is paused, and a restart never repeats one. See and remove routines in Settings → General → Scheduled routines, or ask Aurel to remove one. Like other agents, routines need Claude Code.

## Budget

Aurel has to stay fast and nearly free, so new features must fit under these limits:

- Instant commands: no AI, $0.
- AI asks: median under $0.002 and 6 s over the last 50 (Oct 10, 2026: $0.00095, 5.0 s). Check with `python3 aurel.py --budget`.
- System prompt: under 10,000 characters in source and at most 10,050 with the installed helper path. Every ask pays for it, and tests enforce both limits.
- Anything that waits or runs in the background: $0 while it waits. AI only to set it up and to act at the end.

## Files

- `Aurel.swift`: the app (hotkey, speech, overlay, onboarding window)
- `parakeet/`: the Parakeet speech helper (Swift package on FluidAudio) that `build.sh` puts next to the app
- `aurel.py`: the brain (fast commands, system prompt, helpers for windows, web and screen)
- `ui/ui.html`, `ui/onboarding.html`, `ui/settings.html`: the overlay, the welcome flow, and Settings
- `ui/AppIcon.icns`: the app icon
- `ui/orbs.js`: the [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) engine (MIT, Jakub Antalik)

## License

MIT. See `LICENSE`. `ui/orbs.js` is from [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs), also MIT.

## Contributing

Run regressions with a scratch `AUREL_DIR` and use `tests/ui.html` and `tests/settings.html` for mock-bridge UI checks. Keep personal agent settings, credentials and runtime state out of commits.

Hands: ideas and some logic adapted from Plip (github.com/hussainn7/plip-oss, MIT). Background key authentication and menu-shortcut presses follow Cua Driver (github.com/trycua/cua, MIT).
