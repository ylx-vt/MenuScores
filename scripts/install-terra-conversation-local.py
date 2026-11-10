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
    assert (release["CFBundleIdentifier"], release["CFBundleShortVersionString"], release["CFBundleVersion"]) == ("daniyalmaster.MenuScores", "2.5.4", "30")
    assert (old["CFBundleShortVersionString"], old["CFBundleVersion"]) == ("2.5.3", "29")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", SOURCE)
    api = json.loads((EVIDENCE / "terra-query-live-validation.json").read_text())
    # The parent explicitly accepted the audited user-initiated two-pass query,
    # native cached replay and offline regressions for this release. Do not
    # invent additional assistant live tests or spend on redundant samples.
    assert api["userInitiatedOriginalAudited"] and api["actualFunctionCallVerified"]
    assert api["eventFactsChecked"] and api["markdownPixelsVerified"]
    assert api["assistantNewPaidRequests"] == 0 and api["requestCount"] == 2
    assert all(call["model"] == "gpt-6.1-terra" and call["httpStatus"] == 200 for call in api["calls"])
    assert "final result: passed" in (PROJECT / "design-qa.md").read_text()
    ledger_path = Path.home() / "Library/Application Support/MenuScores/TerraAutofill-v1.json"
    prior_ledger = json.loads(ledger_path.read_text())
    assert not any(job["state"] == "running" for job in prior_ledger.get("reviewOperations", {}).values()), "Wait for active user question; nothing replaced"
    restart = json.loads((BUILD / "CredentialQA/conversation-restart.json").read_text())
    assert restart["processRestartVerified"] and restart["draftRestored"] and restart["turns"] == 2
    assert restart["modelCalls"] == 0 and restart["keychainReads"] == 0
    stopped = stop_own_instances()
    before = protection.snapshot()
    (EVIDENCE / "terra-conversation-install-before.json").write_text(json.dumps(before, indent=2, sort_keys=True))
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
    tests = (BUILD / "terra-conversation-tests.log").read_text()
    assert "** TEST SUCCEEDED **" in tests and "217 tests in 31 suites passed" in tests
    qa = json.loads((BUILD / "CredentialQA/interactions.json").read_text())
    assert qa["missingDataErrorVisible"] and not qa["screenshotsUploaded"]
    for interaction in qa["rows"]:
        assert all(interaction[key] is True for key in ["openedByNativeClick", "evidenceOpenedByNativeClick", "pointOpenedByNativeClick", "returnedWithSelectionAndDraft", "scrollRestored", "sentByNativeClick", "sameVisibleWindowCount", "statisticsTeamRetained", "statisticsPlayerScrollRetained"])
        assert interaction["APIRequests"] == 0 and interaction["keychainReads"] == 0
    assert (BUILD / "terra-credential-release.log").read_text().find("** BUILD SUCCEEDED **") >= 0

    def cache_hashes(folder):
        return {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in folder.glob("*.json")}
    articles = Path.home() / "Library/Caches/NBATerraArticles-v2"
    answers = Path.home() / "Library/Caches/NBAReviewAnswers-v1/answers-v2"
    article_hashes, answer_hashes = cache_hashes(articles), cache_hashes(answers)
    original_articles = json.loads((EVIDENCE / "terra-query-budget-before.json").read_text())["cacheHashes"]
    assert all(article_hashes.get(name) == digest for name, digest in original_articles.items())

    # Recover only original question text explicitly supplied by the user.
    # Remaining old answers retain an honest "question not saved" label.
    import re
    history_root = Path.home() / "Library/Application Support/MenuScores/Conversations-v1"
    history_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    mapping = json.loads((EVIDENCE / "terra-conversation-legacy-question-map.json").read_text())
    map_path = history_root / "legacy-question-map.json"
    previous_mapping = json.loads(map_path.read_text()) if map_path.exists() else {}
    previous_mapping.update(mapping)
    map_staged = map_path.with_suffix(".staged")
    map_staged.write_text(json.dumps(previous_mapping, ensure_ascii=False))
    os.chmod(map_staged, 0o600)
    os.replace(map_staged, map_path)
    groups = {}
    for answer_file in answers.glob("*.json"):
        answer = json.loads(answer_file.read_text())
        game_id = answer.get("gameID", "")
        if not game_id.isdigit() or len(game_id) > 20: continue
        original = mapping.get(answer.get("requestID"))
        if re.search(r"(?i)(sk-|bearer\s+[a-z0-9._-]{8,}|(?:api[_ -]?key|password|密码|密钥)\s*[:：=])", (original or "") + answer.get("text", "")): continue
        if answer.get("searched") and not answer.get("sources"): answer["responseFiltered"] = True
        groups.setdefault(game_id, []).append((answer, original))
    migration = []
    for game_id, entries in groups.items():
        history_file = history_root / (game_id + ".json")
        doc = json.loads(history_file.read_text()) if history_file.exists() else {"version":1, "gameID":game_id, "revision":0, "turns":[], "draft":""}
        assert doc["gameID"] == game_id and doc["version"] == 1
        old_ids = {turn["id"] for turn in doc["turns"]}
        by_request = {turn["answer"].get("requestID"):turn for turn in doc["turns"] if turn["answer"].get("requestID")}
        for answer, original in sorted(entries, key=lambda row:row[0]["generatedAt"]):
            turn = by_request.get(answer.get("requestID"))
            if turn is not None:
                if not turn.get("questionKnown", True) and original: turn.update(question=original, questionKnown=True)
                continue
            turn = {"id":str(uuid.uuid4()).upper(), "question":original or "历史回答（原问未保存）", "answer":answer, "askedAt":answer["generatedAt"], "questionKnown":original is not None}
            context = answer.get("localEvidence", {}).get("queryScope")
            if context: turn["contextLabel"] = context
            doc["turns"].append(turn)
        doc["turns"].sort(key=lambda turn:turn["askedAt"])
        assert old_ids.issubset({turn["id"] for turn in doc["turns"]})
        doc["revision"] += 1
        doc["updatedAt"] = time.time() - 978307200
        temporary = history_file.with_suffix(".staged")
        temporary.write_text(json.dumps(doc, ensure_ascii=False))
        os.chmod(temporary, 0o600)
        os.replace(temporary, history_file)
        migration.append({"gameID":game_id, "turns":len(doc["turns"]), "knownOriginals":sum(turn.get("questionKnown",False) for turn in doc["turns"]), "unknownOriginals":sum(not turn.get("questionKnown",False) for turn in doc["turns"])})
    (EVIDENCE / "terra-conversation-migration.json").write_text(json.dumps({"games":migration,"noModelRequests":True,"originalAnswerCacheBytesUnchanged":answer_hashes == cache_hashes(answers)}, indent=2))

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
        assert article_hashes == cache_hashes(articles), "Article cache changed during replacement"
        assert answer_hashes == cache_hashes(answers), "Saved public answers changed during replacement"
        report = {"version": "2.5.4", "build": "30", "installedPath": str(TARGET),
                  "executableSHA256": expected, "signature": "ad-hoc; deep strict verified",
                  "rollback": str(ROLLBACK), "rollbackVersion": "2.4.9 (22)",
                  "rollbackSHA256": hashlib.sha256(ROLLBACK.read_bytes()).hexdigest(),
                  "rollbackExecutableSHA256": rollback_executable_hash, "previousInstalledExecutableSHA256": old_hash, "protectedDataUnchangedBeforeLaunch": True,
                  "stoppedOwnPIDs": stopped, "auditedUserRequestCount": api["requestCount"], "assistantNewPaidRequests": 0, "articleCacheFilesPreserved": len(article_hashes), "savedAnswerFilesPreserved": len(answer_hashes), "dailyBudgetUSD": 1.50, "budgetUsedOrReservedBeforeLaunchUSD": ledger["spentUSD"], "batchStates": {state: sum(job["state"] == state for job in ledger["jobs"].values()) for state in ["done", "failed", "budget", "uncertain"]},
                  "installedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(), "screenshotsUploaded": False}
        (EVIDENCE / "terra-conversation-install.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    except Exception:
        if TARGET.exists(): shutil.rmtree(TARGET)
        os.rename(previous, TARGET)
        raise
    shutil.rmtree(previous)
    run("/usr/bin/open", TARGET)
    print(json.dumps({"installed": "2.5.4 (30)", "rollback": "2.4.9 (22)", "protectedBeforeLaunch": True, "avatarImages": len(before["avatars"])}))

if __name__ == "__main__":
    main()
