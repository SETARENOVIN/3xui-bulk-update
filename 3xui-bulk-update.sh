#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# 3xui-bulk-update.sh (Interactive)
# - Single PANEL_URL input (e.g. https://panel.example.com:2053/network/aaa)
# - Progress + ETA (no per-client change logs)
# - Modes: expiry / traffic / both
# - Filters: only enabled, expiring within X days, email regex
# - Dry-run mode
# - CSV report (OK/FAIL/DRY + messages)
# - Redirect-safe login (handles 307/301/302/303)
# ==========================================================

# ------------------ helpers ------------------
color() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info()  { color "36" "INFO: $*"; }
ok()    { color "32" "OK:   $*"; }
warn()  { color "33" "WARN: $*"; }
fail()  { color "31" "FAIL: $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { fail "Missing dependency: $1"; exit 1; }; }

read_default() {
  local prompt="$1" def="$2" __var="$3"
  local val
  read -r -p "$prompt [$def]: " val
  val="${val:-$def}"
  printf -v "$__var" "%s" "$val"
}

read_secret() {
  local prompt="$1" __var="$2"
  local val
  read -r -s -p "$prompt: " val
  echo
  printf -v "$__var" "%s" "$val"
}

trim_trailing_slash() {
  local s="$1"
  # remove trailing slashes
  while [[ "$s" == */ ]]; do s="${s%/}"; done
  printf "%s" "$s"
}

now_ms() { echo $(( $(date +%s) * 1000 )); }
ms_from_days() { echo $(( $1 * 86400000 )); }
bytes_from_gb() { echo $(( $1 * 1024 * 1024 * 1024 )); }
gb_from_bytes() { awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'; }

csv_escape() {
  local s="$1"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

fmt_hms() {
  local s="$1"
  if [[ "$s" -lt 0 ]]; then s=0; fi
  local h=$((s/3600))
  local m=$(( (s%3600)/60 ))
  local sec=$((s%60))
  printf "%02d:%02d:%02d" "$h" "$m" "$sec"
}

# ------------------ deps ------------------
need curl
need jq
need awk
need base64
need grep

# ------------------ config prompts ------------------
echo "=== 3x-ui Bulk Update Tool (Progress + ETA) ==="
echo

read_default "PANEL_URL (e.g. https://panel.dlcloud.ir:2053/network/aaa)" "https://panel.dlcloud.ir:2053/network/aaa" PANEL_URL
PANEL_URL="$(trim_trailing_slash "$PANEL_URL")"

read_default "INSECURE_TLS (y/n) (for self-signed certs)" "y" INSECURE_TLS
read_default "USERNAME" "admin" USERNAME
read_secret  "PASSWORD" PASSWORD

read_default "HAS_2FA (y/n)" "n" HAS_2FA
TWO_FACTOR_CODE=""
if [[ "$HAS_2FA" =~ ^[Yy]$ ]]; then
  read_default "TWO_FACTOR_CODE" "" TWO_FACTOR_CODE
fi

read_default "RETRY (curl retries)" "2" RETRY
read_default "TIMEOUT (seconds)" "20" TIMEOUT

echo
echo "OPERATION_MODE:"
echo "  1) EXPIRY_ONLY (add days)"
echo "  2) TRAFFIC_ONLY (add GB)"
echo "  3) BOTH (expiry + traffic)"
read_default "Choose (1/2/3)" "1" OP_MODE

ADD_DAYS=0
ADD_GB=0
NOEXP_BEHAVIOR="skip"      # skip | setFromNow
NOQUOTA_BEHAVIOR="skip"    # skip | setLimit

if [[ "$OP_MODE" == "1" || "$OP_MODE" == "3" ]]; then
  read_default "ADD_DAYS (integer)" "1" ADD_DAYS
  read_default "NOEXP_BEHAVIOR (skip/setFromNow)" "skip" NOEXP_BEHAVIOR
fi

if [[ "$OP_MODE" == "2" || "$OP_MODE" == "3" ]]; then
  read_default "ADD_GB (integer)" "10" ADD_GB
  read_default "NOQUOTA_BEHAVIOR (skip/setLimit)" "skip" NOQUOTA_BEHAVIOR
fi

echo
read_default "ONLY_ENABLED (y/n)" "y" ONLY_ENABLED
read_default "EXPIRE_WITHIN_DAYS (0=all clients)" "0" EXPIRE_WITHIN_DAYS
read_default "EMAIL_REGEX (empty=all)" "" EMAIL_REGEX
read_default "DRY_RUN (y/n)" "y" DRY_RUN
read_default "CSV_PATH" "./report.csv" CSV_PATH

CURL_INSECURE=()
if [[ "$INSECURE_TLS" =~ ^[Yy]$ ]]; then
  CURL_INSECURE=(-k)
fi

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# ------------------ HTTP wrapper ------------------
api_call() {
  # api_call METHOD URL [JSON_BODY]
  local method="$1" url="$2" body="${3:-}"
  local resp http_code rc

  if [[ -n "$body" ]]; then
    set +e
    resp=$(curl -sS "${CURL_INSECURE[@]}" \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$RETRY" --retry-delay 1 \
      --max-time "$TIMEOUT" \
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
    resp=$(curl -sS "${CURL_INSECURE[@]}" \
      --location --max-redirs 5 --post301 --post302 --post303 \
      --retry "$RETRY" --retry-delay 1 \
      --max-time "$TIMEOUT" \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -w "\n%{http_code}" \
      "$url")
    rc=$?
    set -e
  fi

  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  echo "$rc" > /tmp/.xui_rc
  echo "$http_code" > /tmp/.xui_http
  echo "$resp"
}

json_success() { echo "$1" | jq -e '.success == true' >/dev/null 2>&1; }
json_msg() { echo "$1" | jq -r '.msg // .message // empty' 2>/dev/null || true; }

# ------------------ CSV init ------------------
{
  echo "timestamp,inboundId,email,clientId,oldExpiryMs,newExpiryMs,oldTotalBytes,newTotalBytes,oldTotalGB,newTotalGB,status,httpCode,message"
} > "$CSV_PATH"

# ------------------ login (tries /login and /login/) ------------------
LOGIN_PAYLOAD=$(jq -n \
  --arg u "$USERNAME" \
  --arg p "$PASSWORD" \
  --arg tf "$TWO_FACTOR_CODE" \
  'if ($tf|length)>0 then {username:$u,password:$p,twoFactorCode:$tf} else {username:$u,password:$p} end')

info "Logging in: ${PANEL_URL}/login"
LOGIN_BODY="$(api_call POST "${PANEL_URL}/login" "$LOGIN_PAYLOAD")"
LOGIN_HTTP="$(cat /tmp/.xui_http)"
LOGIN_RC="$(cat /tmp/.xui_rc)"

if [[ "$LOGIN_RC" != "0" || "$LOGIN_HTTP" -lt 200 || "$LOGIN_HTTP" -ge 300 ]]; then
  # fallback to /login/
  warn "Login failed on /login (curl_rc=$LOGIN_RC http=$LOGIN_HTTP). Trying /login/ ..."
  LOGIN_BODY="$(api_call POST "${PANEL_URL}/login/" "$LOGIN_PAYLOAD")"
  LOGIN_HTTP="$(cat /tmp/.xui_http)"
  LOGIN_RC="$(cat /tmp/.xui_rc)"
fi

if [[ "$LOGIN_RC" != "0" || "$LOGIN_HTTP" -lt 200 || "$LOGIN_HTTP" -ge 300 ]]; then
  fail "Login failed (curl_rc=$LOGIN_RC http=$LOGIN_HTTP)"
  fail "Response: $LOGIN_BODY"
  exit 1
fi
ok "Login success (http=$LOGIN_HTTP)"

# ------------------ list inbounds ------------------
info "Fetching inbounds list..."
LIST_BODY="$(api_call GET "${PANEL_URL}/panel/api/inbounds/list")"
LIST_HTTP="$(cat /tmp/.xui_http)"
LIST_RC="$(cat /tmp/.xui_rc)"

if [[ "$LIST_RC" != "0" || "$LIST_HTTP" -lt 200 || "$LIST_HTTP" -ge 300 ]]; then
  fail "List inbounds failed (curl_rc=$LIST_RC http=$LIST_HTTP)"
  fail "Response: $LIST_BODY"
  exit 1
fi

INB_ARR="$(echo "$LIST_BODY" | jq -c 'if type=="array" then . else .obj end')"
COUNT="$(echo "$INB_ARR" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  fail "No inbounds found."
  exit 1
fi

echo
echo "=== INBOUNDS ($COUNT) ==="
echo "$INB_ARR" | jq -r '
  to_entries[]
  | "\(.key+1)) id=\(.value.id) | remark=\(.value.remark // "-") | protocol=\(.value.protocol // "-") | port=\(.value.port // "-")"
'

read_default "Select inbound number" "1" PICK
IDX=$((PICK-1))
INBOUND_ID="$(echo "$INB_ARR" | jq -r --argjson i "$IDX" '.[$i].id')"
if [[ -z "$INBOUND_ID" || "$INBOUND_ID" == "null" ]]; then
  fail "Invalid selection."
  exit 1
fi
ok "Selected inboundId=$INBOUND_ID"

# ------------------ get inbound details ------------------
info "Fetching inbound details..."
INB_BODY="$(api_call GET "${PANEL_URL}/panel/api/inbounds/get/${INBOUND_ID}")"
INB_HTTP="$(cat /tmp/.xui_http)"
INB_RC="$(cat /tmp/.xui_rc)"

if [[ "$INB_RC" != "0" || "$INB_HTTP" -lt 200 || "$INB_HTTP" -ge 300 ]]; then
  fail "Get inbound failed (curl_rc=$INB_RC http=$INB_HTTP)"
  fail "Response: $INB_BODY"
  exit 1
fi

SETTINGS_FIELD="$(echo "$INB_BODY" | jq -r '.obj.settings')"
if [[ -z "$SETTINGS_FIELD" || "$SETTINGS_FIELD" == "null" ]]; then
  fail "Inbound settings missing/unexpected."
  fail "Response: $INB_BODY"
  exit 1
fi

CLIENTS_B64=()
if echo "$SETTINGS_FIELD" | jq -e . >/dev/null 2>&1; then
  mapfile -t CLIENTS_B64 < <(echo "$SETTINGS_FIELD" | jq -r '.clients[]? | @base64')
else
  mapfile -t CLIENTS_B64 < <(echo "$SETTINGS_FIELD" | jq -r 'fromjson | .clients[]? | @base64')
fi

if [[ "${#CLIENTS_B64[@]}" -eq 0 ]]; then
  warn "No clients found in this inbound."
  exit 0
fi

# ------------------ derived values ------------------
NOWMS="$(now_ms)"
ADD_MS="$(ms_from_days "$ADD_DAYS")"
ADD_BYTES="$(bytes_from_gb "$ADD_GB")"
WINDOW_MS="$(ms_from_days "$EXPIRE_WITHIN_DAYS")"

TOTAL=0
UPDATED=0
SKIPPED=0
FAILED=0
PROCESSED=0

# Keep a short sample of error messages (no spam)
ERROR_SAMPLE=()
ERROR_SAMPLE_MAX=5

# progress throttle
START_TS="$(date +%s)"
LAST_DRAW_TS=0

draw_progress() {
  local force="${1:-0}"
  local now="$(date +%s)"
  local elapsed=$((now - START_TS))
  local pct=0
  if [[ "$TOTAL" -gt 0 ]]; then
    pct=$(( (PROCESSED * 100) / TOTAL ))
  fi

  local eta="--:--:--"
  if [[ "$PROCESSED" -gt 0 && "$elapsed" -gt 0 ]]; then
    # avg per item
    local rate_num="$PROCESSED"
    local rate_den="$elapsed"
    # remaining seconds = elapsed/proc * (total-proc)
    local remaining=$(( (elapsed * (TOTAL - PROCESSED)) / PROCESSED ))
    eta="$(fmt_hms "$remaining")"
  fi

  # throttle to 1 update/sec unless forced
  if [[ "$force" -eq 0 ]]; then
    if [[ "$now" -le "$LAST_DRAW_TS" ]]; then
      return
    fi
    LAST_DRAW_TS="$now"
  fi

  printf "\rProgress: %3d%% (%d/%d) | OK:%d FAIL:%d SKIP:%d | ETA:%s" \
    "$pct" "$PROCESSED" "$TOTAL" "$UPDATED" "$FAILED" "$SKIPPED" "$eta"
}

echo
info "Clients found: ${#CLIENTS_B64[@]}"
info "DRY_RUN=$DRY_RUN | ONLY_ENABLED=$ONLY_ENABLED | EXPIRE_WITHIN_DAYS=$EXPIRE_WITHIN_DAYS | EMAIL_REGEX='${EMAIL_REGEX}'"
echo

TOTAL="${#CLIENTS_B64[@]}"
draw_progress 1

# ------------------ process clients ------------------
for row in "${CLIENTS_B64[@]}"; do
  c="$(echo "$row" | base64 -d)"

  email="$(echo "$c" | jq -r '.email // ""')"
  enable="$(echo "$c" | jq -r '.enable // true')"

  client_id="$(echo "$c" | jq -r '.id // empty')"
  [[ -z "$client_id" ]] && client_id="$(echo "$c" | jq -r '.password // empty')"
  [[ -z "$client_id" ]] && client_id="$email"

  # filters
  if [[ "$ONLY_ENABLED" =~ ^[Yy]$ ]] && [[ "$enable" != "true" ]]; then
    SKIPPED=$((SKIPPED+1))
    PROCESSED=$((PROCESSED+1))
    draw_progress
    continue
  fi

  if [[ -n "$EMAIL_REGEX" ]]; then
    if ! echo "$email" | grep -Eiq "$EMAIL_REGEX"; then
      SKIPPED=$((SKIPPED+1))
      PROCESSED=$((PROCESSED+1))
      draw_progress
      continue
    fi
  fi

  old_exp="$(echo "$c" | jq -r '.expiryTime // 0')"
  old_tot="$(echo "$c" | jq -r '.totalGB // 0')"

  new_exp="$old_exp"
  new_tot="$old_tot"

  # expire-within filter
  if [[ "$EXPIRE_WITHIN_DAYS" -gt 0 && "$old_exp" -ne 0 ]]; then
    if [[ "$old_exp" -gt $((NOWMS + WINDOW_MS)) ]]; then
      SKIPPED=$((SKIPPED+1))
      PROCESSED=$((PROCESSED+1))
      draw_progress
      continue
    fi
  fi

  # apply expiry
  if [[ "$OP_MODE" == "1" || "$OP_MODE" == "3" ]]; then
    if [[ "$old_exp" -eq 0 ]]; then
      if [[ "$NOEXP_BEHAVIOR" == "setFromNow" ]]; then
        new_exp=$((NOWMS + ADD_MS))
      else
        new_exp="$old_exp"
      fi
    else
      new_exp=$((old_exp + ADD_MS))
    fi
  fi

  # apply traffic
  if [[ "$OP_MODE" == "2" || "$OP_MODE" == "3" ]]; then
    if [[ "$old_tot" -eq 0 ]]; then
      if [[ "$NOQUOTA_BEHAVIOR" == "setLimit" ]]; then
        new_tot="$ADD_BYTES"
      else
        new_tot="$old_tot"
      fi
    else
      new_tot=$((old_tot + ADD_BYTES))
    fi
  fi

  if [[ "$new_exp" -eq "$old_exp" && "$new_tot" -eq "$old_tot" ]]; then
    SKIPPED=$((SKIPPED+1))
    PROCESSED=$((PROCESSED+1))
    draw_progress
    continue
  fi

  # build updated client object
  new_client="$c"
  if [[ "$new_exp" -ne "$old_exp" ]]; then
    new_client="$(echo "$new_client" | jq --argjson v "$new_exp" '.expiryTime = $v')"
  fi
  if [[ "$new_tot" -ne "$old_tot" ]]; then
    new_client="$(echo "$new_client" | jq --argjson v "$new_tot" '.totalGB = $v')"
  fi

  settings_obj="$(jq -n --argjson cl "$new_client" '{clients:[$cl]}')"
  settings_str="$(echo "$settings_obj" | jq -c '.')"
  update_payload="$(jq -n --argjson id "$INBOUND_ID" --arg settings "$settings_str" '{id:$id, settings:$settings}')"

  old_gb="$(gb_from_bytes "$old_tot")"
  new_gb="$(gb_from_bytes "$new_tot")"

  ts="$(date -Iseconds)"

  if [[ "$DRY_RUN" =~ ^[Yy]$ ]]; then
    UPDATED=$((UPDATED+1))
    echo "$(csv_escape "$ts"),$INBOUND_ID,$(csv_escape "$email"),$(csv_escape "$client_id"),$old_exp,$new_exp,$old_tot,$new_tot,$old_gb,$new_gb,DRY,0,$(csv_escape "")" >> "$CSV_PATH"
    PROCESSED=$((PROCESSED+1))
    draw_progress
    continue
  fi

  resp="$(api_call POST "${PANEL_URL}/panel/api/inbounds/updateClient/${client_id}" "$update_payload")"
  http="$(cat /tmp/.xui_http)"
  rc="$(cat /tmp/.xui_rc)"

  status="FAIL"
  message=""

  if [[ "$rc" != "0" ]]; then
    message="curl_rc=$rc"
  elif [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
    message="http=$http body=$resp"
  else
    if json_success "$resp"; then
      status="OK"
    else
      message="$(json_msg "$resp")"
      [[ -z "$message" ]] && message="unexpected response: $resp"
    fi
  fi

  if [[ "$status" == "OK" ]]; then
    UPDATED=$((UPDATED+1))
  else
    FAILED=$((FAILED+1))
    if [[ "${#ERROR_SAMPLE[@]}" -lt "$ERROR_SAMPLE_MAX" ]]; then
      ERROR_SAMPLE+=("$email | $message")
    fi
  fi

  echo "$(csv_escape "$ts"),$INBOUND_ID,$(csv_escape "$email"),$(csv_escape "$client_id"),$old_exp,$new_exp,$old_tot,$new_tot,$old_gb,$new_gb,$status,$http,$(csv_escape "$message")" >> "$CSV_PATH"

  PROCESSED=$((PROCESSED+1))
  draw_progress
done

# final progress line + newline
draw_progress 1
echo
echo

echo "=== SUMMARY ==="
echo "TOTAL   : $TOTAL"
echo "UPDATED : $UPDATED"
echo "SKIPPED : $SKIPPED"
echo "FAILED  : $FAILED"
echo "CSV     : $CSV_PATH"

if [[ "$FAILED" -gt 0 ]]; then
  echo
  warn "Some requests failed. See CSV for full details."
  warn "Error sample (up to $ERROR_SAMPLE_MAX):"
  for e in "${ERROR_SAMPLE[@]}"; do
    echo "  - $e"
  done
fi

ok "Done."
