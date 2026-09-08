# DIS Mission Hub — Year IV

A web app for DIS personnel built around the organisation's **4th Anniversary on October 28, 2026 · 1800H GMT+8**. Personnel register a digital handle, get a Unique ID, play National Education mini-games against the clock, complete a field challenge, and appear on a live, time-ranked leaderboard.

---

## ⚠️ TODO before the event

- [ ] **"Own the Process" Chapter 4** — the real photo is in (`assets/changi-airport.jpg`);
  still need the exact coordinates: `index.html` → `G4_C4_LAT` / `G4_C4_LNG`
  (ships as `1.36` / `103.99`, a public approximation) — set to the exact
  coordinates you want, to 2 decimal places.

---

## What's in this repo

```
index.html          — the entire participant site (one file: HTML/CSS/JS)
assets/
  dis-logo.png      — DIS logo
  harmony.png       — Racial Harmony puzzle image
  scene-1/2/3.jpg   — SGSecure scene photos (hotspots)
  pwned.png         — malware takeover image
supabase/
  schema.sql        — database schema + RPC functions (run once in Supabase)
_config.yml         — keeps project/, chats/, supabase/ out of the deployed site
project/, chats/     — original design files + session history (reference only)
```

> The **admin console (`admin.html`) is intentionally NOT in this repo.** It's a
> private file kept on the organiser's device, so participants can't reach it.

---

## Tech stack

| Layer | What |
|---|---|
| Frontend | Plain HTML + CSS + vanilla JS — no build step, no framework |
| Backend | [Supabase](https://supabase.com) (Postgres + REST + Realtime) |
| Hosting | GitHub Pages (`andoujj.github.io/dis-mission-hub`) |
| Fonts | Google Fonts — Instrument Serif, JetBrains Mono |

---

## Features

- **Access-code gate** → **digital-handle registration** → **Unique ID** issued per handle.
- **United by Action** — no outer gate. Find someone from another command, take a selfie, and get it verified in person by a Game Master, who gives you a code. Entering that code (`pw_expedition`, repurposed as the completion check) logs the mission — untimed, doesn't count toward the leaderboard total.
- **Six NE mini-games:** Foreign Interference (MCQ), SGSecure (tap-the-threat on real photos), **Preserving Racial and Religious Peace** — a 13-clue crossword whose answers spell RACIAL HARMONY down a shared spine column, **Own the Process** — no outer password gate; goes straight into a 4-chapter narrative repelling a simulated cyberattack, opening with its own password-guessing puzzle (Chapter 1), then a Morse-coded attack-type triple, a fill-in-the-missing-line Python snippet, and a Changi Airport coordinates pinpoint — **Echoes of Cipher** — a single riddle combining a spoken (text-to-speech) clue, a letter-position cipher, a system-status icon, and a binary-decode block into one answer — and **The Hidden Vow** — three ordered riddles, each unlocking a one-word key.
- **Per-game password lock + per-game timer.** Each game is unlocked by its own password and timed individually; the leaderboard total is the **sum** of all games' durations.
- **Leaderboard** ranks by **fastest total time**.
- **"Malware injection"** — the organiser can trigger a full-screen takeover on any participant (or everyone). It's tied to the handle in the database, so refresh/incognito can't clear it; the victim must enter **someone else's Unique ID** to clear it. Each wrong guess adds a **+1:00 penalty** (and shows "Guessing passwords isn't clever — it's reckless"); leaving it unresolved for 5 minutes auto-clears it with a **+5 min penalty**.
- **Live `games_locked` switch** stored in Supabase — toggled from the admin console with no redeploy.

---

## Setup

### 1. Database
In Supabase → **SQL Editor**, paste and run `supabase/schema.sql`.

### 2. Settings (Table Editor → `app_settings`)
Change every default before the event:

| key | meaning |
|---|---|
| `pw_ne-1` / `pw_ne-2` / `pw_ne-3` | the three game passwords |
| `pw_ne-5` / `pw_ne-6` | **Echoes of Cipher** / **The Hidden Vow** passwords |
| `pw_expedition` | **United by Action** completion code — give this to a Game Master to hand out in person after verifying the selfie (there's no entry gate; ne-4 "Own the Process" also has no outer gate — Chapter 1 is its own password puzzle) |
| `admin_pw` | admin-console password — **use a long random value** (it's checked over the API) |
| `games_locked` | `true` locks the six NE mini-games behind their passwords (United by Action is never gated) |

### 3. Credentials
`index.html` (and the private `admin.html`) embed the Supabase **Project URL**
and **anon key**. The anon key is public by design. If you spin up a fresh
project, update those two constants in both files.

### 4. Go live
Flip `games_locked` to `true` (from the admin console or the Table Editor) once
everyone's ready. Clients pick it up within ~20s — no redeploy needed.

---

## Security model (important)

There is **no login** — identity is a free-text handle in `localStorage`. RLS
policies and `SECURITY DEFINER` RPCs are the enforcement layer:

- **Challenge IDs are server-validated** (a trigger rejects any `challenge_id`
  not present in the `challenges` table).
- **Passwords** (`pw_*`, `admin_pw`) live in `app_settings`, which has RLS with
  **no policies** — unreadable from the browser; only the RPCs can see them.
- **Unique IDs are not bulk-readable.** The `uid` column on `handles` is revoked
  from the anon role (column-level grant) and `handles` is kept out of Realtime,
  so nobody can dump everyone's IDs to defeat the malware game. The admin console
  reads UIDs via the password-gated `admin_roster` RPC.
- **Every `SECURITY DEFINER` function pins `search_path`** to avoid hijacking.
- **Game times** require a matching completion (`finish_game`), so a time can't
  be recorded without finishing the game.

Residual, accepted risk (inherent to having no auth): a determined user could
POST completions or start/stop timers for a handle via the raw API. Times
require a matching completion, so the blast radius is small for a casual
event — but it is not a hardened competition system.

---

## Local development

Just open `index.html` in a browser. With no Supabase reachable it falls back to
`localStorage`: games are playable and open (no lock, no timer, no malware), but
there's no shared leaderboard. The locked/timed/malware behaviour only applies
when Supabase is connected (the lock state comes from `get_games_locked`).

---

## Deploying

Auto-deploys to GitHub Pages on every push to `main` (~60s). Live URL:
**[andoujj.github.io/dis-mission-hub](https://andoujj.github.io/dis-mission-hub)**

---

## Design rules (don't change these)

- **Don't touch the CSS custom properties** in `:root` — they are the design system.
- **DIS orange `#FF7300`** is the only accent (CB mode swaps it to `#2A84FF`). Keep new color-coded UI working in both palettes.
- **No rounded corners**, **don't uppercase handles** (`V1per` ≠ `Viper`), and match existing card/modal/row patterns rather than redesigning.

---

## Key localStorage keys

| Key | Value |
|---|---|
| `dis_handle` | the registered handle |
| `dis_uid` | the user's Unique ID (issued at registration) |
| `dis_completions_{handle}` | array of completed challenge IDs (JSON) |
| `dis_unlock_{game}` | `"1"` once a game's password has been entered this session |
| `dis_cb` | `"1"` if color-blind mode is on |
