#!/usr/bin/env python3
"""Sense Remote design tokens: design/tokens.json -> Dart + CSS (İnşa planı §4.3).

    python tools/sense-tokens/generate.py          # write the outputs
    python tools/sense-tokens/generate.py --check  # exit 1 if an output is stale

Outputs (never edit by hand):
    flutter/lib/sense/tokens/tokens.g.dart
    design/tokens.css
Standard library only, so it runs anywhere Python 3.9+ is.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "design" / "tokens.json"
DART_OUT = ROOT / "flutter" / "lib" / "sense" / "tokens" / "tokens.g.dart"
CSS_OUT = ROOT / "design" / "tokens.css"

IDENT = re.compile(r"^[a-z][A-Za-z0-9]*$")
HEX = re.compile(r"^#[0-9A-F]{6}$")
# CSS gradient angle -> Flutter begin/end.
ANGLES = {
    0: ("Alignment.bottomCenter", "Alignment.topCenter"),
    90: ("Alignment.centerLeft", "Alignment.centerRight"),
    180: ("Alignment.topCenter", "Alignment.bottomCenter"),
    270: ("Alignment.centerRight", "Alignment.centerLeft"),
}


class TokenError(Exception):
    pass


def kebab(name: str) -> str:
    return re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), name)


def num(value) -> str:
    """Shortest exact text of a JSON number (12 -> '12', 12.5 -> '12.5')."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise TokenError(f"not a number: {value!r}")
    if float(value).is_integer():
        return str(int(value))
    return repr(float(value))


def dart_double(value) -> str:
    text = num(value)
    return text if "." in text else text + ".0"


def names(group: dict, where: str) -> list[str]:
    for name in group:
        if not IDENT.match(name):
            raise TokenError(f"{where}.{name}: names are lowerCamelCase")
    return list(group)


def digest(data: dict) -> str:
    # Canonical form, so line endings and key order on disk do not change it.
    canon = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def validate(data: dict) -> None:
    for key in ("version", "color", "gradient", "font", "fontWeight", "fontSize",
                "letterSpacing", "size", "radius", "breakpoint", "curve", "motion",
                "motionParam", "threshold"):
        if key not in data:
            raise TokenError(f"missing group: {key}")
    for name in names(data["color"], "color"):
        if not HEX.match(data["color"][name]["value"]):
            raise TokenError(f"color.{name}: use #RRGGBB in upper case")
    for name in names(data["gradient"], "gradient"):
        g = data["gradient"][name]
        if g["angleDeg"] not in ANGLES:
            raise TokenError(f"gradient.{name}: angle must be one of {sorted(ANGLES)}")
        for ref in g["colors"]:
            if ref not in data["color"]:
                raise TokenError(f"gradient.{name}: unknown colour {ref}")
    for name in names(data["fontWeight"], "fontWeight"):
        w = data["fontWeight"][name]["value"]
        if w not in range(100, 1000, 100):
            raise TokenError(f"fontWeight.{name}: 100..900")
    for group in ("fontSize", "letterSpacing", "size", "radius", "breakpoint", "motionParam"):
        for name in names(data[group], group):
            num(data[group][name]["value"])
    for name in names(data["curve"], "curve"):
        b = data["curve"][name]["bezier"]
        if len(b) != 4:
            raise TokenError(f"curve.{name}: four numbers")
        for x in b:
            num(x)
        if not (0 <= b[0] <= 1 and 0 <= b[2] <= 1):
            raise TokenError(f"curve.{name}: x1 and x2 must be within 0..1")
    for name in names(data["motion"], "motion"):
        m = data["motion"][name]
        if not isinstance(m["ms"], int) or m["ms"] <= 0:
            raise TokenError(f"motion.{name}: ms is a positive integer")
        if m["curve"] not in data["curve"]:
            raise TokenError(f"motion.{name}: unknown curve {m['curve']}")
        if not isinstance(m["repeat"], bool):
            raise TokenError(f"motion.{name}: repeat is true or false")
    for name in names(data["threshold"], "threshold"):
        t = data["threshold"][name]
        warn, hot = float(t["warn"]), float(t["hot"])
        if t["direction"] == "above" and not warn < hot:
            raise TokenError(f"threshold.{name}: warn < hot when bigger is worse")
        if t["direction"] == "below" and not warn > hot:
            raise TokenError(f"threshold.{name}: warn > hot when smaller is worse")
        if t["direction"] not in ("above", "below"):
            raise TokenError(f"threshold.{name}: direction is above or below")


