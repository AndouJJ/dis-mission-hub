# Working on this repo

## Always preview games before calling work done
For any change to a mini-game (`ne-1`..`ne-6` or new ones) — new game, wording
change, bugfix, anything — render an actual preview before telling the user it's
ready:

1. Serve the repo locally (`python3 -m http.server <port>`).
2. Use Playwright (`/opt/pw-browsers/chromium`, `NODE_PATH=/opt/node22/lib/node_modules
   node ...`) to walk through the flow: pass the access-code gate (`DIS2026`),
   register a handle, open the mission card, unlock/play the game end-to-end
   (including a wrong-answer case where relevant), and screenshot the key states.
3. Send the screenshots to the user (`SendUserFile`) before considering the task
   complete — not just a description of what changed.

This applies even to small edits (copy tweaks, one-line fixes) — always show the
actual rendered result, not just the diff.
