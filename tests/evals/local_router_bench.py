#!/usr/bin/env python3
"""Benchmark a local model as Aurel's one-step voice command router.
Run against a llama.cpp server: python3 tests/evals/local_router_bench.py http://127.0.0.1:8080 [label]
Each case gives the screen context the router sees and the one command line it should write; prints accuracy and latency."""
import json
import re
import statistics
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from aurel import ROUTER as SYSTEM, ROUTER_GRAMMAR as GRAMMAR   # the app's own prompt, so the scores are the app's

SAFARI = ("Front app: Safari, window \"Amazon.com: usb c hub\"\nOpen apps: Safari, Messages, Slack, Terminal, Spotify, Notes\n"
          "Controls:\n1 button: Back\n2 button: Forward\n3 box: Search Amazon\n4 button: Go\n5 link: Anker USB C Hub, 7-in-1\n"
          "6 link: UGREEN USB C Hub 5 in 1\n7 link: Next page\n8 button: Add to Cart\n9 button: Sign in")
MESSAGES = ("Front app: Messages, window \"Sam Rivera\"\nOpen apps: Messages, Safari, Slack, Notes\n"
            "Controls:\n1 button: Compose\n2 box: Search\n3 row: Sam Rivera\n4 row: Mom\n5 box: iMessage\n6 button: Send\n7 button: Emoji")
CODE = ("Front app: Visual Studio Code, window \"aurel.py — aurel-mac\"\nOpen apps: Visual Studio Code, Terminal, Safari, Slack\n"
        "Controls:\n1 tab: aurel.py\n2 tab: README.md\n3 button: Run\n4 box: Search")

# (context, request, expected command line); a regex where several are right
CASES = [
    (SAFARI, "switch to slack", "open Slack"),
    (SAFARI, "bring up my terminal", "open Terminal"),
    (SAFARI, "go to spotify real quick", "open Spotify"),
    (SAFARI, "open up figma", "open Figma"),
    (CODE, "jump over to the browser", "open Safari"),
    (CODE, "show me my notes", "open Notes"),
    (SAFARI, "can you open my calendar", "open Calendar"),
    (SAFARI, "put safari on the left", r"move (Safari )?to left"),
    (CODE, "make this full screen", r"move (Visual Studio Code |Code )?to full"),
    (CODE, "throw code onto the monitor", r"move (Visual Studio )?Code to monitor"),
    (SAFARI, "terminal on the right side please", "move Terminal to right"),
    (CODE, "center this window", r"move (Visual Studio Code |Code )?to center"),
    (CODE, "move slack to my laptop screen", "move Slack to laptop"),
    (MESSAGES, "type see you thursday", r'type "see you thursday"( in Messages)?( field 5)?'),
    (MESSAGES, "write sounds good, I'll be there at five", r'type "sounds good, I.ll be there at (five|5)\.?"( in Messages)?( field 5)?'),
    (SAFARI, "search for usb c hub with hdmi", r'type "usb c hub with hdmi"( in Safari)? field 3'),
    (SAFARI, "type running late in messages", r'type "running late" in Messages'),
    (MESSAGES, "put on my way in the message box", r'type "on my way"( in Messages)? field 5'),
    (CODE, "in slack type deploy is done", r'type "deploy is done" in Slack'),
    (SAFARI, "go down a little", "scroll down bit"),
    (SAFARI, "scroll way down", "scroll bottom"),
    (SAFARI, "go back up to the top", "scroll top"),
    (SAFARI, "keep scrolling", "scroll down"),
    (CODE, "up a bit", "scroll up bit"),
    (SAFARI, "click the anker one", "click 5"),
    (SAFARI, "click the second result", "click 6"),
    (SAFARI, "hit add to cart", "click 8"),
    (SAFARI, "next page", "click 7"),
    (MESSAGES, "open my chat with mom", "click 4"),
    (MESSAGES, "hit the send thing", "click 6"),
    (CODE, "go to the readme tab", "click 2"),
    (SAFARI, "go back a page", r"click 1|press cmd\+\["),
    (SAFARI, "new tab", r"press cmd\+t"),
    (CODE, "save this", r"press cmd\+s"),
    (MESSAGES, "press enter", "press (return|enter)"),
    (SAFARI, "close this tab", r"press cmd\+w"),
    (CODE, "undo that", r"press cmd\+z"),
    (SAFARI, "which of these hubs is the best deal", "ai"),
    (MESSAGES, "reply to sam saying thursday works and ask what time", "ai"),
    (CODE, "what's wrong with this code", "ai"),
    (SAFARI, "find me a cheaper one and add it to my cart", "ai"),
    (SAFARI, "what's the weather tomorrow", "ai"),
]


def ask(url, context, request):
    body = {"messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": context + "\nRequest: " + request}],
            "temperature": 0, "max_tokens": 60, "grammar": GRAMMAR, "chat_template_kwargs": {"enable_thinking": False}}
    r = urllib.request.Request(url.rstrip('/') + '/v1/chat/completions', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    t = time.time()
    with urllib.request.urlopen(r, timeout=120) as response:
        out = json.load(response)
    return out['choices'][0]['message']['content'].strip(), time.time() - t


def main():
    url, label = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    for context in (SAFARI, MESSAGES, CODE): ask(url, context, "switch to slack")   # warm the prompt cache, like a key-down would
    passed, times, misses = 0, [], []
    for context, request, want in CASES:
        try: got, secs = ask(url, context, request)
        except (OSError, ValueError, KeyError) as e: got, secs = f'error {e}', 0
        ok = bool(re.fullmatch(want, got, re.I))
        passed += ok; times.append(secs)
        if not ok: misses.append(f'  {request!r}: {got!r}')
    times.sort()
    print(f'{label}: {passed}/{len(CASES)} right, median {statistics.median(times):.2f} s, p90 {times[int(len(times) * .9)]:.2f} s')
    print('\n'.join(misses))


if __name__ == '__main__':
    main()
