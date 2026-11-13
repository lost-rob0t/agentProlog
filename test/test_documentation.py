"""Dependency-free fixture tests; never read or mutate the real documentation."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'check-docs.py'
SPEC = importlib.util.spec_from_file_location('check_docs', SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def provenance(tag='ai_fixture', topics='agentprolog:configuration', visibility=''):
    return (f'#+AI_GENERATED: t\n#+AI_TAG: {tag}\n'
            f'#+FILETAGS: :ai:{tag}:{topics}:\n'
            '#+SOURCE: file:prolog/agentprolog_config.pl at 0512eb8\n'
            f'{visibility}#+TITLE: Fixture\n')


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, relative, content=''):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        return path

    def check(self):
        return CHECKER.check_documentation(self.root)

    def assert_rejected(self, content, message):
        self.write('README.org', content)
        errors, count = self.check()
        self.assertEqual(count, 1)
        self.assertTrue(any(message in error for error in errors), errors)

    def test_discovers_root_docs_and_examples_only(self):
        self.write('README.org', provenance() + '[[file:docs/wiki/start.org][Start]]\n')
        self.write('docs/wiki/start.org', provenance('ai_start') + '[[file:../../examples/code.pl]]\n')
        self.write('examples/nested/guide.org', provenance('ai_example'))
        self.write('examples/code.pl', 'example.\n')
        self.write('unrelated.org', 'not documentation')
        self.write('docs/old.md', 'not Org')
        self.assertEqual(self.check(), ([], 3))

    def test_directories_and_source_files_are_valid_targets(self):
        self.write('README.org', provenance() + '[[file:prolog/]] [[file:prolog/tool.pl][Source]]\n')
        self.write('prolog/tool.pl', 'tool.\n')
        self.assertEqual(self.check(), ([], 1))

    def test_searches_and_fragments_check_only_file_existence(self):
        self.write('README.org', provenance() + '\n'.join([
            '[[file:source.pl::42]]', '[[file:source.pl::*Unverified heading][Search]]',
            '[[file:source.pl::/arbitrary search/]]', '[[file:source.pl#unverified-fragment]]',
            '[[file:::*Local search]]', '[[file:#local-fragment]]',
        ]))
        self.write('source.pl')
        self.assertEqual(self.check(), ([], 1))

    def test_missing_target_is_not_hidden_by_search_or_fragment(self):
        self.assert_rejected(provenance() + '[[file:missing.org::*Heading]]', 'missing local target')
        self.assert_rejected(provenance() + '[[file:missing.org#heading][Label]]', 'missing local target')

    def test_paths_with_spaces_escapes_and_percent_encoding(self):
        self.write('README.org', provenance() + '\n'.join([
            '[[file:a file.pl]]', r'[[file:a\ file.pl][Space]]',
            '[[file:a%20file.pl]]', '[[file:hash%23name.pl]]', r'[[file:a\[b\].pl]]',
        ]))
        for name in ('a file.pl', 'hash#name.pl', 'a[b].pl'):
            self.write(name)
        self.assertEqual(self.check(), ([], 1))

    def test_remote_links_and_directives_are_not_fetched(self):
        self.write('README.org', provenance() + '\n'.join([
            '[[https://invalid.invalid/never-fetch][Remote]]',
            '[[file:https://invalid.invalid/never-fetch]]',
            '[[file:/ssh:host:/never-stat]]', '[[file://host/never-stat]]',
            '#+INCLUDE: "https://invalid.invalid/never-fetch"',
            '#+SETUPFILE: https://invalid.invalid/never-fetch',
        ]))
        self.assertEqual(self.check(), ([], 1))

    def test_include_and_setupfile_paths_resolve_from_document(self):
        self.write('docs/wiki/start.org', provenance() + '\n'.join([
            '#+INCLUDE: "../../a file.pl::1" src prolog :lines "1-2"',
            '#+SETUPFILE: ../../settings.setup',
            '#+INCLUDE: "file:../../a%20file.pl#fragment"',
        ]))
        self.write('a file.pl')
        self.write('settings.setup')
        self.assertEqual(self.check(), ([], 1))

    def test_broken_include_and_setupfile_rejected(self):
        for directive in ('INCLUDE', 'SETUPFILE'):
            with self.subTest(directive=directive):
                self.assert_rejected(provenance() + f'#+{directive}: "missing.org"', 'missing local target')

    def test_malformed_or_empty_directive_rejected(self):
        for argument in ('', '"', '"unterminated path', '""'):
            with self.subTest(argument=argument):
                self.assert_rejected(provenance() + f'#+INCLUDE: {argument}',
                                     'empty local file target' if argument == '""' else 'malformed INCLUDE')

    def test_literal_examples_and_comments_are_ignored(self):
        body = '# [[file:missing-comment.org]]\n'
        for block in ('src', 'example', 'verbatim', 'export', 'comment'):
            body += (f'#+BEGIN_{block} text\n[[file:missing.org]]\n'
                     '#+INCLUDE: "missing.org"\n#+AI_TAG: ai_fake\n'
                     f'#+END_{block}\n')
        self.write('README.org', provenance() + body)
        self.assertEqual(self.check(), ([], 1))

    def test_real_link_after_literal_block_is_checked_with_line_number(self):
        self.assert_rejected(provenance() + '#+begin_src org\n[[file:ignored]]\n#+end_src\n'
                             '[[file:missing]]', 'README.org:9: missing local target')

    def test_unclosed_literal_block_cannot_hide_broken_documentation(self):
        self.assert_rejected(provenance() + '#+begin_src sh\necho example\n[[file:missing]]',
                             'unterminated literal block')

    def test_file_property_drawer_is_accepted(self):
        self.write('README.org', ':PROPERTIES:\n:AI_GENERATED: t\n:AI_TAG: ai_drawer\n'
                   ':SOURCE: OpenCode ses_abc123\n:END:\n'
                   '#+FILETAGS: :ai_drawer:agentprolog:configuration:\n* Introduction\n')
        self.assertEqual(self.check(), ([], 1))

    def test_audited_writer_metadata_and_navigation_layout(self):
        for relative, tag in (('README.org', 'ai_0000000000000001'),
                              ('docs/README.org', 'ai_0000000000000002'),
                              ('docs/wiki/Home.org', 'ai_0000000000000003'),
                              ('docs/wiki/_Sidebar.org', 'ai_0000000000000004')):
            self.write(relative, ':PROPERTIES:\n:ID: fixture-id\n'
                       ':CREATED: [2026-11-12 Thu]\n:LAST_MODIFIED: [2026-11-12 Thu]\n'
                       ':ROAM_SCHEMA: org-roam-meta/v1\n:ROAM_KIND: documentation\n'
                       ':ROAM_VISIBILITY: private\n:CENSOR_PROFILE: strict\n'
                       ':SOURCE: repository/worktree provenance; OpenCode ses_abc123\n'
                       f':AI_GENERATED: t\n:AI_TAG: {tag}\n:END:\n'
                       f'#+TITLE: Fixture\n#+FILETAGS: :ai:{tag}:agentprolog:navigation:\n')
        self.assertEqual(self.check(), ([], 4))

    def test_links_in_quote_blocks_are_real_prose(self):
        self.assert_rejected(provenance() + '#+begin_quote\n[[file:missing.org]]\n#+end_quote',
                             'missing local target')

    def test_heading_metadata_cannot_impersonate_file_provenance(self):
        self.assert_rejected('* Heading\n' + provenance(), 'file-level AI_GENERATED')

    def test_missing_false_or_duplicate_generated_rejected(self):
        for content in (provenance().replace('#+AI_GENERATED: t\n', ''),
                        provenance().replace('AI_GENERATED: t', 'AI_GENERATED: nil'),
                        provenance() + '#+AI_GENERATED: t\n'):
            with self.subTest(content=content):
                self.assert_rejected(content, 'file-level AI_GENERATED')

    def test_missing_invalid_or_multiple_ai_tag_rejected(self):
        for content in (provenance().replace('#+AI_TAG: ai_fixture\n', ''),
                        provenance().replace('#+AI_TAG: ai_fixture', '#+AI_TAG: other'),
                        provenance().replace('#+AI_TAG: ai_fixture', '#+AI_TAG: ai_'),
                        provenance() + '#+AI_TAG: ai_second\n'):
            with self.subTest(content=content):
                self.assert_rejected(content, 'file-level AI_TAG')

    def test_filetags_must_match_exactly_one_ai_tag(self):
        for tags in (':ai:agentprolog:configuration:', ':ai:ai_wrong:agentprolog:configuration:',
                     ':ai_fixture:ai_fixture:agentprolog:configuration:',
                     ':ai_fixture:ai_wrong:agentprolog:configuration:'):
            with self.subTest(tags=tags):
                content = provenance().replace(':ai:ai_fixture:agentprolog:configuration:', tags)
                self.assert_rejected(content, 'FILETAGS must contain')

    def test_at_least_two_distinct_topic_tags_required(self):
        for topics in ('', 'private:public:ai:ai_tag', 'prolog:prolog', 'Prolog:prolog'):
            with self.subTest(topics=topics):
                self.assert_rejected(provenance(topics=topics), 'two distinct topic tags')

    def test_duplicate_ai_tags_across_documents_rejected(self):
        self.write('README.org', provenance())
        self.write('docs/start.org', provenance())
        errors, count = self.check()
        self.assertEqual(count, 2)
        self.assertTrue(any('duplicate AI_TAG' in error for error in errors), errors)

    def test_source_requires_locator_not_placeholder(self):
        for source in ('', 'TODO', 'TBD', 'unknown', 'N/A', 'conversation', 'operator request'):
            with self.subTest(source=source):
                content = provenance().replace('file:prolog/agentprolog_config.pl at 0512eb8', source)
                self.assert_rejected(content, 'concrete file-level SOURCE')

    def test_source_locator_formats(self):
        for source in ('https://git.starintel.actor/owner/repo/issues/1', 'owner/repo#1',
                       'OpenCode ses_abc123', 'commit 0512eb8', 'prolog/config.pl', 'README.org'):
            with self.subTest(source=source):
                content = provenance().replace('file:prolog/agentprolog_config.pl at 0512eb8', source)
                self.write('README.org', content)
                self.assertEqual(self.check(), ([], 1))

    def test_visibility_is_optional_and_does_not_grant_publication(self):
        for visibility in ('', '#+ROAM_VISIBILITY: private\n', '#+ROAM_VISIBILITY: public\n'):
            with self.subTest(visibility=visibility):
                self.write('README.org', provenance(visibility=visibility))
                self.assertEqual(self.check(), ([], 1))

    def test_invalid_utf8_reported(self):
        self.write('README.org').write_bytes(b'\xff')
        errors, _ = self.check()
        self.assertIn('cannot read UTF-8 documentation', errors[0])

    def test_empty_file_link_rejected(self):
        self.assert_rejected(provenance() + '[[file:]]', 'empty local file target')

    def test_empty_or_nonexistent_root_is_not_a_passing_gate(self):
        errors, count = self.check()
        self.assertEqual(count, 0)
        self.assertIn('no Org documentation found', errors[0])
        errors, count = CHECKER.check_documentation(self.root / 'missing')
        self.assertEqual(count, 0)
        self.assertIn('not a directory', errors[0])

    def test_cli_fixture_root_exit_status_and_diagnostics(self):
        self.write('README.org', provenance())
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 file(s) checked', result.stdout)
        self.assertIn('not a publication authorization gate', result.stdout)
        self.write('README.org', provenance() + '[[file:missing.org]]')
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn('README.org:6: missing local target', result.stderr)


if __name__ == '__main__':
    unittest.main()
