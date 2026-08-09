"""Zips mod/ into dist/LANMP.zip, the file players drop into BeamNG's mods folder.

Also bundles the freshly built lanmp_server.exe so the in-game "Host a Server"
button works without a separate download. The exe is placed at
  lua/ge/extensions/lanmp/bin/lanmp_server.exe
which lanmp/host.lua copies out to a native path at runtime.

    python tools/pack_mod.py
"""

import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "mod")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "LANMP.zip")

EXE_CANDIDATES = [
    os.path.join(ROOT, "server", "build", "lanmp_server.exe"),
    os.path.join(ROOT, "server", "build", "Release", "lanmp_server.exe"),
    os.path.join(ROOT, "server", "build", "lanmp_server"),
]
EXE_DEST = "lua/ge/extensions/lanmp/bin/lanmp_server.exe"


def find_exe():
    for path in EXE_CANDIDATES:
        if os.path.isfile(path):
            return path
    return None


def main():
    os.makedirs(DIST, exist_ok=True)
    exe = find_exe()
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(MOD):
            for name in files:
                path = os.path.join(folder, name)
                z.write(path, os.path.relpath(path, MOD).replace("\\", "/"))
        if exe is not None:
            z.write(exe, EXE_DEST)
            print("bundled server: %s -> %s" % (exe, EXE_DEST))
        else:
            print("WARNING: no server binary found - Host button will not work. "
                  "Build the server first (cmake --build build).")
    print("wrote %s (%.1f KiB)" % (OUT, os.path.getsize(OUT) / 1024.0))
    return 0 if exe is not None else 1


if __name__ == "__main__":
    sys.exit(main())
