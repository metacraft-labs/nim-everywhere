#!/usr/bin/env python3
"""Compile the actual CI-pinned lock readers and read the shipping lock.

No engine, parser, filesystem or compiler is mocked. The sibling Reprobuild
Git object database supplies exact immutable source revisions; no checkout is
moved. Run in nim-everywhere's dev shell with the sibling repository available. This
checks reader compatibility on this host; it does not claim native bootstrap
qualification for other operating systems.
"""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PROBE = '''import std/os
import repro_lock
let text = readFile(paramStr(1))
let solved = parseSolvedGraphLock(text)
let locked = parseLockedDependencies(text)
doAssert solved.packages.len == locked.packages.len
# Both readers are on the build/publication path; neither may accept a
# partial lock silently after a schema migration.
echo "packages=", solved.packages.len, " deps=", locked.deps.len
'''
V2_CONTROL = '''schema = "reprobuild.solved-graph-lock.v2"
[lock]
platform = "amd64-linux"
optimal = false
inputs_digest = "fnv1a64:0123456789abcdef"
variants = []
packages = []
deps = []
'''


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reprobuild', type=Path, default=ROOT.parent / 'reprobuild')
    # Every workflow that builds the engine from source must build the same
    # one (see --workflow).
    parser.add_argument('--workflow', type=Path, action='append',
                        help='default: ci-reprobuild.yml')
    parser.add_argument('--nim', default='nim')
    args = parser.parse_args()
    # ci.yml runs no `repro`, so ci-reprobuild.yml is the only workflow that
    # selects an engine; any future workflow that does must be passed here.
    paths = args.workflow or [ROOT / '.github/workflows/ci-reprobuild.yml']
    workflows = {path.name: path.read_text() for path in paths}
    pins = {}
    for name, text in workflows.items():
        pin = re.search(r'^\s+repro-build-pin:\s*(.+)$', text, re.M)
        if not pin:
            raise AssertionError(f'{name} must declare its Reprobuild source pin')
        pins[name] = sorted(set(re.findall(r'\b[0-9a-f]{40}\b', pin.group(1))))
        if not pins[name]:
            raise AssertionError(f'{name}: CI engines must use immutable full source revisions')
    if len({tuple(v) for v in pins.values()}) != 1:
        raise AssertionError(f'workflows build different engines: {pins}')
    revisions = next(iter(pins.values()))
    committed = (ROOT / 'repro.lock').read_bytes()
    lock = tomllib.loads(committed.decode())['lock']
    expected = f"packages={len(lock['packages'])} deps={len(lock['deps'])}"
    failures = []
    for revision in revisions:
        with tempfile.TemporaryDirectory(prefix='nim-everywhere-ci-lock-reader-') as scratch:
            work = Path(scratch)
            archive = subprocess.check_output(['git', '-C', str(args.reprobuild),
                                                'archive', revision, 'libs', 'flake.lock'])
            with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                # `filter=` exists only on Python 3.12+ and the security backports
                # (3.11.4+); the runner's interpreter may predate them. The archive is
                # read from a revision-pinned object database, but the fallback still
                # refuses any member that is not a plain file or directory inside work.
                if hasattr(tarfile, 'data_filter'):
                    tar.extractall(work, filter='data')
                else:
                    root = work.resolve()
                    for member in tar.getmembers():
                        target = (root / member.name).resolve()
                        if not (member.isfile() or member.isdir()) or \
                                root not in (target, *target.parents):
                            raise SystemExit('unsafe member in engine archive: ' + member.name)
                    tar.extractall(work)
            (work / 'probe.nim').write_text(PROBE)
            (work / 'v2.lock').write_text(V2_CONTROL)
            (work / 'committed.lock').write_bytes(committed)
            paths = sorted((work / 'libs').glob('*/src'))
            command = [args.nim, 'c', '--hints:off', '--parallelBuild:2',
                        '-d:reproVendoredHash',
                        '--passC:-I' + str(work / 'libs/blake3/src/blake3/vendor'),
                        *('--path:' + str(p) for p in paths),
                        '--out:' + str(work / 'probe'), str(work / 'probe.nim')]
            print(f'Compiling exact CI reader {revision}', flush=True)
            run(*command, cwd=work)
            # A v2 positive control proves the probe and dependencies actually
            # work before attributing the shipping lock failure to its schema.
            control = subprocess.check_output([str(work / 'probe'), str(work / 'v2.lock')], text=True)
            assert control.strip() == 'packages=0 deps=0', control
            current = subprocess.run([str(work / 'probe'), str(work / 'committed.lock')],
                                      capture_output=True, text=True)
            if current.returncode or current.stdout.strip() != expected:
                failures.append(revision)
                print(f'FAIL {revision}: {current.stdout}{current.stderr}', flush=True)
            else:
                print(f'PASS {revision}: {expected}', flush=True)
                # A newer reader must not be bootstrapped with the previous
                # engine's explicit library overrides. Compare immutable
                # producer identities, not version strings or ancestry.
                engine_lock = json.loads((work / 'flake.lock').read_text())
                inputs = engine_lock['nodes'][engine_lock['root']]['inputs']
                for name, workflow in workflows.items():
                    # The hook library is bootstrapped from an explicit
                    # revision by the POSIX from-source build.
                    settings = [('repro-runquota-pin', 'runquota-src', True),
                                ('repro-io-mon-pin', 'io-mon-src', True),
                                ('repro-stackable-hooks-pin', 'nim-stackable-hooks-src',
                                 True)]
                    for setting, dependency, required in settings:
                        row = re.search(r'^\s+' + setting + r':\s*(.+)$', workflow, re.M)
                        if not row:
                            assert not required, f'{name} must declare {setting}'
                            continue
                        supplied = set(re.findall(r'\b[0-9a-f]{40}\b', row.group(1)))
                        locked_revision = engine_lock['nodes'][inputs[dependency]]['locked']['rev']
                        assert locked_revision in supplied, (name, revision, setting, locked_revision, supplied)
                    override = re.search(r'^\s+repro-posix-io-mon-pin:\s*(.+)$', workflow, re.M)
                    if override:
                        supplied = set(re.findall(r'\b[0-9a-f]{40}\b', override.group(1)))
                        monitor = engine_lock['nodes'][inputs['io-mon-src']]['locked']['rev']
                        assert supplied <= {monitor}, (name, 'POSIX bootstrap monitor differs from engine', supplied, monitor)
    assert not failures, f'CI engines cannot read committed lock: {failures}'


if __name__ == '__main__':
    main()
