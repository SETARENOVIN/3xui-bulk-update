#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# 3xui-bulk-update.sh
# - PANEL_URL required (no default). Example:
#   https://panel.example.com:2053/network/aaa
# - Select inbound from list
# - Operation menu (3 lines): Expiry / Traffic / Both
# - Filters: ONLY_ENABLED, EXPIRE_WITHIN_DAYS, EMAIL_REGEX
# - Progress + ETA only (no per-client logs)
# - No CSV
# - settings can be string OR object
# - Auto retry/backoff on "database is locked"
# ==========================================================

# -------- fixed defaults (not prompted) --------
CURL_RETRY=2
CURL_TIMEOUT=20
LOCK_RETRY_MAX=6
LOCK_RETRY_BASE_SLEEP=1
INSECURE_TLS_DEFAULT="y"

# -------- deps --------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need curl; need jq; need awk; need base64; need grep

# -------- helpers --------
read_required() {
  local prompt="$1" __var="$2" val
  while true; do
    read -r -p "$prompt: " val
    if [[ -n "$val" ]]; then
      printf -v "$__var" "%s" "$val"
      return 0
    fi
    echo "This value is required."
  done
}

read_default(){
  local p="$1" d="$2" __v="$3" v
  read -r -p "$p [$d]: " v
  v="${v:-$d}"
  printf -v "$__v" "%s" "$v"
}

read_secret(){
  local p="$1" __v="$2" v
  read -r -s -p "$p: " v
  echo
  printf -v "$__v" "%s" "$v"
}

trim_slash(){ local s="$1"; while [[ "$s" == */ ]]; do s="${s%/}"; done; printf "%s" "$s"; }
now_ms(){ echo $(( $(date +%s) * 1000 )); }
ms_days(){ echo $(( $1 * 86400000 )); }
bytes_gb(){ echo $(( $1 * 1024 * 1024 * 1024 )); }