def dart_string(text: str) -> str:
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$") + "'"


def doc(note: str | None, indent: str = "  ") -> list[str]:
    return [f"{indent}/// {note}"] if note else []


def dart_class(name: str, summary: str, typ: str, group: dict, render) -> list[str]:
    out = [f"/// {summary}", f"abstract final class {name} {{"]
    for key, item in group.items():
        out += doc(item.get("note") if isinstance(item, dict) else None)
        out.append(f"  static const {typ} {key} = {render(item)};")
    out.append("")
    out.append(f"  static const Map<String, {typ}> all = {{")
    out += [f"    {dart_string(key)}: {key}," for key in group]
    out.append("  };")
    out.append("}")
    out.append("")
    return out


def build_dart(data: dict, sha: str) -> str:
    out = [
        "// GENERATED by tools/sense-tokens/generate.py from design/tokens.json. Do not edit:",
        "// change the JSON (YH T1-T4, T6; prototype first) and run the generator.",
        f"// sense-tokens v{data['version']} sha256:{sha}",
        "// ignore_for_file: constant_identifier_names",
        "import 'package:flutter/animation.dart';",
        "import 'package:flutter/painting.dart';",
        "",
        "import 'token_types.dart';",
        "",
        "/// Version and content digest of design/tokens.json (panel copy check).",
        "abstract final class SenseTokensMeta {",
        f"  static const int version = {data['version']};",
        f"  static const String digest = {dart_string(sha)};",
        "}",
        "",
    ]
    out += dart_class("SenseColors", "Colours (YH T1). Dark theme only.", "Color",
                      data["color"], lambda c: f"Color(0xFF{c['value'][1:]})")

    out += ["/// Gradients (YH T1): only for big scenes.", "abstract final class SenseGradients {"]
    for key, g in data["gradient"].items():
        begin, end = ANGLES[g["angleDeg"]]
        colors = ", ".join(f"SenseColors.{c}" for c in g["colors"])
        out += doc(g.get("note"))
        out.append(f"  static const LinearGradient {key} = LinearGradient(")
        out.append(f"      begin: {begin}, end: {end}, colors: [{colors}]);")
    out += ["}", ""]

    out += ["/// Type family (YH T2): Poppins, bundled with the app.",
            "abstract final class SenseFont {",
            f"  static const String family = {dart_string(data['font']['family'])};",
            "}", ""]
    out += dart_class("SenseFontWeight", "Font weights (YH T2).", "FontWeight",
                      data["fontWeight"], lambda w: f"FontWeight.w{w['value']}")
    out += dart_class("SenseFontSize", "Font sizes in logical px (YH T2).", "double",
                      data["fontSize"], lambda v: dart_double(v["value"]))
    out += dart_class("SenseLetterSpacing",
                      "Letter spacing in em (YH T2); multiply by the font size for Flutter.",
                      "double", data["letterSpacing"], lambda v: dart_double(v["value"]))
    out += dart_class("SenseSizes", "Sizes in logical px (YH T3, T9).", "double",
                      data["size"], lambda v: dart_double(v["value"]))
    out += dart_class("SenseRadii", "Corner radii in logical px (YH T3).", "double",
                      data["radius"], lambda v: dart_double(v["value"]))
    out += dart_class("SenseBreakpoints",
                      "Window widths below which the medium / narrow sizes apply (YH T3, T9).",
                      "double", data["breakpoint"], lambda v: dart_double(v["value"]))
    out += dart_class("SenseCurves", "Animation curves (YH T4), CSS cubic-bezier equivalents.",
                      "Cubic", data["curve"],
                      lambda c: "Cubic(" + ", ".join(dart_double(x) for x in c["bezier"]) + ")")
    out += dart_class(
        "SenseMotion", "Named animations (YH T4). No rotation.", "SenseMotionSpec",
        data["motion"],
        lambda m: (f"SenseMotionSpec(duration: Duration(milliseconds: {m['ms']}), "
                   f"curve: SenseCurves.{m['curve']}, repeat: {str(m['repeat']).lower()})"))
    out += dart_class("SenseMotionParams", "Offsets, scales and opacities of the animations (YH T4).",
                      "double", data["motionParam"], lambda v: dart_double(v["value"]))
    out += dart_class(
        "SenseThresholds", "Orange / red limits (YH T6); use SenseThreshold.levelOf.",
        "SenseThreshold", data["threshold"],
        lambda t: (f"SenseThreshold(warn: {dart_double(t['warn'])}, hot: {dart_double(t['hot'])}, "
                   f"direction: SenseThresholdDirection.{t['direction']}, "
                   f"unit: {dart_string(t['unit'])})"))
    return "\n".join(out).rstrip("\n") + "\n"


