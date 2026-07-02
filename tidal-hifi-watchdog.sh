#!/usr/bin/env bash
#
# tidal-hifi-watchdog
# Preemptively restarts the com.mastermindzh.tidal-hifi Flatpak before its
# baked-in memory leak grows large enough to crash it. Shows a desktop
# notification countdown first, then kills and relaunches the app.
#
# All knobs can be overridden via environment variables (see the systemd unit).
#
set -uo pipefail

# ----- Configuration --------------------------------------------------------
APP_ID="${APP_ID:-com.mastermindzh.tidal-hifi}"
MEM_LIMIT_MB="${MEM_LIMIT_MB:-3000}"      # restart once memory crosses this
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"    # seconds between memory checks
WARN_SECONDS="${WARN_SECONDS:-30}"        # countdown length before restart
AUTO_RELAUNCH="${AUTO_RELAUNCH:-false}"   # relaunch if app exits on its own
NOTIFY="${NOTIFY:-true}"                  # desktop notifications on/off

NOTIFY_TAG="tidal-hifi-watchdog"
NOTI_ID=""

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

# ----- Launch helper (fully detached so the app outlives this watchdog) -----
launch_app() {
    if command -v setsid >/dev/null 2>&1; then
        setsid -f flatpak run "$APP_ID" >/dev/null 2>&1
    else
        nohup flatpak run "$APP_ID" >/dev/null 2>&1 &
    fi
}

# ----- Locate this app's Flatpak cgroup scope(s) ----------------------------
# Every process of the app (main + GPU + all renderer/utility helpers) lives in
# ONE systemd scope, so that scope's memory.current is the true, de-duplicated
# total — and it grows with the leak. This avoids picking a single stray PID.
app_scope_dirs() {
    # systemd escapes '-' inside the app id as '\x2d' in the scope/cgroup name
    # (e.g. tidal\x2dhifi). Turn each '-' in the id into a '*' glob so we match
    # the escaped form, the literal form, and '_' variants alike. Dots are kept
    # literal (they appear verbatim in the name).
    local pat="${APP_ID//-/\*}"
    find /sys/fs/cgroup -maxdepth 8 -type d -name '*flatpak*.scope' 2>/dev/null \
    | while IFS= read -r d; do
        case "${d##*/}" in
            *flatpak-$pat-[0-9]*.scope) printf '%s\n' "$d" ;;
        esac
      done
}

# ----- Is the app running? --------------------------------------------------
app_running() {
    [ -n "$(app_scope_dirs)" ] && return 0
    pgrep -x "${APP_ID##*.}" >/dev/null 2>&1
}

# ----- Total memory of the whole app, in bytes (echoed); fails => no output -
get_mem_bytes() {
    local total=0 d cur found=1

    # Preferred: sum memory.current across the app's cgroup scope(s).
    while IFS= read -r d; do
        [ -r "$d/memory.current" ] || continue
        cur=$(cat "$d/memory.current" 2>/dev/null) || continue
        total=$(( total + cur )); found=0
    done < <(app_scope_dirs)
    if [ "$found" -eq 0 ]; then printf '%s\n' "$total"; return 0; fi

    # Fallback (no scope found): sum PSS across the app's processes by name.
    # PSS counts shared pages once, so it won't over-count Electron helpers.
    local leaf pid pss self="$$"
    leaf="${APP_ID##*.}"
    while IFS= read -r pid; do
        [ "$pid" = "$self" ] && continue
        pss=$(awk '/^Pss:/ { s += $2 } END { print s+0 }' \
              "/proc/$pid/smaps_rollup" 2>/dev/null)
        if [ -z "$pss" ] || [ "$pss" = "0" ]; then
            pss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
        fi
        [ -n "$pss" ] && total=$(( total + pss * 1024 ))
    done < <(pgrep -x "$leaf" 2>/dev/null | sort -u)
    [ "$total" -gt 0 ] && { printf '%s\n' "$total"; return 0; }
    return 1
}

# ----- Desktop notification (updates one notification in place) -------------
notify() {
    [ "$NOTIFY" = true ] || return 0
    local title="$1" body="$2" out
    if [[ "$NOTI_ID" =~ ^[0-9]+$ ]]; then
        notify-send -a "Tidal Watchdog" -u critical -t 7000 -r "$NOTI_ID" \
            -h "string:x-canonical-private-synchronous:$NOTIFY_TAG" \
            "$title" "$body" 2>/dev/null || true
    else
        out=$(notify-send -p -a "Tidal Watchdog" -u critical -t 7000 \
            -h "string:x-canonical-private-synchronous:$NOTIFY_TAG" \
            "$title" "$body" 2>/dev/null) || true
        NOTI_ID="$out"
    fi
}

# ----- The warn -> kill -> relaunch cycle -----------------------------------
restart_app() {
    log "Memory limit reached — warning user, then restarting."
    local remaining="$WARN_SECONDS" step
    while [ "$remaining" -gt 0 ]; do
        notify "Tidal Hi-Fi will restart" \
                "Clearing the memory leak in ${remaining}s…"
        if [ "$remaining" -le 5 ]; then step=1; else step=5; fi
        sleep "$step"
        remaining=$(( remaining - step ))
    done
    notify "Restarting Tidal Hi-Fi" "Clearing memory now."

    flatpak kill "$APP_ID" 2>/dev/null || true
    sleep 2
    if app_running; then                       # still alive? force it.
        pkill -TERM -x "${APP_ID##*.}" 2>/dev/null || true
        sleep 2
    fi

    launch_app
    log "Relaunched $APP_ID."
    NOTI_ID=""                                 # fresh notification next time
    sleep "$CHECK_INTERVAL"                     # let it boot before measuring
}

# ----- Main loop ------------------------------------------------------------
log "Watchdog started for $APP_ID (limit ${MEM_LIMIT_MB} MB, warn ${WARN_SECONDS}s)."
while true; do
    if app_running; then
        if bytes=$(get_mem_bytes); then
            mb=$(( bytes / 1024 / 1024 ))
            log "Memory: ${mb} MB"
            [ "$mb" -ge "$MEM_LIMIT_MB" ] && restart_app
        else
            log "Running, but could not read memory."
        fi
    else
        log "$APP_ID not running."
        if [ "$AUTO_RELAUNCH" = true ]; then
            log "Auto-relaunching."
            launch_app
            sleep "$CHECK_INTERVAL"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
