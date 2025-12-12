#!/usr/bin/env bash
set -u
set -o pipefail

# ===========
# 3x-ui Bulk Update Tool
# - Extend ExpiryTime (days)
# - Add totalGB (bytes) by GB
# - List inbounds and select
# - CSV report
# Endpoints (per Postman docs):
#   POST  /login/                              (cookie session)  5
#   GET   /panel/api/inbounds/list             6
#   GET   /panel/api/inbounds/get/{inboundId}  7
#   POST  /panel/api/inbounds/updateClient/{uuid} with body {id, settings(stringified)} 8
# ===========

# ---------- utils ----------
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { red "نیاز به نصب: $1"; exit 1; }; }

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

now_ms() { echo $(( $(date +%s) * 1000 )); }

bytes_from_gb() {
  # int GB -> bytes
  echo $(( $1 * 1024 * 1024 * 1024 ))
}

gb_from_bytes() {
  # bytes -> GB (float-ish with 2 decimals via awk)
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}

csv_escape() {
  # Escape CSV field (wrap with quotes, escape quotes)
  local s="$1"
  s="${s//\"/\"\"}"
  printf "\"%s\"" "$s"
}

# ---------- deps ----------
need curl
need jq
need awk
need base64

# ---------- config (interactive) ----------
echo "=== 3x-ui Bulk Update (Expiry / Traffic / Both) ==="
echo

read_default "Scheme (http یا https)" "https" SCHEME
read_default "Host (IP یا domain)" "127.0.0.1" HOST
read_default "Port" "2053" PORT
read_default "WEBBASEPATH (مثل /randompath یا خالی)" "" WEBBASEPATH

