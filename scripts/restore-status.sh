#!/bin/bash
# Monitor Velero restore progress
# Usage: ./restore-status.sh [restore-name]
#   If no restore name given, monitors the latest restore.

set -e

RESTORE_NAME="${1:-}"

if [ -z "$RESTORE_NAME" ]; then
    RESTORE_NAME=$(kubectl get restores.velero.io -n velero --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
fi

if [ -z "$RESTORE_NAME" ]; then
    echo "No restores found"
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

echo "Monitoring restore: $RESTORE_NAME"
echo ""

while true; do
    PHASE=$(kubectl get restores.velero.io -n velero "$RESTORE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
    START=$(kubectl get restores.velero.io -n velero "$RESTORE_NAME" -o jsonpath='{.status.startTimestamp}' 2>/dev/null)
    ERRORS=$(kubectl get restores.velero.io -n velero "$RESTORE_NAME" -o jsonpath='{.status.errors}' 2>/dev/null)
    WARNINGS=$(kubectl get restores.velero.io -n velero "$RESTORE_NAME" -o jsonpath='{.status.warnings}' 2>/dev/null)

    # Data downloads (CSI snapshot restores)
    DD_JSON=$(kubectl get datadownloads.velero.io -n velero -l "velero.io/restore-name=$RESTORE_NAME" -o json 2>/dev/null)
    DD_TOTAL=$(echo "$DD_JSON" | jq '.items | length')
    DD_DONE=$(echo "$DD_JSON" | jq '[.items[] | select(.status.phase=="Completed")] | length')
    DD_COMPLETED_BYTES=$(echo "$DD_JSON" | jq '[.items[] | select(.status.phase=="Completed") | (.status.progress.totalBytes // 0)] | add // 0')
    DD_INFLIGHT_DONE=$(echo "$DD_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.bytesDone // 0)] | add // 0')
    DD_INFLIGHT_TOTAL=$(echo "$DD_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.totalBytes // 0)] | add // 0')

    # Pod volume restores (Kopia fs-restore)
    PVR_JSON=$(kubectl get podvolumerestores.velero.io -n velero -l "velero.io/restore-name=$RESTORE_NAME" -o json 2>/dev/null)
    PVR_COUNT=$(echo "$PVR_JSON" | jq '.items | length')
    PVR_COMPLETED=$(echo "$PVR_JSON" | jq '[.items[] | select(.status.phase=="Completed")] | length')
    PVR_COMPLETED_BYTES=$(echo "$PVR_JSON" | jq '[.items[] | select(.status.phase=="Completed") | (.status.progress.totalBytes // 0)] | add // 0')
    PVR_INFLIGHT_DONE=$(echo "$PVR_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.bytesDone // 0)] | add // 0')
    PVR_INFLIGHT_TOTAL=$(echo "$PVR_JSON" | jq '[.items[] | select(.status.phase=="InProgress") | (.status.progress.totalBytes // 0)] | add // 0')
    PVR_DETAILS=$(echo "$PVR_JSON" | jq -r '.items[] | "\(.spec.volume) [\(.status.phase)]: \((.status.progress.bytesDone // 0) / 1073741824 * 10 | floor / 10) GB / \((.status.progress.totalBytes // 0) / 1073741824 * 10 | floor / 10) GB (\(if (.status.progress.totalBytes // 0) > 0 then ((.status.progress.bytesDone // 0) * 100 / .status.progress.totalBytes | floor) else 0 end)%)"' 2>/dev/null)

    # PVCs
    PVC_TOTAL=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
    PVC_BOUND=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c Bound || echo 0)
    PVC_PENDING=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c Pending || echo 0)

    # Totals
    TOTAL_DOWNLOADED=$(( DD_COMPLETED_BYTES + DD_INFLIGHT_DONE + PVR_COMPLETED_BYTES + PVR_INFLIGHT_DONE ))
    TOTAL_REMAINING=$(( DD_INFLIGHT_TOTAL - DD_INFLIGHT_DONE + PVR_INFLIGHT_TOTAL - PVR_INFLIGHT_DONE ))

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
    if [ "$ELAPSED" -gt 0 ] && [ "$TOTAL_DOWNLOADED" -gt 0 ] 2>/dev/null; then
        SPEED_BPS=$(( TOTAL_DOWNLOADED / ELAPSED ))
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
    echo "=== Velero Restore: $RESTORE_NAME ==="
    echo "Phase: $PHASE | Elapsed: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    echo "Total downloaded: $(fmt_size "$TOTAL_DOWNLOADED")${SPEED:+ | Speed: $SPEED}${ETA:+ | $ETA}"
    echo ""
    echo "--- PVCs: $PVC_BOUND bound, $PVC_PENDING pending ($PVC_TOTAL total) ---"
    echo ""
    echo "--- CSI Snapshot Downloads ($DD_DONE/$DD_TOTAL, $(fmt_size "$DD_COMPLETED_BYTES")) ---"
    if [ "$DD_INFLIGHT_TOTAL" -gt 0 ] 2>/dev/null; then
        DD_PCT=$(( DD_INFLIGHT_DONE * 100 / DD_INFLIGHT_TOTAL ))
        echo "  In-flight: $(fmt_size "$DD_INFLIGHT_DONE") / $(fmt_size "$DD_INFLIGHT_TOTAL") ($DD_PCT%)"
    fi
    echo ""
    echo "--- Kopia fs-restore ($PVR_COMPLETED/$PVR_COUNT, $(fmt_size "$PVR_COMPLETED_BYTES")) ---"
    if [ -n "$PVR_DETAILS" ]; then
        echo "$PVR_DETAILS" | while IFS= read -r line; do
            echo "  $line"
        done
    fi
    echo ""
    if [ -n "$ERRORS" ] && [ "$ERRORS" != "0" ]; then
        echo "Errors: $ERRORS"
    fi
    if [ -n "$WARNINGS" ] && [ "$WARNINGS" != "0" ]; then
        echo "Warnings: $WARNINGS"
    fi

    # Check if done
    DD_INFLIGHT=$(echo "$DD_JSON" | jq '[.items[] | select(.status.phase=="InProgress" or .status.phase=="Accepted" or .status.phase=="New")] | length')
    PVR_INFLIGHT=$(echo "$PVR_JSON" | jq '[.items[] | select(.status.phase=="InProgress" or .status.phase=="New")] | length')

    if [ "$DD_INFLIGHT" -eq 0 ] && [ "$PVR_INFLIGHT" -eq 0 ] 2>/dev/null; then
        if [ "$PHASE" = "Completed" ] || [ "$PHASE" = "Failed" ] || [ "$PHASE" = "PartiallyFailed" ]; then
            echo ""
            echo "=== Restore $PHASE (all downloads finished) ==="
            exit 0
        fi
    fi

    sleep 10
done
