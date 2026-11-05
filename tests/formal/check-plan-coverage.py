#!/usr/bin/env python3
"""Check public plan references and the IMAP command-construction boundary."""

import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = r"[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*"
TOKEN = re.compile(IDENTIFIER + r"|[^\s]")


def source_code(path):
    source = path.read_text(encoding="utf-8")
    literals = re.compile(r'''\#[^\n]*|"(?:\\[\s\S]|[^"\\])*"|'(?:\\.|[^'\\\n])*'|["']''')

    def mask(match):
        if match[0] in ('"', "'"):
            raise ValueError(f"{path}:{source.count(chr(10), 0, match.start()) + 1}: "
                             "unterminated literal")
        return re.sub(r"[^\n]", " ", match[0])

    return literals.sub(mask, source)


def module_aliases(path, source, module):
    aliases = {}
    root = module.parent.parent
    for token in TOKEN.finditer(source):
        if token[0] != "import":
            continue
        number = source.count("\n", 0, token.start()) + 1
        start = source.rfind("\n", 0, token.start()) + 1
        if source[start:token.start()].strip():
            raise ValueError(f"{path}:{number}: unsupported import placement")
        declaration = source[token.start():].split("\n", 1)[0].strip()
        match = re.fullmatch(r"import[ \t]+(Base|\.[\w./-]+\.bend)"
                             r"(?:[ \t]+as[ \t]+([A-Za-z_][A-Za-z_0-9]*))?", declaration)
        if match is None or (match[1] != "Base" and match[2] is None):
            raise ValueError(f"{path}:{number}: unsupported import; "
                             "local Bend imports need an explicit alias")
        if match[1] == "Base":
            continue
        target = (path.parent / match[1]).resolve()
        if not target.is_relative_to(root) or not target.is_file():
            raise ValueError(f"{path}:{number}: import does not name a repository file")
        if match[2] in aliases:
            raise ValueError(f"{path}:{number}: duplicate import alias {match[2]}")
        aliases[match[2]] = target
    return [alias for alias, target in aliases.items() if target == module]


def law_bodies(source):
    starts = [token for token in TOKEN.finditer(source) if token[0] in ("law", "def", "type", "import")]
    bodies = []
    for index, start in enumerate(starts):
        if start[0] != "law":
            continue
        header = re.match(rf"law\s+{IDENTIFIER}\s*:", source[start.start():])
        if header is None:
            raise ValueError("LAWS.bend: unsupported law declaration")
        end = starts[index + 1].start() if index + 1 < len(starts) else len(source)
        bodies.append(source[start.start() + header.end():end])
    return "\n".join(bodies)


def references(path, module, laws_only=False):
    source = source_code(path)
    aliases = module_aliases(path, source, module)
    prefixes = tuple(alias + "." for alias in aliases)
    tokens = list(TOKEN.finditer(law_bodies(source) if laws_only else source))
    names = set()
    for index, token in enumerate(tokens):
        if not token[0].startswith(prefixes):
            continue
        name = token[0].split(".", 1)[1]
        following = [item[0] for item in tokens[index + 1:index + 3]]
        binding = following[:1] == [":"] or (following[:1] == ["="] and following != ["=", "="])
        if laws_only and name.startswith("plan_") and binding:
            raise ValueError(f"LAWS.bend: unsupported qualified plan binding or annotation: {token[0]}")
        names.add(name)
    return names


def def_returns(path):
    tokens = [token[0] for token in TOKEN.finditer(source_code(path))]
    definitions = {}
    for index, token in enumerate(tokens):
        if token != "def":
            continue
        if index + 2 >= len(tokens) or not re.fullmatch(IDENTIFIER, tokens[index + 1]) \
                or tokens[index + 2] not in ("(", ":"):
            raise ValueError(f"{path}: unsupported def declaration")
        name = tokens[index + 1]
        if name in definitions:
            raise ValueError(f"{path}: duplicate def {name}")
        cursor = index + 2
        if tokens[cursor] == "(":
            depth = 1
            cursor += 1
            while cursor < len(tokens) and depth:
                if tokens[cursor] in ("def", "type", "law", "import"):
                    break
                depth += (tokens[cursor] == "(") - (tokens[cursor] == ")")
                cursor += 1
            if depth:
                raise ValueError(f"{path}: unsupported def parameters: {name}")
        annotation = []
        if tokens[cursor:cursor + 2] == ["-", ">"]:
            cursor += 2
            while cursor < len(tokens) and tokens[cursor] not in (":", "def", "type", "law", "import"):
                token = tokens[cursor]
                if not re.fullmatch(IDENTIFIER + r"|[0-9<>,&]", token) or \
                        (token == "&" and (cursor + 1 == len(tokens) or not tokens[cursor + 1].isdigit())):
                    raise ValueError(f"{path}: unsupported def return type: {name}")
                annotation.append(tokens[cursor])
                cursor += 1
        if not annotation:
            raise ValueError(f"{path}: missing def return type: {name}")
        if tokens[cursor:cursor + 1] != [":"]:
            raise ValueError(f"{path}: unsupported def return declaration: {name}")
        definitions[name] = annotation
    return definitions


