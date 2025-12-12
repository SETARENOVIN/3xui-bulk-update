#!/usr/bin/env bash
set -euo pipefail

# 3xui-bulk-update.sh (short, user-friendly)
# - Single PANEL_URL (base path), ex: https://example.com:2053/path
# - Progress + ETA (no per-client logs)
# - Modes: expiry / traffic / both
# - Filters: only enabled, expiring within X days, email regex
# - CSV output (minimal)
# - Auto retry/backoff on "database is locked"

# --- fixed defaults (not prompted) ---
CURL_RETRY=2
CURL_TIMEOUT=20
LOCK_RETRY_MAX=6
LOCK_RETRY_BASE_SLEEP=1
INSECURE_TLS_DEFAULT="y"

# --- helpers ---
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need curl; need jq; need awk; need base64; need grep

read_default(){ local p="$1" d="$2" __v="$3"; local v; read -r -p "$p [$d]: " v; v="${v:-$d}"; printf -v "$__v" "%s" "$v"; }
read_secret(){ local p="$1" __v="$2"; local v; read -r -s -p "$p: " v; echo; printf -v "$__v" "%s" "$v"; }
trim_slash(){ local s="$1"; while [[ "$s" == */ ]]; do s="${s%/}"; done; printf "%s" "$s"; }
now_ms(){ echo $(( $(date +%s) * 1000 )); }
ms_days(){ echo $(( $1 * 86400000 )); }
bytes_gb(){ echo $(( $1 * 1024 * 1024 * 1024 )); }
gb_bytes(){ awk -v b="$1" 'BEGIN{printf "%.2f", b/1024/1024/1024}'; }
csvq(){ local s="$1"; s="${s//\"/\"\"}"; printf "\"%s\"" "$s"; }
fmt_hms(){ local s="$1"; ((s<0)) && s=0; printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60)); }

COOKIE_JAR="$(mktemp)"; trap 'rm -f "$COOKIE_JAR"' EXIT

