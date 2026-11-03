import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent / "workspace"
FONT = {"$ref": "font:font_0"}


def rgb565(red, green, blue):
    return ((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3)


BG = rgb565(14, 20, 28)
PANEL = rgb565(29, 39, 50)
KEY = rgb565(45, 58, 72)
KEY_DOWN = rgb565(69, 88, 105)
TEXT = rgb565(238, 243, 247)
MUTED = rgb565(162, 176, 188)
ACCENT = rgb565(32, 167, 146)
ACCENT_DOWN = rgb565(21, 120, 105)
WARNING = rgb565(255, 170, 44)


COLORS = [
    ("W", 0, (255, 255, 255)),
    ("Y", 1, (255, 224, 112)),
    ("C", 2, (64, 255, 255)),
    ("G", 3, (64, 255, 128)),
    ("O", 4, (255, 144, 0)),
    ("P", 5, (255, 96, 192)),
    ("R", 6, (255, 64, 64)),
]


def button(key, x, y, w, h, text, events, bco=KEY, bco2=KEY_DOWN,
           pco=TEXT, border=rgb565(77, 93, 108), font=FONT):
    return {
        "key": key,
        "type": "button",
        "attributes": {
            "objname": key,
            "x": x,
            "y": y,
            "w": w,
            "h": h,
            "sta": 1,
            "style": 1,
            "borderc": border,
            "borderw": 1,
            "font": font,
            "bco": bco,
            "bco2": bco2,
            "pco": pco,
            "pco2": pco,
            "xcen": 1,
            "ycen": 1,
            "txt": text,
            "txt_maxl": max(8, len(text.encode("utf-8")) + 2),
        },
        "events": {"codesdown": [], "codesup": events},
    }


def text(key, x, y, w, h, value, pco=TEXT, bco=BG, center=1,
         max_bytes=64, global_scope=0):
    return {
        "key": key,
        "type": "text",
        "attributes": {
            "objname": key,
            "vscope": global_scope,
            "x": x,
            "y": y,
            "w": w,
            "h": h,
            "sta": 1,
            "style": 0,
            "font": FONT,
            "bco": bco,
            "pco": pco,
            "xcen": center,
            "ycen": 1,
            "txt": value,
            "txt_maxl": max_bytes,
        },
        "events": {"codesdown": [], "codesup": []},
    }


def variable(key, value):
    return {
        "key": key,
        "type": "variable",
        "attributes": {
            "objname": key,
            "vscope": 1,
            "val": value,
            "txt": "v",
            "txt_maxl": 2,
        },
        "events": {},
    }


def page_root(header, left, right, load_lines):
    attrs = {
        "x": 0,
        "y": 0,
        "w": 480,
        "h": 272,
        "sta": 1,
        "bco": BG,
        "left": {"$ref": f"page:{left}"} if left else 255,
        "right": {"$ref": f"page:{right}"} if right else 255,
    }
    return {
        "header": header,
        "root": {
            "attributes": attrs,
            "events": {
                "codesload": load_lines,
                "codesloadend": [],
                "codesdown": [],
                "codesup": [],
                "codesunload": [],
            },
        },
    }


def append_events(char_upper, char_lower=None, prefix=""):
    if char_lower is None:
        char_lower = char_upper
    upper_hex = f"{ord(char_upper):02X}"
    lower_hex = f"{ord(char_lower):02X}"
    text_name = f"{prefix}tEdit.txt" if prefix else "tEdit.txt"
    len_name = f"{prefix}nLen.val" if prefix else "nLen.val"
    lines = [f"if({len_name}<32)", "{"]
    if char_upper != char_lower:
        case_name = f"{prefix}nCase.val" if prefix else "nCase.val"
        lines += [
            f"if({case_name}==0)",
            "{",
            f'{text_name}={text_name}+"{char_upper}"',
            f"printh 55 01 20 {upper_hex} FF FF FF",
            "}else",
            "{",
            f'{text_name}={text_name}+"{char_lower}"',
            f"printh 55 01 20 {lower_hex} FF FF FF",
            "}",
        ]
    else:
        lines += [
            f'{text_name}={text_name}+"{char_upper}"',
            f"printh 55 01 20 {upper_hex} FF FF FF",
        ]
    lines += [f"{len_name}={len_name}+1", "}"]
    return lines


def set_letter_labels(lower):
    lines = []
    for letter in "QWERTYUIOPASDFGHJKLZXCVBNM":
        shown = letter.lower() if lower else letter
        lines.append(f'b{letter}.txt="{shown}"')
        lines.append(f"ref b{letter}")
    return lines


def make_letter_page(header):
    load = [
        "covx nLen.val,tLen.txt,0,0",
        "if(nCase.val==0)",
        "{",
        *set_letter_labels(False),
        "}else",
        "{",
        *set_letter_labels(True),
        "}",
    ]
    for _, index, rgb in COLORS:
        load += [
            f"if(nColor.val=={index})",
            "{",
            f"tEdit.pco={rgb565(*rgb)}",
            "}",
        ]
    page = page_root(header, "effect", "subtitle_symbols", load)
    page["name"] = "subtitle"
    objects = [
        variable("nLen", 0),
        variable("nCase", 0),
        variable("nColor", 1),
        text("tTitle", 8, 0, 220, 24, "EDIT SUBTITLE", pco=TEXT, center=0),
        text("tLen", 424, 0, 48, 24, "0", pco=MUTED, center=2, max_bytes=4),
        text("tEdit", 10, 26, 460, 32, "", pco=rgb565(255, 224, 112),
             bco=PANEL, center=0, max_bytes=33, global_scope=1),
        text("tSta", 236, 0, 180, 24, "READY", pco=MUTED, center=2, max_bytes=24),
    ]
    start_x = 63
    for idx, (label, color_index, rgb) in enumerate(COLORS):
        color = rgb565(*rgb)
        event = [
            f"nColor.val={color_index}",
            f"tEdit.pco={color}",
            "ref tEdit",
            f"printh 55 01 22 {color_index:02X} FF FF FF",
            f'tSta.txt="COLOR {label}"',
            "ref tSta",
        ]
        objects.append(button(f"bCol{label}", start_x + idx * 51, 64, 42, 25,
                              label, event, bco=color, bco2=color,
                              pco=rgb565(10, 16, 22), border=color))

    rows = [
        ("QWERTYUIOP", 17, 94),
        ("ASDFGHJKL", 40, 132),
        ("ZXCVBNM", 85, 170),
    ]
    for letters, x0, y in rows:
        for pos, letter in enumerate(letters):
            events = append_events(letter, letter.lower()) + [
                "covx nLen.val,tLen.txt,0,0",
                "ref tEdit",
                "ref tLen",
            ]
            objects.append(button(f"b{letter}", x0 + pos * 45, y, 40, 34,
                                  letter, events))

    case_events = [
        "if(nCase.val==0)",
        "{",
        "nCase.val=1",
        *set_letter_labels(True),
        "}else",
        "{",
        "nCase.val=0",
        *set_letter_labels(False),
        "}",
    ]
    objects.append(button("bCase", 5, 170, 72, 34, "Aa", case_events,
                          bco=ACCENT, bco2=ACCENT_DOWN))
    delete_events = [
        "if(nLen.val>0)",
        "{",
        "nLen.val=nLen.val-1",
        "substr tEdit.txt,tEdit.txt,0,nLen.val",
        "printh 55 01 21 00 FF FF FF",
        "covx nLen.val,tLen.txt,0,0",
        "ref tEdit",
        "ref tLen",
        "}",
    ]
    objects.append(button("bDel", 400, 170, 75, 34, "DEL", delete_events,
                          bco=rgb565(120, 59, 59), bco2=rgb565(87, 42, 42)))
    objects += [
        button("bBack", 0, 224, 78, 48, "BACK", ["page ${page:effect}"]),
        button("bSymbols", 80, 224, 78, 48, "123", ["page ${page:subtitle_symbols}"]),
        button("bClear", 160, 224, 76, 48, "CLEAR", [
            'tEdit.txt=""', "nLen.val=0", "printh 55 01 21 01 FF FF FF",
            'tLen.txt="0"', "ref tEdit", "ref tLen",
        ]),
        button("bSpace", 238, 224, 98, 48, "SPACE", append_events(" ") + [
            "covx nLen.val,tLen.txt,0,0", "ref tEdit", "ref tLen",
        ]),
        button("bApply", 338, 224, 142, 48, "APPLY", [
            "printh 55 01 21 02 FF FF FF", 'tSta.txt="APPLIED"', "ref tSta",
        ], bco=ACCENT, bco2=ACCENT_DOWN),
    ]
    page["objects"] = objects
    return page


def make_symbol_page(header):
    load = ["tEdit2.txt=subtitle.tEdit.txt", "ref tEdit2"]
    page = page_root(header, "subtitle", None, load)
    page["name"] = "subtitle_symbols"
    objects = [
        text("tTitle", 8, 0, 220, 24, "NUMBERS & SYMBOLS", pco=TEXT, center=0),
        text("tEdit2", 10, 26, 460, 32, "", pco=rgb565(255, 224, 112),
             bco=PANEL, center=0, max_bytes=33),
    ]

    symbols = list("1234567890") + list(".,!?-+/%:;()_=*")
    rows = [symbols[:10], symbols[10:20], symbols[20:]]
    y_values = [76, 121, 166]
    for row_index, row_chars in enumerate(rows):
        width = len(row_chars) * 40 + max(0, len(row_chars) - 1) * 6
        x0 = (480 - width) // 2
        for pos, char in enumerate(row_chars):
            events = append_events(char, prefix="subtitle.") + [
                "tEdit2.txt=subtitle.tEdit.txt",
                "ref tEdit2",
            ]
            key_name = f"bS{row_index}_{pos}"
            objects.append(button(key_name, x0 + pos * 46, y_values[row_index],
                                  40, 34, char, events))

    delete_events = [
        "if(subtitle.nLen.val>0)",
        "{",
        "subtitle.nLen.val=subtitle.nLen.val-1",
        "substr subtitle.tEdit.txt,subtitle.tEdit.txt,0,subtitle.nLen.val",
        "tEdit2.txt=subtitle.tEdit.txt",
        "printh 55 01 21 00 FF FF FF",
        "ref tEdit2",
        "}",
    ]
    objects += [
        button("bLetters", 0, 224, 78, 48, "ABC", ["page ${page:subtitle}"]),
        button("bDel", 80, 224, 72, 48, "DEL", delete_events,
               bco=rgb565(120, 59, 59), bco2=rgb565(87, 42, 42)),
        button("bClear", 154, 224, 72, 48, "CLEAR", [
            'subtitle.tEdit.txt=""', 'tEdit2.txt=""', "subtitle.nLen.val=0",
            "printh 55 01 21 01 FF FF FF", "ref tEdit2",
        ]),
        button("bSpace", 228, 224, 78, 48, "SPACE", append_events(" ", prefix="subtitle.") + [
            "tEdit2.txt=subtitle.tEdit.txt", "ref tEdit2",
        ]),
        button("bDefault", 308, 224, 82, 48, "DEFAULT", [
            'subtitle.tEdit.txt=""', 'tEdit2.txt=""', "subtitle.nLen.val=0",
            "printh 55 01 21 03 FF FF FF", "ref tEdit2",
        ], bco=WARNING, bco2=rgb565(190, 114, 24), pco=rgb565(20, 20, 20)),
        button("bApply", 392, 224, 88, 48, "APPLY", [
            "printh 55 01 21 02 FF FF FF",
        ], bco=ACCENT, bco2=ACCENT_DOWN),
    ]
    page["objects"] = objects
    return page


def main():
    project_path = ROOT / "project.json"
    effect_path = ROOT / "pages" / "effect.json"
    project = json.loads(project_path.read_text(encoding="utf-8"))
    effect = json.loads(effect_path.read_text(encoding="utf-8"))

    keys = [entry["key"] for entry in project["pages"]]
    if "subtitle" not in keys:
        project["pages"].append({
            "key": "subtitle",
            "content": {"mode": "json", "path": "pages/subtitle.json"},
        })
    if "subtitle_symbols" not in keys:
        project["pages"].append({
            "key": "subtitle_symbols",
            "content": {"mode": "json", "path": "pages/subtitle_symbols.json"},
        })

    effect["root"]["attributes"]["right"] = {"$ref": "page:subtitle"}
    effect["objects"] = [obj for obj in effect["objects"] if obj["key"] != "bSubtitle"]
    effect["objects"].append(button(
        "bSubtitle", 368, 224, 112, 48, "SUBTITLE >",
        ["page ${page:subtitle}"], bco=ACCENT, bco2=ACCENT_DOWN,
    ))

    header = effect["header"]
    letter_page = make_letter_page(header)
    symbol_page = make_symbol_page(header)

    project_path.write_text(json.dumps(project, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")
    effect_path.write_text(json.dumps(effect, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    (ROOT / "pages" / "subtitle.json").write_text(
        json.dumps(letter_page, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (ROOT / "pages" / "subtitle_symbols.json").write_text(
        json.dumps(symbol_page, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print("generated pages: subtitle, subtitle_symbols")


if __name__ == "__main__":
    main()
