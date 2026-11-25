#!/usr/bin/env python3
"""Tests for linux/extract.py and the merging in linux/generate.py.

extract.py decides which lines of an app file end up in a Linux suite. A wrong decision either
fails the build (visible) or silently drops code or tests (not visible), so its parsing is tested
here on the Swift constructs that used to confuse it: braces inside multi-line strings, raw
strings, block comments and interpolations.

Usage: python3 linux/test_extract.py   (also run by .github/workflows/tests_linux.yml)
"""

import os
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract  # noqa: E402
import generate  # noqa: E402


def lines(text):
    return text.strip('\n').split('\n')


class CodeLinesTests(unittest.TestCase):

    def code(self, text):
        return extract.code_lines(lines(text))

    def test_line_comment_and_string_contents_are_removed(self):
        self.assertEqual(self.code('let a = "{ x }" // }'), ['let a = "" '])

    def test_multiline_string_hides_braces_on_every_line(self):
        code = self.code('let json = """\n{"a": {"b": 1}\n"""\nfunc f() {}')
        self.assertEqual(code[1], '')
        self.assertEqual(code[3], 'func f() {}')
        self.assertEqual(sum(extract.brace_delta(line) for line in code), 0)

    def test_block_comments_nest_and_span_lines(self):
        code = self.code('/* a { /* b } */\n still } comment */ let x = 1')
        self.assertEqual(code[0], '')
        self.assertEqual(code[1].strip(), 'let x = 1')

    def test_raw_strings_end_only_at_the_matching_hashes(self):
        code = self.code('let r = #"a "quoted" { brace"# + "}"')
        self.assertEqual(code, ['let r = "" + ""'])

    def test_multiline_raw_string(self):
        code = self.code('let r = #"""\n"""  {\n"""#\nlet y = {}')
        self.assertEqual(code[1], '')
        self.assertEqual(code[3], 'let y = {}')

    def test_interpolation_is_code_with_its_own_strings(self):
        code = self.code('let s = "\\(d["}"] ?? "{") and \\(f(1, (2)))" ; let z = 1')
        self.assertEqual(code, ['let s = "(d[""] ?? "")(f(1, (2)))" ; let z = 1'])

    def test_escaped_quote_does_not_end_the_string(self):
        self.assertEqual(self.code('let q = "a\\"{" + x'), ['let q = "" + x'])

    def test_unterminated_single_line_string_does_not_leak_into_the_next_line(self):
        code = self.code('let broken = "abc\nfunc g() {}')
        self.assertEqual(code[1], 'func g() {}')

    def test_hash_directives_are_code(self):
        self.assertEqual(self.code('#if os(Linux)\n#endif'), ['#if os(Linux)', '#endif'])


class ExtractTests(unittest.TestCase):

    def test_without_keeps_the_method_after_one_returning_json(self):
        source = lines('''
struct A {
    func json() -> String {
        return """
        {"a": {"b": 1}
        """
    }
    func kept() {}
}
''')
        out, found = extract.without(source, ['json'])
        self.assertEqual(found, {'json'})
        self.assertIn('    func kept() {}', out)
        self.assertEqual(out[-1], '}')

    def test_decl_is_not_cut_by_a_brace_in_a_block_comment(self):
        source = lines('''
struct B {
    /* } */
    func x() {}
}
struct C {}
''')
        out, _ = extract.decl(source, ['B'])
        self.assertIn('    func x() {}', out)
        self.assertNotIn('struct C {}', out)

    def test_decl_ignores_a_declaration_inside_a_string(self):
        source = lines('''
let template = """
struct Fake {
}
"""
struct Real {}
''')
        out, found = extract.decl(source, ['Fake', 'Real'])
        self.assertEqual(found, {'Real'})
        self.assertNotIn('struct Fake {', out)

    def test_members_copies_overloads_and_skips_strings(self):
        source = lines('''
enum Texts {
    static let a = "{"
    static func f(_ x: Int) -> Int { x }
    static func f(_ x: String) -> String { "}" + x }
    static let b = 2
}
''')
        out, found = extract.members(source, 'Texts', ['a', 'f'])
        self.assertEqual(found, {'a', 'f'})
        self.assertEqual(sum(1 for line in out if 'static func f' in line), 2)
        self.assertNotIn('    static let b = 2', out)

    def test_members_cases_only_direct_children(self):
        source = lines('''
enum E: Int {
    case a = 1
    case b
    var nested: Int {
        switch self { case .a: return 1
        case .b: return 2 }
    }
}
''')
        out, _ = extract.members(source, 'E', ['cases'])
        self.assertEqual([line.strip() for line in out[1:-1]], ['case a = 1', 'case b'])

    def test_multi_line_signature_and_expression_ends(self):
        source = lines('''
let value = compute(
    1,
    2
)
let next = 3
''')
        code = extract.code_lines(source)
        self.assertEqual(extract.block_end(code, 0), 3)


class MergedGenerationTests(unittest.TestCase):
    """The merged package must build from all suites: nothing declared twice, nothing lost."""

    def test_every_suite_merges_without_duplicate_files_or_declarations(self):
        suites = sorted(name[:-4] for name in os.listdir(generate.SUITES_DIR)
                        if name.endswith('.txt') and not name.startswith('_'))
        package = generate.merged_package(suites, snippet=False)
        names = [os.path.basename(path) for path in package.files]
        self.assertEqual(len(names), len(set(names)))
        # Every test file of every suite is in the merged package.
        for suite in suites:
            for kind, path, _, _ in generate.parse_suite(suite, set(), []):
                if kind == 'test':
                    self.assertIn(os.path.join('Tests', 'xdripTests', generate.flat(path)), package.files, path)

    def test_isolated_generation_is_deterministic(self):
        first = generate.isolated_package('glucose-math', snippet=False).files
        second = generate.isolated_package('glucose-math', snippet=False).files
        self.assertEqual(first, second)


if __name__ == '__main__':
    unittest.main(verbosity=1)
