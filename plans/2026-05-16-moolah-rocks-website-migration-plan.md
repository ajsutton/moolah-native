# moolah.rocks Website Migration — Plan

> Replace the legacy moolah-web login site at moolah.rocks with a new static
> brand site for moolah-native, hosted on GitHub Pages, served from the
> existing `moolah.rocks` domain. Single call to action: register interest
> by email.

## Goals

1. Ship a static, brand-compliant moolah.rocks site that introduces
   moolah-native (currently in private beta, not on the App Store).
2. Drive a single action: **get in touch by email to register interest.**
3. Move hosting off the legacy server onto GitHub Pages, served from the
   `moolah.rocks` apex domain over HTTPS.
4. Decommission the old moolah-web sign-in flow entirely.

## Non-Goals

- App Store / public-availability messaging (the app is beta-only for now).
- Any sign-in, account, or web-app functionality (the old site's reason for
  existing — explicitly dropped).
- **No download links** — no Mac GitHub-release link, no TestFlight link.
  Access is handled off-site after someone registers interest by email.
- A build framework / SSG. The site is small enough to hand-author; no Node
  toolchain, no Jekyll. Plain HTML + one CSS file + static assets.
- Blog, docs portal, or changelog site (out of scope; can come later).
- Migrating anything from the old site's source.

## Key Findings (researched 2026-05-16)

