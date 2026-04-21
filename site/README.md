# autonomous landing

Marketing site for [autonomous](https://github.com/Sma1lboy/autonomous).

## Structure

- `index.html` — single-file, self-contained bundle. Deploy this.
- `landing.html` — source entry point. Loads `styles.css` + `src/app.jsx`.
- `styles.css` — all styling.
- `src/app.jsx` — React + Babel app. Hero, architecture, how-it-works, exploration dims, safety, skills, terminal demo, footer.

## Deploy

Serve `index.html` from anywhere static — Vercel, Netlify, Cloudflare Pages, S3, nginx. No build step.

```
# example: vercel
cd site && vercel --prod

# example: netlify
netlify deploy --prod --dir=site
```

## Edit

Edit `landing.html`, `styles.css`, or `src/app.jsx`, then re-bundle into a single file. Any inliner works; the existing `index.html` was produced by the Claude design tool's bundler.

## Tweaks

The page has a built-in tweaks panel (accent color, density, live-log on/off, copy variants). Toggle via the host chrome when editing in Claude.
