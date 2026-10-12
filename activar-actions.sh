#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$TASK_DIR"
REPO="joselofarias-byte/oracle-cloud-a1-capacity-retry"
command -v gh >/dev/null || { echo 'Falta GitHub CLI: pkg install gh'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Iniciá sesión: gh auth login'; exit 1; }
[[ -f .env ]] || { echo 'Falta .env. Ejecutá bash termux.sh configurar'; exit 1; }
source .env
local_path() {
  if [[ "$1" == /termux-home/* ]]; then printf '%s/%s' "$HOME" "${1#/termux-home/}"; else printf '%s' "$1"; fi
}
CONFIG_PATH="$(local_path "$OCI_CONFIG_FILE")"
KEY_PATH="$HOME/.oci/oci_api_key.pem"
PUBLIC_PATH="$(local_path "$SSH_KEY_FILE")"
for file in "$CONFIG_PATH" "$KEY_PATH" "$PUBLIC_PATH"; do
  [[ -s "$file" ]] || { echo "No se encontró $file"; exit 1; }
done
# Check the actual Debian process lock before enabling an independent launcher.
proot-distro login debian -- flock -n "$LOCK_FILE" true || {
  echo 'El script de Termux sigue activo. Detenelo con Ctrl+C y repetí este comando.'; exit 1;
}
[[ ! -s .env.estado ]] || { echo 'Existe .env.estado. Revisá el resultado local antes de activar Actions.'; exit 1; }
[[ "$SUBNET_ID" == ocid1.subnet.* ]] || { echo 'SUBNET_ID inválido en .env'; exit 1; }
gh variable set A1_ENABLED --repo "$REPO" --body false
gh secret set OCI_CONFIG --repo "$REPO" < "$CONFIG_PATH"
gh secret set OCI_PRIVATE_KEY --repo "$REPO" < "$KEY_PATH"
gh secret set SSH_PUBLIC_KEY --repo "$REPO" < "$PUBLIC_PATH"
gh variable set A1_SUBNET_ID --repo "$REPO" --body "$SUBNET_ID"
gh variable set A1_DISPLAY_NAME --repo "$REPO" --body "$DISPLAY_NAME"
gh workflow enable a1-programado.yml --repo "$REPO"
gh variable set A1_ENABLED --repo "$REPO" --body true
gh workflow run a1-programado.yml --repo "$REPO" --ref main
echo "Activado. Estado y resultados: https://github.com/$REPO/actions/workflows/a1-programado.yml"
echo 'Podés cerrar Termux. No vuelvas a iniciar el lanzador local mientras Actions esté activo.'
