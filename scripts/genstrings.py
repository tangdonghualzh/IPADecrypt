#!/usr/bin/env python3
"""把 src/strings.json 生成 Swift 常量，构建时自动替换界面文案。

用法：
  python3 scripts/genstrings.py --swift build/gen/Strings.swift
  python3 scripts/genstrings.py --get app.title
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "src" / "strings.json"
PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def load():
    try:
        data = json.loads(SOURCE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"找不到 {SOURCE}")
    except json.JSONDecodeError as error:
        die(f"strings.json 格式错误：{error}")
    if not isinstance(data, dict):
        die("strings.json 顶层必须是对象")
    return data


def swift_chunk(text):
    out = ['"']
    for char in text:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\t":
            out.append("\\t")
        elif char == "\r":
            out.append("\\r")
        elif ord(char) < 0x20:
            out.append("\\u{%x}" % ord(char))
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def swift_interpolated(text):
    """把 {name} 变成 Swift 插值，返回 (源码片段, 参数名列表)。"""
    pieces = []
    params = []
    cursor = 0
    for match in PLACEHOLDER.finditer(text):
        pieces.append(swift_chunk(text[cursor:match.start()])[1:-1])
        name = match.group(1)
        if name not in params:
            params.append(name)
        pieces.append("\\(" + name + ")")
        cursor = match.end()
    pieces.append(swift_chunk(text[cursor:])[1:-1])
    return '"' + "".join(pieces) + '"', params


def swift_literal(text):
    if PLACEHOLDER.search(text):
        return swift_interpolated(text)
    return swift_chunk(text), []


def generate(data):
    lines = [
        "// 由 scripts/genstrings.py 从 src/strings.json 生成，不要直接改这个文件。",
        "// 改文案请编辑 src/strings.json，然后重新构建。",
        "",
        "enum S {",
    ]
    for category, entries in data.items():
        if category.startswith("_"):
            continue
        if not isinstance(entries, dict):
            die(f"{category} 必须是对象")
        lines.append(f"    enum {category[:1].upper()}{category[1:]} {{")
        for key, value in entries.items():
            if key.startswith("_"):
                continue
            if not isinstance(value, str):
                die(f"{category}.{key} 的值必须是字符串")
            literal, params = swift_literal(value)
            if not params:
                lines.append(f"        static let {key} = {literal}")
            else:
                signature = ", ".join(f"{name}: String" for name in params)
                lines.append(f"        static func {key}({signature}) -> String {{")
                lines.append(f"            {literal}")
                lines.append("        }")
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift", help="生成的 Swift 文件路径")
    parser.add_argument("--get", help="读取某个键的原始文案，例如 app.title")
    args = parser.parse_args()
    data = load()

    if args.get:
        node = data
        for part in args.get.split("."):
            if not isinstance(node, dict) or part not in node:
                die(f"strings.json 里没有 {args.get}")
            node = node[part]
        if not isinstance(node, str):
            die(f"{args.get} 不是字符串")
        print(node)
        return

    if not args.swift:
        die("需要 --swift 或 --get")

    output = Path(args.swift)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(generate(data), encoding="utf-8")
    print(f"已生成 {output}")


if __name__ == "__main__":
    main()
