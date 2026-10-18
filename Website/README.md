# Swift Engine Ferox website

Static marketing site for Swift Engine Ferox (Ferox), served at https://swengine.net/.
Plain HTML, CSS and a small JavaScript file. No build step, no external scripts, fonts or CDNs.

## Preview locally

```sh
python3 -m http.server -d Website 8000
```

Then open http://localhost:8000/. Note that the pages use root-absolute asset paths
(`/assets/...`), so serve the `Website` directory as the site root, as above.

## Package

```sh
cd Website && zip -r ../dist.zip . -x README.md
```

## Files

- `index.html`: the landing page
- `404.html`: the not-found page
- `assets/css/style.css`, `assets/js/main.js`: styles and behaviour
- `assets/logo.svg`, `assets/favicon.svg`: logo and favicon
- `robots.txt`, `sitemap.xml`: crawler files for https://swengine.net/
