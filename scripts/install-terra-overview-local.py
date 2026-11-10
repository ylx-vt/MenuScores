#!/usr/bin/env python3
"""Install the reviewed local app, with one verified rollback and byte checks."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
BUILD = Path("/tmp/MenuScores-build")
SOURCE = PROJECT / ".local-backups/ReviewCandidate/MenuScores.app"
TARGET = Path("/Applications/MenuScores.app")
EVIDENCE = PROJECT / ".local-backups"
ROLLBACK = Path.home() / "Library/Application Support/MenuScores Backups/MenuScores-rollback.zip"
spec = importlib.util.spec_from_file_location("protection", PROJECT / "scripts/terra-install-protection.py")
protection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protection)

def run(*args):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True)

def info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())

def executable_hash(app):
    return hashlib.sha256((app / "Contents/MacOS/MenuScores").read_bytes()).hexdigest()

def stop_own_instances():
    found = subprocess.run(["/usr/bin/pgrep", "-x", "MenuScores"], capture_output=True, text=True)
    pids = []
    allowed = {str(TARGET / "Contents/MacOS/MenuScores"), str(SOURCE / "Contents/MacOS/MenuScores"), str(BUILD / "Build/Products/Debug/MenuScores.app/Contents/MacOS/MenuScores")}
    for text in found.stdout.split():
        pid = int(text)
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if command in allowed:
            os.kill(pid, signal.SIGTERM); pids.append(pid)
    for _ in range(80):
        alive = []
        for pid in pids:
            try: os.kill(pid, 0); alive.append(pid)
            except ProcessLookupError: pass
        if not alive: return pids
        time.sleep(.1)
    raise RuntimeError("A MenuScores instance did not stop; application replacement was not attempted")

def main():
    release, old = info(SOURCE), info(TARGET)
    assert (release["CFBundleIdentifier"], release["CFBundleShortVersionString"], release["CFBundleVersion"]) == ("daniyalmaster.MenuScores", "2.5.1", "27")
    assert (old["CFBundleShortVersionString"], old["CFBundleVersion"]) == ("2.5.0", "26")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", SOURCE)
    api = json.loads((EVIDENCE / "terra-review-live-validation.json").read_text())
    assert api["allCompleted"] and api["nativeQuestionAndFollowupVerified"] and api["nativeOfficialCitationVisible"]
    assert api["repeatSubmitZeroRequests"] and api["requestCount"] >= 4
    assert all(call["model"] == "gpt-6.1-terra" and call["httpStatus"] == 200 for call in api["calls"])
    assert "final result: passed" in (PROJECT / "design-qa.md").read_text()
    stopped = stop_own_instances()
    before = protection.snapshot()
    (EVIDENCE / "terra-overview-install-before.json").write_text(json.dumps(before, indent=2, sort_keys=True))
    # Keep the single already-verified restored 2.4.9 backup. Do not create
    # another app backup for this automatic-feature increment.
    old_hash = executable_hash(TARGET)
    with zipfile.ZipFile(ROLLBACK) as archive:
        archived = plistlib.loads(archive.read("MenuScores.app/Contents/Info.plist"))
        assert (archived["CFBundleShortVersionString"], archived["CFBundleVersion"]) == ("2.4.9", "22")
        rollback_executable_hash = hashlib.sha256(archive.read("MenuScores.app/Contents/MacOS/MenuScores")).hexdigest()
    prior = json.loads((EVIDENCE / "terra-install.json").read_text())
    assert rollback_executable_hash == prior["rollbackExecutableSHA256"]
    ledger = json.loads((Path.home() / "Library/Application Support/MenuScores/TerraAutofill-v1.json").read_text())
    assert ledger["spentUSD"] <= 1.50
    assert not any(job["state"] == "running" for job in ledger["jobs"].values())
    assert not any(job["state"] == "running" for job in ledger.get("reviewOperations", {}).values())
    tests = (BUILD / "terra-overview-tests.log").read_text()
    assert "** TEST SUCCEEDED **" in tests and "171 tests in 27 suites passed" in tests
    qa = json.loads((BUILD / "OverviewQA/interactions.json").read_text())
    assert qa["missingDataErrorVisible"] and not qa["screenshotsUploaded"]
    for interaction in qa["rows"]:
        assert all(interaction[key] is True for key in ["openedByNativeClick", "evidenceOpenedByNativeClick", "pointOpenedByNativeClick", "returnedWithSelectionAndDraft", "scrollRestored", "sentByNativeClick", "sameVisibleWindowCount", "statisticsTeamRetained", "statisticsPlayerScrollRetained"])
        assert interaction["APIRequests"] == 0 and interaction["keychainReads"] == 0
    assert (BUILD / "terra-overview-release.log").read_text().find("** BUILD SUCCEEDED **") >= 0

    token = uuid.uuid4().hex
    staged = TARGET.parent / (".MenuScores-terra-staged-" + token + ".app")
    previous = TARGET.parent / (".MenuScores-pre-terra-" + token + ".app")
    run("/usr/bin/ditto", SOURCE, staged)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged)
    expected = executable_hash(SOURCE)
    assert executable_hash(staged) == expected
    os.rename(TARGET, previous)
    try:
        os.rename(staged, TARGET)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", TARGET)
        assert executable_hash(TARGET) == expected
        after = protection.snapshot()
        assert before == after, "Protected data changed during replacement"
        report = {"version": "2.5.1", "build": "27", "installedPath": str(TARGET),
                  "executableSHA256": expected, "signature": "ad-hoc; deep strict verified",
                  "rollback": str(ROLLBACK), "rollbackVersion": "2.4.9 (22)",
                  "rollbackSHA256": hashlib.sha256(ROLLBACK.read_bytes()).hexdigest(),
                  "rollbackExecutableSHA256": rollback_executable_hash, "previousInstalledExecutableSHA256": old_hash, "protectedDataUnchangedBeforeLaunch": True,
                  "stoppedOwnPIDs": stopped, "realReviewRequestCount": api["requestCount"], "dailyBudgetUSD": 1.50, "budgetUsedOrReservedBeforeLaunchUSD": ledger["spentUSD"], "batchStates": {state: sum(job["state"] == state for job in ledger["jobs"].values()) for state in ["done", "failed", "budget", "uncertain"]},
                  "installedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "screenshotsUploaded": False}
        (EVIDENCE / "terra-overview-install.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    except Exception:
        if TARGET.exists(): shutil.rmtree(TARGET)
        os.rename(previous, TARGET)
        raise
    shutil.rmtree(previous)
    run("/usr/bin/open", TARGET)
    print(json.dumps({"installed": "2.5.1 (27)", "rollback": "2.4.9 (22)", "protectedBeforeLaunch": True, "avatarImages": len(before["avatars"])}))

if __name__ == "__main__":
    main()
