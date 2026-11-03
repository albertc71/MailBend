#!/usr/bin/env python3
"""Check documented source names without compiling or connecting to a service."""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
NAME = r"[A-Za-z_][A-Za-z_0-9]*"
STRING = r'"(?:\\[\s\S]|[^"\\])*"'
CHAR = r"'(?:\\(?:u\{[0-9a-fA-F]+\}|x[0-9a-fA-F]{2}|.)|[^'\\\n])'"
RAW_STRING = r'(?:br|r)(?P<hashes>\#*)"[\s\S]*?"(?P=hashes)'
ENV_NAME = re.compile(r"MAILBEND_[A-Z_0-9]+")


def source_text(path):
    text = path.read_text()
    rust = path.suffix == ".rs"
    comments = r"//[^\n]*|/\*" if rust else r"\#[^\n]*"
    raw = f"{RAW_STRING}|" if rust else ""
    tokens = re.compile(f"{raw}{CHAR}|{STRING}|{comments}")
    parts = []
    start = 0
    while match := tokens.search(text, start):
        parts.append(text[start:match.start()])
        token = match[0]
        end = match.end()
        if token == "/*":
            depth = 1
            while depth:
                nested = re.search(r"/\*|\*/", text[end:])
                if not nested:
                    raise ValueError(f"{path}: unclosed block comment")
                depth += 1 if nested[0] == "/*" else -1
                end += nested.end()
            token = text[match.start():end]
        if token.startswith('"'):
            parts.append(token)
        elif rust and token.startswith(("r", "br")):
            parts.append(json.dumps(token[token.index('"') + 1:token.rindex('"')]))
        else:
            parts.append(re.sub(r"[^\n]", " ", token))
        start = end
    parts.append(text[start:])
    text = "".join(parts)
    if path.suffix == ".rs":
        masked = re.sub(f"{CHAR}|{STRING}", lambda m: " " * len(m[0]), text)
        test_module = re.compile(r"#\[\s*cfg\s*\(\s*test\s*\)\s*\]\s*mod\s+" + NAME + r"\s*\{")
        for match in reversed(list(test_module.finditer(masked))):
            depth = 1
            end = match.end()
            while depth and end < len(masked):
                depth += (masked[end] == "{") - (masked[end] == "}")
                end += 1
            if depth:
                raise ValueError(f"{path}: unclosed cfg(test) module")
            text = text[:match.start()] + " " * (end - match.start()) + text[end:]
    return text


def definition(text, name):
    match = re.search(r"^def " + re.escape(name) + r"\([^\n]*\)[^\n]*:\n((?:[ \t].*\n|\n)+)", text, re.M)
    if not match:
        raise ValueError(f"main.bend: missing or unrecognized {name}() definition")
    return match[1]


def required(values, description):
    if not values:
        raise ValueError(f"no {description} found")
    return values


def law_references(text, path, root):
    refs = set(re.findall(r"\bLaws\.([a-z_][a-z_0-9]*)", text))
    for label, target in re.findall(r"\[([^]\n]+)\]\(([^)\s]+)\)", text):
        if "://" not in target and (path.parent / target.split("#", 1)[0]).resolve() == root / "LAWS.bend":
            label = label.strip("`")
            if re.fullmatch(NAME, label):
                refs.add(label)
    for match in re.finditer(r"\blaws?\s+((?:`" + NAME + r"`(?:\s*,\s*|\s+and\s+|\s+or\s+)?)+)", text):
        refs.update(re.findall(r"`(" + NAME + r")`", match[1]))
    refs.update(re.findall(r"`(" + NAME + r")`\s+law\b", text))
    return refs


def heading_slugs(text):
    slugs = set()
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            continue
        if marker and (marker[1][0] != "`" or "`" not in marker[2]):
            fence = marker[1]
            continue
        match = re.match(r"^#+ (.+)$", line)
        if not match:
            continue
        heading = match[1]
        base = re.sub(r"[^a-z0-9 _-]", "", heading.lower()).replace(" ", "-")
        slug = base
        suffix = 0
        while slug in slugs:
            suffix += 1
            slug = f"{base}-{suffix}"
        slugs.add(slug)
    return slugs


