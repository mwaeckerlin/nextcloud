#!/usr/bin/env python3
"""Branch contract: which branches the workflow builds and which stay frozen.

The scheduled run of the default branch starts `docker.yml` on every branch a
rule of `branch-tags` matches (shared workflow of mwaeckerlin/scratch, matched
in full with Python's re.fullmatch). Nextcloud 30 to 32 refuse PHP 8.5, which
is the only PHP mwaeckerlin/php-fpm carries, so the branches new-30 to new-32
must stay frozen like 13 to 29; every other version branch must be built.
Branch new-NN publishes nginx-ncNN and nginx-ncNN-vX.Y.Z, branch new nginx
and nginx-vX.Y.Z, each also with the day of the build; no tag carries a
version without its leading «v».
The script `deploy` of package.json must push every image the compose file
builds.
"""
import json, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
# another workflow file as argument checks its rules, such as the one of an
# earlier commit
workflow = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.github' / 'workflows' / 'docker.yml'
line =next(l for l in workflow.read_text().splitlines() if l.strip().startswith('branch-tags:'))
rules = json.loads(line.split(':', 1)[1].strip().strip("'"))

def rule_of(branch):
    for rule in rules:
        found = re.fullmatch(rule['branch'], branch)
        if found:
            return found, rule
    return None, None

def suffix(branch):
    found, rule = rule_of(branch)
    return found.expand(rule['suffix']) if found else None

def tags(branch, tag, version='1.2.3', date='20261026'):
    """The tags the shared workflow publishes for image tag `tag` on `branch`."""
    found, rule = rule_of(branch)
    # without a matching rule the shared workflow appends nothing
    named_version = (rule or {}).get('version', '') + version
    end = found.expand(rule['suffix']) if found else ''
    base = tag + end if tag != 'latest' else (end.lstrip('-') or 'latest')
    named = named_version if base == 'latest' else f'{base}-{named_version}'
    return [base, date if base == 'latest' else f'{base}-{date}', named, f'{named}-{date}']

built = {'new': '', **{f'new-{v}': f'-nc{v}' for v in range(33, 36)}, 'master': '', **{str(v): f'-{v}' for v in range(30, 36)}}
frozen = [f'new-{v}' for v in range(30, 33)] + [str(v) for v in range(13, 30)]
# a version never stands without its leading «v»: nginx-v1.2.3, nginx-nc35-v1.2.3
expected_tags = {
    'new': ['nginx', 'nginx-20261026', 'nginx-v1.2.3', 'nginx-v1.2.3-20261026'],
    **{f'new-{v}': [f'nginx-nc{v}', f'nginx-nc{v}-20261026', f'nginx-nc{v}-v1.2.3', f'nginx-nc{v}-v1.2.3-20261026']
       for v in range(33, 36)},
    'master': ['latest', '20261026', 'v1.2.3', 'v1.2.3-20261026'],
}

failed = 0
for branch, expected in built.items():
    got = suffix(branch)
    ok = got == expected
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  built {branch} -> suffix {got!r}" + ('' if ok else f', expected {expected!r}'))
for branch, expected in expected_tags.items():
    got = tags(branch, 'latest' if branch == 'master' else 'nginx')
    ok = got == expected
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  {branch} publishes {' '.join(got)}" + ('' if ok else f', expected {" ".join(expected)}'))
for branch in built:
    got = [t for t in tags(branch, 'nginx') if re.search(r'(^|-)\d+\.\d+\.\d+', t)]
    ok = not got
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  {branch} publishes no version without «v»" + ('' if ok else f': {" ".join(got)}'))
for branch in frozen:
    got = suffix(branch)
    ok = got is None
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  frozen {branch}" + ('' if ok else f' matches a rule (suffix {got!r})'))
# the build job pushes the architecture tags with `npm run deploy`, and the
# deploy job joins every image of the compose file from them; an image the
# script leaves out fails there with «<image>-<arch>: not found»
config =json.loads(subprocess.run(['docker', 'compose', 'config', '--format', 'json'], cwd=root,
                                   check=True, capture_output=True, text=True).stdout)
images = sorted(name for name, service in config['services'].items() if 'build' in service and service.get('image'))
pushed = json.loads((root / 'package.json').read_text())['scripts']['deploy'].split()
for name in images:
    ok = name in pushed
    failed += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  deploy pushes {name}")
total = 2 * len(built) + len(expected_tags) + len(frozen) + len(images)
print(f'==> Branch contract: {total - failed} passed, {failed} failed')
sys.exit(1 if failed else 0)
