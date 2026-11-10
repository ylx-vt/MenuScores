#!/usr/bin/env python3
"""Hash only MenuScores settings, pin and portrait bytes; never reads Keychain."""
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys

DOMAIN = "daniyalmaster.MenuScores"

def sha(data):
    return hashlib.sha256(data).hexdigest()

def snapshot():
    exported = subprocess.run(["/usr/bin/defaults", "export", DOMAIN, "-"], capture_output=True, check=True).stdout
    settings = plistlib.loads(exported)
    hashed = {key: sha(plistlib.dumps({key: value}, fmt=plistlib.FMT_BINARY, sort_keys=True)) for key, value in settings.items()}
    favorite = settings.get("favoriteTeams")
    pin = Path.home() / "Library/Application Support/MenuScores/nba-pinned-selection-v1.json"
    caches = Path.home() / "Library/Caches"
    avatars = {}
    for folder in ["NBAAvatars", "NBAAvatarThumbnails-v1"]:
        directory = caches / folder
        if directory.exists():
            for file in directory.rglob("*"):
                if file.is_file() and file.suffix in [".image", ".png"]:
                    avatars[str(file.relative_to(caches))] = sha(file.read_bytes())
    return {"settings": hashed, "favoritesSHA": sha(favorite) if isinstance(favorite, bytes) else None,
            "pinSHA": sha(pin.read_bytes()) if pin.exists() else None, "avatars": avatars}

def main():
    if sys.argv[1] == "capture":
        destination = Path(sys.argv[2])
        value = snapshot()
        destination.write_text(json.dumps(value, indent=2, sort_keys=True))
        print(json.dumps({"settingsKeys": len(value["settings"]), "avatarImages": len(value["avatars"]), "captured": str(destination)}))
    elif sys.argv[1] == "compare":
        before = json.loads(Path(sys.argv[2]).read_text())
        after = snapshot()
        changed_settings = [key for key, value in before["settings"].items() if after["settings"].get(key) != value]
        changed_avatars = [key for key, value in before["avatars"].items() if after["avatars"].get(key) != value]
        result = {"existingSettingsUnchanged": not changed_settings, "changedSettingKeys": changed_settings,
                  "favoritesBytesUnchanged": before["favoritesSHA"] == after["favoritesSHA"],
                  "pinBytesUnchanged": before["pinSHA"] == after["pinSHA"],
                  "existingAvatarBytesUnchanged": not changed_avatars, "existingAvatarImages": len(before["avatars"]),
                  "changedAvatarPaths": changed_avatars,
                  "newSettingKeys": sorted(set(after["settings"]) - set(before["settings"]))}
        Path(sys.argv[3]).write_text(json.dumps(result, indent=2, sort_keys=True))
        print(json.dumps(result))
        if changed_settings or changed_avatars or not result["favoritesBytesUnchanged"] or not result["pinBytesUnchanged"]:
            raise SystemExit(1)

if __name__ == "__main__":
    main()
