#!/usr/bin/env python3
"""Adds localized release notes to a Sparkle appcast (run by Scripts/release.sh; not on its own).

    python3 Scripts/localize_appcast.py <appcast.xml> <version>       # rewrite the appcast
    python3 Scripts/localize_appcast.py --missing <version>           # list missing or unedited notes

Release notes live in docs/release-notes/<version>: en.md and <lang>.md for each language in
Scripts/translations.py (LANGS), the same languages as the app. generate_appcast embeds the
English notes as the item's <description>; this marks it xml:lang="en" and adds one <description
xml:lang="..."> per language after it, in Markdown like the English one.

Sparkle shows the description whose language best matches the app's (NSBundle
preferredLocalizationsFromArray). A language the notes don't cover gets the first one, so English comes
first.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "Scripts"))
from translations import LANGS  # noqa: E402

NOTES = root / "docs/release-notes"
# make bump writes this into the templates; notes that still contain it are unedited.
TEMPLATE_MARK = "TODO:"


def notes_path(version, lang):
    return NOTES / version / f"{lang}.md"


def missing(version):
    """Languages whose notes are missing, empty or still the template."""
    result = []
    for lang in ["en", *LANGS]:
        path = notes_path(version, lang)
        text = path.read_text() if path.exists() else ""
        if not text.strip() or TEMPLATE_MARK in text:
            result.append(lang)
    return result


def localize(appcast, version):
    xml = appcast.read_text()
    english = re.search(r"<description( sparkle:format=\"markdown\")?>", xml)
    if english is None or xml.count("<description") != 1:
        sys.exit(f"{appcast}: expected exactly one <description> from generate_appcast")
    xml = xml[: english.start()] + english.group(0).replace("<description", '<description xml:lang="en"', 1) + xml[english.end():]
    end = xml.index("</description>") + len("</description>")
    indent = re.search(r"\n([ \t]*)<description", xml).group(1)
    added = []
    for lang in LANGS:
        path = notes_path(version, lang)
        if not path.exists():
            continue
        text = path.read_text()
        if "]]>" in text:
            sys.exit(f"{path}: contains ]]>, which can't be embedded in CDATA")
        added.append(f'\n{indent}<description xml:lang="{lang}" sparkle:format="markdown"><![CDATA[{text}]]></description>')
    appcast.write_text(xml[:end] + "".join(added) + xml[end:])
    print(f"localized release notes: en {' '.join(lang for lang in LANGS if notes_path(version, lang).exists())}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--missing":
        print(" ".join(missing(sys.argv[2])))
    elif len(sys.argv) == 3:
        localize(pathlib.Path(sys.argv[1]), sys.argv[2])
    else:
        sys.exit(__doc__)
