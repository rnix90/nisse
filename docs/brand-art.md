# Brand art review page

A local page that shows every graphic nisse inherits from Fedora and KDE (505 items in 12 groups), with a verdict,
priority and comment per item, and exports one brief of what to draw.

## Run it

    bash tools/brandart/extract_in_vm.sh        # pulls the art out of out/nisse-live.iso (build VM must be up)
    python tools/brandart/previews.py out/brandart
    bash tools/brandart/run.sh                  # starts the server on 127.0.0.1 and opens the browser

Phone or another device on the home network:

    python -u tools/brandart/serve.py --dir out/brandart --port 8765 --lan

It prints a link ending in `?t=TOKEN`. Open that link on the phone. The token sets a cookie; any request without it
gets 403. The token changes on every start. Use `python.exe`, not `python3.exe`: only `python.exe` has an inbound
Windows firewall allow rule on RN-DESKTOP.

## What it keeps

- `out/brandart/comments.json` (autosaved, atomic; `comments.json.bak` is the previous save). A re-extraction replaces
  only `inventory.json` and `assets/`; comments, backups and submissions are left alone.
- The page also mirrors every change to the browser's localStorage and pushes it on the next load if a save failed.
- Comments on items that are no longer in the image are kept and listed separately in the export.

## Export

"Export submission" writes `out/brandart/submission-DATE.md` (plain ASCII) and a `submission-DATE/` folder with copies
of the originals marked redraw or new variant. The first submission is `docs/brand-art-submission-2026-11-05.md`.

## Items that need your eye after the 0.2 image

The 0.2 image replaced the Fedora hot dog sources, so a few ids changed. Comments on these ids no longer match an item:
`installer/anaconda-apps` and `-2` (now nisse-branding art), `logos/distributor-logo-nisse-apps*` (renamed), `boot/charge`.
They are listed under "Comments on items no longer in this image" in the next export.
