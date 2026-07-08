#!/usr/bin/env python3
"""Validate the repo-managed static site before publication."""

from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = REPO_ROOT / "site"
PUBLIC_ORIGIN = "https://archivale.app"
ALLOWED_FORM_ACTIONS = {
    "/api/forms/beta-signup",
}

EXPECTED_SCHEMA_ROUTES = {
    "/",
    "/pricing/",
    "/beta/",
    "/support/",
    "/privacy/",
    "/blog/",
    "/blog/art-inventory-template-private-collectors/",
    "/blog/artwork-condition-report-checklist-private-collectors/",
    "/blog/collector-records-that-age-well/",
    "/blog/how-to-document-artwork-for-insurance-conversations/",
    "/blog/how-to-organize-provenance-records-private-art-collection/",
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

UNSAFE_STRUCTURED_DATA_PATTERNS = [
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


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tags: list[tuple[str, dict[str, str | None]]] = []
        self.ids: set[str] = set()
        self.doctype_seen = False
        self.title_count = 0
        self.meta_description_count = 0
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
        attr_map = {name.lower(): value for name, value in attrs}
        tag = tag.lower()
        self.tags.append((tag, attr_map))

        node_id = attr_map.get("id")
        if node_id:
            self.ids.add(node_id)
        node_name = attr_map.get("name")
        if node_name:
            self.ids.add(node_name)

        if tag == "title":
            self.title_count += 1
        if tag == "meta" and attr_map.get("name", "").lower() == "description":
            self.meta_description_count += 1
        if tag == "script":
            self._current_script_type = (attr_map.get("type") or "").lower()
            self._current_script_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "script":
            if self._current_script_type == "application/ld+json":
                self.json_ld_blocks.append("".join(self._current_script_parts))
            self._current_script_type = None
            self._current_script_parts = []

    def handle_data(self, data: str) -> None:
        if self._current_script_type is not None:
            self._current_script_parts.append(data)

    def error(self, message: str) -> None:
        self.errors.append(message)


def route_for_html(path: Path) -> str:
    rel = path.relative_to(SITE_ROOT)
    if rel == Path("index.html"):
        return "/"
    if rel.name == "index.html":
        return "/" + rel.parent.as_posix() + "/"
    return "/" + rel.as_posix()


def resolve_local_target(raw_value: str, source: Path) -> Path | None:
    parsed = urlparse(raw_value)
    if parsed.scheme or parsed.netloc:
        return None

    path_text = unquote(parsed.path)
    if path_text == "":
        return source

    if path_text.startswith("/"):
        target = SITE_ROOT / path_text.lstrip("/")
    else:
        target = source.parent / path_text

    if target.is_dir() or raw_value.endswith("/"):
        target = target / "index.html"
    elif target.suffix == "":
        route_target = target / "index.html"
        if route_target.exists():
            target = route_target

    return target.resolve()


def json_strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        strings: list[str] = []
        for item in value:
            strings.extend(json_strings(item))
        return strings
    if isinstance(value, dict):
        strings = []
        for key, item in value.items():
            strings.append(str(key))
            strings.extend(json_strings(item))
        return strings
    return []


def schema_types(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        schema_type = value.get("@type")
        if isinstance(schema_type, str):
            found.add(schema_type)
        elif isinstance(schema_type, list):
            found.update(item for item in schema_type if isinstance(item, str))
        for item in value.values():
            found.update(schema_types(item))
    elif isinstance(value, list):
        for item in value:
            found.update(schema_types(item))
    return found


def validate_json_ld(path: Path, parser: SiteParser) -> list[str]:
    errors: list[str] = []
    route = route_for_html(path)
    if route in EXPECTED_SCHEMA_ROUTES and not parser.json_ld_blocks:
        errors.append(f"{route}: missing JSON-LD block")

    for index, raw_block in enumerate(parser.json_ld_blocks, start=1):
        try:
            parsed = json.loads(raw_block)
        except json.JSONDecodeError as exc:
            errors.append(f"{route}: JSON-LD block {index} does not parse: {exc}")
            continue

        context = parsed.get("@context") if isinstance(parsed, dict) else None
        if context != "https://schema.org":
            errors.append(f"{route}: JSON-LD block {index} missing schema.org context")

        unsupported = schema_types(parsed) - ALLOWED_SCHEMA_TYPES
        if unsupported:
            errors.append(
                f"{route}: unsupported schema types: {', '.join(sorted(unsupported))}"
            )

        text = "\n".join(json_strings(parsed)).lower()
        for pattern in UNSAFE_STRUCTURED_DATA_PATTERNS:
            if re.search(pattern, text):
                errors.append(
                    f"{route}: unsafe structured-data phrase matched {pattern!r}"
                )

        for value in json_strings(parsed):
            if value.startswith("http://"):
                errors.append(f"{route}: JSON-LD uses non-HTTPS URL {value}")
            if (
                value.startswith("https://")
                and not value.startswith(PUBLIC_ORIGIN)
                and value != "https://schema.org"
            ):
                errors.append(f"{route}: JSON-LD uses unexpected external URL {value}")

    return errors


def validate_links_and_assets(path: Path, parser: SiteParser) -> list[str]:
    errors: list[str] = []
    route = route_for_html(path)

    for tag, attrs in parser.tags:
        if tag == "script":
            script_type = (attrs.get("type") or "").lower()
            script_src = attrs.get("src")
            if script_src:
                parsed_script_src = urlparse(script_src)
                if (
                    parsed_script_src.scheme
                    or parsed_script_src.netloc
                    or not parsed_script_src.path.startswith("/scripts/")
                    or not parsed_script_src.path.endswith(".js")
                ):
                    errors.append(f"{route}: script src is not an allowed local script")
            elif script_type != "application/ld+json":
                errors.append(f"{route}: non-JSON-LD script is not allowed")

        for attr in ("href", "src", "action"):
            value = attrs.get(attr)
            if not value:
                continue

            parsed = urlparse(value)
            if attr == "action" and parsed.path in ALLOWED_FORM_ACTIONS:
                continue
            if parsed.scheme in {"mailto", "tel"}:
                continue

            if parsed.scheme or parsed.netloc:
                if tag in {"img", "script", "link", "source", "iframe"}:
                    errors.append(f"{route}: external asset URL is not allowed: {value}")
                continue

            target = resolve_local_target(value, path)
            if target is None:
                continue
            try:
                target.relative_to(SITE_ROOT.resolve())
            except ValueError:
                errors.append(f"{route}: local {attr} escapes site root: {value}")
                continue
            if not target.exists():
                errors.append(f"{route}: local {attr} does not resolve: {value}")
                continue

            if parsed.fragment and target == path.resolve():
                if parsed.fragment not in parser.ids:
                    errors.append(f"{route}: local anchor does not resolve: {value}")

    return errors


def validate_html_shape(path: Path, parser: SiteParser) -> list[str]:
    route = route_for_html(path)
    errors: list[str] = []
    if not parser.doctype_seen:
        errors.append(f"{route}: missing <!doctype html>")
    if parser.title_count != 1:
        errors.append(f"{route}: expected one title, found {parser.title_count}")
    if parser.meta_description_count != 1:
        errors.append(
            f"{route}: expected one meta description, found {parser.meta_description_count}"
        )
    if not any(tag == "html" for tag, _ in parser.tags):
        errors.append(f"{route}: missing html element")
    if not any(tag == "head" for tag, _ in parser.tags):
        errors.append(f"{route}: missing head element")
    if not any(tag == "body" for tag, _ in parser.tags):
        errors.append(f"{route}: missing body element")
    if parser.errors:
        errors.extend(f"{route}: HTML parser error: {error}" for error in parser.errors)
    return errors


def main() -> int:
    html_paths = sorted(SITE_ROOT.glob("**/*.html"))
    routes = {route_for_html(path) for path in html_paths}
    errors: list[str] = []

    missing_routes = EXPECTED_SCHEMA_ROUTES - routes
    if missing_routes:
        errors.extend(f"missing expected route: {route}" for route in sorted(missing_routes))

    for path in html_paths:
        parser = SiteParser()
        parser.feed(path.read_text(encoding="utf-8"))
        parser.close()

        errors.extend(validate_html_shape(path, parser))
        errors.extend(validate_json_ld(path, parser))
        errors.extend(validate_links_and_assets(path, parser))

    if errors:
        print("Static site validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        "Static site validation passed: "
        f"{len(html_paths)} HTML routes, JSON-LD, local links/assets, "
        "trust guardrails, and route smoke checks are valid."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
