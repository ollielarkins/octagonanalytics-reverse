# Octagon Analytics knowledge base

The docs site for the platform: Astro Starlight, replacing the GitHub wiki in `docs/wiki/`.

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # static site in dist/, with search
```

Commands, Tools and the live counts are generated from source by `scripts/generate.mjs` before
every `dev` and `build`. It expects `octagon-plugins` checked out next to this repo, or
`OCTAGON_PLUGINS_DIR` pointing at its `plugins` folder.

How the site is organised and the house style: `src/content/docs/run/writing-docs.mdx`.

Hosted on Cloudflare Pages at https://octagon-kb.pages.dev, deployed by
`.github/workflows/docs.yml` on every push to `main` that touches it. There is no login (the repo
is public too), but every page is `noindex` and `robots.txt` disallows crawling, so it stays out
of search results. Never put candidate names, secrets or keys in a page.
