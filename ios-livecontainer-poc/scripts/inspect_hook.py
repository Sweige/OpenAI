"""Read-only validation of our standalone dylib; does not sign or execute it."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile


def inspect(path, ipa):
    path = Path(path)
    data = path.read_bytes()
    magic, cpu, _, kind, count, command_bytes, _, _ = struct.unpack_from('<8I', data)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 6, 'Expected thin arm64 MH_DYLIB'
    offset = 32
    dependencies, identifiers, cryptids, platforms = [], [], [], []
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        assert size >= 8 and offset+size <= 32+command_bytes <= len(data)
        if command in (0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023):
            start = struct.unpack_from('<I', data, offset+8)[0]
            assert 24 <= start < size
            name = data[offset+start:offset+size].split(b'\0', 1)[0].decode()
            (identifiers if command == 0xD else dependencies).append(name)
        if command in (0x21, 0x2C):
            cryptids.append(struct.unpack_from('<I', data, offset+16)[0])
        if command == 0x32:
            platform, minimum, sdk = struct.unpack_from('<III', data, offset+8)
            platforms.append({'platform': platform, 'minimum': minimum, 'sdk': sdk})
        offset += size
    assert offset == 32+command_bytes and not any(cryptids)
    assert identifiers == ['@rpath/OBSCaptureHook.dylib']
    assert all(n.startswith('/System/Library/') or n.startswith('/usr/lib/') for n in dependencies)
    assert b'com.example.OBSiPhoneLab' in data and b'OBSiPhoneLab.Camera' in data
    with zipfile.ZipFile(ipa) as archive:
        assert not any('OBSCaptureHook' in n for n in archive.namelist()), 'Hook must be external to the host IPA'
    return {'file': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'architecture': 'arm64', 'mach_o_type': 'MH_DYLIB', 'install_names': identifiers,
            'dependencies': dependencies, 'cryptids': cryptids, 'build_versions': platforms,
            'own_bundle_allowlist_present': True, 'own_delegate_allowlist_present': True,
            'absent_from_host_ipa': True, 'signing': 'LiveContainer uses the user-imported local certificate',
            'runtime_external_load_and_replacement': 'not tested by this static inspection'}


if __name__ == '__main__':
    print(json.dumps(inspect(*sys.argv[1:]), indent=2))
