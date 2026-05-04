# Deckhand site

Static site served at `https://dh.printdeck.io` via Cloudflare Pages.

## Deploying via Cloudflare Pages

1. In Cloudflare → **Workers & Pages → Create application → Pages → Connect to Git**.
2. Select `CepheusLabs/deckhand` and authorize.
3. Configure the build:
   - **Build command**: *(leave empty - static files are committed directly)*
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
| `wiki.html` | Wiki home |
| `getting-started.html` | Install walkthrough |
| `usage.html` | App usage guide |
| `manual.html` | Manual shell playbook |
| `cli.html` | CLI and IPC reference |
| `examples.html` | Recipes |
| `faq.html` | FAQ |
| `404.html` | Fallback for missing paths |
| `styles.css` | All styling, no build step |
| `app.js` | Shared navigation, table-of-contents, search modal, and OS highlighting |
| `favicon.svg` | Inline SVG favicon |
| `_headers` | Cloudflare Pages security headers |
| `_redirects` | Extensionless page routes and short URLs |

## Updating download links

Download links should point at GitHub's `releases/latest` URL where possible,
which resolves to the newest release without site changes after a tagged build.
