# Leaf extensions

Third-party source scripts for [Leaf](https://github.com/NmMarcoz/Leaf). Each
`.lua` file here teaches Leaf one site. Leaf itself ships with none of them
and does not link here; you add this repository yourself.

## Using it

In Leaf, open **Extensions → Repositories**, paste this repository's raw
address (the folder holding `index.json`, or `index.json` itself), and
press **Add**. Open the repository to see what it offers; **Install** copies a
script into your library's `extensions/` folder.

Installing does not turn anything on. The script shows up on the Extensions
screen as needing approval, with what it is and every address it may reach;
approve it there once you are happy to run it. Updating a script replaces the
file, which asks for approval again — an update never inherits the old one's.

From a terminal:

```sh
leaf sources repo browse  <address>
leaf sources repo install <address> user.some-site     # or --all
```

## What is here

| folder | kind | what scripts in it can do |
| --- | --- | --- |
| `metadata/` | `metadata` | browse titles and volume lists; never pages |
| `enrich/` | `enrich` | fill in descriptions, credits and covers; never pages |
| `readers/` | `reader` | find chapters on a site and download their pages |

Only scripts in `readers/` can fetch pages, and Leaf enforces that when a
script loads — a `metadata` or `enrich` script that tries is refused.

No images, binaries, chapter samples or screenshots of series live in this
repository, and none should be added: scripts only.

## Contributing a script

How to write one — the manifest, the functions each kind needs, the sandbox
— is documented in Leaf's own
[`docs/EXTENSIONS.md`](https://github.com/NmMarcoz/Leaf/blob/main/docs/EXTENSIONS.md).
Here:

1. Put the file in the folder matching its `SOURCE.kind`, named after its id
   without the prefix (`user.some-site` → `readers/some-site.lua`).
2. Check it loads: `leaf sources verify readers/some-site.lua`.
3. Regenerate the index and commit it with the script:

   ```sh
   python3 scripts/build-index.py
   ```

   `index.json` is generated, never edited by hand. CI regenerates it and
   fails if the committed one differs, and also loads every script through
   Leaf's real sandbox. To catch a stale index before CI does:

   ```sh
   git config core.hooksPath .githooks
   ```

   The scripts need a `leaf` binary — on `PATH`, or as `LEAF_BIN`.

`index.json`'s `version` for a script is the date its bytes last changed;
the sha256 is the real version, and is what Leaf's approval records.

## Mirrors

The address you added is all Leaf knows about this repository. Every tagged
release attaches `index.json` and the scripts as assets, so the whole thing
can be served from any static host; if this repository moves, point Leaf at
the new address and nothing else changes.

See [`TERMS.md`](TERMS.md).
