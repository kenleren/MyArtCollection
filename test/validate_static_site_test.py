from __future__ import annotations

import html
import json
import shutil
import struct
import tempfile
import unittest
from pathlib import Path

from scripts import generate_sitemap
from scripts import validate_static_site as validator


class StaticSiteValidatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.site_root = Path(self.temp_dir.name) / "site"
        (self.site_root / "assets").mkdir(parents=True)
        (self.site_root / "scripts").mkdir()
        (self.site_root / "styles.css").write_text("", encoding="utf-8")
        (self.site_root / "scripts/pageview-counter.js").write_text("", encoding="utf-8")
        (self.site_root / "scripts/beta-signup.js").write_text("", encoding="utf-8")
        shutil.copy2(
            validator.SITE_ROOT / "assets/collector-room.png",
            self.site_root / "assets/collector-room.png",
        )
        shutil.copy2(
            validator.SITE_ROOT / "assets/archivale-logo.svg",
            self.site_root / "assets/archivale-logo.svg",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_page(
        self,
        route: str = "/",
        *,
        title: str = "Archivale & Collector's Records",
        description: str = 'Careful records for "art" & family notes.',
        headline: str = "Archivale & Collector's Records",
    ) -> Path:
        canonical = validator.PUBLIC_ORIGIN + route
        schema_type, schema_id = validator.PRIMARY_SCHEMA[route]
        is_article = route in validator.ARTICLE_ROUTES
        schema = {
            "@context": "https://schema.org",
            "@type": schema_type,
            "@id": schema_id,
            "url": canonical,
            "description": description,
            "image": validator.SOCIAL_IMAGE_URL,
            "headline" if is_article else "name": headline if is_article else title,
        }
        escaped_title = html.escape(title, quote=True)
        escaped_description = html.escape(description, quote=True)
        escaped_alt = html.escape(validator.SOCIAL_IMAGE_ALT, quote=True)
        og_type = "article" if is_article else "website"
        collector_image = (
            '<img src="/assets/collector-room.png" alt="Collection room">'
            if route == "/"
            else ""
        )
        route_form = ""
        route_script = ""
        if route == "/beta/":
            route_form = '<form action="/api/forms/beta-signup"><button>Join</button></form>'
            route_script = '<script src="/scripts/beta-signup.js" defer></script>'
        elif route == "/support/":
            route_form = (
                '<form action="mailto:ken.leren@icloud.com"><button>Send</button></form>'
            )
        body_h1 = html.escape(headline if is_article else title)
        content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{escaped_title}</title>
  <meta name="description" content="{escaped_description}">
  <link rel="canonical" href="{canonical}">
  <meta property="og:type" content="{og_type}">
  <meta property="og:title" content="{escaped_title}">
  <meta property="og:description" content="{escaped_description}">
  <meta property="og:url" content="{canonical}">
  <meta property="og:site_name" content="Archivale">
  <meta property="og:image" content="{validator.SOCIAL_IMAGE_URL}">
  <meta property="og:image:type" content="image/png">
  <meta property="og:image:width" content="1672">
  <meta property="og:image:height" content="941">
  <meta property="og:image:alt" content="{escaped_alt}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{escaped_title}">
  <meta name="twitter:description" content="{escaped_description}">
  <meta name="twitter:image" content="{validator.SOCIAL_IMAGE_URL}">
  <meta name="twitter:image:alt" content="{escaped_alt}">
  <link rel="stylesheet" href="/styles.css">
  <script type="application/ld+json">{json.dumps(schema, ensure_ascii=False)}</script>
</head>
<body>
  <img src="/assets/archivale-logo.svg" alt="">
  {collector_image}
  <h1>{body_h1}</h1>
  {route_form}
  {route_script}
  <script src="/scripts/pageview-counter.js" defer></script>
</body>
</html>
"""
        path = self.site_root / ("index.html" if route == "/" else route.strip("/"))
        if route != "/":
            path.mkdir(parents=True, exist_ok=True)
            path /= "index.html"
        path.write_text(content, encoding="utf-8")
        return path

    def mutate(self, path: Path, old: str, new: str) -> None:
        content = path.read_text(encoding="utf-8")
        self.assertIn(old, content)
        path.write_text(content.replace(old, new, 1), encoding="utf-8")

    def errors_for(self, path: Path) -> list[str]:
        return validator.validate_page(path, self.site_root)[0]

    def assert_error(self, errors: list[str], fragment: str) -> None:
        self.assertTrue(
            any(fragment in error for error in errors),
            f"Expected {fragment!r} in:\n" + "\n".join(errors),
        )

    def test_checked_in_site_passes_complete_contract(self) -> None:
        self.assertEqual([], validator.validate_site())

    def test_checked_in_site_has_exact_route_and_metadata_counts(self) -> None:
        paths = sorted(validator.SITE_ROOT.glob("**/*.html"))
        self.assertEqual(18, len(paths))
        self.assertEqual(
            validator.EXPECTED_ROUTES,
            {validator.route_for_html(path) for path in paths},
        )
        for path in paths:
            parser = validator.SiteParser()
            parser.feed(path.read_text(encoding="utf-8"))
            og, _ = validator.metadata_values(parser, "property", "og:")
            twitter, _ = validator.metadata_values(parser, "name", "twitter:")
            self.assertEqual(validator.OG_FIELDS, set(og), path)
            self.assertEqual(validator.TWITTER_FIELDS, set(twitter), path)
            self.assertTrue(all(len(values) == 1 for values in og.values()), path)
            self.assertTrue(all(len(values) == 1 for values in twitter.values()), path)

    def test_valid_escaped_unicode_fixture_passes(self) -> None:
        path = self.write_page(
            title='Archivale & "Élan" Records',
            description="A collector's notes & careful records.",
        )
        self.assertEqual([], self.errors_for(path))

    def test_missing_and_duplicate_canonical_fail(self) -> None:
        for replacement, expected in (
            ("", "expected one canonical link, found 0"),
            (
                '<link rel="canonical" href="https://archivale.app/">\n'
                '<link rel="canonical" href="https://archivale.app/">',
                "expected one canonical link, found 2",
            ),
        ):
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(
                    path,
                    '<link rel="canonical" href="https://archivale.app/">',
                    replacement,
                )
                self.assert_error(self.errors_for(path), expected)

    def test_noncanonical_url_forms_fail(self) -> None:
        invalid_urls = (
            "http://archivale.app/",
            "https://www.archivale.app/",
            "https://archivale.app",
            "https://archivale.app/?draft=1",
            "https://archivale.app/#top",
            "https://user@archivale.app/",
            "https://archivale.app:443/",
            "https://archivale.app:bad/",
            "https://archivale.app//",
            "https://archivale.app/./",
        )
        for invalid in invalid_urls:
            with self.subTest(url=invalid):
                path = self.write_page()
                self.mutate(path, "https://archivale.app/", invalid)
                errors = self.errors_for(path)
                self.assert_error(errors, "canonical must be exactly")

    def test_missing_duplicate_and_extra_social_fields_fail(self) -> None:
        mutations = (
            ('  <meta property="og:site_name" content="Archivale">\n', "", "expected one og:site_name, found 0"),
            (
                '  <meta name="twitter:card" content="summary_large_image">',
                '  <meta name="twitter:card" content="summary_large_image">\n'
                '  <meta name="twitter:card" content="summary">',
                "expected one twitter:card, found 2",
            ),
            (
                '  <meta property="og:site_name" content="Archivale">',
                '  <meta property="og:locale" content="en_US">',
                "unexpected Open Graph field og:locale",
            ),
        )
        for old, new, expected in mutations:
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(path, old, new)
                self.assert_error(self.errors_for(path), expected)

    def test_exact_social_constants_and_alignment_fail_closed(self) -> None:
        mutations = (
            ("summary_large_image", "summary", "twitter:card"),
            ('og:site_name" content="Archivale', 'og:site_name" content="Archive', "og:site_name"),
            ('og:image:width" content="1672', 'og:image:width" content="1200', "og:image:width"),
            (validator.SOCIAL_IMAGE_ALT, "An attributed masterpiece.", "og:image:alt"),
        )
        for old, new, expected in mutations:
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(path, old, new)
                self.assert_error(self.errors_for(path), expected)

    def test_article_type_id_and_visible_headline_contract(self) -> None:
        route = "/blog/how-to-organize-provenance-records-private-art-collection/"
        headline = "How to Organize Provenance Records for a Private Art Collection"
        path = self.write_page(route, title=f"{headline} | Archivale", headline=headline)
        self.assertEqual([], self.errors_for(path))
        self.mutate(path, f"<h1>{headline}</h1>", "<h1>Different visible headline</h1>")
        self.assert_error(self.errors_for(path), "headline does not match visible h1")

    def test_site_route_rejects_article_type_and_wrong_primary_id(self) -> None:
        path = self.write_page()
        self.mutate(path, 'og:type" content="website', 'og:type" content="article')
        self.mutate(path, "https://archivale.app/#webpage", "https://archivale.app/#post")
        errors = self.errors_for(path)
        self.assert_error(errors, "og:type")
        self.assert_error(errors, "expected one primary WebPage node")

    def test_primary_schema_ambiguity_and_duplicate_id_fail(self) -> None:
        path = self.write_page()
        content = path.read_text(encoding="utf-8")
        schema_text = content.split('<script type="application/ld+json">', 1)[1].split("</script>", 1)[0]
        schema = json.loads(schema_text)
        graph = {"@context": "https://schema.org", "@graph": [schema, schema]}
        self.mutate(path, schema_text, json.dumps(graph))
        errors = self.errors_for(path)
        self.assert_error(errors, "expected one primary WebPage node")

    def test_duplicate_nonprimary_schema_definition_fails(self) -> None:
        path = self.write_page()
        content = path.read_text(encoding="utf-8")
        schema_text = content.split('<script type="application/ld+json">', 1)[1].split("</script>", 1)[0]
        primary = json.loads(schema_text)
        organization = {
            "@type": "Organization",
            "@id": "https://archivale.app/#organization",
            "name": "Archivale",
        }
        graph = {
            "@context": "https://schema.org",
            "@graph": [primary, organization, organization],
        }
        self.mutate(path, schema_text, json.dumps(graph))
        self.assert_error(
            self.errors_for(path),
            "duplicate schema definition for @id https://archivale.app/#organization",
        )

    def test_primary_schema_alignment_fields_fail(self) -> None:
        mutations = (
            ('"url": "https://archivale.app/"', '"url": "https://archivale.app/pricing/"', "schema url"),
            ('"description": "Careful records', '"description": "Different records', "schema description"),
            (f'"image": "{validator.SOCIAL_IMAGE_URL}"', '"image": "https://archivale.app/assets/other.png"', "schema image"),
            ('"name": "Archivale & Collector', '"name": "Different & Collector', "schema name"),
        )
        for old, new, expected in mutations:
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(path, old, new)
                self.assert_error(self.errors_for(path), expected)

    def test_missing_invalid_and_wrong_dimension_png_fail(self) -> None:
        image_path = self.site_root / "assets/collector-room.png"
        cases = ("missing", "invalid", "dimensions")
        for case in cases:
            with self.subTest(case=case):
                path = self.write_page()
                original = image_path.read_bytes()
                if case == "missing":
                    image_path.unlink()
                elif case == "invalid":
                    image_path.write_bytes(b"not a png")
                else:
                    changed = bytearray(original)
                    changed[16:24] = struct.pack(">II", 1200, 630)
                    image_path.write_bytes(changed)
                self.assert_error(self.errors_for(path), "social image")
                image_path.write_bytes(original)

    def test_script_stylesheet_body_image_and_form_inventories_are_frozen(self) -> None:
        mutations = (
            (
                '<script src="/scripts/pageview-counter.js" defer></script>',
                '<script src="/scripts/new-tracker.js"></script>\n'
                '<script src="/scripts/pageview-counter.js" defer></script>',
                "script inventory",
            ),
            (
                '<link rel="stylesheet" href="/styles.css">',
                '<link rel="preload" href="/assets/collector-room.png">\n'
                '<link rel="stylesheet" href="/styles.css">',
                "unexpected link resource",
            ),
            (
                '<img src="/assets/collector-room.png" alt="Collection room">',
                '<img src="/assets/collector-room.png" alt="Collection room">\n'
                '<img src="/assets/collector-room.png" width="1" height="1" alt="">',
                "body image inventory",
            ),
            ("<h1>", '<form action="/collect"><button>Send</button></form><h1>', "form action inventory"),
        )
        for old, new, expected in mutations:
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(path, old, new)
                self.assert_error(self.errors_for(path), expected)

    def test_external_resources_inline_script_base_and_cookie_fail(self) -> None:
        additions = (
            ('<script src="https://tracker.example/pixel.js"></script>', "script inventory"),
            ("<script>track()</script>", "inline executable script"),
            ('<base href="https://example.com/">', "base element is forbidden"),
            ('<iframe src="https://example.com/pixel"></iframe>', "iframe"),
            ('<meta http-equiv="set-cookie" content="id=1">', "request/cookie metadata"),
            ('<input type="image" src="/assets/collector-room.png">', "unexpected src resource"),
            ('<div style="background:url(/assets/collector-room.png)"></div>', "inline style/resource"),
            ('<img src="/assets/archivale-logo.svg" srcset="/assets/collector-room.png 2x">', "srcset"),
        )
        for addition, expected in additions:
            with self.subTest(expected=expected):
                path = self.write_page()
                self.mutate(path, "</head>", f"{addition}</head>")
                self.assert_error(self.errors_for(path), expected)

    def test_request_bearing_bypasses_fail_in_every_document_section(self) -> None:
        additions = (
            (
                '<img src="https://tracker.example/pixel.gif" alt="">',
                "image resources must be in body",
                "body image inventory",
            ),
            (
                '<a href="/pricing/" ping="https://tracker.example/collect">Pricing</a>',
                "ping",
                "ping",
            ),
            (
                '<button formaction="https://tracker.example/collect">Send</button>',
                "formaction",
                "formaction",
            ),
            (
                '<input type="submit" formaction="/unexpected">',
                "formaction",
                "formaction",
            ),
            (
                '<svg><image href="https://tracker.example/pixel.svg"></image></svg>',
                "unexpected href resource",
                "unexpected href resource",
            ),
            (
                '<svg><use xlink:href="https://tracker.example/icons.svg#mark"></use></svg>',
                "xlink:href",
                "xlink:href",
            ),
            (
                '<object data="https://tracker.example/pixel"></object>',
                "request-bearing attribute data",
                "request-bearing attribute data",
            ),
            (
                '<link rel="preload" imagesrcset="https://tracker.example/pixel.png 1x">',
                "imagesrcset",
                "imagesrcset",
            ),
            (
                '<img src="/assets/archivale-logo.svg" '
                'attributionsrc="https://tracker.example/report">',
                "attributionsrc",
                "attributionsrc",
            ),
            (
                '<div background="https://tracker.example/pixel.png"></div>',
                "background",
                "background",
            ),
            (
                '<button onclick="fetch(\'https://tracker.example/collect\')">Send</button>',
                "inline event handler onclick",
                "inline event handler onclick",
            ),
        )
        for addition, head_error, body_error in additions:
            for marker, expected in (("</head>", head_error), ("</body>", body_error)):
                with self.subTest(addition=addition, section=marker):
                    path = self.write_page()
                    self.mutate(path, marker, f"{addition}{marker}")
                    self.assert_error(self.errors_for(path), expected)

    def test_approved_resources_links_and_form_actions_remain_allowed(self) -> None:
        for route in ("/", "/beta/", "/support/"):
            with self.subTest(route=route):
                path = self.write_page(route, title="Archivale", headline="Archivale")
                self.assertEqual([], self.errors_for(path))

    def test_unsafe_hidden_social_and_nested_schema_copy_fail(self) -> None:
        path = self.write_page()
        self.mutate(path, "Careful records for", "Authenticity confirmed for")
        self.assert_error(self.errors_for(path), "unsafe social metadata phrase")

        path = self.write_page()
        self.mutate(
            path,
            '"image": "https://archivale.app/assets/collector-room.png"',
            '"image": "https://archivale.app/assets/collector-room.png", '
            '"about": {"name": "Provenance proof"}',
        )
        self.assert_error(self.errors_for(path), "unsafe structured-data phrase")

    def test_duplicate_canonical_across_files_is_reported(self) -> None:
        self.write_page("/")
        pricing = self.write_page("/pricing/", title="Pricing", headline="Pricing")
        self.mutate(pricing, "https://archivale.app/pricing/", "https://archivale.app/")
        sitemap = self.site_root / "sitemap.xml"
        sitemap.write_text(generate_sitemap.sitemap_xml(["/", "/pricing/"]), encoding="utf-8")
        errors = validator.validate_site(self.site_root, sitemap)
        self.assert_error(errors, "duplicate canonical URL across routes")

    def test_sitemap_rejects_duplicate_stale_and_missing_urls(self) -> None:
        sitemap = self.site_root / "sitemap.xml"
        sitemap.write_text(
            generate_sitemap.sitemap_xml(["/", "/", "/stale/"]),
            encoding="utf-8",
        )
        errors = validator.validate_sitemap(
            ["https://archivale.app/", "https://archivale.app/pricing/"], sitemap
        )
        self.assert_error(errors, "duplicate URL")
        self.assert_error(errors, "stale URL")
        self.assert_error(errors, "missing URL")

    def test_sitemap_matches_generator_without_write(self) -> None:
        routes = sorted(
            generate_sitemap.route_for_html(path)
            for path in generate_sitemap.SITE_ROOT.glob("**/*.html")
        )
        routes.remove("/")
        routes.insert(0, "/")
        expected = generate_sitemap.sitemap_xml(routes)
        actual = generate_sitemap.SITEMAP_PATH.read_text(encoding="utf-8")
        self.assertEqual(expected, actual)


if __name__ == "__main__":
    unittest.main()
