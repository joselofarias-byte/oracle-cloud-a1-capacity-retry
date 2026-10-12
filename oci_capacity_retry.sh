#!/usr/bin/env bash
# =============================================================================
# OCI Always Free A1.Flex capacity retry
# =============================================================================
# All account, placement, networking, and retry values are loaded from .env.
# Keep .env private; it is intentionally excluded from Git.
# =============================================================================

umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
DRY_RUN_OVERRIDE="${DRY_RUN:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No se encontró .env: $ENV_FILE"
  echo "Copiá .env.example a .env y completá la configuración OCI."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# An explicit DRY_RUN=value on the command line may override .env for testing.
if [[ -n "$DRY_RUN_OVERRIDE" ]]; then
  DRY_RUN="$DRY_RUN_OVERRIDE"
fi

: "${TENANCY_NAME:?TENANCY_NAME falta en .env}"
: "${COMPARTMENT_ID:?COMPARTMENT_ID falta en .env}"
: "${OCI_CONFIG_FILE:?OCI_CONFIG_FILE falta en .env}"
: "${OCI_PROFILE:?OCI_PROFILE falta en .env}"
: "${SSH_KEY_FILE:?SSH_KEY_FILE falta en .env}"
: "${DISPLAY_NAME:?DISPLAY_NAME falta en .env}"
: "${SHAPE:?SHAPE falta en .env}"
: "${OCPUS:?OCPUS falta en .env}"
: "${MEMORY_GB:?MEMORY_GB falta en .env}"
: "${TOTAL_OCPU_LIMIT:?TOTAL_OCPU_LIMIT falta en .env}"
: "${TOTAL_MEMORY_LIMIT:?TOTAL_MEMORY_LIMIT falta en .env}"
: "${SLEEP_SECONDS:?SLEEP_SECONDS falta en .env}"
: "${MAX_RETRY_DELAY_SECONDS:?MAX_RETRY_DELAY_SECONDS falta en .env}"
: "${CAPACITY_REQUEST_DELAY_SECONDS:?CAPACITY_REQUEST_DELAY_SECONDS falta en .env}"
: "${OCI_READ_TIMEOUT:?OCI_READ_TIMEOUT falta en .env}"
: "${OCI_NO_RETRY:?OCI_NO_RETRY falta en .env}"
: "${IMAGE_OS:?IMAGE_OS falta en .env}"
: "${IMAGE_OS_VERSION:?IMAGE_OS_VERSION falta en .env}"
: "${ASSIGN_PUBLIC_IP:?ASSIGN_PUBLIC_IP falta en .env}"
: "${LAUNCH_WAIT_STATE:?LAUNCH_WAIT_STATE falta en .env}"
: "${LAUNCH_MAX_WAIT_SECONDS:?LAUNCH_MAX_WAIT_SECONDS falta en .env}"
: "${NETWORK_RECHECK_DELAYS:?NETWORK_RECHECK_DELAYS falta en .env}"
: "${REGION:?REGION falta en .env}"
: "${LOCK_FILE:?LOCK_FILE falta en .env}"
: "${ADS:?ADS falta en .env}"

SUBNET_ID="${SUBNET_ID:-}"
IMAGE_ID="${IMAGE_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
OCI_BIN="${OCI_BIN:-}"
LOG_TO_FILE="${LOG_TO_FILE:-1}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_PREFIX="${LOG_PREFIX:-oci-capacity-retry}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-3}"
LOG_DAY=""
LOG_FILE=""
NTP_CHECK_ENABLED="${NTP_CHECK_ENABLED:-1}"
NTP_SERVERS="${NTP_SERVERS:-time.apple.com,pool.ntp.org}"
NTP_MAX_OFFSET_SECONDS="${NTP_MAX_OFFSET_SECONDS:-120}"
NTP_TIMEOUT_SECONDS="${NTP_TIMEOUT_SECONDS:-5}"
NTP_RETRY_DELAY_SECONDS="${NTP_RETRY_DELAY_SECONDS:-30}"
SNTP_BIN="${SNTP_BIN:-}"
IFS=',' read -r -a ADS <<< "$ADS"
IFS=',' read -r -a RECHECK_DELAYS <<< "$NETWORK_RECHECK_DELAYS"
IFS=',' read -r -a NTP_SERVER_LIST <<< "$NTP_SERVERS"

