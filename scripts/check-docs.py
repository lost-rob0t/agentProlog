#!/usr/bin/env python3
"""Check local Org documentation integrity, without Emacs or network access.

Scans README.org, docs/**/*.org and examples/**/*.org. File-level provenance
may use #+KEYWORD lines or a pre-heading :PROPERTIES: drawer. Links in literal
src/example/verbatim/export/comment blocks and comment lines are ignored. Only ordinary
single-line bracket links and include/setupfile directives are parsed; this is
not a complete Org parser. Search/fragment suffixes are removed, not validated.

Metadata checks are structural: SOURCE must contain a recognizable locator and
topic tags must be distinct and non-generic. Their truth/specificity cannot be
established here. Missing visibility means private; visibility and private
subtrees are deliberately not interpreted as export permission. Passing this
check proves neither secret-freedom nor authorization to publish.
"""

import argparse
from pathlib import Path
import re
import sys
from urllib.parse import unquote


LINK = re.compile(r'\[\[file:((?:\\.|[^\]\\\n])*)\](?:\[(?:\\.|[^\]\\\n])*\])?\]', re.I)
KEYWORD = re.compile(r'^\s*#\+([\w]+):\s*(.*?)\s*$', re.I)
PROPERTY = re.compile(r'^\s*:([\w]+):\s*(.*?)\s*$')
LITERAL_BEGIN = re.compile(r'^\s*#\+begin_(src|example|verbatim|export|comment)\b', re.I)
AI_TAG = re.compile(r'ai_[A-Za-z0-9][A-Za-z0-9_-]*\Z')
REMOTE = re.compile(r'^(?:[A-Za-z][A-Za-z0-9+.-]*:|//|/[^/:]+:[^/]*:)', re.I)
SOURCE_LOCATOR = re.compile(
    r'https?://[^\s\]<>]+|file:[^\s\]<>]+|\bses_[A-Za-z0-9]+\b|'
    r'\b[0-9a-fA-F]{7,40}\b|\b[\w.-]+/[\w.-]+#\d+\b|'
    r'(?:[\w.-]+/)+[\w.-]+|\b[\w-]+\.(?:org|md|pl|py|js|json)\b'
)
GENERIC_TAGS = {'ai', 'ai_tag', 'ai_generated', 'private', 'public'}


def documentation_files(root):
    paths = [root / 'README.org'] if (root / 'README.org').is_file() else []
    for directory in ('docs', 'examples'):
        paths.extend(path for path in (root / directory).rglob('*.org') if path.is_file())
    return sorted(paths)


def active_lines(text):
    """Yield line numbers and nonliteral text without evaluating any Org code."""
    block = None
    opening = None
    for number, line in enumerate(text.splitlines(), 1):
        if block:
            if re.match(r'^\s*#\+end_' + block + r'\s*$', line, re.I):
                block = None
            continue
        begin = LITERAL_BEGIN.match(line)
        if begin:
            block = begin.group(1)
            opening = number
        elif not re.match(r'^\s*#(?:\s|$)', line):
            yield number, line
    if block:
        raise ValueError(f'unterminated literal block {block} opened at line {opening}')


def unescape(value):
    return re.sub(r'\\([\\\[\]" ])', r'\1', value)


def local_target(value):
    """Return a local path, None for remote targets, or '' for this document."""
    if value.lower().startswith('file:'):
        value = value[5:]
    # Split before decoding: %23 is a filename character, not a fragment.
    value = value.split('::', 1)[0].split('#', 1)[0]
    if REMOTE.match(value):
        return None
    return unquote(unescape(value))


def check_file(path, root):
    errors = []
    metadata = {}
    name = path.relative_to(root).as_posix()

    def error(line, message):
        errors.append(f'{name}:{line}: {message}')

    try:
        text = path.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as exc:
        error(1, f'cannot read UTF-8 documentation: {exc}')
        return errors, None
    try:
        lines = list(active_lines(text))
    except ValueError as exc:
        error(1, str(exc))
        return errors, None

    def check_target(value, line):
        if not value:
            error(line, 'empty local file target')
            return
        target = local_target(value)
        if target is None or target == '':
            return
        try:
            exists = (path.parent / target).exists()
        except (OSError, ValueError):
            exists = False
        if not exists:
            error(line, f'missing local target: {value}')

    in_header = True
    in_properties = False
    for number, line in lines:
        if re.match(r'^\*+\s', line):
            in_header = False
        keyword = KEYWORD.match(line)
        if in_header:
            if line.strip().upper() == ':PROPERTIES:':
                in_properties = True
            elif line.strip().upper() == ':END:':
                in_properties = False
            item = keyword or (PROPERTY.match(line) if in_properties else None)
            if item:
                key, value = item.groups()
                metadata.setdefault(key.upper(), []).append((number, value))

        for link in LINK.finditer(line):
            check_target(link.group(1), number)
        if keyword and keyword.group(1).upper() in {'INCLUDE', 'SETUPFILE'}:
            argument = re.match(r'^(?:"((?:\\.|[^"\\])*)"|(\S+))(?:\s|$)', keyword.group(2))
            if not argument or (argument.group(2) or '').startswith('"'):
                error(number, f'malformed {keyword.group(1).upper()} path')
            else:
                check_target(argument.group(1) if argument.group(1) is not None else argument.group(2), number)

    generated = metadata.get('AI_GENERATED', [])
    if len(generated) != 1 or generated[0][1].lower() != 't':
        error(1, 'require exactly one file-level AI_GENERATED: t')
    ai_tags = metadata.get('AI_TAG', [])
    tag = ai_tags[0][1] if len(ai_tags) == 1 else None
    if tag is None or not AI_TAG.fullmatch(tag):
        error(1, 'require exactly one file-level AI_TAG of the form ai_<id>')
        tag = None
    filetags = [token for _, value in metadata.get('FILETAGS', [])
                for token in re.split(r'[:\s]+', value) if token]
    if tag is not None and (filetags.count(tag) != 1 or
                            any(t.startswith('ai_') and t != tag for t in filetags)):
        error(1, 'FILETAGS must contain the AI_TAG exactly once and no other ai_<id>')
    topics = {t.lower() for t in filetags
              if t.lower() not in GENERIC_TAGS and not t.lower().startswith('ai_')}
    if len(topics) < 2:
        error(1, 'FILETAGS require at least two distinct topic tags besides AI/visibility tags')
    if not any(value.lower() != 'n/a' and SOURCE_LOCATOR.search(value)
               for _, value in metadata.get('SOURCE', [])):
        error(1, 'require a concrete file-level SOURCE locator (URL, path, session, issue or commit)')
    return errors, tag


def check_documentation(root):
    root = Path(root).resolve()
    if not root.is_dir():
        return [f'{root}: documentation root is not a directory'], 0
    paths = documentation_files(root)
    if not paths:
        return ['no Org documentation found (README.org, docs/**/*.org, examples/**/*.org)'], 0
    errors = []
    owners = {}
    for path in paths:
        file_errors, tag = check_file(path, root)
        errors.extend(file_errors)
        if tag in owners:
            errors.append(f'{path.relative_to(root)}:1: duplicate AI_TAG {tag} also used by {owners[tag]}')
        elif tag is not None:
            owners[tag] = path.relative_to(root)
    return errors, len(paths)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1],
                        help='repository or fixture root (default: this script\'s repository)')
    args = parser.parse_args(argv)
    errors, count = check_documentation(args.root)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'Org documentation integrity: {count} file(s) checked; not a publication authorization gate.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
