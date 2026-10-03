#!/usr/bin/env python3
"""Branch contract: which branches the workflow builds and which stay frozen.

The scheduled run of the default branch starts `docker.yml` on every branch a
rule of `branch-tags` matches (shared workflow of mwaeckerlin/scratch, matched
in full with Python's re.fullmatch). Nextcloud 30 to 32 refuse PHP 8.5, which
is the only PHP mwaeckerlin/php-fpm carries, so the branches new-30 to new-32
must stay frozen like 13 to 29; every other version branch must be built.
"""
import json, pathlib, re, sys

workflow = pathlib.Path(__file__).resolve().parent.parent / '.github' / 'workflows' / 'docker.yml'
line = next(l for l in workflow.read_text().splitlines() if l.strip().startswith('branch-tags:'))
rules = json.loads(line.split(':', 1)[1].strip().strip("'"))

def suffix(branch):
    for rule in rules:
        found = re.fullmatch(rule['branch'], branch)
        if found:
            return found.expand(rule['suffix'])
    return None

built = {'new': '', **{f'new-{v}': f'-{v}' for v in range(33, 36)}, **{str(v): f'-{v}' for v in range(30, 36)}}
frozen = [f'new-{v}' for v in range(30, 33)] + [str(v) for v in range(13, 30)]

failed = 0
for branch, expected in built.items():
    got = suffix(branch)
    ok = got == expected
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  built {branch} -> suffix {got!r}" + ('' if ok else f', expected {expected!r}'))
for branch in frozen:
    got = suffix(branch)
    ok = got is None
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  frozen {branch}" + ('' if ok else f' matches a rule (suffix {got!r})'))
print(f'==> Branch contract: {len(built) + len(frozen) - failed} passed, {failed} failed')
sys.exit(1 if failed else 0)
