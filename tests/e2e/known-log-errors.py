#!/usr/bin/env python3
"""Decide whether the errors in nextcloud.log are the one known upstream error.

The admin overview warns «Errors in the log» for every entry of level error or
fatal. One entry is known and comes from outside the images: richdocuments of
the Nextcloud 31 line calls fclose() on a stream the HTTP client has already
closed, in RemoteService.php line 71, on every conversion of an office file
to a preview (nextcloud/richdocuments issue #5743, fixed in commit 02f87c2a9c
and backported to stable32 to stable34, with no backport to stable31).

The warning counts as known only when every error and fatal entry is exactly
that one, the Nextcloud major version is 31, and the installed RemoteService.php
still carries the fclose() in line 71. Any other entry, the same entry on
another major version, or the entry after richdocuments has the fix, is not.

Usage:
  known-log-errors.py --major N --unfixed yes|no < nextcloud.log
      prints every error and fatal entry with its verdict; exits 0 when there
      is at least one and all are known, 1 when one is not, 2 when there is none
  known-log-errors.py --self-test
"""
import json
import re
import sys

KNOWN = re.compile(
    r"fclose\(\): supplied resource is not a valid stream resource"
    r" in file '[^']*/richdocuments/lib/Service/RemoteService\.php' line 71$")
KNOWN_MAJOR = 31


def errors(lines):
    """Every entry of level error (3) or fatal (4), with its message."""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            yield 4, f'unreadable log line: {line[:200]}'
            continue
        if int(entry.get('level', 0)) >= 3:
            yield int(entry['level']), str(entry.get('message', ''))


def verdict(lines, major, unfixed):
    """(exit code, report lines) for the entries of a log."""
    found = list(errors(lines))
    if not found:
        return 2, ['no error or fatal entry in nextcloud.log']
    report, unknown = [], 0
    for level, message in found:
        known = bool(KNOWN.search(message)) and major == KNOWN_MAJOR and unfixed
        unknown += not known
        report.append(f"{'known' if known else 'UNKNOWN'} level {level}: {message}")
    return (0 if not unknown else 1), report


def entry(message, level=3):
    return json.dumps({'level': level, 'app': 'index', 'message': message})


def self_test():
    known = entry("fclose(): supplied resource is not a valid stream resource in file "
                  "'/app/custom_apps/richdocuments/lib/Service/RemoteService.php' line 71")
    foreign = entry('Something else failed', level=3)
    other_line = entry("fclose(): supplied resource is not a valid stream resource in file "
                       "'/app/custom_apps/richdocuments/lib/Service/RemoteService.php' line 80")
    info = entry('a note', level=1)
    cases = [
        ('only the known entry on 31 without the fix', [known, known, info], 31, True, 0),
        ('the known entry and a foreign error', [known, foreign], 31, True, 1),
        ('a foreign error alone', [foreign], 31, True, 1),
        ('the known entry on 32', [known], 32, True, 1),
        ('the known entry on 31 with the fix', [known], 31, False, 1),
        ('the same fclose() in another line', [other_line], 31, True, 1),
        ('an unreadable line beside the known entry', [known, '{broken'], 31, True, 1),
        ('no error at all', [info], 31, True, 2),
    ]
    failed = 0
    for name, lines, major, unfixed, expected in cases:
        got, _ = verdict(lines, major, unfixed)
        ok = got == expected
        failed += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: exit {got}" + ('' if ok else f', expected {expected}'))
    print(f'==> Known log errors filter: {len(cases) - failed} passed, {failed} failed')
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ['--self-test']:
        return self_test()
    args = dict(zip(argv[1::2], argv[2::2]))
    major = int(args['--major'])
    unfixed = args['--unfixed'] == 'yes'
    code, report = verdict(sys.stdin, major, unfixed)
    for line in report:
        print(f'  {line}')
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv))