def build_css(data: dict, sha: str) -> str:
    out = [
        "/* GENERATED by tools/sense-tokens/generate.py from design/tokens.json. Do not edit. */",
        f"/* sense-tokens v{data['version']} sha256:{sha} */",
        ":root {",
        f"  --sr-tokens-version: {data['version']};",
    ]

    def line(name: str, value: str, note: str | None = None) -> None:
        out.append(f"  --sr-{name}: {value};" + (f" /* {note} */" if note else ""))

    for key, c in data["color"].items():
        line(f"color-{kebab(key)}", c["value"].lower(), c.get("note"))
    for key, g in data["gradient"].items():
        colors = ", ".join(f"var(--sr-color-{kebab(c)})" for c in g["colors"])
        line(f"gradient-{kebab(key)}", f"linear-gradient({g['angleDeg']}deg, {colors})", g.get("note"))
    family = ", ".join([data["font"]["family"], *data["font"]["cssFallback"]])
    line("font-family", family)
    for key, w in data["fontWeight"].items():
        line(f"font-weight-{kebab(key)}", str(w["value"]))
    for key, v in data["fontSize"].items():
        line(f"font-size-{kebab(key)}", num(v["value"]) + "px")
    for key, v in data["letterSpacing"].items():
        line(f"letter-spacing-{kebab(key)}", num(v["value"]) + "em")
    for key, v in data["size"].items():
        line(f"size-{kebab(key)}", num(v["value"]) + "px")
    for key, v in data["radius"].items():
        line(f"radius-{kebab(key)}", num(v["value"]) + "px")
    for key, v in data["breakpoint"].items():
        # Media queries cannot read variables; kept for scripts and as the reference value.
        line(f"breakpoint-{kebab(key)}", num(v["value"]) + "px")
    for key, c in data["curve"].items():
        line(f"ease-{kebab(key)}", c["css"])
    for key, m in data["motion"].items():
        line(f"motion-{kebab(key)}", f"{m['ms']}ms")
        line(f"motion-{kebab(key)}-easing", data["curve"][m["curve"]]["css"])
    for key, v in data["motionParam"].items():
        line(f"motion-param-{kebab(key)}", num(v["value"]) + v.get("unit", ""))
    for key, t in data["threshold"].items():
        line(f"threshold-{kebab(key)}-warn", num(t["warn"]))
        line(f"threshold-{kebab(key)}-hot", num(t["hot"]))
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if an output is stale")
    args = parser.parse_args()
    try:
        data = json.loads(SOURCE.read_text(encoding="utf-8"))
        validate(data)
    except (OSError, ValueError, KeyError, TokenError) as err:
        print(f"tokens.json: {err}", file=sys.stderr)
        return 2
    sha = digest(data)
    outputs = {DART_OUT: build_dart(data, sha), CSS_OUT: build_css(data, sha)}
    stale = []
    for path, text in outputs.items():
        current = path.read_text(encoding="utf-8").replace("\r\n", "\n") if path.exists() else None
        if current == text:
            continue
        stale.append(path)
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8", newline="\n")
    rel = [str(p.relative_to(ROOT)) for p in stale]
    if args.check:
        if rel:
            print("stale, run tools/sense-tokens/generate.py: " + ", ".join(rel), file=sys.stderr)
            return 1
        print("tokens up to date")
    else:
        print("written: " + (", ".join(rel) if rel else "nothing (up to date)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
