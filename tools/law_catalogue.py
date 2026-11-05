"""Source readers for the generated law catalogue and safety-claim checks."""

import ast
from dataclasses import dataclass
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = r"[A-Za-z_][A-Za-z_0-9.]*"


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def local_path(root, relative):
    require(isinstance(relative, str) and relative and "\\" not in relative,
            f"invalid repository path: {relative!r}")
    path = (root / relative).resolve()
    require(not Path(relative).is_absolute() and path.is_relative_to(root.resolve()),
            f"path outside repository: {relative}")
    require(path.is_file(), f"missing file: {relative}")
    return path


def load_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"{path}: duplicate key {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


@dataclass(frozen=True)
class Law:
    name: str
    section: str
    summary: str
    line: int


def laws(root):
    path = local_path(root, "LAWS.bend")
    lines = path.read_text(encoding="utf-8").splitlines()
    declarations = {line: name for name, line in bend_headers(path, "law").items()}
    supplements = load_json(local_path(root, "docs/law-summaries.json"))
    require(isinstance(supplements, dict), "law summaries must be an object")
    section = "Laws"
    summary = ""
    used = set()
    result = {}
    for index, line in enumerate(lines):
        if re.fullmatch(r"# [-=]{3,}", line) and index and lines[index - 1].startswith("# "):
            section = lines[index - 1][2:]
            summary = ""
        if line.startswith("# LAW:"):
            comments = [line[len("# LAW:"):].strip()]
            following = index + 1
            while following < len(lines) and lines[following].startswith("# "):
                comments.append(lines[following][2:].strip())
                following += 1
            summary = " ".join(comments)
        if index + 1 in declarations:
            name = declarations[index + 1]
            require(name not in result, f"duplicate law {name}")
            description = summary
            # Supplements cover missing prose without editing the law contract.
            if name in supplements:
                require(not summary, f"law {name} has both source and supplemental summaries")
                description = supplements[name]
                used.add(name)
            require(isinstance(description, str) and description.strip(),
                    f"law {name} needs a source or supplemental summary")
            result[name] = Law(name, section, description, index + 1)
            summary = ""
    require(result, "LAWS.bend contains no laws")
    require(used == set(supplements), f"unused law summaries: {sorted(set(supplements) - used)}")
    return result


def bend_headers(path, kind):
    """Read supported declaration names and their first source line together.

    This is deliberately not a Bend parser. Recognize whitespace and the
    documented @unsafe prefix, and fail closed on unknown attributes/headers
    rather than silently omit a possible observer or catalogue entry.
    """
    require(kind in ("law", "def"), f"unsupported Bend declaration kind: {kind}")
    source = path.read_text(encoding="utf-8")
    starts = re.compile(r"^[ \t]*(?P<token>@|def\b|law\b)", re.M)
    header = re.compile(rf"\s+({IDENTIFIER})\s*(?P<delimiter>[(:])")
    names = {}
    offset = 0
    line = 1
    while start := starts.search(source, offset):
        number = line + source.count("\n", offset, start.start())
        token = start["token"]
        end = start.end()
        if token == "@":
            attribute = re.match(r"unsafe\s+def\b", source[end:])
            require(attribute is not None,
                    f"unsupported Bend attribute/header at {path}:{number}")
            token = "def"
            end += attribute.end()
        declaration = header.match(source, end)
        require(declaration is not None
                and (token != "law" or declaration["delimiter"] == ":"),
                f"unsupported Bend {token} declaration at {path}:{number}")
        line = number + source.count("\n", start.start(), declaration.end())
        offset = declaration.end()
        if token == kind:
            name = declaration[1]
            require(name not in names, f"duplicate Bend {kind} {name} at {path}:{number}")
            names[name] = number
    return names


def bend_names(path, kind):
    return set(bend_headers(path, kind))


def reference(root, value, kind, cache=None):
    require(isinstance(value, str), f"{kind} reference must be a string")
    relative, separator, name = value.partition("#")
    path = local_path(root, relative)
    require(separator and name, f"{kind} reference needs path#name: {value}")
    key = (path, kind)
    if cache is not None and key in cache:
        names = cache[key]
    elif path.suffix == ".bend":
        names = bend_names(path, "law" if kind == "law" else "def")
    elif path.suffix == ".py" and kind == "test":
        tree = ast.parse(path.read_text(encoding="utf-8"))
        names = {n.name for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    else:
        raise ValueError(f"unsupported {kind} reference: {value}")
    if cache is not None:
        cache[key] = names
    require(name in names, f"missing {kind} name: {value}")
    return relative, name


def local_imports(path):
    """Read the supported Bend module imports, rejecting unknown syntax.

    Whitespace and trailing comments are accepted by Bend, including before
    an import. Keep this intentionally smaller than a Bend parser: only Base
    and repository-local .bend modules are supported by this source reader.
    New import forms must not silently shrink the observer search closure.
    """
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        declaration = line.partition("#")[0].strip()
        if not re.match(r"import\b", declaration):
            continue
        match = re.fullmatch(
            r"import[ \t]+(Base|\.[\w./-]+\.bend)(?:[ \t]+as[ \t]+\w+)?", declaration)
        require(match is not None, f"unsupported Bend import at {path}:{number}; "
                "only Base and repository-local .bend module imports are supported "
                "by this source reader (not foreign effect-body imports)")
        if match[1] != "Base":
            yield match[1]


def proof_files(root):
    pending = [local_path(root, "PROOF.bend")]
    visited = set()
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        for relative in local_imports(path):
            child = (path.parent / relative).resolve()
            local_path(root, child.relative_to(root.resolve()).as_posix())
            pending.append(child)
    return visited


def observer_names(root, value):
    """Bind Bend's name-only diagnostic to one reachable source declaration.

    Bend may omit the Laws. prefix. It does not report the source path, so
    rejecting collisions is necessary before a path#name can identify a failure.
    """
    relative, name = reference(root, value, "proof")
    reachable = proof_files(root)
    require(local_path(root, relative) in reachable, "mutation proof is not reachable")
    bare = name.removeprefix("Laws.")
    candidates = sorted(
        f"{path.relative_to(root.resolve()).as_posix()}#{definition}"
        for path in reachable for definition in bend_names(path, "def")
        if definition.removeprefix("Laws.") == bare)
    require(candidates == [value],
            f"ambiguous mutation observer {value}: {candidates}")
    return {name, bare}


def catalogue(root):
    records = laws(root)
    output = ["# Law catalogue", "", "Generated by `python3 tools/gen-laws.py`. Do not edit this file.", "",
              f"`LAWS.bend` declares **{len(records)} laws**. Every declaration appears below.",
              "Summaries come from `# LAW:` comments. The explicit supplements in",
              "[law-summaries.json](law-summaries.json) cover declarations without their own summary.",
              "Imported model and helper laws remain in their source files. The",
              "[claim coverage](PROOF-COVERAGE.md) links any that support a public claim.", "",
              "A law is a statement about the named pure functions, not a proof of native IO,",
              "the mail provider, or the agent. See [proof limits](../README.md#what-the-proofs-cover).", ""]
    section = None
    for law in records.values():
        if law.section != section:
            section = law.section
            output.extend(["", f"## {section}", ""])
        output.extend([f"- [`{law.name}`](../LAWS.bend#L{law.line}). {law.summary}"])
    return "\n".join(output) + "\n"


def generated(path, content, check):
    if check:
        require(path.is_file() and path.read_text(encoding="utf-8") == content,
                f"stale generated file: {path.name}")
    else:
        path.write_text(content, encoding="utf-8")
