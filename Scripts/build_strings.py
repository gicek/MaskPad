#!/usr/bin/env python3
"""Generate MaskPad/Resources/Localizable.xcstrings from Scripts/translations.py.

    python3 Scripts/build_strings.py           # validate and write
    python3 Scripts/build_strings.py --check   # validate only; exit 1 if the catalog is out of date

Checks:
- L("…") keys in code match the translation table exactly (missing or extra keys are errors);
- every entry has all languages, and placeholders (%@ / %lld) match the English;
- interpolated variables must have a registered type (INT_VARS / STRING_VARS): Swift's
  String.LocalizationValue emits %lld for Int and %@ for String, and a mismatched key silently
  falls back to English at runtime, so fail loudly instead.
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "Scripts"))
from translations import LANGS, T  # noqa: E402

# Types of interpolated variables, keyed by the literal Swift interpolation expression.
INT_VARS = {"remaining", "minutes"}
STRING_VARS = {"Self.appName", "Self.appVersion"}

CALL = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"\)')
INTERPOLATION = re.compile(r"\\\(([^()]*)\)")
PLACEHOLDER = re.compile(r"%(?:lld|@)")
OUT = root / "MaskPad/Resources/Localizable.xcstrings"

errors = []


def to_key(source, path):
    def replace(match):
        name = match.group(1).strip()
        if name in INT_VARS:
            return "%lld"
        if name in STRING_VARS:
            return "%@"
        errors.append(f"{path}: unregistered interpolation \\({name}) — add it to INT_VARS or STRING_VARS")
        return "%@"
    if "\\(" in INTERPOLATION.sub("", source):
        errors.append(f"{path}: unsupported interpolation in L(\"{source}\")")
    return INTERPOLATION.sub(replace, source)


used = set()
for path in sorted((root / "MaskPad").rglob("*.swift")):
    for source in CALL.findall(path.read_text()):
        used.add(to_key(source, path.relative_to(root)))

for key in sorted(used - T.keys()):
    errors.append(f"missing translation: {key}")
for key in sorted(T.keys() - used):
    errors.append(f"unused translation: {key}")
for key, values in T.items():
    if len(values) != len(LANGS):
        errors.append(f"wrong language count: {key}")
        continue
    expected = sorted(PLACEHOLDER.findall(key))
    for lang, value in zip(LANGS, values):
        if sorted(PLACEHOLDER.findall(value)) != expected:
            errors.append(f"placeholder mismatch [{lang}]: {key}")

if errors:
    print("\n".join(errors))
    sys.exit(1)

def typeset(lang, value):
    """French typography: narrow no-break space (U+202F) before ? ! ; : » and after «, so lines never break before punctuation."""
    if lang == "fr":
        value = re.sub(r" ([?!;:»])", "\u202f\\1", value)
        value = value.replace("« ", "«\u202f")
    return value


strings = {}
for key in sorted(T, key=str.lower):
    strings[key] = {"localizations": {
        lang: {"stringUnit": {"state": "translated", "value": typeset(lang, value)}}
        for lang, value in zip(LANGS, T[key])
    }}
catalog = json.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                     ensure_ascii=False, indent=2, sort_keys=True) + "\n"

if "--check" in sys.argv[1:]:
    if not OUT.exists() or OUT.read_text() != catalog:
        print(f"{OUT.relative_to(root)} is out of date; run python3 Scripts/build_strings.py")
        sys.exit(1)
    print(f"ok: {len(strings)} keys x {len(LANGS)} languages")
else:
    OUT.write_text(catalog)
    print(f"wrote {len(strings)} keys x {len(LANGS)} languages -> {OUT.relative_to(root)}")