def command_names(imap):
    tokens = [token[0] for token in TOKEN.finditer(source_code(imap))]
    starts = [index for index, token in enumerate(tokens[:-1])
              if token == "type" and tokens[index + 1] == "Cmd"]
    if len(starts) != 1 or tokens[starts[0]:starts[0] + 5] != ["type", "Cmd", "is", "Data", ":"]:
        raise ValueError("src/imap.bend: missing supported Cmd type declaration")
    names = set()
    index = starts[0] + 5
    while index < len(tokens) and tokens[index] not in ("def", "type", "law", "import", "@"):
        name = tokens[index]
        if not re.fullmatch(IDENTIFIER, name) or index + 1 >= len(tokens) or tokens[index + 1] != "{":
            raise ValueError("src/imap.bend: unsupported Cmd constructor declaration")
        if name in names:
            raise ValueError(f"src/imap.bend: duplicate Cmd constructor {name}")
        names.add(name)
        index += 2
        depth = 1
        while index < len(tokens) and depth:
            depth += (tokens[index] == "{") - (tokens[index] == "}")
            index += 1
        if depth:
            raise ValueError("src/imap.bend: unclosed Cmd constructor")
    if not names:
        raise ValueError("src/imap.bend: Cmd has no constructors")
    return names


def check_commands(path, imap, commands, root):
    source = source_code(path)
    names = {f"{alias}.{name}" for alias in module_aliases(path, source, imap)
             for name in commands}
    tokens = list(TOKEN.finditer(source))
    pattern = False
    depth = 0
    for index, token in enumerate(tokens):
        name = token[0]
        if name == "case":
            pattern = True
            depth = 0
        elif pattern:
            if name in ("(", "[", "{"):
                depth += 1
            elif name in (")", "]", "}"):
                depth -= 1
            elif name == ":" and depth == 0:
                pattern = False
            continue
        elif name in names and index + 1 < len(tokens) and tokens[index + 1][0] == "{":
            number = source.count("\n", 0, token.start()) + 1
            raise ValueError(f"{path.relative_to(root)}:{number}: command {name} "
                             "constructed outside src/ops.bend and src/imap.bend")


def check(root):
    root = root.resolve()
    ops = root / "src/ops.bend"
    paths = [root / "main.bend", *sorted((root / "src").rglob("*.bend"))]
    definitions = def_returns(ops)
    plans = {name for name in definitions if name.startswith("plan_")}
    public = set().union(*(references(path, ops) for path in paths if path != ops)) & plans
    missing = public - references(root / "LAWS.bend", ops, laws_only=True)
    if missing:
        raise ValueError("public plans missing from LAWS.bend: " + ", ".join(sorted(missing)))
    imap = root / "src/imap.bend"
    cmd_types = {f"{alias}.Cmd" for alias in module_aliases(ops, source_code(ops), imap)}
    wrappers = {name for name, annotation in definitions.items()
                if name not in plans and cmd_types.intersection(annotation)}
    factories = {name for name, annotation in def_returns(imap).items() if "Cmd" in annotation}
    commands = command_names(imap)
    for path in paths:
        for module, producers in ((ops, wrappers), (imap, factories)):
            if path == module:
                continue
            forbidden = references(path, module) & producers
            if forbidden:
                raise ValueError(f"{path.relative_to(root)}: command-returning defs outside "
                                 "src/ops.bend plan_* boundary: " + ", ".join(sorted(forbidden)))
        if path not in (ops, imap):
            check_commands(path, imap, commands, root)
    return len(public)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        count = check(args.root)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"{count} public plans referenced in LAWS.bend; command construction checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
