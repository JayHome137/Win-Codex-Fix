import argparse
import glob
import json
import os
import shutil
import sqlite3
import time
from datetime import datetime, timezone


CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
STATE_DB = os.path.join(CODEX_HOME, "state_5.sqlite")
SESSION_ROOTS = (
    os.path.join(CODEX_HOME, "sessions"),
    os.path.join(CODEX_HOME, "archived_sessions"),
)
BACKUP_ROOT = os.environ.get(
    "CODEX_SESSION_INDEX_BACKUP_ROOT",
    os.path.join(os.environ.get("CODEX_REPAIR_ROOT", CODEX_HOME), "archives", "codex-session-index-backups"),
)


def normalize_cwd(value):
    value = str(value or "").replace("/", "\\").strip()
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return value.rstrip("\\").casefold()


def storage_cwd(value):
    value = str(value or "").replace("/", "\\").strip()
    if not value or value.startswith("\\\\?\\"):
        return value
    if value.startswith("\\\\"):
        return "\\\\?\\UNC\\" + value[2:]
    if len(value) >= 3 and value[1] == ":" and value[2] == "\\":
        return "\\\\?\\" + value
    return value


def session_records():
    result = {}
    cwd_conflicts = set()
    files = []
    for root in SESSION_ROOTS:
        files.extend(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    for path in files:
        try:
            with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
                for _ in range(64):
                    line = handle.readline()
                    if not line:
                        break
                    try:
                        item = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if item.get("type") == "session_meta":
                        thread_id = item.get("payload", {}).get("id")
                        if thread_id:
                            thread_id = str(thread_id)
                            cwd = str(item.get("payload", {}).get("cwd") or "")
                            existing = result.get(thread_id)
                            if existing is None or (not existing["cwd"] and cwd):
                                result[thread_id] = {"cwd": cwd}
                            elif cwd and existing["cwd"] and normalize_cwd(cwd) != normalize_cwd(existing["cwd"]):
                                cwd_conflicts.add(thread_id)
                        break
        except OSError:
            continue
    return files, result, cwd_conflicts


def read_state():
    if not os.path.isfile(STATE_DB):
        raise RuntimeError("state_5.sqlite is missing")
    connection = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=10)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        state = connection.execute(
            "SELECT status, last_watermark, last_success_at FROM backfill_state WHERE id = 1"
        ).fetchone()
        rows = connection.execute(
            "SELECT id, thread_source, archived, cwd FROM threads"
        ).fetchall()
    finally:
        connection.close()
    files, disk_records, cwd_conflicts = session_records()
    disk_ids = set(disk_records)
    db_rows = {str(row[0]): row for row in rows}
    db_ids = set(db_rows)
    cwd_mismatch_ids = {
        thread_id
        for thread_id, record in disk_records.items()
        if thread_id in db_ids
        and record["cwd"]
        and normalize_cwd(record["cwd"])
        != normalize_cwd(db_rows[thread_id][3])
    }
    return {
        "integrity": integrity,
        "backfillStatus": state[0] if state else None,
        "lastWatermark": state[1] if state else None,
        "lastSuccessAt": state[2] if state else None,
        "jsonlFiles": len(files),
        "jsonlIds": len(disk_ids),
        "threadRows": len(rows),
        "userSourceRows": sum(row[1] == "user" for row in rows),
        "subagentRows": sum(row[1] == "subagent" for row in rows),
        "unknownSourceRows": sum(row[1] not in ("user", "subagent") for row in rows),
        "activeRows": sum(not row[2] for row in rows),
        "archivedRows": sum(bool(row[2]) for row in rows),
        "missingRows": len(disk_ids - db_ids),
        "staleRows": len(db_ids - disk_ids),
        "cwdMismatches": len(cwd_mismatch_ids),
        "cwdConflicts": len(cwd_conflicts),
    }


def is_healthy(state):
    return (
        state["integrity"] == "ok"
        and state["backfillStatus"] == "complete"
        and state["missingRows"] == 0
        and state["staleRows"] == 0
        and state["cwdMismatches"] == 0
        and state["cwdConflicts"] == 0
        and state["jsonlIds"] == state["threadRows"]
    )


def backup_state():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    backup_dir = os.path.join(BACKUP_ROOT, f"automatic-session-backfill-{stamp}")
    os.makedirs(backup_dir, exist_ok=True)
    backup_db = os.path.join(backup_dir, "state_5.sqlite")
    source = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=30)
    destination = sqlite3.connect(backup_db)
    try:
        source.backup(destination)
    finally:
        destination.close()
        source.close()
    shutil.copy2(os.path.join(CODEX_HOME, "session_index.jsonl"), os.path.join(backup_dir, "session_index.jsonl"))
    return backup_dir


def reset_backfill_state():
    connection = sqlite3.connect(STATE_DB, timeout=30)
    try:
        connection.execute("BEGIN IMMEDIATE")
        changed = connection.execute(
            """
            UPDATE backfill_state
            SET status = 'pending', last_watermark = NULL,
                last_success_at = NULL, updated_at = ?
            WHERE id = 1
            """,
            (int(time.time()),),
        ).rowcount
        if changed != 1:
            raise RuntimeError("backfill_state singleton row is missing")
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    if integrity != "ok":
        raise RuntimeError(f"state database integrity after reset is {integrity!r}")


def reconcile_cwds():
    _, disk_records, cwd_conflicts = session_records()
    if cwd_conflicts:
        raise RuntimeError("session metadata contains conflicting cwd values")

    connection = sqlite3.connect(STATE_DB, timeout=30)
    try:
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute("SELECT id, cwd FROM threads").fetchall()
        db_cwds = {str(row[0]): str(row[1] or "") for row in rows}
        updates = [
            (storage_cwd(record["cwd"]), thread_id)
            for thread_id, record in disk_records.items()
            if thread_id in db_cwds
            and record["cwd"]
            and normalize_cwd(record["cwd"]) != normalize_cwd(db_cwds[thread_id])
        ]
        connection.executemany("UPDATE threads SET cwd = ? WHERE id = ?", updates)
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    if integrity != "ok":
        raise RuntimeError(f"state database integrity after cwd reconciliation is {integrity!r}")
    return len(updates)


def backup_and_prepare():
    before = read_state()
    if before["integrity"] != "ok":
        raise RuntimeError(f"state database integrity before repair is {before['integrity']!r}")
    if before["cwdConflicts"]:
        raise RuntimeError("session metadata contains conflicting cwd values")

    backup_dir = backup_state()
    needs_backfill = (
        before["backfillStatus"] != "complete"
        or before["missingRows"] != 0
        or before["staleRows"] != 0
    )
    cwd_rows_reconciled = 0
    if needs_backfill:
        reset_backfill_state()
    else:
        cwd_rows_reconciled = reconcile_cwds()
    return {
        "backupDir": backup_dir,
        "before": before,
        "reset": needs_backfill,
        "needsBackfill": needs_backfill,
        "cwdRowsReconciled": cwd_rows_reconciled,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check", "repair", "reconcile"))
    args = parser.parse_args()
    if args.command == "check":
        state = read_state()
        print(json.dumps(state, ensure_ascii=False, separators=(",", ":")))
        return 0 if is_healthy(state) else 10
    if args.command == "reconcile":
        print(json.dumps({"cwdRowsReconciled": reconcile_cwds()}, ensure_ascii=False, separators=(",", ":")))
        return 0
    result = backup_and_prepare()
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
