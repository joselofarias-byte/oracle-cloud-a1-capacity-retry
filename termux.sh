#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]]; then
  command -v proot-distro >/dev/null || pkg install -y proot-distro
  if ! proot-distro login debian -- true 2>/dev/null; then
    proot-distro install debian
  fi
  termux-wake-lock 2>/dev/null || true
  trap 'termux-wake-unlock 2>/dev/null || true' EXIT
  proot-distro login debian --bind "$TASK_DIR:/oracle-a1" --bind "$HOME:/termux-home" -- bash /oracle-a1/termux.sh "${1:-instalar}"
  exit
fi
cd "$TASK_DIR"
case "${1:-instalar}" in
  instalar)
    apt-get update
    apt-get install -y python3 python3-venv python3-dev build-essential libssl-dev libffi-dev bc util-linux
    python3 -m venv "$TASK_DIR/.venv"
    "$TASK_DIR/.venv/bin/pip" install oci-cli
    echo 'Instalación lista. Ejecutá: bash termux.sh configurar'
    ;;
  configurar|simular|consultar|iniciar)
    export PATH="$TASK_DIR/.venv/bin:$PATH"
    case "$1" in
      configurar) python3 configurar.py ;;
      simular) DRY_RUN=1 bash oci_capacity_retry.sh ;;
      consultar) python3 oracle_free_tier_checker.py --json ;;
      iniciar) bash oci_capacity_retry.sh ;;
    esac
    ;;
  *) echo 'Uso: bash termux.sh instalar|configurar|simular|consultar|iniciar'; exit 2 ;;
esac
