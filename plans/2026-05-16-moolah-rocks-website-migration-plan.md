# moolah.rocks Website Migration — Plan

> Replace the legacy moolah-web login site at moolah.rocks with a new static
> marketing/beta site for moolah-native, hosted on GitHub Pages, served from
> the existing `moolah.rocks` domain.

## Goals

1. Ship a static, brand-compliant moolah.rocks site that markets moolah-native
   (currently in beta, not on the App Store).
2. Give Mac users a one-click download of the latest RC from GitHub Releases.
3. Let iOS users join the TestFlight beta.
4. Move hosting off the legacy server onto GitHub Pages, served from the
   `moolah.rocks` apex domain over HTTPS.
5. Decommission the old moolah-web sign-in flow entirely.

## Non-Goals

- App Store / public-availability messaging (the app is beta-only for now).
- Any sign-in, account, or web-app functionality (the old site's reason for
  existing — explicitly dropped).
- A build framework / SSG. The site is small enough to hand-author; no Node
  toolchain, no Jekyll. Plain HTML + one CSS file + static assets.
- Blog, docs portal, or changelog site (out of scope; can come later).

## Key Findings (researched 2026-05-16)

- **No website source exists in this repo.** The legacy site lives on a
  separate server. Brand assets (`Brand/`), releases, and the notarised Mac
  zip all live in *this* repo, so co-locating the site here keeps the
  "latest Mac download" link and brand assets trivially in sync.
- **DNS is on Cloudflare.** `moolah.rocks` nameservers are
  `elaine.ns.cloudflare.com` / `gabe.ns.cloudflare.com`. The apex `A` records
  (`104.21.14.16`, `172.67.133.192`) are Cloudflare proxy IPs pointing at the
  old server. Cutover is a Cloudflare-dashboard DNS change — no registrar
  involvement, 300s TTL, fast rollback.
- **No MX records.** `moolah.rocks` has no email. A `beta@moolah.rocks`
  request flow would require standing up email first (Cloudflare Email
  Routing is free) — so the plan defaults to a **public TestFlight link**,
  which needs zero infrastructure.
- **Release artifacts.** `release-final.yml` attaches `Moolah-*.zip` (notarised
  Mac build) to each GitHub Release; RCs carry the same via `release-rc`. The
  site should link to the latest release's Mac zip, not a pinned version.
