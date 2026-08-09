"""Zips the host bundle into dist/LANMP-Server.zip: the server executable plus
the double-click launcher and instructions for whoever is hosting.

Build the server first, then:

    python tools/pack_host.py
"""

import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.path.join(ROOT, "tools", "host")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "LANMP-Server.zip")

EXE_CANDIDATES = [
    os.path.join(ROOT, "server", "build", "lanmp_server.exe"),
    os.path.join(ROOT, "server", "build", "Release", "lanmp_server.exe"),
    os.path.join(ROOT, "server", "build", "lanmp_server"),
]


def find_exe():
    for path in EXE_CANDIDATES:
        if os.path.isfile(path):
            return path
    return None


def main():
    exe = find_exe()
    if exe is None:
        print("no server binary found - build it first (cmake --build build)")
        return 1

    os.makedirs(DIST, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(exe, os.path.basename(exe))
        for name in sorted(os.listdir(HOST)):
            z.write(os.path.join(HOST, name), name)
    print("wrote %s (%.1f KiB)" % (OUT, os.path.getsize(OUT) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