if [[ -n "$WEBBASEPATH" && "$WEBBASEPATH" != /* ]]; then
  WEBBASEPATH="/$WEBBASEPATH"
fi

read_default "Allow insecure TLS? (برای سلف‌ساین) y/n" "y" INSECURE_TLS

read_default "Username" "admin" USERNAME
read_secret  "Password" PASSWORD

read_default "آیا 2FA داری؟ y/n" "n" HAS_2FA
TWOFA=""
if [[ "$HAS_2FA" =~ ^[Yy]$ ]]; then
  read_default "کد 2FA (six-digit)" "" TWOFA
fi

read_default "Retry count (curl)" "2" RETRY
read_default "Timeout seconds" "20" TIMEOUT

echo
echo "عملیات:"
echo "  1) فقط تمدید انقضا (days)"
echo "  2) فقط افزایش حجم (GB)"
echo "  3) هر دو (Expiry + Traffic)"
read_default "انتخاب (1/2/3)" "1" OP_MODE

ADD_DAYS=0
ADD_GB=0

if [[ "$OP_MODE" == "1" || "$OP_MODE" == "3" ]]; then
  read_default "چند روز به expiryTime اضافه شود؟" "1" ADD_DAYS
  read_default "اگر expiryTime=0 بود: skip یا setFromNow" "skip" NOEXP_BEHAVIOR
fi

if [[ "$OP_MODE" == "2" || "$OP_MODE" == "3" ]]; then
  read_default "چند گیگ به totalGB اضافه شود؟" "10" ADD_GB
  read_default "اگر totalGB=0 بود: skip یا setLimit" "skip" NOQUOTA_BEHAVIOR
fi

echo
read_default "فقط کلاینت‌های enable=true اعمال شود؟ y/n" "y" ONLY_ENABLED

echo
echo "فیلتر اختیاری:"
echo " - اگر فقط کسانی که تا X روز آینده منقضی می‌شن را هدف بگیری، X را بده."
echo " - اگر 0 بزنی یعنی بدون فیلتر (همه‌ی کلاینت‌ها)"
read_default "Expire-within-days (0=همه)" "0" EXPIRE_WITHIN_DAYS

echo
read_default "فیلتر ایمیل (regex اختیاری، خالی=همه)" "" EMAIL_REGEX

echo
read_default "Dry-run (فقط نمایش، بدون اعمال) y/n" "y" DRY_RUN

echo
read_default "مسیر خروجی CSV" "./report.csv" CSV_PATH

BASE_URL="${SCHEME}://${HOST}:${PORT}${WEBBASEPATH}"

CURL_INSECURE=()
if [[ "$INSECURE_TLS" =~ ^[Yy]$ ]]; then
  CURL_INSECURE=(-k)
fi

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

# ---------- http helper ----------
api_call() {
  # api_call METHOD URL [JSON_BODY]
  local method="$1" url="$2" body="${3:-}"
  local resp http_code curl_rc

  if [[ -n "$body" ]]; then
    set +e
    resp=$(curl -sS "${CURL_INSECURE[@]}" \
      --retry "$RETRY" --retry-delay 1 \
      --max-time "$TIMEOUT" \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -d "$body" \
      -w "\n%{http_code}" \
      "$url")
    curl_rc=$?
    set -e
  else
    set +e
    resp=$(curl -sS "${CURL_INSECURE[@]}" \
      --retry "$RETRY" --retry-delay 1 \
      --max-time "$TIMEOUT" \
      -X "$method" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -w "\n%{http_code}" \
      "$url")
    curl_rc=$?
    set -e
  fi

  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  echo "$curl_rc" > /tmp/.xui_curl_rc
  echo "$http_code" > /tmp/.xui_http_code
  echo "$resp"
}

is_success_json() {
  # returns 0 if .success==true, else 1
  local body="$1"
  echo "$body" | jq -e '.success == true' >/dev/null 2>&1
}

json_msg() {
  local body="$1"
  echo "$body" | jq -r '.msg // .message // empty' 2>/dev/null || true
}

# ---------- login ----------
echo
yellow "Login -> ${BASE_URL}/login/"
LOGIN_PAYLOAD=$(jq -n \
  --arg u "$USERNAME" \
  --arg p "$PASSWORD" \
  --arg tf "$TWOFA" \
  'if ($tf|length)>0 then {username:$u,password:$p,twoFactorCode:$tf} else {username:$u,password:$p} end')

LOGIN_BODY="$(api_call POST "${BASE_URL}/login/" "$LOGIN_PAYLOAD")"
LOGIN_HTTP="$(cat /tmp/.xui_http_code)"
LOGIN_RC="$(cat /tmp/.xui_curl_rc)"

if [[ "$LOGIN_RC" != "0" || "$LOGIN_HTTP" -lt 200 || "$LOGIN_HTTP" -ge 300 ]]; then
  red "Login failed (curl_rc=$LOGIN_RC http=$LOGIN_HTTP)"
  red "Response: $LOGIN_BODY"
  exit 1
fi

# بعضی نسخه‌ها success را برمی‌گردانند، بعضی نه؛ همین که 2xx باشد و کوکی ست شود کافیست.
green "Login OK (http=$LOGIN_HTTP)"

# ---------- list inbounds ----------
echo
yellow "Fetching inbounds list -> /panel/api/inbounds/list"
INB_LIST_BODY="$(api_call GET "${BASE_URL}/panel/api/inbounds/list")"
INB_LIST_HTTP="$(cat /tmp/.xui_http_code)"
INB_LIST_RC="$(cat /tmp/.xui_curl_rc)"

if [[ "$INB_LIST_RC" != "0" || "$INB_LIST_HTTP" -lt 200 || "$INB_LIST_HTTP" -ge 300 ]]; then
  red "Failed to list inbounds (curl_rc=$INB_LIST_RC http=$INB_LIST_HTTP)"
  red "Response: $INB_LIST_BODY"
  exit 1
fi

# normalize to array:
# - sometimes: {success:true, obj:[...]}
# - sometimes: [...]
INB_ARR="$(echo "$INB_LIST_BODY" | jq -c 'if type=="array" then . else .obj end')"

COUNT="$(echo "$INB_ARR" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  red "هیچ inboundی پیدا نشد."
  exit 1
fi

echo
echo "=== Inbounds (${COUNT}) ==="
echo "$INB_ARR" | jq -r '
  to_entries[]
  | "\(.key+1)) id=\(.value.id) | remark=\(.value.remark // "-") | protocol=\(.value.protocol // "-") | port=\(.value.port // "-")"
'

read_default "شماره inbound را انتخاب کن" "1" PICK
IDX=$((PICK-1))
INBOUND_ID="$(echo "$INB_ARR" | jq -r --argjson i "$IDX" '.[$i].id')"

if [[ -z "$INBOUND_ID" || "$INBOUND_ID" == "null" ]]; then
  red "انتخاب نامعتبر."
  exit 1
fi

green "Selected inboundId=$INBOUND_ID"

# ---------- get inbound details ----------
echo
yellow "Fetching inbound details -> /panel/api/inbounds/get/${INBOUND_ID}"
INB_BODY="$(api_call GET "${BASE_URL}/panel/api/inbounds/get/${INBOUND_ID}")"
INB_HTTP="$(cat /tmp/.xui_http_code)"
INB_RC="$(cat /tmp/.xui_curl_rc)"

if [[ "$INB_RC" != "0" || "$INB_HTTP" -lt 200 || "$INB_HTTP" -ge 300 ]]; then
  red "Failed to get inbound (curl_rc=$INB_RC http=$INB_HTTP)"
  red "Response: $INB_BODY"
  exit 1
fi

# settings can be JSON string
SETTINGS_RAW="$(echo "$INB_BODY" | jq -r '.obj.settings')"
if [[ -z "$SETTINGS_RAW" || "$SETTINGS_RAW" == "null" ]]; then
  red "این inbound settings ندارد یا فرمت غیرمنتظره است."
  red "Response: $INB_BODY"
  exit 1
fi

CLIENTS_B64=()
# Try parse settings as JSON string containing clients
if echo "$SETTINGS_RAW" | jq -e . >/dev/null 2>&1; then
  # It's already JSON (rare)
  mapfile -t CLIENTS_B64 < <(echo "$SETTINGS_RAW" | jq -r '.clients[]? | @base64')
else
  # It's stringified JSON
  mapfile -t CLIENTS_B64 < <(echo "$SETTINGS_RAW" | jq -r 'fromjson | .clients[]? | @base64')
fi

if [[ "${#CLIENTS_B64[@]}" -eq 0 ]]; then
  yellow "هیچ کلاینتی در این inbound پیدا نشد."
  exit 0
fi

# ---------- CSV header ----------
{
  echo "timestamp,inboundId,email,clientId,oldExpiryMs,newExpiryMs,oldTotalBytes,newTotalBytes,oldTotalGB,newTotalGB,status,httpCode,message"
} > "$CSV_PATH"

# ---------- apply ----------
NOWMS="$(now_ms)"
ADD_MS=$(( ADD_DAYS * 86400000 ))
ADD_BYTES="$(bytes_from_gb "$ADD_GB")"
WINDOW_MS=$(( EXPIRE_WITHIN_DAYS * 86400000 ))

TOTAL=0
UPDATED=0
SKIPPED=0
FAILED=0

echo
echo "=== Clients: ${#CLIENTS_B64[@]} ==="

for row in "${CLIENTS_B64[@]}"; do
  TOTAL=$((TOTAL+1))

  c="$(echo "$row" | base64 -d)"

  email="$(echo "$c" | jq -r '.email // ""')"
  enable="$(echo "$c" | jq -r '.enable // true')"
  uuid="$(echo "$c" | jq -r '.id // empty')" # updateClient expects {uuid} in path 9

  if [[ -z "$uuid" ]]; then
    # If no id exists (unusual for vmess/vless), try password as fallback
    uuid="$(echo "$c" | jq -r '.password // empty')"
  fi

  if [[ -z "$uuid" ]]; then
    # last resort: email
    uuid="$email"
  fi

  # filters
  if [[ "$ONLY_ENABLED" =~ ^[Yy]$ ]] && [[ "$enable" != "true" ]]; then
    SKIPPED=$((SKIPPED+1))
    echo "SKIP(disabled): $email"
    continue
  fi

  if [[ -n "$EMAIL_REGEX" ]]; then
    if ! echo "$email" | grep -Eiq "$EMAIL_REGEX"; then
      SKIPPED=$((SKIPPED+1))
      echo "SKIP(regex): $email"
      continue
    fi
  fi

  oldExp="$(echo "$c" | jq -r '.expiryTime // 0')"
  oldTot="$(echo "$c" | jq -r '.totalGB // 0')"

  newExp="$oldExp"
  newTot="$oldTot"

  # expiry filter (only if user asked and expiry is part of operation OR you explicitly want filter anyway)
  if [[ "$EXPIRE_WITHIN_DAYS" -gt 0 ]]; then
    # If expiryTime==0 (no-expiry), it's not "expiring soon"
    if [[ "$oldExp" -eq 0 ]]; then
      # keep as-is, but still can be modified if user chose setFromNow
      :
    else
      if [[ "$oldExp" -gt $((NOWMS + WINDOW_MS)) ]]; then
        # not within window
        SKIPPED=$((SKIPPED+1))
        echo "SKIP(not-in-window): $email"
        continue
      fi
    fi
  fi

  # apply expiry
  if [[ "$OP_MODE" == "1" || "$OP_MODE" == "3" ]]; then
    if [[ "$oldExp" -eq 0 ]]; then
      if [[ "${NOEXP_BEHAVIOR}" == "setFromNow" ]]; then
        newExp=$((NOWMS + ADD_MS))
      else
        # skip expiry change
        newExp="$oldExp"
      fi
    else
      newExp=$((oldExp + ADD_MS))
    fi
  fi

  # apply traffic
  if [[ "$OP_MODE" == "2" || "$OP_MODE" == "3" ]]; then
    if [[ "$oldTot" -eq 0 ]]; then
      if [[ "${NOQUOTA_BEHAVIOR}" == "setLimit" ]]; then
        newTot="$ADD_BYTES"
      else
        newTot="$oldTot"
      fi
    else
      newTot=$((oldTot + ADD_BYTES))
    fi
  fi

  # if nothing changes, skip
  if [[ "$newExp" -eq "$oldExp" && "$newTot" -eq "$oldTot" ]]; then
    SKIPPED=$((SKIPPED+1))
    echo "SKIP(no-change): $email"
    continue
  fi

  # build new client object
  newClient="$c"
  if [[ "$newExp" -ne "$oldExp" ]]; then
    newClient="$(echo "$newClient" | jq --argjson v "$newExp" '.expiryTime = $v')"
  fi
  if [[ "$newTot" -ne "$oldTot" ]]; then
    newClient="$(echo "$newClient" | jq --argjson v "$newTot" '.totalGB = $v')"
  fi

  # update payload per common pattern: { id: inboundId, settings: JSON.stringify({clients:[client]}) } 10
  settings_obj="$(jq -n --argjson cl "$newClient" '{clients:[$cl]}')"
  settings_str="$(echo "$settings_obj" | jq -c '.')"

  update_body="$(jq -n --argjson id "$INBOUND_ID" --arg settings "$settings_str" '{id:$id, settings:$settings}')"

  if [[ "$DRY_RUN" =~ ^[Yy]$ ]]; then
    echo "DRY: $email | expiry: $oldExp -> $newExp | total: $(gb_from_bytes "$oldTot")GB -> $(gb_from_bytes "$newTot")GB"
    UPDATED=$((UPDATED+1))
    {
      ts="$(date -Iseconds)"
      echo "$(csv_escape "$ts"),$INBOUND_ID,$(csv_escape "$email"),$(csv_escape "$uuid"),$oldExp,$newExp,$oldTot,$newTot,$(gb_from_bytes "$oldTot"),$(gb_from_bytes "$newTot"),DRY,0,$(csv_escape "")"
    } >> "$CSV_PATH"
    continue
  fi

  # POST /panel/api/inbounds/updateClient/{uuid} 11
  resp="$(api_call POST "${BASE_URL}/panel/api/inbounds/updateClient/${uuid}" "$update_body")"
  http="$(cat /tmp/.xui_http_code)"
  rc="$(cat /tmp/.xui_curl_rc)"

  status="FAIL"
  msg=""

  if [[ "$rc" != "0" ]]; then
    msg="curl_rc=$rc"
  elif [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
    msg="http=$http body=$resp"
  else
    if is_success_json "$resp"; then
      status="OK"
    else
      # some responses may not contain success, try accept 2xx but log body
      # prefer explicit success
      status="FAIL"
      msg="$(json_msg "$resp")"
      [[ -z "$msg" ]] && msg="unexpected response: $resp"
    fi
  fi

  if [[ "$status" == "OK" ]]; then
    green "OK: $email | expiry: $oldExp -> $newExp | total: $(gb_from_bytes "$oldTot")GB -> $(gb_from_bytes "$newTot")GB"
    UPDATED=$((UPDATED+1))
  else
    red "FAIL: $email | $msg"
    FAILED=$((FAILED+1))
  fi

  {
    ts="$(date -Iseconds)"
    echo "$(csv_escape "$ts"),$INBOUND_ID,$(csv_escape "$email"),$(csv_escape "$uuid"),$oldExp,$newExp,$oldTot,$newTot,$(gb_from_bytes "$oldTot"),$(gb_from_bytes "$newTot"),$status,$http,$(csv_escape "$msg")"
  } >> "$CSV_PATH"

done

echo
echo "=== Summary ==="
echo "Total:   $TOTAL"
echo "Updated: $UPDATED"
echo "Skipped: $SKIPPED"
echo "Failed:  $FAILED"
echo "CSV:     $CSV_PATH"
