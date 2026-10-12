#!/usr/bin/env python3
"""Consulta de capacidad OCI para Ampere A1 Flex, sin crear instancias.

The tenancy, region, shape, availability domains, and OCI profile are loaded
from .env. This tool only requests capacity reports; it never creates,
deletes, or changes an OCI instance.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_DIR = Path(__file__).resolve().parent


def load_env_file(path: Path) -> None:
    """Load simple KEY=value .env entries without overwriting real env vars."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValueError(f"No se pudo leer .env: {path}: {exc}") from exc

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        if not separator or not key.replace("_", "a").isalnum() or key[0].isdigit():
            continue
        value = value.strip()
        if value:
            try:
                tokens = shlex.split(value, comments=False, posix=True)
                value = tokens[0] if len(tokens) == 1 else value
            except ValueError:
                pass
        os.environ.setdefault(key, value)


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} falta o está vacío en .env")
    return value


@dataclass(frozen=True)
class Settings:
    tenancy_name: str
    compartment_ocid: str
    region: str
    config_file: Path
    profile: str
    oci_bin: str
    shape: str
    ocpus: float
    memory_gib: float
    availability_domains: tuple[str, ...]
    timeout_seconds: int


SETTINGS: Settings | None = None


def load_settings() -> Settings:
    oci_bin = os.environ.get("OCI_BIN", "").strip()
    if not oci_bin:
        oci_bin = shutil.which("oci") or ""
    if not oci_bin and Path("/usr/local/bin/oci").is_file():
        oci_bin = "/usr/local/bin/oci"
    if not oci_bin and Path("/opt/homebrew/bin/oci").is_file():
        oci_bin = "/opt/homebrew/bin/oci"
    if not oci_bin:
        raise ValueError("No se encontró OCI CLI en PATH o OCI_BIN")

    domains = tuple(
        item.strip()
        for item in required_env("ADS").split(",")
        if item.strip()
    )
    if not domains:
        raise ValueError("ADS no contiene dominios de disponibilidad")

    try:
        ocpus = float(required_env("OCPUS"))
        memory_gib = float(required_env("MEMORY_GB"))
        timeout_seconds = int(os.environ.get("OCI_READ_TIMEOUT", "30"))
    except ValueError as exc:
        raise ValueError("OCPUS, MEMORY_GB y OCI_READ_TIMEOUT deben ser números") from exc
    if ocpus <= 0 or memory_gib <= 0 or timeout_seconds <= 0:
        raise ValueError("OCPUS, MEMORY_GB y OCI_READ_TIMEOUT deben ser positivos")

    return Settings(
        tenancy_name=required_env("TENANCY_NAME"),
        compartment_ocid=required_env("COMPARTMENT_ID"),
        region=required_env("REGION"),
        config_file=Path(required_env("OCI_CONFIG_FILE")).expanduser(),
        profile=os.environ.get("OCI_PROFILE", "DEFAULT"),
        oci_bin=oci_bin,
        shape=required_env("SHAPE"),
        ocpus=ocpus,
        memory_gib=memory_gib,
        availability_domains=domains,
        timeout_seconds=timeout_seconds,
    )


def settings() -> Settings:
    if SETTINGS is None:
        raise RuntimeError("No se cargó la configuración")
    return SETTINGS


def shape_availability_request() -> list[dict[str, Any]]:
    current = settings()
    return [
        {
            "instanceShape": current.shape,
            "instanceShapeConfig": {
                "ocpus": current.ocpus,
                "memoryInGBs": current.memory_gib,
            },
        }
    ]


def build_command(availability_domain: str) -> list[str]:
    current = settings()
    command = [
        current.oci_bin,
        "--config-file",
        str(current.config_file),
        "--profile",
        current.profile,
        "--region",
        current.region,
        "--read-timeout",
        str(current.timeout_seconds),
    ]
    if os.environ.get("OCI_NO_RETRY", "1") == "1":
        command.append("--no-retry")
    command.extend(
        [
            "compute",
            "compute-capacity-report",
            "create",
            "--compartment-id",
            current.compartment_ocid,
            "--availability-domain",
            availability_domain,
            "--shape-availabilities",
            json.dumps(shape_availability_request(), separators=(",", ":")),
            "--output",
            "json",
        ]
    )
    return command


def extract_shape_availability(payload: dict[str, Any]) -> dict[str, Any]:
    data = payload.get("data", payload)
    if isinstance(data, list):
        entries = data
    else:
        entries = data.get(
            "shapeAvailabilities",
            data.get("shape-availabilities", data.get("shape_availabilities", [])),
        )
    if not entries:
        raise ValueError("OCI devolvió un informe de capacidad vacío")
    entry = entries[0]
    if not isinstance(entry, dict):
        raise ValueError("OCI devolvió un informe inválido")
    return entry


def configured_tenancy(config_file: Path, profile: str) -> str | None:
    """Read only the tenancy OCID from the selected OCI CLI profile."""
    parser = configparser.ConfigParser()
    try:
        with config_file.open(encoding="utf-8") as handle:
            parser.read_file(handle)
    except (OSError, configparser.Error):
        return None

    if profile.upper() == "DEFAULT":
        return parser.defaults().get("tenancy")
    if parser.has_section(profile):
        return parser[profile].get("tenancy")
    return None


