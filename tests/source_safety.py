#!/usr/bin/env python3
"""Keep the application/native safety boundary enforceable in every CI run."""
import re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
forbidden = re.compile(r'\b(?:external_call|Pointer|UnsafePointer|MutUntrackedOrigin|ImmutUntrackedOrigin|unsafe_\w+|as_c_string_span|__mlir_\w+)\b|\bfrom\s+std\.(?:ffi|memory|python)|\bimport\s+std\.(?:ffi|memory|python)')
# Comments are not code, but string literals are deliberately scanned: generated
# source and dynamic call names must not bypass this simple repository contract.
errors=[]
for path in sorted(list((root/'src').glob('*.mojo'))+list((root/'tests').glob('*.mojo'))):
    source=path.read_text()
    if 'unsafe_from_utf8' in source:
        errors.append(f'{path.relative_to(root)}: unchecked UTF-8 construction')
    if path.name=='native_boundary.mojo':
        continue
    for number,line in enumerate(source.splitlines(),1):
        code=line.split('#',1)[0]
        if forbidden.search(code):
            errors.append(f'{path.relative_to(root)}:{number}: unsafe operation outside native boundary')
    if re.search(r'\.(?:_handle|_statements)\b',source):
        errors.append(f'{path.relative_to(root)}: native resource ownership escaped')
assert not errors, '\n'.join(errors)
print('PASS: no FFI/raw-pointer APIs outside native_boundary.mojo; no unchecked UTF-8 constructors anywhere')