fmt_hms(){
  local s="$1"
  ((s<0)) && s=0
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

json_success(){ echo "$1" | jq -e '.success==true' >/dev/null 2>&1; }
json_msg(){ echo "$1" | jq -r '.msg // .message // empty' 2>/dev/null || true; }

# -------- temp/session --------
COOKIE_JAR="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$COOKIE_JAR"; rm -rf "$TMP_DIR"' EXIT

HTTP_FILE="$TMP_DIR/http"
RC_FILE="$TMP_DIR/rc"

# -------- HTTP wrapper (writes http/rc to temp files) --------
api_call(){
  # api_call METHOD URL [JSON_BODY]
  local method="$1" url="$2" body="${3:-}"
  local resp rc http

  if [[ -n "$body" ]]; then
    set +e
    resp=$(curl -sS ${CURL_INSECURE:-} \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$CURL_RETRY" --retry-delay 1 --max-time "$CURL_TIMEOUT" \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -d "$body" \
      -w "\n%{http_code}" \
      "$url")
    rc=$?
    set -e
  else
    set +e
    resp=$(curl -sS ${CURL_INSECURE:-} \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$CURL_RETRY" --retry-delay 1 --max-time "$CURL_TIMEOUT" \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -w "\n%{http_code}" \
      "$url")
    rc=$?
    set -e
  fi

  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  echo "$http" > "$HTTP_FILE"
  echo "$rc"   > "$RC_FILE"

  printf "%s" "$resp"
}

# -------- prompts --------
echo "=== 3x-ui Bulk Update (Progress + ETA) ==="
echo

read_required "PANEL_URL (e.g. https://example.com:2053/path)" PANEL_URL
PANEL_URL="$(trim_slash "$PANEL_URL")"

read_default "INSECURE_TLS (y/n)" "$INSECURE_TLS_DEFAULT" INSECURE_TLS
CURL_INSECURE=""
[[ "$INSECURE_TLS" =~ ^[Yy]$ ]] && CURL_INSECURE="-k"

read_default "USERNAME" "admin" USERNAME
read_secret  "PASSWORD" PASSWORD

read_default "HAS_2FA (y/n)" "n" HAS_2FA
TWOFA=""
if [[ "$HAS_2FA" =~ ^[Yy]$ ]]; then
  read_default "TWO_FACTOR_CODE" "" TWOFA
fi

echo
echo "OPERATION_MODE:"
echo "  1) EXPIRY_ONLY (add days)"
echo "  2) TRAFFIC_ONLY (add GB)"
echo "  3) BOTH (expiry + traffic)"
read_default "Choose (1/2/3)" "1" MODE

ADD_DAYS=0
ADD_GB=0
NOEXP="skip"       # skip | setFromNow
NOQUOTA="skip"     # skip | setLimit

if [[ "$MODE" == "1" || "$MODE" == "3" ]]; then
  read_default "ADD_DAYS (integer)" "1" ADD_DAYS
  read_default "NOEXP_BEHAVIOR (skip/setFromNow)" "skip" NOEXP
fi
if [[ "$MODE" == "2" || "$MODE" == "3" ]]; then
  read_default "ADD_GB (integer)" "10" ADD_GB
  read_default "NOQUOTA_BEHAVIOR (skip/setLimit)" "skip" NOQUOTA
fi

echo
read_default "ONLY_ENABLED (y/n)" "y" ONLY_ENABLED
read_default "EXPIRE_WITHIN_DAYS (0=all)" "0" WITHIN_DAYS
read_default "EMAIL_REGEX (empty=all)" "" EMAIL_RE

# -------- login (try /login and /login/) --------
LOGIN_PAYLOAD=$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" --arg tf "$TWOFA" \
  'if ($tf|length)>0 then {username:$u,password:$p,twoFactorCode:$tf} else {username:$u,password:$p} end')

echo
echo "INFO: Logging in..."
BODY="$(api_call POST "${PANEL_URL}/login" "$LOGIN_PAYLOAD")"
HTTP="$(cat "$HTTP_FILE")"; RC="$(cat "$RC_FILE")"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  BODY="$(api_call POST "${PANEL_URL}/login/" "$LOGIN_PAYLOAD")"
  HTTP="$(cat "$HTTP_FILE")"; RC="$(cat "$RC_FILE")"
fi

# If body says success:true, treat as OK even if proxy gives odd code
if ! { [[ "$RC" == "0" && "$HTTP" -ge 200 && "$HTTP" -lt 300 ]]; } ; then
  if echo "$BODY" | jq -e '.success==true' >/dev/null 2>&1; then
    echo "WARN: Login http/rc looked odd (rc=$RC http=$HTTP) but success=true. Continuing..."
  else
    echo "FAIL: Login failed (curl_rc=$RC http=$HTTP)"
    echo "FAIL: Response: $BODY"
    exit 1
  fi
fi

# -------- list inbounds --------
LIST="$(api_call GET "${PANEL_URL}/panel/api/inbounds/list")"
HTTP="$(cat "$HTTP_FILE")"; RC="$(cat "$RC_FILE")"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  echo "FAIL: inbounds/list (curl_rc=$RC http=$HTTP)"
  echo "FAIL: Response: $LIST"
  exit 1
fi

ARR="$(echo "$LIST" | jq -c 'if type=="array" then . else .obj end')"
N="$(echo "$ARR" | jq 'length')"
((N>0)) || { echo "No inbounds found."; exit 1; }

echo
echo "=== INBOUNDS ($N) ==="
echo "$ARR" | jq -r 'to_entries[] | "\(.key+1)) id=\(.value.id) | remark=\(.value.remark//"-") | protocol=\(.value.protocol//"-") | port=\(.value.port//"-")"'
read_default "Select inbound number" "1" PICK
IDX=$((PICK-1))
INB_ID="$(echo "$ARR" | jq -r --argjson i "$IDX" '.[$i].id')"
[[ -n "$INB_ID" && "$INB_ID" != "null" ]] || { echo "Invalid inbound selection."; exit 1; }

# -------- get inbound --------
INB="$(api_call GET "${PANEL_URL}/panel/api/inbounds/get/${INB_ID}")"
HTTP="$(cat "$HTTP_FILE")"; RC="$(cat "$RC_FILE")"
if [[ "$RC" != "0" || "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
  echo "FAIL: inbounds/get (curl_rc=$RC http=$HTTP)"
  echo "FAIL: Response: $INB"
  exit 1
fi

# Parse clients from settings (string OR object)
mapfile -t CLIENTS < <(
  echo "$INB" | jq -r '
    .obj.settings
    | (try fromjson catch .)
    | .clients[]? | @base64
  '
)

TOTAL="${#CLIENTS[@]}"
((TOTAL>0)) || { echo "No clients in inbound."; exit 0; }

# -------- derived --------
NOW="$(now_ms)"
ADDMS="$(ms_days "$ADD_DAYS")"
ADDBYTES="$(bytes_gb "$ADD_GB")"
WINMS="$(ms_days "$WITHIN_DAYS")"

OKN=0
SKIPN=0
FAILN=0
DONE=0

ERROR_SAMPLE=()
ERROR_SAMPLE_MAX=5

START="$(date +%s)"
LAST=0

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
  printf "\rProgress: %3d%% (%d/%d) | OK:%d FAIL:%d SKIP:%d | ETA:%s" \
    "$pct" "$DONE" "$TOTAL" "$OKN" "$FAILN" "$SKIPN" "$eta"
}

echo
progress 1

# -------- loop --------
for b64 in "${CLIENTS[@]}"; do
  c="$(echo "$b64" | base64 -d)"

  email="$(echo "$c" | jq -r '.email // ""')"
  enable="$(echo "$c" | jq -r '.enable // true')"

  # Filters
  if [[ "$ONLY_ENABLED" =~ ^[Yy]$ ]] && [[ "$enable" != "true" ]]; then
    SKIPN=$((SKIPN+1)); DONE=$((DONE+1)); progress; continue
  fi
  if [[ -n "$EMAIL_RE" ]] && ! echo "$email" | grep -Eiq "$EMAIL_RE"; then
    SKIPN=$((SKIPN+1)); DONE=$((DONE+1)); progress; continue
  fi

  client_id="$(echo "$c" | jq -r '.id // empty')"
  [[ -z "$client_id" ]] && client_id="$(echo "$c" | jq -r '.password // empty')"
  [[ -z "$client_id" ]] && client_id="$email"

  old_exp="$(echo "$c" | jq -r '.expiryTime // 0')"
  old_tot="$(echo "$c" | jq -r '.totalGB // 0')"

  # Expire-within filter:
  # If WITHIN_DAYS>0 and expiryTime==0 => not expiring => skip
  if (( WITHIN_DAYS > 0 )); then
    if (( old_exp == 0 )); then
      SKIPN=$((SKIPN+1)); DONE=$((DONE+1)); progress; continue
    fi
    if (( old_exp > NOW + WINMS )); then
      SKIPN=$((SKIPN+1)); DONE=$((DONE+1)); progress; continue
    fi
  fi

  new_exp="$old_exp"
  new_tot="$old_tot"

  # Apply expiry
  if [[ "$MODE" == "1" || "$MODE" == "3" ]]; then
    if (( old_exp == 0 )); then
      [[ "$NOEXP" == "setFromNow" ]] && new_exp=$((NOW + ADDMS))
    else
      new_exp=$((old_exp + ADDMS))
    fi
  fi

  # Apply traffic
  if [[ "$MODE" == "2" || "$MODE" == "3" ]]; then
    if (( old_tot == 0 )); then
      [[ "$NOQUOTA" == "setLimit" ]] && new_tot="$ADDBYTES"
    else
      new_tot=$((old_tot + ADDBYTES))
    fi
  fi

  # No change => skip
  if (( new_exp == old_exp && new_tot == old_tot )); then
    SKIPN=$((SKIPN+1)); DONE=$((DONE+1)); progress; continue
  fi

  # Build updated client
  new_client="$c"
  (( new_exp != old_exp )) && new_client="$(echo "$new_client" | jq --argjson v "$new_exp" '.expiryTime=$v')"
  (( new_tot != old_tot )) && new_client="$(echo "$new_client" | jq --argjson v "$new_tot" '.totalGB=$v')"

  settings_obj="$(jq -n --argjson cl "$new_client" '{clients:[$cl]}')"
  settings_str="$(echo "$settings_obj" | jq -c '.')"
  payload="$(jq -n --argjson id "$INB_ID" --arg settings "$settings_str" '{id:$id,settings:$settings}')"

  # Update with retry/backoff on database lock
  attempt=0
  status="FAIL"
  message=""

  while true; do
    resp="$(api_call POST "${PANEL_URL}/panel/api/inbounds/updateClient/${client_id}" "$payload")"
    HTTP="$(cat "$HTTP_FILE")"; RC="$(cat "$RC_FILE")"
    mt="$(json_msg "$resp")"

    if echo "$resp" | grep -qi "database is locked" || echo "$mt" | grep -qi "database is locked"; then
      attempt=$((attempt+1))
      if (( attempt > LOCK_RETRY_MAX )); then
        message="database is locked (gave up)"
        break
      fi
      sleep $(( LOCK_RETRY_BASE_SLEEP * (2 ** (attempt-1)) ))
      continue
    fi

    if [[ "$RC" != "0" ]]; then
      message="curl_rc=$RC"
    elif [[ "$HTTP" -lt 200 || "$HTTP" -ge 300 ]]; then
      message="http=$HTTP"
    else
      if json_success "$resp"; then
        status="OK"
      else
        message="${mt:-unexpected response}"
      fi
    fi
    break
  done

  if [[ "$status" == "OK" ]]; then
    OKN=$((OKN+1))
  else
    FAILN=$((FAILN+1))
    if [[ "${#ERROR_SAMPLE[@]}" -lt "$ERROR_SAMPLE_MAX" ]]; then
      ERROR_SAMPLE+=("$email | $message")
    fi
  fi

  DONE=$((DONE+1))
  progress
done

progress 1
echo
echo

echo "=== SUMMARY ==="
echo "TOTAL : $TOTAL"
echo "OK    : $OKN"
echo "SKIP  : $SKIPN"
echo "FAIL  : $FAILN"

if (( FAILN > 0 )); then
  echo
  echo "WARN: Some requests failed. Error sample (up to $ERROR_SAMPLE_MAX):"
  for e in "${ERROR_SAMPLE[@]}"; do
    echo "  - $e"
  done
fi

echo "OK: Done."
