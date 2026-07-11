#!/usr/bin/env python3
"""Validate the repo-managed static site before publication."""

from __future__ import annotations

import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = REPO_ROOT / "site"
PUBLIC_ORIGIN = "https://archivale.app"
SITEMAP_PATH = SITE_ROOT / "sitemap.xml"
SOCIAL_IMAGE_URL = f"{PUBLIC_ORIGIN}/assets/collector-room.png"
SOCIAL_IMAGE_PATH = "/assets/collector-room.png"
SOCIAL_IMAGE_TYPE = "image/png"
SOCIAL_IMAGE_WIDTH = 1672
SOCIAL_IMAGE_HEIGHT = 941
SOCIAL_IMAGE_ALT = (
    "A collection room with framed artwork, a catalog, and a phone on a table."
)

ARTICLE_ROUTES = {
    "/blog/annual-art-collection-record-review-checklist/",
    "/blog/art-inventory-template-private-collectors/",
    "/blog/artwork-condition-report-checklist-private-collectors/",
    "/blog/artwork-location-inventory-for-private-collections/",
    "/blog/collector-records-that-age-well/",
    "/blog/how-to-document-artwork-for-insurance-conversations/",
    "/blog/how-to-organize-provenance-records-private-art-collection/",
    "/blog/how-to-photograph-artwork-for-private-records/",
    "/blog/how-to-prepare-art-records-for-family-handoff/",
    "/blog/how-to-prepare-artwork-records-before-a-move/",
    "/blog/how-to-record-artwork-labels-and-inscriptions/",
    "/blog/what-to-record-after-buying-artwork/",
}

PRIMARY_SCHEMA = {
    "/": ("WebPage", f"{PUBLIC_ORIGIN}/#webpage"),
    "/pricing/": ("WebPage", f"{PUBLIC_ORIGIN}/pricing/#webpage"),
    "/beta/": ("WebPage", f"{PUBLIC_ORIGIN}/beta/#webpage"),
    "/support/": ("ContactPage", f"{PUBLIC_ORIGIN}/support/#webpage"),
    "/privacy/": ("PrivacyPolicy", f"{PUBLIC_ORIGIN}/privacy/#webpage"),
    "/blog/": ("Blog", f"{PUBLIC_ORIGIN}/blog/#blog"),
    **{
        route: ("BlogPosting", f"{PUBLIC_ORIGIN}{route}#post")
        for route in ARTICLE_ROUTES
    },
}
EXPECTED_ROUTES = set(PRIMARY_SCHEMA)

OG_FIELDS = {
    "og:type",
    "og:title",
    "og:description",
    "og:url",
    "og:site_name",
    "og:image",
    "og:image:type",
    "og:image:width",
    "og:image:height",
    "og:image:alt",
}
TWITTER_FIELDS = {
    "twitter:card",
    "twitter:title",
    "twitter:description",
    "twitter:image",
    "twitter:image:alt",
}

ALLOWED_SCHEMA_TYPES = {
    "Blog",
    "BlogPosting",
    "ContactPage",
    "ItemList",
    "ListItem",
    "Organization",
    "PrivacyPolicy",
    "SoftwareApplication",
    "WebPage",
    "WebSite",
}

UNSAFE_METADATA_PATTERNS = [
    r"\bauthenticity confirmed\b",
    r"\bauthentic\b",
    r"\bappraised at\b",
    r"\bmarket value is\b",
    r"\bcertified\b",
    r"\bguaranteed\b",
    r"\bproven\b",
    r"\boriginal by\b",
    r"\bverified artist attribution\b",
    r"\binsurance-approved\b",
    r"\bofficial appraisal\b",
    r"\bproves authenticity\b",
    r"\bproof of authenticity\b",
    r"\bprovenance proof\b",
    r"\bcertified provenance\b",
]

SUPPORT_COPY_BANNED_PATTERNS = [
    r"\bbackend\b",
    r"\bbeta\b",
    r"\bbroker\b",
    r"\bdeploy\b",
    r"\benabled\b",
    r"\bfirebase\b",
    r"\bgate\b",
    r"\bprovider\b",
    r"\bremote config\b",
    r"\brelease track\b",
    r"\bservice-boundary\b",
    r"\bpayload\b",
    r"\bsdk\b",
]

