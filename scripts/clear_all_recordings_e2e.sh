#!/usr/bin/env bash
set -euo pipefail
OUT="${1:-/tmp/rn-e2e}"
CHILD="emulator-5554"
PARENT="emulator-5556"
PKG="ru.ilvex.radionanny"
log(){ printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/e2e.log"; }
adb_s(){ adb -s "$1" "${@:2}"; }
dump_ui(){ local s="$1" f="/tmp/ui_clear_${1}.xml"; adb_s "$s" shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || true; adb_s "$s" exec-out cat /sdcard/window.xml > "$f" 2>/dev/null || true; test -s "$f"; }
has_text(){ local s="$1" q="$2"; dump_ui "$s" >/dev/null; python3 - "/tmp/ui_clear_${s}.xml" "$q" <<'PY'
import sys,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot(); q=sys.argv[2].casefold()
raise SystemExit(0 if any(q in (n.attrib.get('text','')+' '+n.attrib.get('content-desc','')).casefold() for n in root.iter('node')) else 1)
PY
}
center(){ local s="$1" q="$2"; dump_ui "$s" >/dev/null; python3 - "/tmp/ui_clear_${s}.xml" "$q" <<'PY'
import sys,re,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot(); q=sys.argv[2].casefold(); found=[]
for n in root.iter('node'):
    if q not in (n.attrib.get('text','')+' '+n.attrib.get('content-desc','')).casefold(): continue
    m=re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',n.attrib.get('bounds',''))
    if m:
        x1,y1,x2,y2=map(int,m.groups()); found.append(((x1+x2)//2,(y1+y2)//2))
if not found: raise SystemExit(2)
print(*found[-1])
PY
}
tap_visible(){ local s="$1" q="$2" xy; xy=$(center "$s" "$q"); adb_s "$s" shell input tap $xy; sleep 1; }
wait_text(){ local s="$1" q="$2" timeout="${3:-45}" start=$(date +%s); while (( $(date +%s)-start < timeout )); do has_text "$s" "$q" && return 0; sleep 1; done; return 1; }
scroll_until(){ local s="$1" q="$2"; for _ in $(seq 1 14); do if has_text "$s" "$q"; then return 0; fi; adb_s "$s" shell input swipe 500 1500 500 450 350; sleep .5; done; return 1; }
version_code(){ adb_s "$1" shell dumpsys package "$PKG" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1 | tr -d '\r'; }

log "Clear-all E2E: verify both phones are v0.17.8"
[[ "$(version_code "$CHILD")" == "27" ]]
[[ "$(version_code "$PARENT")" == "27" ]]

log "Create orphan/private-folder leftovers to prove folder-level purge"
adb_s "$CHILD" shell run-as "$PKG" sh -c 'mkdir -p files/recordings; printf orphan > files/recordings/orphan.mp3.part; printf junk > files/recordings/orphan.tmp'
before=$(adb_s "$CHILD" shell run-as "$PKG" sh -c 'find files/recordings -maxdepth 1 -type f | wc -l' | tr -d '\r ')
(( before >= 3 ))
log "Child private recording folder contains $before files before purge"

adb_s "$PARENT" shell am force-stop "$PKG" || true
adb_s "$PARENT" shell am start -W -n "$PKG/.MainActivity" >/dev/null
wait_text "$PARENT" "ТЕЛЕФОН РОДИТЕЛЯ" 45
scroll_until "$PARENT" "Удалить все записи с телефона ребёнка"
tap_visible "$PARENT" "Удалить все записи с телефона ребёнка"
wait_text "$PARENT" "Удалить ВСЕ записи?" 20
tap_visible "$PARENT" "Удалить все"

log "Wait for persistent delete_all_recordings command to reach child"
start=$(date +%s)
while (( $(date +%s)-start < 75 )); do
  left=$(adb_s "$CHILD" shell run-as "$PKG" sh -c 'find files/recordings -maxdepth 1 -type f | wc -l' 2>/dev/null | tr -d '\r ' || echo 999)
  [[ "$left" == "0" ]] && break
  sleep 2
done
left=$(adb_s "$CHILD" shell run-as "$PKG" sh -c 'find files/recordings -maxdepth 1 -type f | wc -l' | tr -d '\r ')
[[ "$left" == "0" ]]
log "Child private recording folder is physically empty"

adb_s "$PARENT" shell am force-stop "$PKG" || true
adb_s "$PARENT" shell am start -W -n "$PKG/.MainActivity" >/dev/null
wait_text "$PARENT" "ТЕЛЕФОН РОДИТЕЛЯ" 45
for _ in $(seq 1 8); do
  if has_text "$PARENT" "Записей пока нет."; then break; fi
  adb_s "$PARENT" shell input swipe 500 1450 500 500 300 || true
  sleep 2
done
wait_text "$PARENT" "Записей пока нет." 30
adb_s "$PARENT" exec-out screencap -p > "$OUT/16_parent_archive_after_clear_all.png" || true
adb_s "$CHILD" exec-out screencap -p > "$OUT/17_child_after_clear_all.png" || true
log "CLEAR_ALL_RECORDINGS_E2E=PASS"