- **No website source exists in this repo.** The legacy site lives in the
  separate `ajsutton/moolah` repo (which also contains the moolah web
  front-end source we don't need) and is served from a separate server.
  Brand assets (`Brand/`) live in *this* repo. The new site is authored
  fresh here from `guides/BRAND_GUIDE.md` — no code is carried over from
  `ajsutton/moolah`. (Note: agent GitHub access is scoped to
  `ajsutton/moolah-native`, so the old repo is referenced for context /
  decommissioning only, not read.)
- **DNS is on Cloudflare.** `moolah.rocks` nameservers are
  `elaine.ns.cloudflare.com` / `gabe.ns.cloudflare.com`. The apex `A` records
  (`104.21.14.16`, `172.67.133.192`) are Cloudflare proxy IPs pointing at the
  old server. Cutover is a Cloudflare-dashboard DNS change — no registrar
  involvement, 300s TTL, fast rollback.
- **No MX records yet.** `moolah.rocks` currently has no email. The single
  CTA is a `mailto:` to an address on the domain (e.g.
  `hello@moolah.rocks`); **the user will set up email for moolah.rocks
  separately** so that address works. The site only needs the `mailto:`
  link — no email infrastructure is built or blocked by this plan.
- **Repo conventions.** `CLAUDE.md` reserves `docs/` ("Never create a `docs/`
  directory") and routes plans to `plans/`. The site therefore lives in
  `site/`. `just format-check` / CI only inspect tracked `.swift` files, so
  web files won't trip Swift tooling.

## Decisions (confirmed with user)

| Decision | Choice |
|---|---|
| Site source location | `site/` in this repo, deployed via GitHub Actions to Pages |
| Custom domain | Keep `moolah.rocks` (apex), served by GitHub Pages over HTTPS |
| Call to action | **Single CTA:** register interest via `mailto:` to a moolah.rocks address |
| Downloads | None on the site (no Mac/TestFlight links) |
| Domain email | User sets up moolah.rocks email separately; site just links `mailto:` |

## Architecture

### Repository layout

```
site/
  index.html            # single-page brand site
  styles.css            # brand-compliant styles (Poppins, color tokens)
  CNAME                 # contains: moolah.rocks
  404.html
  robots.txt
  favicon.ico           # copied from Brand/Web/
  apple-touch-icon.png
  android-chrome-192x192.png
  android-chrome-512x512.png
  og-image-1200x630.png
  site.webmanifest
  assets/
    icon.svg            # from Brand/Logo/icon-only/
    lockup-horizontal-on-dark.png
    website-hero-2560x1440.png
    (other brand imagery as needed)
```

Brand assets are **copied** into `site/` (not symlinked) so the Pages
artifact is self-contained and the deploy workflow stays trivial. A short
note documents that `site/` brand assets derive from `Brand/` and must be
re-copied if the source changes.

### Hosting & deploy

- **GitHub Pages via Actions** (not branch-based Pages), so `docs/`/`gh-pages`
  conventions are avoided and the publish source is explicit.
- New workflow `.github/workflows/deploy-site.yml`:
  - Triggers: `push` to `main` on `site/**` paths, plus `workflow_dispatch`.
  - Uses `actions/configure-pages`, `actions/upload-pages-artifact`
    (path: `site/`), `actions/deploy-pages`.
  - `permissions: pages: write, id-token: write`; `concurrency` group
    `pages` so deploys don't overlap.
  - Pin all actions to commit SHAs (matches repo's existing
    `actions/checkout@<sha>` convention).
- One-time GitHub repo settings: **Settings → Pages → Source: GitHub Actions**;
  set the custom domain to `moolah.rocks` and enable **Enforce HTTPS** once
  the cert provisions.
- `site/CNAME` ⇒ `moolah.rocks` so the domain survives every deploy.

### DNS cutover (Cloudflare)

Done in the Cloudflare dashboard for `moolah.rocks`:

1. Add GitHub Pages apex records (replace the old-server `A` records):
   - `A @ 185.199.108.153`, `185.199.109.153`, `185.199.110.153`,
     `185.199.111.153` (GitHub Pages apex IPs), **and** the AAAA equivalents
     (`2606:50c0:8000::153` … `8003::153`).
   - Optionally `CNAME www → ajsutton.github.io` (then add `www` redirect).
2. **Set these records to "DNS only" (grey cloud), not proxied.** GitHub
   Pages provisions its own Let's Encrypt cert for the custom domain; a
   Cloudflare orange-cloud proxy in front of an unprovisioned cert causes
   redirect loops / cert errors. Re-enabling proxy later requires Cloudflare
   SSL mode = Full (strict) and a confirmed Pages cert — a follow-up, not
   part of cutover.
3. Email records (`MX`, SPF/DKIM `TXT`) the user adds for moolah.rocks email
   are **independent** of the Pages `A`/`AAAA` records and can coexist —
   the `mailto:` CTA works as soon as the user's email is live.
4. Verify in repo **Settings → Pages**: custom domain shows a green check,
   then tick **Enforce HTTPS**.
5. Keep the old server running until the new site is verified live at
   `https://moolah.rocks`, then decommission.

Rollback: revert the Cloudflare records to the old proxy IPs (300s TTL).

### Decommission legacy moolah-web

- After cutover is verified, retire the old login site/server. The source
  in `ajsutton/moolah` is left as-is (archive that repo separately if
  desired — outside this plan's scope and repo).
- A static `404.html` on Pages handles legacy auth deep links
  (`/login`, `/signin`, …) gracefully — they simply 404.
- No data migration: the old site was a login shell for an unmaintained
  product; nothing to preserve.

## Site Content (single page, brand-compliant)

All copy from `guides/BRAND_GUIDE.md §11` (approved) — no invented features.
Voice: playful surface, rigorous underneath. Colors/typography per
§3/§4 (Poppins, Brand Space `#07102E` hero, Income Blue CTAs, etc.).

1. **Nav** — horizontal lockup (`lockup-horizontal-on-dark.png`), anchor
   links (Features, Privacy, Register interest). **No sign-in button**
   (this is the whole point of the migration).
2. **Hero** — Brand Space background + `website-hero` imagery. Headline using
   approved tagline "Your money, rock solid." + hero subhead. Single primary
   CTA: **"Register your interest"** (Income Blue) → `mailto:` anchor that
   jumps to / triggers the email link.
3. **Beta notice** — short, honest banner: the app is in private beta, not
   yet on the App Store; the way in is to get in touch. Calm/transparent
   tone (§2 legal/privacy tone).
4. **Features** — grid from §10 Product Facts (tracking, categories, splits,
   notes, search, recurring, multiple accounts, budgets, reports, charts,
   filters, export). Feature→benefit framing from §11.
5. **Privacy** — "Private. Like, actually private." + the approved privacy
   detail. On-device, optional iCloud, no accounts, no servers.
6. **Register interest** — the single conversion point. Short, warm copy
   ("Want in? Drop us a line and we'll get you set up."), one button:
   `mailto:` to the moolah.rocks address (placeholder
   `hello@moolah.rocks` — **user confirms the exact mailbox**), with a
   sensible `?subject=` (e.g. "moolah beta — register interest"). Show the
   address as plain text too (not everyone has a mail client wired up).
7. **Footer** — wordmark, copyright, link to the GitHub repo. No legal
   sign-in remnants.
8. **`<head>`** — meta tags exactly per `BRAND_GUIDE.md §7` (favicon,
   apple-touch-icon, OG title/description/image), `theme-color` = Brand
   Space, `site.webmanifest` linked, viewport, description.

Accessibility: semantic landmarks, alt text on all imagery, visible focus
states, color contrast meeting WCAG AA against Brand Space. The `mailto:`
must be a real, focusable, screen-reader-labelled link.

## Task Breakdown

1. **Scaffold** `site/` with `index.html`, `styles.css`, `CNAME`,
   `robots.txt`, `404.html`.
2. **Copy brand assets** from `Brand/Web/` and `Brand/Logo/` /
   `Brand/Social/` into `site/` + `site/assets/`.
3. **Build the page** section by section against `BRAND_GUIDE.md`; use only
   approved copy and §10 product facts. Single email CTA, no downloads.
4. **Wire the CTA** to the `mailto:` placeholder; flag the exact address for
   the user to confirm.
5. **Add deploy workflow** `.github/workflows/deploy-site.yml` (Actions →
   Pages, SHA-pinned actions, path-filtered to `site/**`).
6. **Local check:** open `site/index.html`, verify layout/responsive/links,
   run an HTML/contrast sanity pass.
7. **Commit & push** to `claude/migrate-to-moolah-native-V1Ygs`; open a PR
   (PR-only — `main` is protected).
8. **Post-merge, one-time (user actions, documented in PR):**
   - Repo Settings → Pages → Source = GitHub Actions; custom domain
     `moolah.rocks`.
   - Set up moolah.rocks email; confirm the CTA mailbox address.
   - Cloudflare DNS cutover (Pages `A`/`AAAA`, grey-cloud) + email records.
   - Verify `https://moolah.rocks`, enable Enforce HTTPS.
   - Decommission the old server.

## Optional / Follow-ups

- `just site-assets` recipe that re-copies `Brand/` → `site/` so brand
  updates have one obvious sync command.
- `www → moolah.rocks` redirect.
- Lighthouse/htmltest CI check on the Pages artifact.
- Re-enable Cloudflare proxy with SSL Full (strict) once the Pages cert is
  confirmed, if DDoS/edge caching is wanted.
- Add a privacy policy / support page later if an App Store submission
  needs one.

## Risks & Open Questions

- **CTA mailbox address** — site ships with a `hello@moolah.rocks`
  placeholder; the user confirms the exact address when setting up
  moolah.rocks email. The site can deploy before email is live (the link
  just won't deliver until then); recommend confirming the address before
  the DNS cutover so the live site is fully functional.
- **Cloudflare proxy vs. Pages cert** — cutover must use grey-cloud DNS or
  HTTPS breaks. Called out explicitly above.
- **Old repo archival** — retiring `ajsutton/moolah` (or its web front-end)
  is outside this repo/plan; flagged so it isn't forgotten after cutover.
