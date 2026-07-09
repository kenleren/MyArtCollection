#!/usr/bin/env python3
"""Generate the static-site sitemap from checked-in HTML routes."""

from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape


REPO_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = REPO_ROOT / "site"
PUBLIC_ORIGIN = "https://archivale.app"
SITEMAP_PATH = SITE_ROOT / "sitemap.xml"


def route_for_html(path: Path) -> str:
    rel = path.relative_to(SITE_ROOT)
    if rel == Path("index.html"):
        return "/"
    if rel.name == "index.html":
        return "/" + rel.parent.as_posix() + "/"
    return "/" + rel.as_posix()


def sitemap_xml(routes: list[str]) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ]
    for route in routes:
        lines.extend(
            [
                "  <url>",
                f"    <loc>{escape(PUBLIC_ORIGIN + route)}</loc>",
                "  </url>",
            ]
        )
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def main() -> int:
    routes = sorted(route_for_html(path) for path in SITE_ROOT.glob("**/*.html"))
    if "/" in routes:
        routes.remove("/")
        routes.insert(0, "/")

    SITEMAP_PATH.write_text(sitemap_xml(routes), encoding="utf-8")
    print(f"Wrote {SITEMAP_PATH.relative_to(REPO_ROOT)} with {len(routes)} routes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
