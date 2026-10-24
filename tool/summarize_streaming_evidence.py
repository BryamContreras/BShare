#!/usr/bin/env python3
"""Print full streaming reports into CI logs and summarize every expected run."""
import argparse
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', type=Path, nargs='+')
    options = parser.parse_args()
    lines = ['## Native streaming evidence', '',
        '| Report | Result | Cases |', '| --- | --- | --- |']
    for path in options.reports:
        if not path.is_file():
            lines.append(f'| `{path.as_posix()}` | Not produced | — |')
            continue
        try:
            report = json.loads(path.read_text(encoding='utf-8-sig'))
            result = 'Passed' if report.get('passed') is True else 'Failed'
            cases = report.get('cases', [])
            count = f'{sum(case.get("passed") is True for case in cases)}/{len(cases)}' if cases else '—'
            lines.append(f'| `{path.as_posix()}` | {result} | {count} |')
            print(f'\nReport: {path.as_posix()}\n{json.dumps(report, indent=2)}', flush=True)
        except (OSError, ValueError, TypeError) as error:
            lines.append(f'| `{path.as_posix()}` | Invalid report | — |')
            print(f'Could not read {path}: {error}', flush=True)
    summary = '\n'.join(lines) + '\n'
    print(summary, flush=True)
    target = os.environ.get('GITHUB_STEP_SUMMARY')
    if target:
        with Path(target).open('a', encoding='utf-8') as output:
            output.write(summary)


if __name__ == '__main__':
    main()
