#!/usr/bin/env python3
"""Independent JSON parser checks for broadcast escaping and UTF-8 span copies."""
import json,random,subprocess
from pathlib import Path
rng=random.Random(42043)
chars=''.join(chr(i) for i in range(128))+'éעברית😀雪\u2028\u2029'
values=['',chars,'"\\</script>&','a'*20000,'é'*10000,'\x00', '\\b', '\\f']
values += [''.join(rng.choice(chars) for _ in range(rng.randrange(512))) for _ in range(1000)]
Path('build/json-strings.json').write_text(json.dumps(values))
rows=subprocess.check_output(['build/json-encoding'],text=True).split('\n')[:-1]
assert len(rows)==len(values)
for i,(value,row) in enumerate(zip(values,rows)):
 assert json.loads(row)==value,i
 assert not any(c in row for c in '<>&'),i
assert rows[6]=='"\\\\b"' and rows[7]=='"\\\\f"'
print(f'PASS: {len(values)} independent JSON round trips, all ASCII controls, UTF-8, empty/large strings and HTML-safe output')