HOMEPAGE_BANNED_COPY_PATTERNS = [
    r"\bbroker\b",
    r"\bprovider\b",
    r"\brollout\b",
    r"\bdeploy(?:ed|ment|s)?\b",
    r"\benable(?:d|s|ment)?\b",
    r"\bfirebase\b",
    r"\bsdk\b",
    r"\bremote config\b",
    r"\bservice-boundary\b",
    r"\bpayload\b",
    r"\bbeta\b",
    r"\brelease track\b",
    r"\bflags?\b",
    r"\btodo\b",
    r"\brelease note\b",
    r"\bimplementation\b",
]

BETA_COPY_BANNED_PATTERNS = [
    r"\bseparate tester instructions\b",
    r"\bfirebase\b",
    r"\bapp distribution\b",
    r"\bplay tester\b",
    r"\bdeploy route\b",
    r"\bbackend process\b",
]


class SiteParser(HTMLParser):
    """Collect decoded metadata and resource references without regex parsing HTML."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tags: list[tuple[str, dict[str, str | None], str]] = []
        self.ids: set[str] = set()
        self.doctype_seen = False
        self.in_head = False
        self.in_body = False
        self._title_depth = 0
        self._h1_depth = 0
        self._title_parts: list[str] = []
        self._h1_parts: list[str] = []
        self.titles: list[str] = []
        self.h1s: list[str] = []
        self._current_script_type: str | None = None
        self._current_script_parts: list[str] = []
        self.json_ld_blocks: list[str] = []
        self.errors: list[str] = []

    def handle_decl(self, decl: str) -> None:
        if decl.lower() == "doctype html":
            self.doctype_seen = True

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        tag = tag.lower()
        names = [name.lower() for name, _ in attrs]
        duplicates = sorted(name for name, count in Counter(names).items() if count > 1)
        if duplicates:
            self.errors.append(
                f"<{tag}> has duplicate attributes: {', '.join(duplicates)}"
            )
        attr_map = {name.lower(): value for name, value in attrs}

        if tag == "head":
            self.in_head = True
        if tag == "body":
            self.in_body = True
        section = "head" if self.in_head else "body" if self.in_body else "document"
        self.tags.append((tag, attr_map, section))

        node_id = attr_map.get("id")
        if node_id:
            self.ids.add(node_id)
        node_name = attr_map.get("name")
        if node_name:
            self.ids.add(node_name)

        if tag == "title":
            self._title_depth += 1
            self._title_parts = []
        if tag == "h1":
            self._h1_depth += 1
            self._h1_parts = []
        if tag == "script":
            self._current_script_type = (attr_map.get("type") or "").lower()
            self._current_script_parts = []

    def handle_startendtag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag == "title" and self._title_depth:
            self.titles.append("".join(self._title_parts).strip())
            self._title_depth -= 1
        if tag == "h1" and self._h1_depth:
            self.h1s.append(" ".join("".join(self._h1_parts).split()))
            self._h1_depth -= 1
        if tag == "script":
            if self._current_script_type == "application/ld+json":
                self.json_ld_blocks.append("".join(self._current_script_parts))
            self._current_script_type = None
            self._current_script_parts = []
        if tag == "head":
            self.in_head = False
        if tag == "body":
            self.in_body = False

    def handle_data(self, data: str) -> None:
        if self._title_depth:
            self._title_parts.append(data)
        if self._h1_depth:
            self._h1_parts.append(data)
        if self._current_script_type is not None:
            self._current_script_parts.append(data)

    def error(self, message: str) -> None:
        self.errors.append(message)


def route_for_html(path: Path, site_root: Path = SITE_ROOT) -> str:
    rel = path.relative_to(site_root)
    if rel == Path("index.html"):
        return "/"
    if rel.name == "index.html":
        return "/" + rel.parent.as_posix() + "/"
    return "/" + rel.as_posix()


def resolve_local_target(raw_value: str, source: Path, site_root: Path) -> Path | None:
    parsed = urlparse(raw_value)
    if parsed.scheme or parsed.netloc:
        return None
    path_text = unquote(parsed.path)
    if path_text == "":
        return source
    target = (
        site_root / path_text.lstrip("/")
        if path_text.startswith("/")
        else source.parent / path_text
    )
    if target.is_dir() or raw_value.endswith("/"):
        target = target / "index.html"
    elif target.suffix == "" and (target / "index.html").exists():
        target = target / "index.html"
    return target.resolve()


def json_strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [text for item in value for text in json_strings(item)]
    if isinstance(value, dict):
        return [
            text
            for key, item in value.items()
            for text in (str(key), *json_strings(item))
        ]
    return []


def json_dicts(value: object) -> list[dict[str, object]]:
    if isinstance(value, dict):
        return [value, *(node for item in value.values() for node in json_dicts(item))]
    if isinstance(value, list):
        return [node for item in value for node in json_dicts(item)]
    return []


def schema_types(value: object) -> set[str]:
    found: set[str] = set()
    for node in json_dicts(value):
        schema_type = node.get("@type")
        if isinstance(schema_type, str):
            found.add(schema_type)
        elif isinstance(schema_type, list):
            found.update(item for item in schema_type if isinstance(item, str))
    return found


def metadata_values(
    parser: SiteParser, attribute: str, prefix: str
) -> tuple[dict[str, list[str]], list[str]]:
    values: dict[str, list[str]] = {}
    misplaced: list[str] = []
    for tag, attrs, section in parser.tags:
        if tag != "meta":
            continue
        key = attrs.get(attribute)
        if not key or not key.lower().startswith(prefix):
            continue
        key = key.lower()
        values.setdefault(key, []).append(attrs.get("content") or "")
        if section != "head":
            misplaced.append(key)
    return values, misplaced


def one_value(
    route: str, values: dict[str, list[str]], key: str, errors: list[str]
) -> str:
    found = values.get(key, [])
    if len(found) != 1:
        errors.append(f"{route}: expected one {key}, found {len(found)}")
        return ""
    if not found[0].strip():
        errors.append(f"{route}: {key} must be nonempty")
    return found[0]


def parse_json_ld(route: str, parser: SiteParser) -> tuple[object | None, list[str]]:
    errors: list[str] = []
    if len(parser.json_ld_blocks) != 1:
        errors.append(
            f"{route}: expected one inline JSON-LD script, found {len(parser.json_ld_blocks)}"
        )
        return None, errors
    try:
        parsed = json.loads(parser.json_ld_blocks[0])
    except json.JSONDecodeError as exc:
        return None, [f"{route}: JSON-LD does not parse: {exc}"]
    if not isinstance(parsed, dict) or parsed.get("@context") != "https://schema.org":
        errors.append(f"{route}: JSON-LD missing schema.org context")
    unsupported = schema_types(parsed) - ALLOWED_SCHEMA_TYPES
    if unsupported:
        errors.append(f"{route}: unsupported schema types: {', '.join(sorted(unsupported))}")
    return parsed, errors


def validate_schema(
    route: str,
    parsed: object | None,
    title: str,
    description: str,
    h1s: list[str],
) -> list[str]:
    if parsed is None:
        return []
    errors: list[str] = []
    expected_type, expected_id = PRIMARY_SCHEMA[route]
    nodes = json_dicts(parsed)
    candidates = [
        node
        for node in nodes
        if node.get("@id") == expected_id and node.get("@type") == expected_type
    ]
    if len(candidates) != 1:
        errors.append(
            f"{route}: expected one primary {expected_type} node {expected_id}, found {len(candidates)}"
        )
        return errors

    definitions = [
        node for node in nodes if node.get("@id") and set(node) != {"@id"}
    ]
    duplicate_ids = sorted(
        node_id
        for node_id, count in Counter(node.get("@id") for node in definitions).items()
        if count > 1
    )
    errors.extend(f"{route}: duplicate schema definition for @id {node_id}" for node_id in duplicate_ids)

    primary = candidates[0]
    canonical = f"{PUBLIC_ORIGIN}{route}"
    expected_fields = {
        "url": canonical,
        "description": description,
        "image": SOCIAL_IMAGE_URL,
    }
    for key, expected in expected_fields.items():
        if primary.get(key) != expected:
            errors.append(f"{route}: primary schema {key} does not match metadata")

    if route in ARTICLE_ROUTES:
        if len(h1s) != 1:
            errors.append(f"{route}: expected one visible h1, found {len(h1s)}")
        elif primary.get("headline") != h1s[0]:
            errors.append(f"{route}: primary schema headline does not match visible h1")
    elif primary.get("name") != title:
        errors.append(f"{route}: primary schema name does not match title")

    for key in ("datePublished", "dateModified", "sameAs"):
        if any(key in node for node in nodes):
            errors.append(f"{route}: schema field {key} is not allowed")

    for value in json_strings(parsed):
        lowered = value.lower()
        for pattern in UNSAFE_METADATA_PATTERNS:
            if re.search(pattern, lowered):
                errors.append(f"{route}: unsafe structured-data phrase matched {pattern!r}")
        if value.startswith("http://"):
            errors.append(f"{route}: JSON-LD uses non-HTTPS URL {value}")
        if value.startswith("https://") and not (
            value.startswith(PUBLIC_ORIGIN) or value == "https://schema.org"
        ):
            errors.append(f"{route}: JSON-LD uses unexpected external URL {value}")
    return errors


def png_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        header = path.read_bytes()[:24]
    except OSError:
        return None
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", header[16:24])


def validate_metadata(
    path: Path, parser: SiteParser, site_root: Path
) -> tuple[list[str], str]:
    route = route_for_html(path, site_root)
    errors: list[str] = []
    title = parser.titles[0] if len(parser.titles) == 1 else ""

    descriptions, misplaced_description = metadata_values(parser, "name", "description")
    description = one_value(route, descriptions, "description", errors)
    if misplaced_description:
        errors.append(f"{route}: description metadata must be in head")

    canonical_tags = [
        (attrs.get("href") or "", section)
        for tag, attrs, section in parser.tags
        if tag == "link" and "canonical" in (attrs.get("rel") or "").lower().split()
    ]
    if len(canonical_tags) != 1:
        errors.append(f"{route}: expected one canonical link, found {len(canonical_tags)}")
        canonical = ""
    else:
        canonical, section = canonical_tags[0]
        if section != "head":
            errors.append(f"{route}: canonical link must be in head")

    expected_canonical = f"{PUBLIC_ORIGIN}{route}"
    if canonical != expected_canonical:
        errors.append(f"{route}: canonical must be exactly {expected_canonical}")
    try:
        parsed_canonical = urlparse(canonical)
        canonical_is_normalized = not (
            parsed_canonical.scheme != "https"
            or parsed_canonical.netloc != "archivale.app"
            or parsed_canonical.query
            or parsed_canonical.fragment
            or parsed_canonical.username
            or parsed_canonical.password
            or parsed_canonical.port
            or "//" in parsed_canonical.path
            or "/./" in parsed_canonical.path
            or "/../" in parsed_canonical.path
        )
    except ValueError:
        canonical_is_normalized = False
    if canonical and not canonical_is_normalized:
        errors.append(f"{route}: canonical URL is not normalized")

    og, misplaced_og = metadata_values(parser, "property", "og:")
    twitter, misplaced_twitter = metadata_values(parser, "name", "twitter:")
    if misplaced_og or misplaced_twitter:
        errors.append(f"{route}: social metadata must be in head")
    for extra in sorted(set(og) - OG_FIELDS):
        errors.append(f"{route}: unexpected Open Graph field {extra}")
    for extra in sorted(set(twitter) - TWITTER_FIELDS):
        errors.append(f"{route}: unexpected Twitter field {extra}")
    og_values = {key: one_value(route, og, key, errors) for key in sorted(OG_FIELDS)}
    twitter_values = {
        key: one_value(route, twitter, key, errors) for key in sorted(TWITTER_FIELDS)
    }

    exact_values = {
        "og:type": "article" if route in ARTICLE_ROUTES else "website",
        "og:title": title,
        "og:description": description,
        "og:url": expected_canonical,
        "og:site_name": "Archivale",
        "og:image": SOCIAL_IMAGE_URL,
        "og:image:type": SOCIAL_IMAGE_TYPE,
        "og:image:width": str(SOCIAL_IMAGE_WIDTH),
        "og:image:height": str(SOCIAL_IMAGE_HEIGHT),
        "og:image:alt": SOCIAL_IMAGE_ALT,
        "twitter:card": "summary_large_image",
        "twitter:title": title,
        "twitter:description": description,
        "twitter:image": SOCIAL_IMAGE_URL,
        "twitter:image:alt": SOCIAL_IMAGE_ALT,
    }
    for key, expected in exact_values.items():
        actual = og_values.get(key) if key.startswith("og:") else twitter_values.get(key)
        if actual != expected:
            errors.append(f"{route}: {key} does not match the exact metadata contract")

    if og_values.get("og:image:alt") != twitter_values.get("twitter:image:alt"):
        errors.append(f"{route}: OG and Twitter image alt must match")
    metadata_text = "\n".join([title, description, *sum(og.values(), []), *sum(twitter.values(), [])]).lower()
    for pattern in UNSAFE_METADATA_PATTERNS:
        if re.search(pattern, metadata_text):
            errors.append(f"{route}: unsafe social metadata phrase matched {pattern!r}")

    image_path = site_root / SOCIAL_IMAGE_PATH.lstrip("/")
    dimensions = png_dimensions(image_path)
    if dimensions is None:
        errors.append(f"{route}: social image is missing or is not a valid PNG")
    elif dimensions != (SOCIAL_IMAGE_WIDTH, SOCIAL_IMAGE_HEIGHT):
        errors.append(
            f"{route}: social image dimensions are {dimensions[0]}x{dimensions[1]}, expected {SOCIAL_IMAGE_WIDTH}x{SOCIAL_IMAGE_HEIGHT}"
        )
    return errors, canonical


def validate_resources(path: Path, parser: SiteParser, site_root: Path) -> list[str]:
    route = route_for_html(path, site_root)
    errors: list[str] = []
    script_sources: list[str] = []
    stylesheets: list[str] = []
    body_images: list[str] = []
    form_actions: list[str] = []

    if any(tag == "base" for tag, _, _ in parser.tags):
        errors.append(f"{route}: base element is forbidden")

    for tag, attrs, section in parser.tags:
        if tag == "style" or "style" in attrs:
            errors.append(f"{route}: inline style/resource expansion is forbidden")
        for request_attribute in ("srcset", "poster"):
            if request_attribute in attrs:
                errors.append(
                    f"{route}: request-bearing attribute {request_attribute} is forbidden"
                )
        if "src" in attrs and tag not in {"img", "script"}:
            errors.append(f"{route}: unexpected src resource on <{tag}>")
        if "href" in attrs and tag not in {"a", "link"}:
            errors.append(f"{route}: unexpected href resource on <{tag}>")
        if "action" in attrs and tag != "form":
            errors.append(f"{route}: unexpected action resource on <{tag}>")

        if tag == "script":
            src = attrs.get("src")
            script_type = (attrs.get("type") or "").lower()
            if src:
                script_sources.append(src)
            elif script_type != "application/ld+json":
                errors.append(f"{route}: inline executable script is forbidden")
        elif tag == "link":
            rel = set((attrs.get("rel") or "").lower().split())
            if "stylesheet" in rel:
                stylesheets.append(attrs.get("href") or "")
            elif "canonical" not in rel:
                errors.append(f"{route}: unexpected link resource")
        elif tag == "img" and section == "body":
            body_images.append(attrs.get("src") or "")
        elif tag == "form":
            form_actions.append(attrs.get("action") or "")
        elif tag in {"source", "iframe", "video", "audio", "embed", "object", "picture"}:
            errors.append(f"{route}: <{tag}> resource is forbidden")
        elif tag == "meta" and (attrs.get("http-equiv") or "").lower() in {
            "refresh",
            "set-cookie",
        }:
            errors.append(f"{route}: request/cookie metadata is forbidden")

    expected_scripts = ["/scripts/pageview-counter.js"]
    if route == "/beta/":
        expected_scripts.append("/scripts/beta-signup.js")
    if Counter(script_sources) != Counter(expected_scripts):
        errors.append(f"{route}: script inventory differs from the frozen allowlist")
    if Counter(stylesheets) != Counter(["/styles.css"]):
        errors.append(f"{route}: stylesheet inventory differs from the frozen allowlist")
    expected_images = ["/assets/archivale-logo.svg"]
    if route == "/":
        expected_images.append("/assets/collector-room.png")
    if Counter(body_images) != Counter(expected_images):
        errors.append(f"{route}: body image inventory differs from the frozen allowlist")

    expected_actions: list[str] = []
    if route == "/beta/":
        expected_actions = ["/api/forms/beta-signup"]
    elif route == "/support/":
        expected_actions = ["mailto:ken.leren@icloud.com"]
    if Counter(form_actions) != Counter(expected_actions):
        errors.append(f"{route}: form action inventory differs from the frozen allowlist")

    local_references = [*script_sources, *stylesheets, *body_images]
    for value in local_references:
        parsed = urlparse(value)
        if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
            errors.append(f"{route}: executable/body resource is not a plain local path: {value}")
            continue
        target = resolve_local_target(value, path, site_root)
        if target is None:
            errors.append(f"{route}: local resource does not resolve: {value}")
            continue
        try:
            target.relative_to(site_root.resolve())
        except ValueError:
            errors.append(f"{route}: local resource escapes site root: {value}")
            continue
        if not target.exists():
            errors.append(f"{route}: local resource does not resolve: {value}")

    for tag, attrs, _ in parser.tags:
        if tag != "a":
            continue
        value = attrs.get("href")
        if not value:
            continue
        parsed = urlparse(value)
        if parsed.scheme or parsed.netloc:
            errors.append(f"{route}: external link/call is not allowed: {value}")
            continue
        target = resolve_local_target(value, path, site_root)
        if target is None or not target.exists():
            errors.append(f"{route}: local href does not resolve: {value}")
        elif parsed.fragment and target == path.resolve() and parsed.fragment not in parser.ids:
            errors.append(f"{route}: local anchor does not resolve: {value}")
    return errors


def validate_html_shape(path: Path, parser: SiteParser, site_root: Path) -> list[str]:
    route = route_for_html(path, site_root)
    errors: list[str] = []
    if not parser.doctype_seen:
        errors.append(f"{route}: missing <!doctype html>")
    if len(parser.titles) != 1:
        errors.append(f"{route}: expected one title, found {len(parser.titles)}")
    elif not parser.titles[0]:
        errors.append(f"{route}: title must be nonempty")
    for element in ("html", "head", "body"):
        if not any(tag == element for tag, _, _ in parser.tags):
            errors.append(f"{route}: missing {element} element")
    errors.extend(f"{route}: HTML parser error: {error}" for error in parser.errors)
    return errors


def validate_copy_surface(path: Path, site_root: Path) -> list[str]:
    route = route_for_html(path, site_root)
    patterns = (
        HOMEPAGE_BANNED_COPY_PATTERNS
        if route == "/"
        else SUPPORT_COPY_BANNED_PATTERNS
        if route == "/support/"
        else []
    )
    text = path.read_text(encoding="utf-8").lower()
    return [f"{route}: banned copy matched {pattern!r}" for pattern in patterns if re.search(pattern, text)]


def validate_page(path: Path, site_root: Path = SITE_ROOT) -> tuple[list[str], str]:
    route = route_for_html(path, site_root)
    if route not in EXPECTED_ROUTES:
        return [f"unexpected public route: {route}"], ""
    parser = SiteParser()
    parser.feed(path.read_text(encoding="utf-8"))
    parser.close()
    errors = validate_html_shape(path, parser, site_root)
    metadata_errors, canonical = validate_metadata(path, parser, site_root)
    errors.extend(metadata_errors)
    parsed, json_errors = parse_json_ld(route, parser)
    errors.extend(json_errors)
    title = parser.titles[0] if len(parser.titles) == 1 else ""
    descriptions, _ = metadata_values(parser, "name", "description")
    description = descriptions.get("description", [""])[0]
    errors.extend(validate_schema(route, parsed, title, description, parser.h1s))
    errors.extend(validate_resources(path, parser, site_root))
    errors.extend(validate_copy_surface(path, site_root))
    return errors, canonical


def sitemap_urls(sitemap_path: Path) -> tuple[list[str], list[str]]:
    if not sitemap_path.exists():
        return [], ["missing sitemap.xml"]
    try:
        root = ET.fromstring(sitemap_path.read_text(encoding="utf-8"))
    except ET.ParseError as exc:
        return [], [f"sitemap.xml does not parse: {exc}"]
    errors: list[str] = []
    if root.tag != "{http://www.sitemaps.org/schemas/sitemap/0.9}urlset":
        errors.append("sitemap.xml root is not a sitemap urlset")
    namespace = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    urls: list[str] = []
    for loc in root.findall("sm:url/sm:loc", namespace):
        if loc.text is None or not loc.text.strip():
            errors.append("sitemap.xml contains empty loc")
        else:
            urls.append(loc.text.strip())
    return urls, errors


def validate_sitemap(canonicals: list[str], sitemap_path: Path) -> list[str]:
    urls, errors = sitemap_urls(sitemap_path)
    for url, count in Counter(urls).items():
        if count > 1:
            errors.append(f"sitemap.xml has duplicate URL: {url}")
    expected = set(canonicals)
    actual = set(urls)
    errors.extend(f"sitemap.xml missing URL: {url}" for url in sorted(expected - actual))
    errors.extend(f"sitemap.xml has stale URL: {url}" for url in sorted(actual - expected))
    return errors


def validate_beta_copy_surface(site_root: Path) -> list[str]:
    errors: list[str] = []
    for relative in ("beta/index.html", "scripts/beta-signup.js"):
        path = site_root / relative
        if not path.exists():
            errors.append(f"beta copy surface missing file: {relative}")
            continue
        content = path.read_text(encoding="utf-8").lower()
        for pattern in BETA_COPY_BANNED_PATTERNS:
            if re.search(pattern, content):
                errors.append(f"beta copy surface {relative} matched banned pattern {pattern!r}")
    return errors


def validate_site(
    site_root: Path = SITE_ROOT, sitemap_path: Path | None = None
) -> list[str]:
    sitemap_path = sitemap_path or site_root / "sitemap.xml"
    html_paths = sorted(site_root.glob("**/*.html"))
    routes = {route_for_html(path, site_root) for path in html_paths}
    errors: list[str] = []
    errors.extend(f"missing expected route: {route}" for route in sorted(EXPECTED_ROUTES - routes))
    errors.extend(f"unexpected public route: {route}" for route in sorted(routes - EXPECTED_ROUTES))

    canonicals: list[str] = []
    for path in html_paths:
        page_errors, canonical = validate_page(path, site_root)
        errors.extend(page_errors)
        if canonical:
            canonicals.append(canonical)
    for canonical, count in Counter(canonicals).items():
        if count > 1:
            errors.append(f"duplicate canonical URL across routes: {canonical}")
    errors.extend(validate_sitemap(canonicals, sitemap_path))
    errors.extend(validate_beta_copy_surface(site_root))
    return errors


def main() -> int:
    errors = validate_site()
    if errors:
        print("Static site validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(
        "Static site validation passed: 18 HTML routes, canonical/social metadata, "
        "primary JSON-LD, frozen local resources, sitemap, and trust guardrails are valid."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
