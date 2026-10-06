"""Fetch readable text from MediaWiki pages, for adapting into marker notes.

Uses the wiki's public API politely (at most one live request per second, an
identifying User-Agent, responses cached in tools/.wiki-cache). Text from wikis
is usually CC BY-SA: credit the page you adapt from (TOME's `source` field does
this) and license your marker data under CC BY-SA too.

Usage:
    python wiki_text.py https://hollowknight.wiki/mw/api.php "Moss Grotto" [--section Description]
"""

import argparse
import hashlib
import html
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "TOME-pack-builder/0.1 (https://github.com/rahulskann/tome)"
CACHE_DIR = Path(__file__).resolve().parent / ".wiki-cache"
_last_request = 0.0


def api(api_url: str, **params: str) -> dict:
    """GET the MediaWiki API (cached; at most one live request per second)."""
    global _last_request
    query = urllib.parse.urlencode({**params, "format": "json", "formatversion": "2"})
    url = f"{api_url}?{query}"
    cache = CACHE_DIR / (hashlib.sha1(url.encode()).hexdigest() + ".json")
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))
    wait = 1.0 - (time.monotonic() - _last_request)
    if wait > 0:
        time.sleep(wait)
    _last_request = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    if "error" in data:
        raise RuntimeError(f"{params.get('page')}: {data['error'].get('info')}")
    CACHE_DIR.mkdir(exist_ok=True)
    cache.write_text(json.dumps(data), encoding="utf-8")
    return data


def page_wikitext(api_url: str, page: str, prefer: str | None = None) -> tuple[str, str]:
    """(resolved title, wikitext), following redirects.

    On a disambiguation page, follows the option containing `prefer`
    (e.g. "Silksong") if there is one.
    """
    parsed = api(api_url, action="parse", page=page, prop="wikitext", redirects="1")["parse"]
    title, text = parsed["title"], parsed["wikitext"]
    m = re.match(r"\s*\{\{Disambiguation\|([^}]*)\}\}", text)
    if m and prefer:
        options = [o.strip() for o in m.group(1).split("|")]
        match = next((o for o in options if prefer.lower() in o.lower()), None)
        if match:
            return page_wikitext(api_url, match)
    return title, text


# ---- wikitext -> plain text ------------------------------------------------

# Inline templates whose content matters; everything else is dropped.
_INLINE = {
    "R": lambda a: f"{a[0]} Rosaries" if a else "Rosaries",
    "S": lambda a: f"{a[0]} Shell Shards" if a else "Shell Shards",
    "CrestSlot": lambda a: f"{a[0]} Tools" if a else "Tools",
    "C": lambda a: f"{a[0]} Craftmetal" if a else "Craftmetal",
}