api_call(){
  local method="$1" url="$2" body="${3:-}"
  local resp http rc
  if [[ -n "$body" ]]; then
    set +e
    resp=$(curl -sS ${CURL_INSECURE:-} \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$CURL_RETRY" --retry-delay 1 --max-time "$CURL_TIMEOUT" \
      -X "$method" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" -d "$body" \
      -w "\n%{http_code}" "$url")
    rc=$?
    set -e
  else
    set +e
    resp=$(curl -sS ${CURL_INSECURE:-} \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$CURL_RETRY" --retry-delay 1 --max-time "$CURL_TIMEOUT" \
      -X "$method" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -w "\n%{http_code}" "$url")
    rc=$?
    set -e
  fi
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
  echo "$rc" > /tmp/.xui_rc; echo "$http" > /tmp/.xui_http
  echo "$resp"
}

json_success(){ echo "$1" | jq -e '.success==true' >/dev/null 2>&1; }
json_msg(){ echo "$1" | jq -r '.msg // .message // empty' 2>/dev/null || true; }

# --- prompts (minimal) ---
echo "=== 3x-ui Bulk Update (Progress+ETA) ==="
read_default "PANEL_URL" "https://example.com:2053/panelpath" PANEL_URL
PANEL_URL="$(trim_slash "$PANEL_URL")"

read_default "INSECURE_TLS (y/n)" "$INSECURE_TLS_DEFAULT" INSECURE_TLS
CURL_INSECURE=""
[[ "$INSECURE_TLS" =~ ^[Yy]$ ]] && CURL_INSECURE="-k"

read_default "USERNAME" "admin" USERNAME
read_secret  "PASSWORD" PASSWORD

read_default "HAS_2FA (y/n)" "n" HAS_2FA
TWOFA=""
[[ "$HAS_2FA" =~ ^[Yy]$ ]] && read_default "TWO_FACTOR_CODE" "" TWOFA

echo "MODE: 1=EXPIRY  2=TRAFFIC  3=BOTH"
read_default "MODE" "1" MODE

ADD_DAYS=0; ADD_GB=0
NOEXP="skip"; NOQUOTA="skip"
if [[ "$MODE" == "1" || "$MODE" == "3" ]]; then
  read_default "ADD_DAYS" "1" ADD_DAYS
  read_default "NOEXP (skip/setFromNow)" "skip" NOEXP
fi
if [[ "$MODE" == "2" || "$MODE" == "3" ]]; then
  read_default "ADD_GB" "10" ADD_GB
  read_default "NOQUOTA (skip/setLimit)" "skip" NOQUOTA
fi

read_default "ONLY_ENABLED (y/n)" "y" ONLY_ENABLED
read_default "EXPIRE_WITHIN_DAYS (0=all)" "0" WITHIN
read_default "EMAIL_REGEX (empty=all)" "" EMAIL_RE
read_default "CSV_PATH" "./report.csv" CSV

# --- CSV (minimal) ---
echo "timestamp,inboundId,email,status,message" > "$CSV"

# --- login (try /login and /login/) ---
LOGIN_PAYLOAD=$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" --arg tf "$TWOFA" \
  'if ($tf|length)>0 then {username:$u,password:$p,twoFactorCode:$tf} else {username:$u,password:$p} end')

echo "INFO: Login..."
BODY="$(api_call POST "${PANEL_URL}/login" "$LOGIN_PAYLOAD")"
HTTP="$(cat /tmp/.xui_http)"; RC="$(cat /tmp/.xui_rc)"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  BODY="$(api_call POST "${PANEL_URL}/login/" "$LOGIN_PAYLOAD")"
  HTTP="$(cat /tmp/.xui_http)"; RC="$(cat /tmp/.xui_rc)"
fi
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  echo "FAIL: Login (rc=$RC http=$HTTP)"; echo "$BODY"; exit 1
fi

# --- list inbounds ---
LIST="$(api_call GET "${PANEL_URL}/panel/api/inbounds/list")"
HTTP="$(cat /tmp/.xui_http)"; RC="$(cat /tmp/.xui_rc)"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  echo "FAIL: inbounds/list (rc=$RC http=$HTTP)"; echo "$LIST"; exit 1
fi
ARR="$(echo "$LIST" | jq -c 'if type=="array" then . else .obj end')"
N="$(echo "$ARR" | jq 'length')"
((N>0)) || { echo "No inbounds."; exit 1; }

echo "=== INBOUNDS ($N) ==="
echo "$ARR" | jq -r 'to_entries[] | "\(.key+1)) id=\(.value.id) remark=\(.value.remark//"-") protocol=\(.value.protocol//"-") port=\(.value.port//"-")"'
read_default "Select inbound number" "1" PICK
IDX=$((PICK-1))
INB_ID="$(echo "$ARR" | jq -r --argjson i "$IDX" '.[$i].id')"
[[ -n "$INB_ID" && "$INB_ID" != "null" ]] || { echo "Invalid inbound."; exit 1; }

# --- get inbound ---
INB="$(api_call GET "${PANEL_URL}/panel/api/inbounds/get/${INB_ID}")"
HTTP="$(cat /tmp/.xui_http)"; RC="$(cat /tmp/.xui_rc)"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  echo "FAIL: inbounds/get (rc=$RC http=$HTTP)"; echo "$INB"; exit 1
fi

SETTINGS="$(echo "$INB" | jq -r '.obj.settings')"
[[ -n "$SETTINGS" && "$SETTINGS" != "null" ]] || { echo "Missing settings."; exit 1; }

mapfile -t CLIENTS < <(echo "$SETTINGS" | jq -r 'fromjson | .clients[]? | @base64')
TOTAL="${#CLIENTS[@]}"
((TOTAL>0)) || { echo "No clients in inbound."; exit 0; }

NOW="$(now_ms)"
ADDMS="$(ms_days "$ADD_DAYS")"
ADDBYTES="$(bytes_gb "$ADD_GB")"
WINMS="$(ms_days "$WITHIN")"

UPDATED=0; SKIPPED=0; FAILED=0; DONE=0
START="$(date +%s)"; LAST=0

progress(){
  local force="${1:-0}" now elapsed pct eta="--:--:--"
  now="$(date +%s)"; elapsed=$((now-START))
  pct=$(( (DONE*100)/TOTAL ))
  if ((DONE>0 && elapsed>0)); then
    eta="$(fmt_hms $(( (elapsed*(TOTAL-DONE))/DONE )) )"
  fi
  if ((force==0)); then
    ((now>LAST)) || return 0
    LAST="$now"
  fi
  printf "\rProgress: %3d%% (%d/%d) | OK:%d FAIL:%d SKIP:%d | ETA:%s" "$pct" "$DONE" "$TOTAL" "$UPDATED" "$FAILED" "$SKIPPED" "$eta"
}

progress 1

for b in "${CLIENTS[@]}"; do
  c="$(echo "$b" | base64 -d)"
  email="$(echo "$c" | jq -r '.email // ""')"
  enable="$(echo "$c" | jq -r '.enable // true')"

  if [[ "$ONLY_ENABLED" =~ ^[Yy]$ ]] && [[ "$enable" != "true" ]]; then
    SKIPPED=$((SKIPPED+1)); DONE=$((DONE+1)); progress; continue
  fi
  if [[ -n "$EMAIL_RE" ]] && ! echo "$email" | grep -Eiq "$EMAIL_RE"; then
    SKIPPED=$((SKIPPED+1)); DONE=$((DONE+1)); progress; continue
  fi

  client_id="$(echo "$c" | jq -r '.id // empty')"
  [[ -z "$client_id" ]] && client_id="$(echo "$c" | jq -r '.password // empty')"
  [[ -z "$client_id" ]] && client_id="$email"

  old_exp="$(echo "$c" | jq -r '.expiryTime // 0')"
  old_tot="$(echo "$c" | jq -r '.totalGB // 0')"

  # within filter
  if ((WITHIN>0 && old_exp!=0)); then
    if (( old_exp > NOW + WINMS )); then
      SKIPPED=$((SKIPPED+1)); DONE=$((DONE+1)); progress; continue
    fi
  fi

  new_exp="$old_exp"; new_tot="$old_tot"

  if [[ "$MODE" == "1" || "$MODE" == "3" ]]; then
    if ((old_exp==0)); then
      [[ "$NOEXP" == "setFromNow" ]] && new_exp=$((NOW + ADDMS))
    else
      new_exp=$((old_exp + ADDMS))
    fi
  fi

  if [[ "$MODE" == "2" || "$MODE" == "3" ]]; then
    if ((old_tot==0)); then
      [[ "$NOQUOTA" == "setLimit" ]] && new_tot="$ADDBYTES"
    else
      new_tot=$((old_tot + ADDBYTES))
    fi
  fi

  if ((new_exp==old_exp && new_tot==old_tot)); then
    SKIPPED=$((SKIPPED+1)); DONE=$((DONE+1)); progress; continue
  fi

  new_client="$c"
  ((new_exp!=old_exp)) && new_client="$(echo "$new_client" | jq --argjson v "$new_exp" '.expiryTime=$v')"
  ((new_tot!=old_tot)) && new_client="$(echo "$new_client" | jq --argjson v "$new_tot" '.totalGB=$v')"

  settings_obj="$(jq -n --argjson cl "$new_client" '{clients:[$cl]}')"
  settings_str="$(echo "$settings_obj" | jq -c '.')"
  payload="$(jq -n --argjson id "$INB_ID" --arg settings "$settings_str" '{id:$id,settings:$settings}')"

  # retry on "database is locked"
  attempt=0; status="FAIL"; msg=""
  while true; do
    resp="$(api_call POST "${PANEL_URL}/panel/api/inbounds/updateClient/${client_id}" "$payload")"
    http="$(cat /tmp/.xui_http)"; rc="$(cat /tmp/.xui_rc)"
    mt="$(json_msg "$resp")"

    if echo "$resp" | grep -qi "database is locked" || echo "$mt" | grep -qi "database is locked"; then
      attempt=$((attempt+1))
      if ((attempt>LOCK_RETRY_MAX)); then
        msg="database is locked (gave up)"; break
      fi
      sleep $(( LOCK_RETRY_BASE_SLEEP * (2 ** (attempt-1)) ))
      continue
    fi

    if ((rc!=0)); then
      msg="curl_rc=$rc"
    elif ((http<200 || http>=300)); then
      msg="http=$http"
    else
      if json_success "$resp"; then
        status="OK"
      else
        msg="${mt:-unexpected response}"
      fi
    fi
    break
  done

  ts="$(date -Iseconds)"
  echo "$(csvq "$ts"),$INB_ID,$(csvq "$email"),$status,$(csvq "$msg")" >> "$CSV"

  if [[ "$status" == "OK" ]]; then
    UPDATED=$((UPDATED+1))
  else
    FAILED=$((FAILED+1))
  fi

  DONE=$((DONE+1))
  progress
done

progress 1
echo; echo
echo "=== SUMMARY ==="
echo "TOTAL  : $TOTAL"
echo "OK     : $UPDATED"
echo "SKIP   : $SKIPPED"
echo "FAIL   : $FAILED"
echo "CSV    : $CSV"
