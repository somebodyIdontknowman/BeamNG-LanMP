"""Zips mod/ into dist/LANMP.zip, the file players drop into BeamNG's mods folder.

    python tools/pack_mod.py
"""

import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "mod")
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "LANMP.zip")


def main():
    os.makedirs(DIST, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(MOD):
            for name in files:
                path = os.path.join(folder, name)
                z.write(path, os.path.relpath(path, MOD).replace("\\", "/"))
    print("wrote %s (%.1f KiB)" % (OUT, os.path.getsize(OUT) / 1024.0))


if __name__ == "__main__":
    main()
