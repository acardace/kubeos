#!/bin/bash
# Monitor Velero backup progress
# Usage: ./backup-status.sh [backup-name]
#   If no backup name given, monitors the latest backup.

set -e

BACKUP_NAME="${1:-}"

if [ -z "$BACKUP_NAME" ]; then
    BACKUP_NAME=$(kubectl get backups.velero.io -n velero --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
fi

if [ -z "$BACKUP_NAME" ]; then
    echo "No backups found"
    exit 1
fi

fmt_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(( bytes / 1048576 )) MB"
    elif [ "$bytes" -gt 0 ] 2>/dev/null; then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "0"
    fi
}

echo "Monitoring backup: $BACKUP_NAME"
echo ""

while true; do
    # Backup phase and timing
    PHASE=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
    START=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.startTimestamp}' 2>/dev/null)
    OPS_DONE=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.backupItemOperationsCompleted}' 2>/dev/null)
    OPS_TOTAL=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.backupItemOperationsAttempted}' 2>/dev/null)

    # CSI snapshot data uploads
    DU_JSON=$(kubectl get datauploads.velero.io -n velero -l "velero.io/backup-name=$BACKUP_NAME" -o json 2>/dev/null)
    DU_TOTAL=$(echo "$DU_JSON" | jq '.items | length')
    DU_DONE=$(echo "$DU_JSON" | jq '[.items[] | select(.status.phase=="Completed")] | length')
    DU_COMPLETED_BYTES=$(echo "$DU_JSON" | jq '[.items[] | select(.status.phase=="Completed") | (.status.progress.totalBytes // 0)] | add // 0')
    DU_INFLIGHT_DONE=$(echo "$DU_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.bytesDone // 0)] | add // 0')
    DU_INFLIGHT_TOTAL=$(echo "$DU_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.totalBytes // 0)] | add // 0')

    # Pod volume backups (Kopia fs-backup)
    PVB_JSON=$(kubectl get podvolumebackups.velero.io -n velero -l "velero.io/backup-name=$BACKUP_NAME" -o json 2>/dev/null)
    PVB_COUNT=$(echo "$PVB_JSON" | jq '.items | length')
    PVB_COMPLETED=$(echo "$PVB_JSON" | jq '[.items[] | select(.status.phase=="Completed")] | length')
    PVB_COMPLETED_BYTES=$(echo "$PVB_JSON" | jq '[.items[] | select(.status.phase=="Completed") | (.status.progress.totalBytes // 0)] | add // 0')
    PVB_INFLIGHT_DONE=$(echo "$PVB_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.bytesDone // 0)] | add // 0')
    PVB_INFLIGHT_TOTAL=$(echo "$PVB_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.totalBytes // 0)] | add // 0')
    PVB_DETAILS=$(echo "$PVB_JSON" | jq -r '.items[] | "\(.spec.volume) [\(.status.phase)]: \((.status.progress.bytesDone // 0) / 1073741824 * 10 | floor / 10) GB / \((.status.progress.totalBytes // 0) / 1073741824 * 10 | floor / 10) GB (\(if (.status.progress.totalBytes // 0) > 0 then ((.status.progress.bytesDone // 0) * 100 / .status.progress.totalBytes | floor) else 0 end)%)"' 2>/dev/null)

    # Totals
    TOTAL_UPLOADED=$(( DU_COMPLETED_BYTES + DU_INFLIGHT_DONE + PVB_COMPLETED_BYTES + PVB_INFLIGHT_DONE ))
    TOTAL_REMAINING=$(( DU_INFLIGHT_TOTAL - DU_INFLIGHT_DONE + PVB_INFLIGHT_TOTAL - PVB_INFLIGHT_DONE ))

    # Elapsed time
    ELAPSED=0
    ELAPSED_MIN=0
    ELAPSED_SEC=0
    if [ -n "$START" ]; then
        START_EPOCH=$(date -d "$START" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
        ELAPSED_MIN=$(( ELAPSED / 60 ))
        ELAPSED_SEC=$(( ELAPSED % 60 ))
    fi

    # Speed and ETA
    SPEED=""
    ETA=""
    if [ "$ELAPSED" -gt 0 ] && [ "$TOTAL_UPLOADED" -gt 0 ] 2>/dev/null; then
        SPEED_BPS=$(( TOTAL_UPLOADED / ELAPSED ))
        SPEED="$(fmt_size "$SPEED_BPS")/s"
        if [ "$SPEED_BPS" -gt 0 ] && [ "$TOTAL_REMAINING" -gt 0 ] 2>/dev/null; then
            ETA_SECS=$(( TOTAL_REMAINING / SPEED_BPS ))
            ETA_H=$(( ETA_SECS / 3600 ))
            ETA_M=$(( (ETA_SECS % 3600) / 60 ))
            ETA_S=$(( ETA_SECS % 60 ))
            ETA="ETA: ${ETA_H}h ${ETA_M}m ${ETA_S}s"
        fi
    fi

    # Display
    clear
    echo "=== Velero Backup: $BACKUP_NAME ==="
    echo "Phase: $PHASE | Elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    echo "Total uploaded: $(fmt_size "$TOTAL_UPLOADED")${SPEED:+ | Speed: $SPEED}${ETA:+ | $ETA}"
    echo ""
    echo "--- CSI Snapshot Uploads ($DU_DONE/$DU_TOTAL, $(fmt_size "$DU_COMPLETED_BYTES")) ---"
    if [ "$DU_INFLIGHT_TOTAL" -gt 0 ] 2>/dev/null; then
        DU_PCT=$(( DU_INFLIGHT_DONE * 100 / DU_INFLIGHT_TOTAL ))
        echo "  In-flight: $(fmt_size "$DU_INFLIGHT_DONE") / $(fmt_size "$DU_INFLIGHT_TOTAL") ($DU_PCT%)"
    fi
    echo ""
    echo "--- Kopia fs-backup ($PVB_COMPLETED/$PVB_COUNT, $(fmt_size "$PVB_COMPLETED_BYTES")) ---"
    if [ -n "$PVB_DETAILS" ]; then
        echo "$PVB_DETAILS" | while IFS= read -r line; do
            echo "  $line"
        done
    fi
    echo ""
    echo "--- Operations: ${OPS_DONE:-0}/${OPS_TOTAL:-?} ---"

    # Show errors/warnings if any
    ERRORS=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.errors}' 2>/dev/null)
    WARNINGS=$(kubectl get backups.velero.io -n velero "$BACKUP_NAME" -o jsonpath='{.status.warnings}' 2>/dev/null)
    if [ -n "$ERRORS" ] && [ "$ERRORS" != "0" ] || [ -n "$WARNINGS" ] && [ "$WARNINGS" != "0" ]; then
        echo ""
        [ -n "$ERRORS" ] && [ "$ERRORS" != "0" ] && echo "Errors: $ERRORS"
        [ -n "$WARNINGS" ] && [ "$WARNINGS" != "0" ] && echo "Warnings: $WARNINGS"
    fi

    # Check if everything is truly done (phase terminal AND no uploads still running)
    DU_INFLIGHT=$(echo "$DU_JSON" | jq '[.items[] | select(.status.phase=="InProgress" or .status.phase=="Accepted")] | length')
    PVB_INFLIGHT=$(echo "$PVB_JSON" | jq '[.items[] | select(.status.phase=="InProgress")] | length')

    if [ "$DU_INFLIGHT" -eq 0 ] && [ "$PVB_INFLIGHT" -eq 0 ] 2>/dev/null; then
        if [ "$PHASE" = "Completed" ] || [ "$PHASE" = "Failed" ] || [ "$PHASE" = "PartiallyFailed" ]; then
            echo ""
            echo "=== Backup $PHASE (all uploads finished) ==="
            exit 0
        fi
    fi

    sleep 10
done
