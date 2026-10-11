"""Read-only inspection of our own IPA outputs; never execute binaries."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import zipfile


def inspect(path):
    path = Path(path)
    with zipfile.ZipFile(path) as archive:
        roots = [name for name in archive.namelist()
                 if name.startswith("Payload/") and name.endswith(".app/Info.plist")
                 and name.count("/") == 2]
        if len(roots) != 1:
            raise ValueError(f"Expected one root app in {path.name}")
        root = roots[0][:-len("Info.plist")]
        info = plistlib.loads(archive.read(roots[0]))
        binary = archive.read(root + info["CFBundleExecutable"])
        if len(binary) < 32:
            raise ValueError("Truncated Mach-O")
        magic, cpu, _, _, count, command_bytes, _, _ = struct.unpack_from("<8I", binary)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError("Expected a thin arm64 Mach-O")
        if 32 + command_bytes > len(binary):
            raise ValueError("Truncated load commands")
        offset, cryptids = 32, []
        for _ in range(count):
            if offset + 8 > 32 + command_bytes:
                raise ValueError("Invalid load command count")
            command, size = struct.unpack_from("<2I", binary, offset)
            if size < 8 or offset + size > 32 + command_bytes:
                raise ValueError("Invalid load command size")
            if command in (0x21, 0x2C):
                if size < 20:
                    raise ValueError("Truncated encryption command")
                cryptids.append(struct.unpack_from("<I", binary, offset + 16)[0])
            offset += size
        if any(cryptids):
            raise ValueError("Encrypted executable is not expected from our build")
        framework = root + "Frameworks/ProbeKit.framework/ProbeKit"
        if framework not in archive.namelist():
            raise ValueError("Embedded ProbeKit is missing")
        return {
            "file": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bundle_identifier": info["CFBundleIdentifier"],
            "minimum_os": info.get("MinimumOSVersion"),
            "architecture": "arm64",
            "cryptids": cryptids,
            "ProbeKit_embedded": True,
            "Apple_developer_signature": "not supplied by this workflow",
            "iPhone_runtime_test": "not performed by this workflow",
        }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("Usage: inspect_ipa.py own-app.ipa [own-app2.ipa]")
    print(json.dumps([inspect(item) for item in sys.argv[1:]], indent=2))