def skill_references(root):
    errors = []
    directory = root / "skills/mailbend"
    for relative in ("SKILL.md", "references/tools.md", "references/cli.md"):
        if not (directory / relative).is_file():
            errors.append(f"skills/mailbend/{relative}: missing skill file")
    if errors:
        return errors

    spec = importlib.util.spec_from_file_location("mailbend_documented_schema", root / "tools/gen-schema.py")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except (Exception, SystemExit) as error:
        raise ValueError(f"tools/gen-schema.py: cannot load schema ({type(error).__name__}: {error})") from error
    try:
        tools = required({tool["name"]: set(tool["inputSchema"]["properties"])
                          for tool in module.TOOLS}, "schema tools")
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        raise ValueError(f"tools/gen-schema.py: invalid tool schema ({type(error).__name__}: {error})") from error
    tool_name = r"mail_[A-Za-z_0-9]+"
    signatures = re.compile(r"\b(" + tool_name + r")\(([^()\n]*)\)")
    listed = set()
    for path in sorted(directory.rglob("*.md")):
        text = path.read_text()
        label = str(path.relative_to(root))
        names = set(re.findall(r"\b" + tool_name + r"\b", text))
        errors.extend(f"{label}: unknown tool {name}" for name in sorted(names - tools.keys()))
        arguments = set(re.findall(r"\b(" + tool_name + r")\.(" + NAME + r")\b", text))
        for match in signatures.finditer(text):
            name, raw = match.groups()
            line_start = text.rfind("\n", 0, match.start()) + 1
            index_entry = (path == directory / "references/tools.md"
                           and text[line_start:match.start()] == "- `"
                           and text[match.end():].startswith("`:"))
            if index_entry:
                listed.add(name)
            signature_arguments = set()
            for argument in raw.split(",") if raw.strip() else []:
                argument = argument.strip()
                if not re.fullmatch(NAME, argument):
                    errors.append(f"{label}: invalid argument notation {name}({raw})")
                else:
                    arguments.add((name, argument))
                    signature_arguments.add(argument)
            if index_entry and name in tools:
                errors.extend(f"{label}: missing argument {name}.{argument}"
                              for argument in sorted(tools[name] - signature_arguments))
        for name, argument in sorted(arguments):
            if name in tools and argument not in tools[name]:
                errors.append(f"{label}: unknown argument {name}.{argument}")
        for target in re.findall(r"\[[^]\n]+\]\(([^)\s]+)\)", text):
            repository_prefix = "https://github.com/albertc71/MailBend/blob/main/"
            if target.startswith(repository_prefix):
                relative, _, anchor = target[len(repository_prefix):].partition("#")
                destination = (root / relative).resolve()
            elif re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target):
                continue
            else:
                relative, _, anchor = target.partition("#")
                destination = (path.parent / relative).resolve() if relative else path
            if not destination.is_relative_to(root):
                errors.append(f"{label}: linked file outside repository {target}")
            elif not destination.is_file():
                errors.append(f"{label}: missing linked file {target}")
            elif anchor and destination.suffix == ".md":
                if anchor not in heading_slugs(destination.read_text()):
                    errors.append(f"{label}: missing linked heading {target}")
    errors.extend(f"skills/mailbend/references/tools.md: missing tool {name}"
                  for name in sorted(tools.keys() - listed))
    return errors


def check(root):
    errors = skill_references(root)
    laws = required(set(re.findall(r"^law (" + NAME + r")\s*:", (root / "LAWS.bend").read_text(), re.M)), "law declarations")
    docs = (sorted(root.glob("*.md")) + sorted((root / "docs").rglob("*.md"))
            + sorted((root / "skills/mailbend").rglob("*.md")))
    count = 0
    for path in docs:
        refs = law_references(path.read_text(), path, root)
        count += len(refs)
        errors.extend(f"{path.relative_to(root)}: unknown law {name}" for name in sorted(refs - laws))
    required(count, "documented law references")

    bend = required(sorted((root / "src").glob("*.bend")), "src/*.bend files")
    rust = required(sorted((root / "native").glob("*/src/**/*.rs")), "native Rust source files")
    variables = set()
    for path in [root / "main.bend", *bend, *rust]:
        variables.update(value[1:-1] for value in re.findall(STRING, source_text(path))
                         if ENV_NAME.fullmatch(value[1:-1]))
    required(variables, "MAILBEND_* source string literals")
    documented = required(set(re.findall(r"\b" + ENV_NAME.pattern + r"\b", (root / ".env.example").read_text())), ".env.example variable names")
    errors.extend(f".env.example: missing {name}" for name in sorted(variables - documented))

    main = source_text(root / "main.bend")
    verbs = required(set(re.findall(r'^\s*case\s+"([^"\s]+)"\s*<>', definition(main, "cli"), re.M)), "CLI verbs")
    usage = "".join(json.loads(value) for value in re.findall(STRING, definition(main, "usage")))
    usage_verbs = required(set(re.findall(r"\bmailbend\s+([^\s|]+)", usage)), "usage() verbs")
    launcher = re.search(r"^# Usage:\s*(.+)$", (root / "scripts/mailbend").read_text(), re.M)
    if not launcher:
        raise ValueError("scripts/mailbend: missing Usage comment")
    launcher_verbs = required(set(re.findall(r"(?:^scripts/mailbend\s+|\|\s*)([^\s|]+)", launcher[1])), "launcher Usage verbs")
    for label, listed in [("main.bend usage()", usage_verbs), ("scripts/mailbend Usage", launcher_verbs)]:
        errors.extend(f"{label}: missing CLI verb {verb}" for verb in sorted(verbs - listed))
        errors.extend(f"{label}: unknown CLI verb {verb}" for verb in sorted(listed - verbs))

    stdin_form = 'case "call" <> name <> "-" <> Nil{}:' in definition(main, "cli")
    if stdin_form:
        for label, text in [("main.bend usage()", usage), ("scripts/mailbend Usage", launcher[1])]:
            if not re.search(r"call <tool> \[[^]]* or -\]", text):
                errors.append(f"{label}: missing CLI stdin form")
        cli_doc = root / "docs/CLI.md"
        if not cli_doc.is_file() or "call mail_search -" not in cli_doc.read_text():
            errors.append("docs/CLI.md: missing CLI stdin example")

    architecture = (root / "docs/ARCHITECTURE.md").read_text()
    layers = re.search(r"^## Layers\s*\n(.*?)(?=^## |\Z)", architecture, re.M | re.S)
    if not layers:
        raise ValueError("docs/ARCHITECTURE.md: missing Layers section")
    listed = required(set(re.findall(r"\bsrc/[\w-]+\.bend\b", layers[1])), "Layers source paths")
    actual = {str(path.relative_to(root)) for path in bend}
    errors.extend(f"docs/ARCHITECTURE.md Layers: missing {name}" for name in sorted(actual - listed))
    errors.extend(f"docs/ARCHITECTURE.md Layers: unknown {name}" for name in sorted(listed - actual))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="checkout to inspect")
    args = parser.parse_args()
    try:
        errors = check(args.root.resolve())
    except (OSError, ValueError) as error:
        errors = [str(error)]
    if errors:
        print("Documentation drift:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print("Documentation names resolve: laws, environment, CLI usage, source layers, and skill tools")
    return 0


if __name__ == "__main__":
    sys.exit(main())