def _strip_templates(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        if text.startswith("{{", i):
            depth, j = 0, i
            while j < len(text):
                if text.startswith("{{", j):
                    depth += 1
                    j += 2
                elif text.startswith("}}", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            body = text[i + 2 : j - 2]
            name, *args = [p.strip() for p in body.split("|")]
            if name in _INLINE:
                out.append(_INLINE[name]([a for a in args if "=" not in a]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def to_plain(wikitext: str) -> str:
    t = re.sub(r"<ref[^>/]*/>", "", wikitext)
    t = re.sub(r"<ref[^>]*>.*?</ref>", "", t, flags=re.S)
    t = re.sub(r"<!--.*?-->", "", t, flags=re.S)
    t = re.sub(r"<gallery.*?</gallery>", "", t, flags=re.S)
    t = _strip_templates(t)
    t = re.sub(r"\{\|.*?\|\}", "", t, flags=re.S)  # tables
    t = re.sub(r"\[\[(?:File|Image|Category):[^\[\]]*(?:\[\[[^\]]*\]\][^\[\]]*)*\]\]", "", t)
    t = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", t)
    t = re.sub(r"\[\[([^\]]*)\]\]", r"\1", t)
    t = re.sub(r"\[https?://\S+ ([^\]]*)\]", r"\1", t)
    t = re.sub(r"'''?", "", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t)
    lines = []
    for line in t.splitlines():
        line = re.sub(r"\s+", " ", line).strip()
        if line.startswith(("*", "#")):
            line = "• " + line.lstrip("*#: ").strip()
        lines.append(line)
    text = "\n".join(lines)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def sections(wikitext: str) -> dict[str, str]:
    """{heading: raw wikitext}; "" is the lead. Sub-headings stay in their parent."""
    parts = re.split(r"^(==+)\s*(.*?)\s*\1\s*$", wikitext, flags=re.M)
    result = {"": parts[0]}
    current_top = ""
    for level, name, body in zip(parts[1::3], parts[2::3], parts[3::3]):
        if len(level) == 2:
            current_top = name
            result[name] = body
        else:
            result[current_top] = result.get(current_top, "") + f"\n{body}"
    return result


def paragraphs(text: str, bullets: bool = False) -> list[str]:
    """Prose paragraphs of plain text (and bullet lines if `bullets`)."""
    out = []
    for block in text.split("\n\n"):
        lines = [l for l in block.splitlines() if l and (bullets or not l.startswith("• "))]
        if lines:
            out.append("\n".join(lines))
    return out


# ---- TabbedPOI: what an area contains ---------------------------------------

def area_features(section_wikitext: str) -> dict[str, list[str]]:
    """Parse the first {{TabbedPOI}} in a section into {"Items": [...], "NPCs": [...], ...}."""
    start = section_wikitext.find("{{TabbedPOI")
    if start < 0:
        return {}
    depth, j = 0, start
    while j < len(section_wikitext):
        if section_wikitext.startswith("{{", j):
            depth, j = depth + 1, j + 2
        elif section_wikitext.startswith("}}", j):
            depth, j = depth - 1, j + 2
            if depth == 0:
                break
        else:
            j += 1
    params: dict[str, str] = {}
    for m in re.finditer(r"^\|\s*([A-Za-z]+\d+(?:_[A-Za-z]+|Note)?)\s*=\s*(.*)$",
                         section_wikitext[start:j], flags=re.M):
        params[m.group(1)] = m.group(2).strip()

    def collect(prefix: str, name_key: str, note_key: str) -> list[str]:
        items = []
        for n in range(1, 100):
            name = params.get(name_key.format(prefix=prefix, n=n))
            if name is None:
                break
            # Loot entries name an image file; a separate _Name wins when given.
            name = params.get(f"{prefix}{n}_Name", name)
            name = to_plain(name.split("{{!}}")[-1])
            note = params.get(note_key.format(prefix=prefix, n=n))
            items.append(f"{name} {to_plain(note)}".strip() if note else name)
        return items

    return {k: v for k, v in {
        "Items": collect("Loot", "{prefix}{n}_FileName", "{prefix}{n}_Description"),
        "NPCs": collect("NPC", "{prefix}{n}", "{prefix}{n}Note"),
        "Bosses": collect("Boss", "{prefix}{n}", "{prefix}{n}Note"),
        "Enemies": collect("Enemy", "{prefix}{n}", "{prefix}{n}Note"),
    }.items() if v}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("api", help="MediaWiki API URL, e.g. https://hollowknight.wiki/mw/api.php")
    parser.add_argument("page")
    parser.add_argument("--section", default="", help="Section heading; defaults to the page's lead")
    args = parser.parse_args()
    title, wikitext = page_wikitext(args.api, args.page)
    secs = sections(wikitext)
    raw = secs.get(args.section)
    if raw is None:
        raise SystemExit(f"No section {args.section!r}. Sections: {', '.join(s for s in secs if s)}")
    print(f"# {title}" + (f" — {args.section}" if args.section else "") + "\n")
    print("\n\n".join(paragraphs(to_plain(raw), bullets=True)))
    for kind, entries in area_features(raw).items():
        print(f"\n{kind}: " + "; ".join(entries))


if __name__ == "__main__":
    main()
