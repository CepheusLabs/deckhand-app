# Deckhand landing page

Static site served at `https://dh.printdeck.io` via Cloudflare Pages.

## Deploying via Cloudflare Pages

1. In Cloudflare → **Workers & Pages → Create application → Pages → Connect to Git**.
2. Select `CepheusLabs/deckhand` and authorize.
3. Configure the build:
   - **Build command**: *(leave empty — static files are committed directly)*
   - **Build output directory**: `site`
   - **Root directory**: `/` (repo root)
4. Add the custom domain `dh.printdeck.io` under **Custom domains**.
   Cloudflare will provision the TLS certificate automatically.

Every push to `main` rebuilds; PR branches get preview URLs.

## Local preview

Any static server works:

```powershell
cd D:\git\3dprinting\deckhand\site
npx serve .
```

or

```bash
python3 -m http.server -d site 8080
```

## Files

| File | Purpose |
|------|---------|
| `index.html` | Landing page |
| `404.html` | Fallback for missing paths |
| `styles.css` | All styling, no build step |
| `app.js` | Tiny JS that highlights the OS-matching download card |
| `favicon.svg` | Inline SVG favicon |
| `_headers` | Cloudflare Pages security headers |
| `_redirects` | Short URLs (e.g., `/docs/*` → GitHub) |

## Updating download links

The download cards point at GitHub's `releases/latest` URL, which always
resolves to the newest release. When we cut a tagged release, the links
work without any changes here.
