# SPDX-License-Identifier: GPL-2.0-or-later
"""Browser tests for the brand art review page (playwright + a real serve.py on a fixture inventory)."""
import json
import struct
import sys
import threading
import zlib
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import inventory  # noqa: E402
import previews  # noqa: E402
import serve  # noqa: E402
from test_inventory import GOOD, make_root, write_surfaces  # noqa: E402

sync_api = pytest.importorskip("playwright.sync_api")


def tiny_png():
    raw = b"\x00" + b"\x10\x20\x30"
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def start(out):
    server = serve.make_server(out, port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


@pytest.fixture
def site(tmp_path):
    root = make_root(tmp_path)
    out = tmp_path / "brandart"
    inventory.build(root, write_surfaces(tmp_path, GOOD), out, image={"iso": "nisse-live.iso", "built": "2026-11-04T10:00Z", "sha256": "abcd"})
    previews.run(out)
    server, base = start(out)
    yield base, out, server
    server.shutdown()
    server.server_close()


@pytest.fixture
def browser():
    with sync_api.sync_playwright() as p:
        b = p.chromium.launch()
        yield b
        b.close()


def groups_of(out):
    return json.loads((out / "inventory.json").read_text())["groups"]


def open_page(browser, base):
    page = browser.new_page(viewport={"width": 1300, "height": 900})
    page.goto(base + "/")
    page.wait_for_selector("#groups li")
    return page


def test_every_group_and_the_items_of_the_first_group_are_listed(browser, site):
    base, out, _ = site
    page = open_page(browser, base)
    groups = groups_of(out)
    names = page.locator("#groups li button").all_inner_texts()
    for g in groups:
        assert any(g["title"] in n for n in names), g["title"]
    assert page.locator("#cards .card").count() == len(groups[0]["items"])
    page.locator('#groups li[data-group="wallpapers"] button').click()
    assert page.locator("#cards .card").count() == len(next(g for g in groups if g["id"] == "wallpapers")["items"])


def test_a_comment_is_saved_and_survives_a_reload(browser, site):
    base, out, _ = site
    page = open_page(browser, base)
    first = page.locator("#cards .card").first
    item_id = first.get_attribute("data-id")
    first.locator("textarea.comment").fill("Make the cap bigger.")
    page.wait_for_selector('#save-state[data-state="saved"]')
    saved = json.loads((out / "comments.json").read_text())
    assert saved["items"][item_id]["comment"] == "Make the cap bigger."
    page.reload()
    page.wait_for_selector("#cards .card")
    assert page.locator(f'#cards .card[data-id="{item_id}"] textarea.comment').input_value() == "Make the cap bigger."


def test_verdict_and_priority_are_saved(browser, site):
    base, out, _ = site
    page = open_page(browser, base)
    card = page.locator("#cards .card").first
    item_id = card.get_attribute("data-id")
    card.locator('.verdict button[data-verdict="redraw"]').click()
    card.locator("select.priority").select_option("must")
    page.wait_for_selector('#save-state[data-state="saved"]')
    saved = json.loads((out / "comments.json").read_text())["items"][item_id]
    assert (saved["verdict"], saved["priority"]) == ("redraw", "must")
    assert card.locator('.verdict button[data-verdict="redraw"]').get_attribute("aria-pressed") == "true"


def test_two_tabs_see_each_others_saved_comments_after_a_reload(browser, site):
    base, _, _ = site
    a, b = open_page(browser, base), open_page(browser, base)
    card = a.locator("#cards .card").first
    item_id = card.get_attribute("data-id")
    card.locator("textarea.comment").fill("from tab A")
    a.wait_for_selector('#save-state[data-state="saved"]')
    b.reload()
    b.wait_for_selector("#cards .card")
    assert b.locator(f'#cards .card[data-id="{item_id}"] textarea.comment').input_value() == "from tab A"


def test_the_background_switch_changes_every_preview_background(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    preview = page.locator("#cards .card .preview").first
    colors = set()
    for choice in ("light", "dark", "ink"):
        page.select_option("#bg", choice)
        colors.add(preview.evaluate("e => getComputedStyle(e).backgroundColor"))
    assert len(colors) == 3
    page.select_option("#bg", "checker")
    assert "gradient" in preview.evaluate("e => getComputedStyle(e).backgroundImage")


def test_the_uncommented_filter_hides_commented_cards(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    total = page.locator("#cards .card").count()
    page.locator("#cards .card").first.locator("textarea.comment").fill("done")
    page.wait_for_selector('#save-state[data-state="saved"]')
    page.check("#only-uncommented")
    assert page.locator("#cards .card").count() == total - 1
    page.uncheck("#only-uncommented")
    assert page.locator("#cards .card").count() == total


def test_search_finds_items_across_groups(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    page.fill("#search", "dawn")
    page.wait_for_selector("#cards .card")
    titles = page.locator("#cards .card .title").all_inner_texts()
    assert titles and all("dawn" in t.lower() for t in titles)


def test_adding_a_request_shows_up_in_the_export(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    page.click("#add-request")
    page.locator("#custom .custom input.title").last.fill("Tray icon")
    page.locator("#custom .custom textarea.comment").last.fill("Monochrome, four states")
    page.wait_for_selector('#save-state[data-state="saved"]')
    page.click("#export")
    page.wait_for_selector("#export-md")
    md = page.locator("#export-md").inner_text()
    assert "Tray icon" in md and "Monochrome, four states" in md and "Overall direction" in md


def test_the_overall_direction_and_group_comment_are_saved(browser, site):
    base, out, _ = site
    page = open_page(browser, base)
    page.fill("#direction", "Warm and round.")
    page.fill("#group-comment", "Start with these.")
    page.wait_for_selector('#save-state[data-state="saved"]')
    state = json.loads((out / "comments.json").read_text())
    assert state["direction"] == "Warm and round."
    assert state["groups"][groups_of(out)[0]["id"]]["comment"] == "Start with these."


def test_a_failed_save_turns_red_and_keeps_the_text(browser, site):
    base, _, server = site
    page = open_page(browser, base)
    server.shutdown()
    server.server_close()
    box = page.locator("#cards .card").first.locator("textarea.comment")
    box.fill("must not be lost")
    page.wait_for_selector('#save-state[data-state="error"]', timeout=15000)
    assert box.input_value() == "must not be lost"


def test_text_typed_while_the_server_was_down_is_pushed_after_a_reload(browser, site):
    base, out, server = site
    port = server.server_address[1]
    page = open_page(browser, base)
    card = page.locator("#cards .card").first
    item_id = card.get_attribute("data-id")
    server.shutdown()
    server.server_close()
    card.locator("textarea.comment").fill("typed during an outage")
    page.wait_for_selector('#save-state[data-state="error"]', timeout=15000)
    # the server comes back on the same port (localStorage is per origin); the reload pushes the local copy
    server2 = serve.make_server(out, port=port)
    threading.Thread(target=server2.serve_forever, daemon=True).start()
    try:
        page.reload()
        page.wait_for_selector('#save-state[data-state="saved"]', timeout=15000)
        assert page.locator(f'#cards .card[data-id="{item_id}"] textarea.comment').input_value() == "typed during an outage"
        assert json.loads((out / "comments.json").read_text())["items"][item_id]["comment"] == "typed during an outage"
    finally:
        server2.shutdown()
        server2.server_close()


def test_no_card_prints_the_word_null_or_undefined(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    for gid in [g["id"] for g in groups_of(site[1])]:
        page.locator(f'#groups li[data-group="{gid}"] button').click()
        text = page.locator("#cards").evaluate("e => e.textContent")  # textContent: innerText skips stray text nodes
        assert "null" not in text and "undefined" not in text, gid


def test_missing_art_cards_say_so(browser, site):
    base, _, _ = site
    page = open_page(browser, base)
    assert page.locator("#cards .card.missing").count() >= 1
    assert "no graphic" in page.locator("#cards .card.missing .preview").first.inner_text().lower()


def test_keyboard_moves_between_cards_and_sets_a_verdict(browser, site):
    base, out, _ = site
    page = open_page(browser, base)
    page.keyboard.press("j")
    page.keyboard.press("2")  # verdict: redraw
    page.wait_for_selector('#save-state[data-state="saved"]')
    focused = page.locator("#cards .card.focus")
    assert focused.count() == 1
    item_id = focused.get_attribute("data-id")
    assert json.loads((out / "comments.json").read_text())["items"][item_id]["verdict"] == "redraw"


def test_the_page_makes_no_request_outside_the_local_server(browser, site):
    base, _, _ = site
    page = browser.new_page()
    seen = []
    page.on("request", lambda r: seen.append(r.url))
    page.goto(base + "/")
    page.wait_for_selector("#cards .card")
    page.click("#export")
    page.wait_for_selector("#export-md")
    assert seen and all(u.startswith(base) or u.startswith("data:") for u in seen), [u for u in seen if not u.startswith(base)]


def test_a_large_group_loads_only_the_images_near_the_viewport(browser, tmp_path):
    out = tmp_path / "big"
    (out / "assets").mkdir(parents=True)
    (out / "assets" / "x.png").write_bytes(tiny_png())
    items = [{"id": f"big/item-{n}", "title": f"item {n}", "seen": "x", "kind": "png", "source": f"/usr/x/{n}.png", "owner": "", "license": "",
              "width": 1, "height": 1, "asset": "assets/x.png", "preview": "assets/x.png", "variants": []} for n in range(400)]
    inv = {"image": {"iso": "t", "built": "t", "sha256": "t"}, "groups": [{"id": "big", "title": "Big", "seen": "x", "items": items}], "notes": []}
    (out / "inventory.json").write_text(json.dumps(inv))
    server, base = start(out)
    try:
        page = open_page(browser, base)
        page.wait_for_selector("#cards .card")
        page.wait_for_timeout(500)
        assert page.locator("#cards .card").count() == 400
        loaded = page.evaluate("() => [...document.querySelectorAll('#cards img')].filter(i => i.complete && i.naturalWidth > 0).length")
        assert loaded < 80, f"{loaded} of 400 images loaded at once"
    finally:
        server.shutdown()
        server.server_close()
