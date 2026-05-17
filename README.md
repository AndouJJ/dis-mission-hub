# DIS Mission Hub — Year IV

A web app for DIS personnel built around the organisation's **4th Anniversary on October 28, 2026 · 1800H GMT+8**. Personnel log in with a digital handle, track a live countdown, complete missions to earn points, and appear on a personnel leaderboard.

---

## What's in this repo

```
index.html          — the entire site (one file, plain HTML/CSS/JS)
assets/
  dis-logo.png      — DIS logo
supabase/
  schema.sql        — database schema (run once in Supabase)
project/            — original design files from Claude Design (reference only)
chats/              — design session transcript (context/history)
```

---

## Tech stack

| Layer | What |
|---|---|
| Frontend | Plain HTML + CSS + vanilla JS — no build step, no framework |
| Backend | [Supabase](https://supabase.com) (Postgres + REST API) |
| Hosting | GitHub Pages (`andoujj.github.io/dis-mission-hub`) |
| Fonts | Google Fonts — Instrument Serif, Inter, JetBrains Mono |

---

## Getting started (local)

No install needed. Just open the file:

```bash
open index.html
# or drag it into any browser
```

The site works fully offline using `localStorage` if Supabase isn't configured. You won't have a live leaderboard or handle uniqueness, but everything else works.

---

## Connecting to Supabase

The Supabase project is already provisioned. To get the credentials:

1. Go to [app.supabase.com](https://app.supabase.com) → the `dis-mission-hub` project
2. **Settings → API** → copy the **Project URL** and **anon/public key**

Then open `index.html` and find these two lines near the bottom of the `<script>` block:

```javascript
const SUPABASE_URL      = 'https://bdbgbhedupsjqukgethi.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGci...';
```

They're already filled in — you don't need to change them unless the project is replaced.

### If setting up a fresh Supabase project

1. Create a project at [app.supabase.com](https://app.supabase.com)
2. Go to **SQL Editor → New query**, paste the contents of `supabase/schema.sql`, and run it
3. Replace the URL and anon key in `index.html` with your new project's values

---

## Database schema

Three objects live in Supabase:

**`handles` table** — one row per registered digital handle

| Column | Type | Notes |
|---|---|---|
| `handle` | text | Primary key, unique, case-sensitive |
| `created_at` | timestamptz | Auto-set on insert |
| `points` | int | Updated automatically by trigger |

**`completions` table** — one row per challenge a user completes

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | Auto-generated |
| `handle` | text | FK → handles |
| `challenge_id` | text | e.g. `exp-1`, `exp-2` |
| `points` | int | Points awarded for this challenge |
| `completed_at` | timestamptz | Auto-set on insert |

A `UNIQUE(handle, challenge_id)` constraint prevents double-submission.

**Trigger** — when a completion is inserted, `handles.points` is recalculated automatically. You never write points directly.

---

## Adding a new mission

1. **Add the card HTML** in `index.html` inside `.missions-grid` — copy any existing `<article class="mission-card">` as a template
2. **Add the detail modal** if the mission has sub-challenges — copy the `#mission-modal` block and give it a new ID
3. **Register the challenge IDs and point values** in the `CHALLENGE_PTS` object near the top of the `<script>`:

```javascript
const CHALLENGE_PTS = {
  'exp-1': 10,
  'exp-2': 70,
  'exp-3': 80,
  'exp-4': 100,
  'new-mission-1': 50,  // ← add new ones here
};
```

4. Each challenge `<li>` needs `data-cid` (matching the key above) and `data-pts` (the point value):

```html
<li class="challenge" data-cid="new-mission-1" data-pts="50">
```

The checkmark confirmation flow, point tracking, and duplicate-submission prevention are all wired up automatically.

---

## Deploying

The site auto-deploys to GitHub Pages on every push to `main`.

Live URL: **[andoujj.github.io/dis-mission-hub](https://andoujj.github.io/dis-mission-hub)**

To push changes:

```bash
git add .
git commit -m "your message"
git push origin main
```

GitHub Pages picks it up within ~60 seconds.

---

## Design rules (don't change these)

The visual system is locked. When making changes:

- **Don't touch the CSS custom properties** in `:root` — colors, fonts, and spacing are the design system
- **DIS orange `#FF7300`** is the only accent color. Don't introduce new accent colors
- **No rounded corners** — `border-radius: 0` everywhere, intentional
- **Don't uppercase handles** — case is preserved as typed (`V1per` ≠ `Viper`)
- **Don't redesign components** — if you need a new UI surface, match the existing card/modal/row patterns

Color-blind mode (CB MODE button in the topbar) swaps orange → `#2A84FF`. If you add new color-coded UI, make sure it works in both palettes.

---

## Key localStorage keys

| Key | Value |
|---|---|
| `dis_handle` | The user's registered handle (string) |
| `dis_completions_{handle}` | Array of completed challenge IDs (JSON) |
| `dis_cb` | `"1"` if color-blind mode is on |

These are used as a local cache and fallback. Supabase is the source of truth when configured.

---

## Countdown target

**October 28, 2026 · 18:00 local time.** When the countdown hits zero, all mission cards automatically flip from "Unlocks Oct 28" → "Open" and become clickable. No server change needed — it's client-side.

---

## Questions?

Check `chats/chat1.md` for the full design history — it explains why specific decisions were made (handle case-sensitivity, point values, the accessibility toggle, etc.).