if (( ${#ADS[@]} == 0 )); then
  echo "ERROR: ADS está vacío en .env."
  exit 1
fi

if [[ "$LOG_TO_FILE" != "0" && "$LOG_TO_FILE" != "1" ]]; then
  echo "ERROR: LOG_TO_FILE debe ser 0 o 1."
  exit 1
fi
if ! [[ "$LOG_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: LOG_RETENTION_DAYS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$LOG_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: LOG_PREFIX may contain only letters, numbers, dots, underscores, and hyphens."
  exit 1
fi
if [[ "$NTP_CHECK_ENABLED" != "0" && "$NTP_CHECK_ENABLED" != "1" ]]; then
  echo "ERROR: NTP_CHECK_ENABLED debe ser 0 o 1."
  exit 1
fi
if ! [[ "$NTP_MAX_OFFSET_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_MAX_OFFSET_SECONDS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$NTP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_TIMEOUT_SECONDS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$NTP_RETRY_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_RETRY_DELAY_SECONDS debe ser un entero positivo."
  exit 1
fi
if [[ "$NTP_CHECK_ENABLED" == "1" ]]; then
  if [[ -z "$NTP_SERVERS" ]]; then
    echo "ERROR: NTP_SERVERS cannot be empty when NTP_CHECK_ENABLED=1."
    exit 1
  fi
  for ntp_server in "${NTP_SERVER_LIST[@]}"; do
    if [[ ! "$ntp_server" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
      echo "ERROR: Invalid Servidor NTP name: $ntp_server"
      exit 1
    fi
  done
fi

prune_old_logs() {
  local candidate
  for candidate in "$LOG_DIR"/"${LOG_PREFIX}"-????-??-??.log; do
    [[ -f "$candidate" ]] || continue
    find "$candidate" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  done
}

rotate_log_if_needed() {
  local today
  [[ "$LOG_TO_FILE" == "1" ]] || return 0

  today="$(date '+%Y-%m-%d')"
  if [[ -z "$LOG_DAY" || "$today" != "$LOG_DAY" ]]; then
    mkdir -p "$LOG_DIR" || {
      echo "ERROR: No se pudo crear la carpeta de registros: $LOG_DIR"
      exit 1
    }
    LOG_DAY="$today"
    LOG_FILE="$LOG_DIR/${LOG_PREFIX}-${LOG_DAY}.log"
    exec >> "$LOG_FILE" 2>&1
    echo "Registro en $LOG_FILE; conservando registros durante $LOG_RETENTION_DAYS day(s)."
  fi

  prune_old_logs
}

rotate_log_if_needed

mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
exec 9>"$LOCK_FILE" || exit 1
flock -n 9 || { echo "ERROR: Ya hay otro proceso activo para esta cuenta."; exit 1; }
STATE_FILE="${STATE_FILE:-${ENV_FILE}.estado}"
if [[ "$DRY_RUN" != "1" && -s "$STATE_FILE" ]]; then
  echo "Proceso detenido: existe un resultado anterior en $STATE_FILE."
  echo "Revisá la consola antes de retirar ese archivo."
  exit 1
fi

python3 -c 'import sys,math; a=list(map(float,sys.argv[1:])); assert all(math.isfinite(v) and v>0 for v in a); assert a[0]<=a[2]<=2 and a[1]<=a[3]<=12' "$OCPUS" "$MEMORY_GB" "$TOTAL_OCPU_LIMIT" "$TOTAL_MEMORY_LIMIT" || { echo "ERROR: tamaños A1 inválidos; límite total 2 OCPU / 12 GB."; exit 1; }
if [[ "$SHAPE" != "VM.Standard.A1.Flex" ]]; then
  echo "ERROR: esta adaptación admite únicamente VM.Standard.A1.Flex."; exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "SIMULACIÓN: cuenta $TENANCY_NAME | region $REGION"
  echo "SIMULACIÓN: shape $SHAPE | ${OCPUS} OCPU / ${MEMORY_GB} GB"
  echo "SIMULACIÓN: OCI config $OCI_CONFIG_FILE"
  printf 'SIMULACIÓN: AD %s\n' "${ADS[@]}"
  exit 0
fi

if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
  echo "ERROR: Configuración OCI de cuenta $TENANCY_NAME no encontrada: $OCI_CONFIG_FILE"
  echo "Creá el perfil API y definí OCI_CONFIG_FILE en .env."
  exit 1
fi

OCI_BIN="${OCI_BIN:-}"
if [[ -z "$OCI_BIN" ]]; then
  OCI_BIN="$(command -v oci 2>/dev/null || true)"
fi
if [[ -z "$OCI_BIN" && -x "/usr/local/bin/oci" ]]; then
  OCI_BIN="/usr/local/bin/oci"
fi
if [[ -z "$OCI_BIN" && -x "/opt/homebrew/bin/oci" ]]; then
  OCI_BIN="/opt/homebrew/bin/oci"
fi

if [[ -z "$OCI_BIN" ]]; then
  echo "ERROR: No se encontró OCI CLI en PATH."
  exit 1
fi

OCI=("$OCI_BIN" --config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE" --region "$REGION" --read-timeout "$OCI_READ_TIMEOUT")
if [[ "$OCI_NO_RETRY" == "1" ]]; then
  OCI+=(--no-retry)
fi
export SUPPRESS_LABEL_WARNING=True

if ! [[ "$SLEEP_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: SLEEP_SECONDS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$MAX_RETRY_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: MAX_RETRY_DELAY_SECONDS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$CAPACITY_REQUEST_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CAPACITY_REQUEST_DELAY_SECONDS debe ser un entero positivo."
  exit 1
fi
if ! [[ "$OCI_READ_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OCI_READ_TIMEOUT debe ser un entero positivo."
  exit 1
fi
if ! [[ "$LAUNCH_MAX_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: LAUNCH_MAX_WAIT_SECONDS debe ser un entero positivo."
  exit 1
fi
if (( MAX_RETRY_DELAY_SECONDS < SLEEP_SECONDS )); then
  MAX_RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
fi

validate_oci_access() {
  local tenancy_name output
  if ! output=$("${OCI[@]}" iam tenancy get \
      --tenancy-id "$COMPARTMENT_ID" \
      --query 'data.name' \
      --raw-output 2>&1); then
    echo "ERROR: Autenticación o configuración OCI de cuenta $TENANCY_NAME inválida."
    echo "$output"
    exit 1
  fi
  tenancy_name="$output"
  if [[ -z "$tenancy_name" || "$tenancy_name" == "null" ]]; then
    echo "ERROR: OCI devolvió un valor vacío para cuenta nombre; proceso detenido."
    exit 1
  fi
  echo "Acceso OCI confirmado para cuenta: $cuenta_name"
}

is_fatal_oci_error() {
  grep -Eqi 'NotAuthenticated|NotAuthorized|AuthenticationFailed|Authorization failed|InvalidParameter|LimitExceeded|ConfigFileNotFound|No such file or directory|401|403' <<< "$1"
}

is_capacity_error() {
  grep -Eqi 'OUT_OF_HOST_CAPACITY|OutOfHostCapacity|out of host capacity|OutOfCapacity|capacity unavailable' <<< "$1"
}

is_rate_limit_error() {
  grep -Eqi 'TooManyRequests|too many requests|Throttl|status.?[": ]+429|HTTP.?429' <<< "$1"
}

is_network_error() {
  grep -Eqi 'timed out|timeout|connection|ConnectionError|RequestException|read timeout|Max retries exceeded|ConnectTimeout' <<< "$1"
}

# OCI request signatures use the local system clock. Query public NTP servers
# as a safety check, but do not substitute their time into OCI requests.
check_ntp_clock() {
  local sntp_bin="$SNTP_BIN"
  local ntp_server ntp_output offset absolute_offset
  local unsafe_response=0

  [[ "$NTP_CHECK_ENABLED" == "1" ]] || return 0

  if [[ -z "$sntp_bin" ]]; then
    sntp_bin="$(command -v sntp 2>/dev/null || true)"
  fi
  if [[ -z "$sntp_bin" ]]; then
    echo "ERROR: No se encontró sntp; se pausa la comprobación externa del reloj."
    return 1
  fi

  for ntp_server in "${NTP_SERVER_LIST[@]}"; do
    if ntp_output=$("$sntp_bin" -t "$NTP_TIMEOUT_SECONDS" "$ntp_server" 2>&1); then
      offset="$(printf '%s\n' "$ntp_output" | awk '$1 ~ /^[+-]?[0-9]+([.][0-9]+)?$/ { print $1; exit }')"
      if [[ -z "$offset" ]]; then
        echo "WARNING: Servidor NTP $ntp_server devolvió un desfase ilegible."
        continue
      fi

      absolute_offset="$(awk -v value="$offset" 'BEGIN { if (value < 0) value = -value; print value }')"
      if awk -v offset="$absolute_offset" -v maximum="$NTP_MAX_OFFSET_SECONDS" 'BEGIN { exit !(offset <= maximum) }'; then
        echo "Reloj NTP verificado: $ntp_server; desfase medido ${offset}s."
        return 0
      fi

      unsafe_response=1
      echo "WARNING: Desfase del reloj: ${offset}s según $ntp_server; trying the next Servidor NTP."
      continue
    fi

    echo "WARNING: Servidor NTP $ntp_server no respondió: $(printf '%s\n' "$ntp_output" | head -1)"
  done

  if (( unsafe_response )); then
    echo "ERROR: No configured Servidor NTP reported a safe clock offset."
  else
    echo "ERROR: No configured Servidor NTP responded with a readable clock offset."
  fi
  return 1
}

wait_for_ntp_clock() {
  while ! check_ntp_clock; do
    echo "WARNING: No se verificó el reloj; reintentando en ${NTP_RETRY_DELAY_SECONDS}s."
    sleep "$NTP_RETRY_DELAY_SECONDS"
  done
}

wait_for_ntp_clock
validate_oci_access

get_resource_id() {
  local kind="$1"
  local value

  if [[ "$kind" == "subnet" ]]; then
    if ! value=$("${OCI[@]}" network subnet list \
      --compartment-id "$COMPARTMENT_ID" \
      --display-name "$SUBNET_NAME" \
      --all \
      --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' \
      --raw-output); then
      return 1
    fi
  else
    if ! value=$("${OCI[@]}" compute image list \
      --compartment-id "$COMPARTMENT_ID" \
      --operating-system "$IMAGE_OS" \
      --operating-system-version "$IMAGE_OS_VERSION" \
      --shape "$SHAPE" \
      --sort-by TIMECREATED \
      --sort-order DESC \
      --all \
      --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' \
      --raw-output); then
      return 1
    fi
  fi

  printf '%s' "$value"
}

if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(get_resource_id subnet)
fi
if [[ -z "$IMAGE_ID" ]]; then
  IMAGE_ID=$(get_resource_id image)
fi

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
  echo "ERROR: No se encontró una subred disponible en el compartimento raíz."
  exit 1
fi
if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
  echo "ERROR: No se encontró una imagen Oracle Linux 9 para A1.Flex."
  exit 1
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "ERROR: No se encontró la clave pública SSH en $SSH_KEY_FILE"
  exit 1
fi

# --- Notification (macOS pop-up + sound) ---
notify() {
  local title="$1"
  local message="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"Glass\"" 2>/dev/null
  fi
  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --title "$title" --content "$message" 2>/dev/null || true
  fi
  echo "[NOTIFICACIÓN] ${title}: ${message}"
}

# --- Check the capacity report before a launch attempt ---
check_capacity() {
  local availability_domain="$1"
  "${OCI[@]}" compute compute-capacity-report create \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$availability_domain" \
    --shape-availabilities "[{\"instanceShape\":\"$SHAPE\",\"instanceShapeConfig\":{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}}]" \
    --query 'data."shape-availabilities"[0]."availability-status"' \
    --raw-output
}

# --- Sum OCPU and memory for all non-terminated A1.Flex instances in the compartment ---
get_total_usage() {
  "${OCI[@]}" compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --query "data[?shape=='$SHAPE' && \"lifecycle-state\" != 'TERMINATED' && \"lifecycle-state\" != 'TERMINATING'].{ocpus:\"shape-config\".ocpus, mem:\"shape-config\".\"memory-in-gbs\"}" \
    --raw-output
}

check_totals() {
  local json
  if ! json=$(get_total_usage); then
    return 1
  fi
  if [[ -z "$json" || "$json" == "null" ]]; then
    echo "ERROR: OCI devolvió una lista de uso vacía o nula." >&2
    return 1
  fi
  printf '%s' "$json" | python3 -c '
import json,sys,math
rows=json.load(sys.stdin)
if not isinstance(rows,list): raise ValueError("Lista de instancias inválida")
totals=[sum(float(row[key]) for row in rows) for key in ("ocpus","mem")]
if not all(math.isfinite(v) and v >= 0 for v in totals): raise ValueError("Uso inválido")
print(*totals)
'

}

echo "=========================================="
echo "Iniciando reintentos automáticos A1.Flex ($OCPUS OCPU / ${MEMORY_GB}GB por intento)"
echo "Límite total: $TOTAL_OCPU_LIMIT OCPU / ${TOTAL_MEMORY_LIMIT}GB (suma de instancias A1 del compartimento)"
echo "Región: $REGION | Espera: ${SLEEP_SECONDS}s | Espera entre consultas: ${CAPACITY_REQUEST_DELAY_SECONDS}s | Detener con Ctrl+C"
echo "=========================================="

target_reached() {
  python3 -c 'import sys; c,m,lc,lm=map(float,sys.argv[1:]); sys.exit(0 if c>=lc or m>=lm else 1)' "$1" "$2" "$TOTAL_OCPU_LIMIT" "$TOTAL_MEMORY_LIMIT"
}

attempt=0
RETRY_DELAY_SECONDS="$SLEEP_SECONDS"

while true; do
  rotate_log_if_needed

  if ! check_ntp_clock; then
    echo "[$(date '+%H:%M:%S')] AVISO: no se verificó el reloj; pausando OCI y reintentando en ${NTP_RETRY_DELAY_SECONDS}s."
    sleep "$NTP_RETRY_DELAY_SECONDS"
    continue
  fi

  if ! CURRENT_TOTALS="$(check_totals)"; then
    echo "[$(date '+%H:%M:%S')] ERROR: No se pudo consultar el uso A1; proceso detenido."
    notify "Oracle Cloud - ERROR" "Falló la consulta de instancias existentes."
    exit 1
  fi
  read -r CUR_OCPU CUR_MEM <<< "$CURRENT_TOTALS"
  CUR_OCPU="${CUR_OCPU:-0}"
  CUR_MEM="${CUR_MEM:-0}"

  echo "[$(date '+%H:%M:%S')] Uso actual: ${CUR_OCPU} OCPU / ${CUR_MEM}GB (límite: ${TOTAL_OCPU_LIMIT}/${TOTAL_MEMORY_LIMIT})"

  if target_reached "$CUR_OCPU" "$CUR_MEM"; then
    echo "=========================================="
    echo "LÍMITE ALCANZADO. El uso de ${CUR_OCPU} OCPU / ${CUR_MEM}GB alcanzó el límite."
    echo "Proceso finalizado."
    echo "=========================================="
    notify "Oracle Cloud - Completado" "Límite alcanzado: ${CUR_OCPU} OCPU / ${CUR_MEM}GB. Proceso detenido."
    exit 0
  fi

  cycle_had_capacity=0
  cycle_had_error=0
  cycle_had_rate_limit=0
  launch_succeeded=0
  launch_uncertain=0
  capacity_checks=0

  BASE_OCPUS="$OCPUS"
  BASE_MEMORY="$MEMORY_GB"
  SIZES=("$BASE_OCPUS/$BASE_MEMORY")
  [[ "${TRY_SMALLER:-1}" == "1" && "$BASE_OCPUS/$BASE_MEMORY" != "1/6" ]] && SIZES+=("1/6")
  for size in "${SIZES[@]}"; do
    IFS=/ read -r OCPUS MEMORY_GB <<< "$size"
    if ! python3 -c 'import sys; c,m,o,r,lc,lm=map(float,sys.argv[1:]); sys.exit(0 if c+o<=lc and m+r<=lm else 1)' "$CUR_OCPU" "$CUR_MEM" "$OCPUS" "$MEMORY_GB" "$TOTAL_OCPU_LIMIT" "$TOTAL_MEMORY_LIMIT"; then
      continue
    fi
  # Check every AD without waiting between them; wait only after the full cycle.
  for ad_suffix in "${ADS[@]}"; do
    attempt=$((attempt + 1))
    AD_FULL="$ad_suffix"

    if (( capacity_checks > 0 )); then
      sleep "$CAPACITY_REQUEST_DELAY_SECONDS"
    fi
    capacity_checks=$((capacity_checks + 1))

    CAPACITY_OUTPUT="$(check_capacity "$AD_FULL" 2>&1)"
    CAPACITY_EXIT=$?
    CAPACITY_STATUS="$(printf '%s\n' "$CAPACITY_OUTPUT" | awk 'NF { line=$0 } END { print line }' | tr -d '\r')"

    if (( CAPACITY_EXIT != 0 )); then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: falló el informe de capacidad:"
      echo "$CAPACITY_OUTPUT" | head -20
      if is_rate_limit_error "$CAPACITY_OUTPUT"; then
        echo "[$(date '+%H:%M:%S')] Límite de frecuencia OCI; aumentando la espera."
        cycle_had_rate_limit=1
      elif is_fatal_oci_error "$CAPACITY_OUTPUT"; then
        notify "Oracle Cloud - ERROR" "Proceso detenido por autenticación, configuración o cuota OCI."
        exit 1
      else
        cycle_had_error=1
      fi
      continue
    fi

    if [[ "$CAPACITY_STATUS" == "OUT_OF_HOST_CAPACITY" ]]; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: sin capacidad según el informe."
      cycle_had_capacity=1
      continue
    fi
    if [[ "$CAPACITY_STATUS" != "AVAILABLE" ]]; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: estado de capacidad=${CAPACITY_STATUS:-UNKNOWN}; se omite el lanzamiento."
      cycle_had_error=1
      continue
    fi

    echo "[$(date '+%H:%M:%S')] Intento #${attempt} - ${AD_FULL} (capacity AVAILABLE) ..."

    printf 'PENDIENTE %s %s %s/%s\n' "$(date -u +%FT%TZ)" "$AD_FULL" "$OCPUS" "$MEMORY_GB" > "$STATE_FILE" || exit 1
    RESULT="$("${OCI[@]}" compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD_FULL" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_GB}}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip "$ASSIGN_PUBLIC_IP" \
      --display-name "$DISPLAY_NAME" \
      --ssh-authorized-keys-file "$SSH_KEY_FILE" \
      --wait-for-state "$LAUNCH_WAIT_STATE" \
      --max-wait-seconds "$LAUNCH_MAX_WAIT_SECONDS" \
      --query 'data.id' \
      --raw-output \
      2>&1)"
    LAUNCH_EXIT=$?
    INSTANCE_ID="$(printf '%s\n' "$RESULT" | grep -Eo 'ocid1\.instance\.[A-Za-z0-9._-]+' | tail -n 1)"

    if (( LAUNCH_EXIT == 0 )); then
      if [[ -z "$INSTANCE_ID" ]]; then
        echo "[$(date '+%H:%M:%S')] El lanzamiento no devolvió OCID; no se repetirá sin revisión."
        echo "$RESULT" | head -20
        launch_uncertain=1
        break
      fi

      printf 'CREADA %s\n' "$INSTANCE_ID" > "$STATE_FILE"
      notify "Oracle Cloud - Instancia creada" "$INSTANCE_ID"
      echo "Instancia creada: $INSTANCE_ID. Proceso finalizado."
      exit 0
    fi

    if is_fatal_oci_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] Error OCI definitivo en ${AD_FULL}:"
      echo "$RESULT" | head -20
      notify "Oracle Cloud - ERROR" "Proceso detenido por autenticación, configuración o cuota OCI."
      exit 1
    elif is_rate_limit_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: Límite de frecuencia durante el lanzamiento."
      rm -f "$STATE_FILE"
      cycle_had_rate_limit=1
    elif is_capacity_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: lanzamiento sin capacidad. Continuando..."
      rm -f "$STATE_FILE"
      cycle_had_capacity=1
    elif is_network_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: falló la conexión tras el lanzamiento; consultando instancias existentes..."
      for recheck_delay in "${RECHECK_DELAYS[@]}"; do
        sleep "$recheck_delay"
        if ! RECHECK_TOTALS="$(check_totals)"; then
          echo "[$(date '+%H:%M:%S')] No se pudo confirmar el resultado; no se repetirá el lanzamiento."
          launch_uncertain=1
          break
        fi
        read -r RECHECK_OCPU RECHECK_MEM <<< "$RECHECK_TOTALS"
        RECHECK_OCPU="${RECHECK_OCPU:-0}"
        RECHECK_MEM="${RECHECK_MEM:-0}"
        if target_reached "$RECHECK_OCPU" "$RECHECK_MEM" || \
           python3 -c 'import sys; sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)' "$RECHECK_OCPU" "$CUR_OCPU"; then
          echo "La instancia fue creada pese al error de conexión. Finalizando."
          notify "Oracle Cloud - Instancia creada" "Se creó una instancia pese al error de conexión en ${AD_FULL}."
          exit 0
        fi
      done
      if (( launch_uncertain == 0 )); then
        echo "[$(date '+%H:%M:%S')] No se confirmó la instancia; se conserva el estado para revisión."
        launch_uncertain=1
      fi
      break
    else
      echo "[$(date '+%H:%M:%S')] Respuesta OCI desconocida en ${AD_FULL}; se conservará el estado para revisión:"
      echo "$RESULT" | head -10
      cycle_had_error=1
    fi
  done

  [[ -s "$STATE_FILE" ]] && break
  done
  OCPUS="$BASE_OCPUS"
  MEMORY_GB="$BASE_MEMORY"
  if [[ -s "$STATE_FILE" ]]; then
    echo "Resultado incierto: revisar Oracle antes de repetir. Estado: $STATE_FILE"
    exit 2
  fi

  if (( launch_uncertain )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    echo "[$(date '+%H:%M:%S')] Esperando ${RETRY_DELAY_SECONDS}s antes de revisar el lanzamiento incierto..."
    sleep "$RETRY_DELAY_SECONDS"
    continue
  fi

  if (( launch_succeeded )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    sleep "$RETRY_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_rate_limit )); then
    RETRY_DELAY_SECONDS=$(( RETRY_DELAY_SECONDS * 2 ))
    if (( RETRY_DELAY_SECONDS > MAX_RETRY_DELAY_SECONDS )); then
      RETRY_DELAY_SECONDS="$MAX_RETRY_DELAY_SECONDS"
    fi
    echo "[$(date '+%H:%M:%S')] Límite de frecuencia OCI; esperando ${RETRY_DELAY_SECONDS}s antes del siguiente ciclo."
    sleep "$RETRY_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_error )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    echo "[$(date '+%H:%M:%S')] Hubo un error; reintentando en ${RETRY_DELAY_SECONDS}s."
    sleep "$RETRY_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_capacity )); then
    echo "[$(date '+%H:%M:%S')] Sin capacidad en los dominios consultados. Esperando ${RETRY_DELAY_SECONDS}s antes del siguiente ciclo."
    sleep "$RETRY_DELAY_SECONDS"
    if (( RETRY_DELAY_SECONDS < MAX_RETRY_DELAY_SECONDS )); then
      RETRY_DELAY_SECONDS=$(( RETRY_DELAY_SECONDS * 2 ))
      if (( RETRY_DELAY_SECONDS > MAX_RETRY_DELAY_SECONDS )); then
        RETRY_DELAY_SECONDS="$MAX_RETRY_DELAY_SECONDS"
      fi
    fi
    continue
  fi

  RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
  sleep "$RETRY_DELAY_SECONDS"
done
