#!/usr/bin/env bash
# GHUL - Delete aborted/incomplete run from local database
# Usage: ./tools/ghul-delete-run.sh [run_id]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "${SCRIPT_DIR}/.." && pwd)"
DB_PATH="${BASE}/db/ghul.sqlite"

if [[ ! -f "$DB_PATH" ]]; then
    echo "Error: Database not found at $DB_PATH"
    exit 1
fi

# Get run_id from argument or latest run
if [[ $# -ge 1 ]]; then
    RUN_ID="$1"
else
    # Get latest run
    RUN_ID="$(sqlite3 "$DB_PATH" "SELECT run_id FROM runs ORDER BY ts DESC LIMIT 1;" 2>/dev/null || echo "")"
    if [[ -z "$RUN_ID" ]]; then
        echo "No runs found in database."
        exit 0
    fi
fi

echo "Deleting run: $RUN_ID"
echo ""

# Get all tables
TABLES="$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null || echo "")"

if [[ -z "$TABLES" ]]; then
    echo "No tables found in database."
    exit 1
fi

# Delete from all tables that have run_id column
DELETED=0
for table in $TABLES; do
    if [[ "$table" == "runs" ]]; then
        # Delete from runs table
        COUNT="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM runs WHERE run_id = '$RUN_ID';" 2>/dev/null || echo "0")"
        if [[ "$COUNT" -gt 0 ]]; then
            sqlite3 "$DB_PATH" "DELETE FROM runs WHERE run_id = '$RUN_ID';" 2>/dev/null || true
            echo "  Deleted from runs: $COUNT entry(ies)"
            DELETED=$((DELETED + COUNT))
        fi
    else
        # Check if table has run_id column
        HAS_RUN_ID="$(sqlite3 "$DB_PATH" "PRAGMA table_info($table);" 2>/dev/null | grep -c "run_id" || echo "0")"
        if [[ "${HAS_RUN_ID:-0}" -gt 0 ]]; then
            COUNT="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM $table WHERE run_id = '$RUN_ID';" 2>/dev/null || echo "0")"
            if [[ "$COUNT" -gt 0 ]]; then
                sqlite3 "$DB_PATH" "DELETE FROM $table WHERE run_id = '$RUN_ID';" 2>/dev/null || true
                echo "  Deleted from $table: $COUNT entry(ies)"
                DELETED=$((DELETED + COUNT))
            fi
        fi
    fi
done

if [[ $DELETED -eq 0 ]]; then
    echo "No data found for run_id: $RUN_ID"
else
    echo ""
    echo "Successfully deleted $DELETED entries for run: $RUN_ID"
    echo ""
    echo "Note: If this run was uploaded to ghul.run, you need to delete it manually"
    echo "      on the website (ghul.run) as well."
fi