def check_domain(availability_domain: str) -> dict[str, Any]:
    current = settings()
    command = build_command(availability_domain)
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=current.timeout_seconds,
            check=False,
        )
    except FileNotFoundError:
        return {
            "availability_domain": availability_domain,
            "available": None,
            "status": "ERROR",
            "error": "No se encontró OCI CLI",
        }
    except subprocess.TimeoutExpired:
        return {
            "availability_domain": availability_domain,
            "available": None,
            "status": "TIMEOUT",
            "error": f"La consulta OCI agotó su tiempo después de {current.timeout_seconds}s",
        }

    if completed.returncode != 0:
        error = (completed.stderr or completed.stdout).strip()
        return {
            "availability_domain": availability_domain,
            "available": None,
            "status": "ERROR",
            "error": error[-1200:] or f"Código de salida OCI {completed.returncode}",
        }

    try:
        entry = extract_shape_availability(json.loads(completed.stdout))
    except (json.JSONDecodeError, ValueError) as exc:
        return {
            "availability_domain": availability_domain,
            "available": None,
            "status": "ERROR",
            "error": str(exc),
        }

    status = entry.get("availability-status", entry.get("availabilityStatus"))
    available = entry.get("available")
    if status == "AVAILABLE": available = True
    elif status == "OUT_OF_HOST_CAPACITY": available = False
    shape_config = entry.get("instanceShapeConfig", entry.get("instance-shape-config", {}))
    return {
        "availability_domain": availability_domain,
        "available": available,
        "status": "AVAILABLE" if available is True else "OUT_OF_HOST_CAPACITY" if available is False else "UNKNOWN",
        "shape": entry.get("instanceShape", settings().shape),
        "ocpus": shape_config.get("ocpus", settings().ocpus),
        "memory_gib": shape_config.get("memoryInGBs", settings().memory_gib),
    }


def print_results(results: list[dict[str, Any]], as_json: bool) -> None:
    current = settings()
    if as_json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
        return

    print(f"{current.shape} | {int(current.ocpus)} OCPU | {int(current.memory_gib)} GB | {current.region}")
    for result in results:
        domain = result["availability_domain"]
        status = result["status"]
        if result.get("error"):
            print(f"{domain}: {status} - {result['error']}")
        else:
            print(f"{domain}: {status}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--env-file",
        type=Path,
        default=None,
        help="Ruta .env (predeterminada: ENV_FILE o junto al script)",
    )
    parser.add_argument(
        "--config-file",
        type=Path,
        default=None,
        help="Usar otra ruta de configuración OCI",
    )
    parser.add_argument(
        "--profile",
        default=None,
        help="Usar otro perfil OCI",
    )
    parser.add_argument("--timeout", type=int, default=None, help="Tiempo máximo por dominio en segundos")
    parser.add_argument("--watch", action="store_true", help="Repetir hasta Ctrl+C")
    parser.add_argument("--interval", type=int, default=30, help="Segundos entre ciclos")
    parser.add_argument("--stop-when-available", action="store_true", help="Detener al encontrar capacidad")
    parser.add_argument("--json", action="store_true", help="Mostrar JSON")
    parser.add_argument("--dry-run", action="store_true", help="Mostrar comandos sin consultar OCI")
    return parser.parse_args()


def main() -> int:
    global SETTINGS

    args = parse_args()
    if args.interval <= 0:
        print("--interval debe ser positivo", file=sys.stderr)
        return 2

    env_file = args.env_file or Path(os.environ.get("ENV_FILE", PROJECT_DIR / ".env"))
    env_file = env_file.expanduser()
    if not env_file.is_file():
        print(f"No se encontró .env: {env_file}. Copiá .env.example a .env.", file=sys.stderr)
        return 2

    try:
        load_env_file(env_file)
        if args.config_file is not None:
            os.environ["OCI_CONFIG_FILE"] = str(args.config_file.expanduser())
        if args.profile is not None:
            os.environ["OCI_PROFILE"] = args.profile
        if args.timeout is not None:
            if args.timeout <= 0:
                raise ValueError("--timeout debe ser positivo")
            os.environ["OCI_READ_TIMEOUT"] = str(args.timeout)
        SETTINGS = load_settings()
    except ValueError as exc:
        print(f"Error de configuración: {exc}", file=sys.stderr)
        return 2

    current = settings()
    if args.dry_run:
        for domain in current.availability_domains:
            print(" ".join(build_command(domain)))
        return 0

    selected_tenancy = configured_tenancy(current.config_file, current.profile)
    if selected_tenancy != current.compartment_ocid:
        print(
            "La configuración OCI no corresponde a la cuenta de .env "
            f"({current.tenancy_name}). Revisá OCI_CONFIG_FILE/OCI_PROFILE.",
            file=sys.stderr,
        )
        return 2

    try:
        while True:
            if args.watch and not args.json:
                print(datetime.now(timezone.utc).isoformat(timespec="seconds"))
            results = [check_domain(domain) for domain in current.availability_domains]
            print_results(results, args.json)

            if not args.watch or (
                args.stop_when_available and any(item.get("available") is True for item in results)
            ):
                return 0 if any(item["status"] != "ERROR" for item in results) else 1
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nInterrumpido.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