- **Repo conventions.** `CLAUDE.md` reserves `docs/` ("Never create a `docs/`
  directory") and routes plans to `plans/`. The site therefore lives in
  `site/`. `just format-check` / CI only inspect tracked `.swift` files, so
  web files won't trip Swift tooling.

## Decisions (confirmed with user)

| Decision | Choice |
|---|---|
| Site source location | `site/` in this repo, deployed via GitHub Actions to Pages |
| Custom domain | Keep `moolah.rocks` (apex), served by GitHub Pages over HTTPS |
| iOS beta join | **Recommended:** public TestFlight invitation link (no MX on domain) |

## Architecture

### Repository layout

```
site/
  index.html            # single-page marketing/beta site
  styles.css            # brand-compliant styles (Poppins, color tokens)
  CNAME                 # contains: moolah.rocks
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
  robots.txt
```

Brand assets are **copied** into `site/` (not symlinked) so the Pages
artifact is self-contained and the deploy workflow stays trivial. A short
note in the site README (or a `just` recipe — see Optional) documents that
`site/` brand assets are derived from `Brand/` and must be re-copied if the
source changes.

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
   redirect loops / cert errors. If the user wants to keep Cloudflare proxy
   later, that's a follow-up requiring Cloudflare SSL mode = Full (strict)
   and confirmed Pages cert — out of scope for the cutover.
3. Verify in repo **Settings → Pages**: custom domain shows a green check,
   then tick **Enforce HTTPS**.
4. Keep the old server running until the new site is verified live at
   `https://moolah.rocks`, then decommission.

Rollback: revert the Cloudflare records to the old proxy IPs (300s TTL).

### Decommission legacy moolah-web

- After cutover is verified, retire the old login site/server.
- Add explicit redirects/410s for any legacy auth paths if they were indexed
  (e.g. `/login`, `/signin`) — a static `404.html` on Pages handles unknown
  paths gracefully; old deep links simply 404.
- No data migration: the old site was a login shell for an unmaintained
  product; nothing to preserve.

## Site Content (single page, brand-compliant)

All copy from `guides/BRAND_GUIDE.md §11` (approved) — no invented features.
Voice: playful surface, rigorous underneath. Colors/typography per
§3/§4 (Poppins, Brand Space `#07102E` hero, Income Blue CTAs, etc.).

1. **Nav** — horizontal lockup (`lockup-horizontal-on-dark.png`), anchor
   links (Features, Privacy, Get the app). **No sign-in button** (this is the
   whole point of the migration).
2. **Hero** — Brand Space background + `website-hero` imagery. Headline using
   approved tagline "Your money, rock solid." + hero subhead. Two CTAs:
   "Download for Mac" (primary, Income Blue) and "Join the iOS beta"
   (secondary, bordered).
3. **Beta notice** — short, honest banner: the app is in beta, not yet on the
   App Store. Calm/transparent tone (§2 legal/privacy tone).
4. **Features** — grid from §10 Product Facts (tracking, categories, splits,
   notes, search, recurring, multiple accounts, budgets, reports, charts,
   filters, export). Feature→benefit framing from §11.
5. **Privacy** — "Private. Like, actually private." + the approved privacy
   detail. On-device, optional iCloud, no accounts, no servers.
6. **Get the app**
   - **Mac:** primary button → latest release Mac zip. Use a stable URL:
     `https://github.com/ajsutton/moolah-native/releases/latest`
     (lands on the newest release; the `Moolah-*.zip` asset is right there).
     A direct-asset link isn't stable across versions, so link to
     `releases/latest` and label it "Download the latest Mac build (beta)".
   - **iOS:** "Join the TestFlight beta" → public TestFlight invitation URL
     (placeholder `https://testflight.apple.com/join/REPLACE_ME` until the
     user supplies the real code). Note: requires the TestFlight build to
     have a **public link** enabled in App Store Connect.
   - Fallback path (only if user later rejects the public link): Cloudflare
     Email Routing → `beta@moolah.rocks` forwarding to a real inbox, site
     shows a `mailto:`. Documented but not built by default.
7. **Footer** — wordmark, copyright, links to GitHub repo and (if it exists)
   a privacy policy / support contact. No legal sign-in remnants.
8. **`<head>`** — meta tags exactly per `BRAND_GUIDE.md §7` (favicon,
   apple-touch-icon, OG title/description/image), `theme-color` = Brand
   Space, `site.webmanifest` linked, viewport, description.

Accessibility: semantic landmarks, alt text on all imagery, visible focus
states, color contrast meeting WCAG AA against Brand Space (the brand palette
is designed for this — verify the gold-on-navy combos).

## Task Breakdown

1. **Scaffold** `site/` with `index.html`, `styles.css`, `CNAME`,
   `robots.txt`, `404.html`.
2. **Copy brand assets** from `Brand/Web/` and `Brand/Logo/` /
   `Brand/Social/` into `site/` + `site/assets/`.
3. **Build the page** section by section against `BRAND_GUIDE.md`; use only
   approved copy and §10 product facts.
4. **Wire links:** Mac → `releases/latest`; iOS → TestFlight placeholder
   (flag clearly for the user to fill in).
5. **Add deploy workflow** `.github/workflows/deploy-site.yml` (Actions →
   Pages, SHA-pinned actions, path-filtered to `site/**`).
6. **Local check:** open `site/index.html`, verify layout/responsive/links,
   run an HTML/contrast sanity pass.
7. **Commit & push** to `claude/migrate-to-moolah-native-V1Ygs`; open a PR
   (PR-only — `main` is protected).
8. **Post-merge, one-time (user actions, documented in PR):**
   - Repo Settings → Pages → Source = GitHub Actions; custom domain
     `moolah.rocks`.
   - Enable TestFlight public link; replace the placeholder URL.
   - Cloudflare DNS cutover (records above, grey-cloud).
   - Verify `https://moolah.rocks`, enable Enforce HTTPS.
   - Decommission the old server.

## Optional / Follow-ups

- `just site-assets` recipe that re-copies `Brand/` → `site/` so brand
  updates have one obvious sync command.
- `www → moolah.rocks` redirect.
- Lighthouse/htmltest CI check on the Pages artifact.
- Cloudflare Email Routing for `beta@moolah.rocks` if the email path is
  ever preferred over the public TestFlight link.
- Re-enable Cloudflare proxy with SSL Full (strict) once the Pages cert is
  confirmed, if DDoS/edge caching is wanted.

## Risks & Open Questions

- **TestFlight public link** must be enabled in App Store Connect by the
  user; the site ships with a placeholder until then. (Decision: confirm
  public link vs. gated email — recommended public.)
- **Cloudflare proxy vs. Pages cert** — cutover must use grey-cloud DNS or
  HTTPS breaks. Called out explicitly above.
- **`releases/latest` includes RCs?** `release-rc` publishes pre-releases;
  `releases/latest` resolves to the latest *non-prerelease*. While the app
  is beta with no final releases, `releases/latest` may 404 or be stale.
  Mitigation: link to `releases` (list) or the specific current RC tag until
  a final release exists; revisit when the first non-RC ships. **Open
  question for the user: is there a current non-prerelease, or should the
  Mac button point at the releases list / newest RC for now?**
- **Privacy policy page** — does one exist to link from the footer? If the
  App Store submission later needs one, a `site/privacy.html` is a small
  add-on (not in current scope).
