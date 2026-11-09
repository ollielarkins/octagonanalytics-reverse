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

Not hosted yet. It documents internal architecture and security, so publish it only behind a
login, never as a public page.
