"""Strictly separate isolated synthetic ARM timings from live QR throughput."""
import argparse
import json
import re
import statistics
from pathlib import Path


def read(path, fast):
    data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    lines = [s['text'] for s in data['samples']]
    begin = f'[BENCH BEGIN] synthetic=1 live_pipeline=0 fast={fast} repeats=30'
    end = '[BENCH COMPLETE] regression=PASS samples=210 synthetic=1 live_pipeline=0'
    # Reset can leave the previous firmware's incomplete UART line directly
    # before the complete begin marker. Ignore that prefix only, never repair
    # or skip a damaged benchmark sample.
    starts=[i for i,line in enumerate(lines) if line.endswith(begin) and line.count('[BENCH BEGIN]')==1]
    if len(starts) != 1 or lines.count(end) != 1:
        raise ValueError('Missing or repeated benchmark boundary')
    start, stop = starts[0], lines.index(end)
    if stop <= start:
        raise ValueError('Reversed benchmark boundaries')
    rows = []
    for line in lines[start+1:stop]:
        if line.startswith('[BENCH] '):
            row = {k: int(v) for k, v in re.findall(r'(\w+)=(-?\d+)', line)}
            if set(row) != {'fast','fixture','rep','status','us','fallback_us','early','refined'}:
                raise ValueError('Incomplete benchmark row')
            rows.append(row)
    if len(rows) != 210:
        raise ValueError('Expected seven fixtures x 30 independent samples')
    for index, row in enumerate(rows):
        if (row['fast'], row['fixture'], row['rep']) != (fast, index//30, index%30):
            raise ValueError('Wrong version, duplicate or missing sample')
        if (row['status'] == 0) != (row['fixture'] < 5):
            raise ValueError('Unexpected decode acceptance/rejection')
        if row['us'] < row['fallback_us'] or row['fallback_us'] <= 0:
            raise ValueError('Invalid measured time')
    return rows


def describe(rows):
    values = sorted(r['us'] for r in rows)
    return dict(n=len(rows), mean_us=statistics.mean(values),
                median_us=statistics.median(values), max_us=max(values),
                early=sum(r['early'] for r in rows),
                refined=sum(r['refined'] for r in rows))


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--control',required=True);p.add_argument('--fast',required=True)
    p.add_argument('--output',required=True)
    args=p.parse_args()
    output=Path(args.output)
    if output.exists(): raise ValueError('Output exists; choose another name')
    old,new=read(args.control,0),read(args.fast,1)
    fixtures=[]
    for fixture in range(7):
        a=describe([r for r in old if r['fixture']==fixture])
        b=describe([r for r in new if r['fixture']==fixture])
        fixtures.append(dict(fixture=fixture,control=a,fast=b,
                             mean_reduction_percent=100*(1-b['mean_us']/a['mean_us'])))
    result=dict(control_source=args.control,fast_source=args.fast,fixtures=fixtures,
        success_cases=dict(control=describe(old[:150]),fast=describe(new[:150])),
        note='Synthetic version-3 QR, isolated Cortex-A9 O2; no live camera, PL candidates, DMA or display load. '
             'Same five affine transforms plus blank and damaged payload. Each call resets outside timing; '
             'live 1/6 fallback throttle is NOT represented by these rates. Warmup discarded. '
             'Do not treat these measurements as real-scene recognition rate, pipeline throughput, or a worst-case bound.')
    output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))


if __name__=='__main__': main()
