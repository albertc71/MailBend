#!/usr/bin/env python3
"""Exercise documentation drift failures and parse the published client snippets."""

import ast
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check-docs.py"


class DriftChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mailbend-docs-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = [*ROOT.glob("*.md"), ROOT / "LAWS.bend", ROOT / "main.bend",
                 ROOT / ".env.example", ROOT / "scripts/mailbend", ROOT / "tools/gen-schema.py",
                 *ROOT.glob("src/*.bend"), *ROOT.glob("native/*/src/**/*.rs"),
                 *ROOT.glob("docs/**/*.md"), *ROOT.glob("skills/mailbend/**/*.md")]
        for source in files:
            target = self.root / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)

    def replace(self, path, old, new):
        target = self.root / path
        text = target.read_text()
        self.assertIn(old, text)
        target.write_text(text.replace(old, new))

    def append(self, path, text):
        with (self.root / path).open("a") as output:
            output.write(text)

    def check(self, expected=None):
        result = subprocess.run([sys.executable, str(CHECKER), "--root", str(self.root)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1 if expected else 0, result.stdout + result.stderr)
        if expected:
            self.assertIn(expected, result.stderr)

    def test_current_documentation(self):
        self.check()

    def test_skill_unknown_tool(self):
        for name in ("mail_missing", "mail_getWrong"):
            with self.subTest(name=name):
                self.append("skills/mailbend/SKILL.md", f"\nCall `{name}`.\n")
                self.check(f"unknown tool {name}")

    def test_skill_unknown_scoped_argument(self):
        self.append("skills/mailbend/SKILL.md", "\nUse `mail_get.nonexistent`.\n")
        self.check("unknown argument mail_get.nonexistent")

    def test_skill_argument_must_belong_to_named_tool(self):
        self.append("skills/mailbend/SKILL.md", "\nUse mail_probe.max_response_bytes.\n")
        self.check("unknown argument mail_probe.max_response_bytes")

    def test_skill_signature_arguments_are_scoped(self):
        self.append("skills/mailbend/references/tools.md", "\nmail_probe(max_response_bytes)\n")
        self.check("unknown argument mail_probe.max_response_bytes")

    def test_skill_valid_scoped_arguments(self):
        self.append("skills/mailbend/SKILL.md", "\nUse `mail_get.projection` or mail_get.max_response_bytes.\n")
        self.append("skills/mailbend/references/tools.md", "\n`mail_get(folder, uid, projection, max_response_bytes)`\n")
        self.check()

    def test_skill_signature_rejects_unparsed_argument(self):
        self.append("skills/mailbend/references/tools.md", "\n`mail_get(folder, bogus-field)`\n")
        self.check("invalid argument notation mail_get(folder, bogus-field)")

    def test_skill_tool_index_must_cover_current_schema(self):
        path = self.root / "skills/mailbend/references/tools.md"
        path.write_text(re.sub(r"\bmail_probe\([^()\n]*\)", "mail_probe", path.read_text()))
        self.check("references/tools.md: missing tool mail_probe")

    def test_missing_skill_reference_fails(self):
        (self.root / "skills/mailbend/references/cli.md").unlink()
        self.check("references/cli.md: missing skill file")

    def test_skill_local_file_and_heading_links(self):
        self.append("skills/mailbend/SKILL.md", "\n[Missing](references/not-there.md)\n")
        self.check("missing linked file references/not-there.md")
        self.append("skills/mailbend/SKILL.md", "\n[Missing](../../README.md#not-a-heading)\n")
        self.check("missing linked heading ../../README.md#not-a-heading")

    def test_skill_schema_import_does_not_regenerate(self):
        generated = self.root / "src/schema.bend"
        before = generated.read_bytes()
        self.check()
        self.assertEqual(generated.read_bytes(), before)

    def test_stale_law_in_existing_architecture_table(self):
        self.replace("docs/ARCHITECTURE.md", "read_only_tools_are_exactly_twelve",
                     "read_only_tools_are_exactly_seven")
        self.check("unknown law read_only_tools_are_exactly_seven")

    def test_legacy_law_reference_forms(self):
        for citation in ["law `absent_law`", "laws `read_is_read_only`, `absent_law`",
                         "`absent_law` law", "`Laws.absent_law`"]:
            with self.subTest(citation=citation):
                (self.root / "docs/fixture.md").write_text(citation)
                self.check("unknown law absent_law")

    def test_local_law_links_resolve_relative_paths_and_anchors(self):
        self.append("README.md", "\n[`read_is_read_only`](LAWS.bend#tool-classes)\n")
        self.append("docs/REFRESH.md", "\n[LAWS.bend](../LAWS.bend)\n"
                    "[foreign_law](https://example.test/LAWS.bend)\n")
        self.check()

    def test_missing_law_source_or_reference_section_fails(self):
        (self.root / "LAWS.bend").write_text("# no laws\n")
        self.check("no law declarations")

    def test_undocumented_bend_variable_through_helper(self):
        self.append("src/tools.bend", '\ndef extra() -> String:\n  env_or(\n    "MAILBEND_NEW_SETTING", "")\n')
        self.check(".env.example: missing MAILBEND_NEW_SETTING")

    def test_undocumented_native_variable_through_constant(self):
        self.append("native/mailbend-tls/src/settings.rs", '\nconst SETTING: &str = "MAILBEND_NEW_SETTING";\n')
        self.check(".env.example: missing MAILBEND_NEW_SETTING")

    def test_numeric_environment_suffix_is_checked(self):
        self.append("native/mailbend-tls/src/settings.rs", '\nconst SETTING: &str = "MAILBEND_2_SETTING";\n')
        self.check(".env.example: missing MAILBEND_2_SETTING")

    def test_missing_existing_env_variable(self):
        self.replace(".env.example", "MAILBEND_TYPESAFE_IMAGES=", "REMOVED_IMAGES=")
        self.check(".env.example: missing MAILBEND_TYPESAFE_IMAGES")

    def test_comments_strings_and_test_modules_are_not_config(self):
        self.append("src/tools.bend", '\n# IO.get_env("MAILBEND_COMMENT_ONLY")\n')
        self.append("native/mailbend-tls/src/settings.rs", '''
// const COMMENT: &str = "MAILBEND_COMMENT_ONLY";
#[cfg(test)]
mod fixture {
    const ONLY_IN_TESTS: &str = "MAILBEND_TEST_ONLY";
    const BRACES: &str = "{ } }";
    const QUOTE: char = '"';
    // } }
    fn nested() { let _ = "MAILBEND_NESTED_TEST"; }
}
const ERROR: &str = "MAILBEND_NOT_CONFIG is an example";
''')
        self.check()

    def test_production_after_test_module_is_checked(self):
        self.append("native/mailbend-tls/src/settings.rs", '''
#[cfg(test)] mod fixture { const X: &str = "MAILBEND_TEST_ONLY"; }
const AFTER: &str = "MAILBEND_AFTER_TEST";
''')
        self.check("missing MAILBEND_AFTER_TEST")

    def test_raw_strings_and_nested_comments_do_not_hide_production(self):
        self.append("native/mailbend-tls/src/settings.rs", '''
#[cfg(test)] mod fixture { const TEXT: &str = r#""} "MAILBEND_RAW_TEST_ONLY""#; }
/* outer /* inner */ const X: &str = "MAILBEND_COMMENT_ONLY"; */
const LIVE: &str = r#"MAILBEND_LIVE"#;
''')
        self.check("missing MAILBEND_LIVE")
        self.append(".env.example", "\nMAILBEND_LIVE=\n")
        self.check()

    def test_quote_character_does_not_hide_environment_name(self):
        self.append("native/mailbend-tls/src/settings.rs", '''
const QUOTE: char = '"';
const LIVE: &str = "MAILBEND_AFTER_QUOTE";
''')
        self.check("missing MAILBEND_AFTER_QUOTE")

    def test_similar_env_name_does_not_document_a_variable(self):
        self.append("src/tools.bend", '\ndef extra() -> String:\n  env_or("MAILBEND_NEW_SETTING", "")\n')
        self.append(".env.example", "\nXMAILBEND_NEW_SETTING=\nMAILBEND_NEW_SETTING_SUFFIX=\n")
        self.check("missing MAILBEND_NEW_SETTING")

    def test_usage_omits_version(self):
        self.replace("main.bend", " | mailbend version", "")
        self.check("usage(): missing CLI verb version")

    def test_launcher_omits_diagnose(self):
        self.replace("scripts/mailbend", " | diagnose [--imap] [--smtp]", "")
        self.check("Usage: missing CLI verb diagnose")

    def test_stdin_form_requires_both_usage_texts(self):
        self.replace("main.bend", "[json-arguments or -]", "[json-arguments]")
        self.check("usage(): missing CLI stdin form")
        self.replace("scripts/mailbend", "[json or -]", "[json]")
        self.check("Usage: missing CLI stdin form")

    def test_stdin_example_is_required(self):
        self.replace("docs/CLI.md", "call mail_search -", "call mail_search")
        self.check("CLI.md: missing CLI stdin example")

    def test_new_cli_verb_requires_both_usage_texts(self):
        self.replace("main.bend", '    case "version" <> Nil{}:', '    case "future-command_2" <> Nil{}:\n      IO.print("ok")\n    case "version" <> Nil{}:')
        self.check("usage(): missing CLI verb future-command_2")

    def test_unknown_usage_verb(self):
        self.replace("main.bend", " | mailbend version", " | mailbend version | mailbend absent")
        self.check("usage(): unknown CLI verb absent")

    def test_missing_required_sections(self):
        for path, old, new, diagnostic in [
            ("main.bend", "def usage()", "def removed_usage()", "usage() definition"),
            ("main.bend", "def cli(", "def removed_cli(", "cli() definition"),
            ("scripts/mailbend", "# Usage:", "# Removed:", "missing Usage comment"),
            ("docs/ARCHITECTURE.md", "## Layers", "## Removed", "missing Layers section"),
        ]:
            with self.subTest(path=path):
                self.replace(path, old, new)
                self.check(diagnostic)
                self.replace(path, new, old)

    def test_empty_layers_section_does_not_pass(self):
        path = self.root / "docs/ARCHITECTURE.md"
        path.write_text(re.sub(r"^## Layers\s*\n.*?(?=^## |\Z)", "## Layers\n\n",
                               path.read_text(), flags=re.M | re.S))
        self.check("no Layers source paths")

    def test_empty_environment_example_does_not_pass(self):
        (self.root / ".env.example").write_text("# no settings\n")
        self.check("no .env.example variable names")

    def test_new_hyphenated_source_requires_layer_entry(self):
        (self.root / "src/new-module.bend").write_text("# new module\n")
        self.check("Layers: missing src/new-module.bend")

    def test_underscore_source_can_be_documented(self):
        (self.root / "src/new_module.bend").write_text("# new module\n")
        self.replace("docs/ARCHITECTURE.md", "## Layers", "## Layers\n\nsrc/new_module.bend  new module")
        self.check()

    def test_stale_layer_entry(self):
        self.replace("docs/ARCHITECTURE.md", "src/search-cursor.bend", "src/old-cursor.bend")
        self.check("Layers: unknown src/old-cursor.bend")

    def test_missing_input_file(self):
        (self.root / ".env.example").unlink()
        self.check(".env.example")


class ClientSnippets(unittest.TestCase):
    def test_password_file_recipe_python(self):
        text = (ROOT / "docs/MCP_CLIENTS.md").read_text()
        recipe = re.search(r"python3 - <<'PY'\n(.*?)\nPY\n", text, re.S)
        self.assertIsNotNone(recipe)
        ast.parse(recipe[1])

    def test_password_file_recipe_hides_input_and_refuses_echo_fallback(self):
        text = (ROOT / "docs/MCP_CLIENTS.md").read_text()
        recipe = re.search(r"python3 - <<'PY'\n(.*?)\nPY\n", text, re.S)[1]
        with tempfile.TemporaryDirectory(prefix="mailbend-password-recipe-") as home:
            master, slave = pty.openpty()
            process = subprocess.Popen([sys.executable, "-c", recipe], stdin=slave,
                                       stdout=slave, stderr=slave, start_new_session=True,
                                       env={"HOME": home, "PATH": "/usr/bin:/bin"})
            os.close(slave)
            captured = b""
            entered = False
            fixture = b"fixture-only-password"
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            captured += os.read(master, 4096)
                        except OSError:
                            break
                    if not entered and b"Mail app password:" in captured:
                        os.write(master, fixture + b"\n")
                        entered = True
                self.assertEqual(process.wait(timeout=1), 0, captured)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)
            self.assertTrue(entered)
            self.assertNotIn(fixture, captured)
            password_file = Path(home) / ".config/mailbend/personal.password"
            self.assertEqual(password_file.stat().st_mode & 0o777, 0o600)
            self.assertEqual(password_file.read_bytes(), fixture + b"\n")
            non_tty_home = str(Path(home) / "non-tty")
            result = subprocess.run([sys.executable, "-c", recipe], input=b"must-not-echo\n",
                                    capture_output=True, start_new_session=True,
                                    env={"HOME": non_tty_home, "PATH": "/usr/bin:/bin"}, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"GetPassWarning", result.stderr)
            self.assertNotIn(b"must-not-echo", result.stdout + result.stderr)
            self.assertFalse((Path(non_tty_home) / ".config/mailbend/personal.password").exists())
            self.assertEqual(password_file.read_bytes(), fixture + b"\n")

    def test_local_document_links(self):
        path = ROOT / "docs/MCP_CLIENTS.md"
        for target in re.findall(r"\[[^]\n]+\]\(([^)\s]+)\)", path.read_text()):
            if "://" in target:
                continue
            relative, _, anchor = target.partition("#")
            destination = (path.parent / relative).resolve()
            self.assertTrue(destination.is_file(), target)
            if anchor:
                headings = re.findall(r"^#+ (.+)$", destination.read_text(), re.M)
                slugs = {re.sub(r"[^a-z0-9 -]", "", heading.lower()).replace(" ", "-")
                         for heading in headings}
                self.assertIn(anchor, slugs, target)

    def test_published_configurations(self):
        text = (ROOT / "docs/MCP_CLIENTS.md").read_text()
        blocks = re.findall(r"^```(json|toml|sh)\n(.*?)^```", text, re.M | re.S)
        servers = []
        formats = set()
        for language, body in blocks:
            if language == "json":
                config = json.loads(body)
                formats.update(config)
                servers.extend(config.get("mcpServers", config.get("servers", {})).values())
            elif language == "toml":
                config = tomllib.loads(body)
                formats.update(config)
                servers.extend(config["mcp_servers"].values())
            else:
                result = subprocess.run(["bash", "-n"], input=body, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                words = shlex.split(body.replace("\\\n", ""))
                if words[:3] == ["openclaw", "mcp", "set"]:
                    servers.append(json.loads(words[4]))
                if words[:3] == ["claude", "mcp", "add"]:
                    delimiter = words.index("--")
                    self.assertEqual(words[delimiter - 3:delimiter], ["--transport", "stdio", "mailbend"])
                    env = dict(words[i + 1].split("=", 1) for i, word in enumerate(words) if word == "--env")
                    servers.append(dict(command=words[delimiter + 1], args=words[delimiter + 2:], env=env))
        self.assertEqual(formats, {"mcpServers", "servers", "mcp_servers"})
        self.assertEqual(len(servers), 8)
        for server in servers:
            with self.subTest(command=server["command"]):
                if server["command"] == "wsl.exe":
                    args = server["args"]
                    self.assertEqual(args[:4], ["--distribution", "Ubuntu", "--exec", "env"])
                    env = dict(pair.split("=", 1) for pair in args[4:-2])
                    command, mode = args[-2:]
                else:
                    command = server["command"]
                    self.assertEqual(server["args"], ["mcp"])
                    mode = server["args"][0]
                    env = server["env"]
                self.assertTrue(command.startswith("/"))
                self.assertTrue(command.endswith("/scripts/mailbend"))
                self.assertEqual(mode, "mcp")
                self.assertEqual(env["MAILBEND_READ_ONLY"], "1")
                self.assertEqual(env["MAILBEND_TYPESAFE"], "0")
                self.assertTrue(env["MAILBEND_PASSWORD_FILE"].startswith("/"))
                self.assertTrue(env["MAILBEND_EMAIL"].endswith("@example.test"))
                self.assertNotIn("MAILBEND_APP_PASSWORD", env)
                self.assertNotIn("MAILBEND_TYPESAFE_API_KEY", env)


if __name__ == "__main__":
    unittest.main()
