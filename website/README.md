# AppleTree website

The download and feature page for AppleTree, built with React and Vite. It shows English by default and has a 한국어 toggle. A `?lang=ko` link opens it in Korean, and the visitor's choice is remembered.

## Develop

```sh
npm install
npm run package-app   # builds the Mac app and puts AppleTree.dmg + release.json in public/downloads/
npm run dev
```

## Build and deploy

```sh
npm run package-app
npm run build         # static site in dist/
```

Upload `dist/` to any static host (Vercel, Netlify, Cloudflare Pages, GitHub Pages, S3). The build uses relative paths, so it works at a domain root or under a sub-path.

- **Cloudflare Workers (Workers Builds):** in the Worker's Settings → Build, set the root directory to `website`, the build command to `npm run build` and the deploy command to `npx wrangler deploy`. `wrangler.jsonc` serves `dist/` as static assets. Its `name` must match the Worker's name in the dashboard. Locally, `npm run deploy` builds and deploys in one step.
- **Vercel / Netlify / Cloudflare Pages:** set the root directory to `website`, the build command to `npm run build` and the output directory to `dist`.

Hosted builders run on Linux and can't build the Mac app, so `public/downloads/` is committed. After changing the app, run `npm run package-app` on a Mac and commit the new dmg, or host the dmg elsewhere with `VITE_DOWNLOAD_URL` (below).
- **GitHub Pages:** run both commands on a Mac and publish `dist/`.

### Hosting the dmg elsewhere

To serve the app from a GitHub Release or a CDN instead of the site itself, set `VITE_DOWNLOAD_URL` at build time (see `.env.example`):

```sh
VITE_DOWNLOAD_URL=https://github.com/tangible-idea/appletree/releases/latest/download/AppleTree.dmg npm run build
```

If `public/downloads/release.json` is missing, the page leaves out the version and file size and keeps the system requirements.

## Content

- All text lives in `src/i18n.ts` (`en` and `ko`).
- Screenshots in `public/screenshots/` come from the app's debug build:
  `swift run AppleTree -AppleLanguages '(en)' --snapshot "$PWD/website/public/screenshots/app-en.png"`
  and `--cleanup-result-snapshot` for the cleanup screen. Use `'(ko)'` for the Korean versions.

The app is ad-hoc signed, so macOS asks visitors to allow it on first launch. The install steps on the page explain how. Signing with a Developer ID and notarizing the app would remove that step.
