[Versión en español y flujo para Termux](README_ES.md)

# OCI Always Free A1.Flex Capacity Retry

This project monitors OCI Ampere A1 Flex capacity and attempts to launch a VM when OCI reports that capacity is available.

It is intended for an Always Free workload, but it does not assume a specific Oracle account, region, tenancy, or server. Account, placement, network, and retry settings are loaded from a local .env file.

## What the project does

- Checks existing A1.Flex usage before every attempt.
- Checks multiple availability domains through the OCI Capacity Report API.
- Skips a launch when OCI returns OUT_OF_HOST_CAPACITY.
- Spaces API calls to reduce the chance of TooManyRequests responses.
- Uses exponential backoff between retry cycles, with a configurable maximum.
- Launches an instance only when capacity is reported as available.
- Waits for the instance to reach RUNNING.
- Rechecks total OCPU and memory usage and stops when the target is reached.
- Checks the local system clock against a primary and fallback public NTP server before OCI calls.
- Stops on authentication or configuration errors instead of retrying forever.
- Never stores the private API key in the project.

## Files

| File | Purpose |
| --- | --- |
| oci_capacity_retry.sh | Main capacity-aware retry and launch process |
| oracle_free_tier_checker.py | Read-only capacity checker; it never creates instances |
| bootstrap_oci_network.sh | Idempotently creates a VCN, Internet Gateway, subnet, and SSH security list |
| .env.example | Safe configuration template without account secrets |
| .gitignore | Prevents .env files, keys, OCI config files, and logs from being committed |

The beginner-friendly, step-by-step guide for finding tenancy, compartment, availability domain, subnet, image, and user/API-key values is in [TUTORIAL_IDS.md](TUTORIAL_IDS.md). Its screenshots are intentionally masked.

## Prerequisites

- Bash
- Python 3
- OCI CLI
- bc for numeric limit comparisons
- An OCI API signing-key profile in the OCI CLI config
- An SSH public key for the instance

The OCI config file and private API key must remain outside this repository.

## Configuration

Copy the template and fill it with values from your tenancy:

~~~bash
cp .env.example .env
chmod 600 .env
~~~

Important variables:

| Variable | Description |
| --- | --- |
| TENANCY_NAME | Human-readable name used in logs |
| COMPARTMENT_ID | Root tenancy/compartment OCID used by the current script |
| REGION | Tenancy home region or the region where the resources exist |
| OCI_CONFIG_FILE / OCI_PROFILE | OCI CLI authentication profile |
| SHAPE | For example, VM.Standard.A1.Flex |
| OCPUS / MEMORY_GB | Size of one launch attempt |
| TOTAL_OCPU_LIMIT / TOTAL_MEMORY_LIMIT | Total usage limit after which the process stops |
| ADS | Comma-separated availability domains |
| SUBNET_ID / IMAGE_ID | Optional fixed IDs; empty values are resolved dynamically |
| SLEEP_SECONDS | Initial delay between retry cycles |
| MAX_RETRY_DELAY_SECONDS | Maximum exponential backoff delay |
| CAPACITY_REQUEST_DELAY_SECONDS | Delay between capacity-report calls |
| LOG_TO_FILE / LOG_DIR | Enable daily log files and optionally choose their directory |
| LOG_PREFIX | Prefix for daily log filenames |
| LOG_RETENTION_DAYS | Delete daily log files older than this many days; `3` keeps the current day plus recent history |
| NTP_CHECK_ENABLED | Check the system clock against public NTP before OCI calls |
| NTP_SERVERS | Comma-separated primary/fallback NTP hosts, for example `time.apple.com,pool.ntp.org,time.nist.gov` |
| NTP_MAX_OFFSET_SECONDS | Maximum accepted measured clock offset; `120` leaves margin below OCI's five-minute limit |
| NTP_TIMEOUT_SECONDS | Timeout for each NTP query |
| NTP_RETRY_DELAY_SECONDS | How long to wait before retrying when NTP is unavailable or unsafe |
| SSH_SOURCE_CIDR | TCP/22 source for the network helper; restrict it to your /32 when possible |

For the current Always Free A1 target, the total limit is 2 OCPU and 12 GB of memory. These values are configuration values, not hardcoded behavior.

## Running

Read-only capacity check:

~~~bash
python3 oracle_free_tier_checker.py --json
~~~

One-time dry run of the main script:

~~~bash
DRY_RUN=1 ./oci_capacity_retry.sh
~~~

Capacity retry and launch:

~~~bash
./oci_capacity_retry.sh
~~~

The script uses a lock file to prevent parallel launch processes. Keep runtime logs in a private directory outside the Git repository.

When `LOG_TO_FILE=1`, the script writes one log file per calendar day and checks for a new day at the start of every retry cycle. With `LOG_RETENTION_DAYS=3`, files older than three days are removed automatically. The active log and the most recent history remain available in `LOG_DIR`.

### Clock synchronization

OCI API requests are signed with the computer's local clock. The script uses `sntp` to compare that clock with the configured hosts in `NTP_SERVERS`. If one host reports an unsafe offset, the script tries the remaining hosts. If no host reports a safe offset, the process stays alive, pauses OCI calls, and retries after `NTP_RETRY_DELAY_SECONDS`; it does not exit. The NTP check does not replace the operating system clock or insert an NTP timestamp into the OCI request.

On macOS, enable automatic network time once with an administrator account:

~~~bash
sudo systemsetup -setnetworktimeserver time.apple.com
sudo systemsetup -setusingnetworktime on
sudo sntp -sS time.apple.com
~~~

The first two commands configure the Mac's system time source; the last command can correct the clock immediately. macOS supports one configured network time server, so `NTP_SERVERS` is the script's verification/fallback list, not a second system clock configuration. If the remote user cannot run `sudo`, an administrator must perform these commands or use System Settings → General → Date & Time → Set time and date automatically.

## Network

bootstrap_oci_network.sh can create:

- A VCN.
- An Internet Gateway.
- A default route through the Internet Gateway.
- A public subnet.
- A security list with SSH ingress and full egress.

Before using it in production, set SSH_SOURCE_CIDR to a known public IP address or VPN CIDR. The template default is open for compatibility but is not recommended for long-term use.

## Security and GitHub

This project intentionally does not contain:

- OCI private keys or API-key files.
- OCI config files.
- .env or remote deployment .env files.
- SSH private or public keys.
- SSH hostnames, users, or server ports.
- Runtime logs.
- Tenancy-specific values.

Before committing, run:

~~~bash
git status --ignored
git diff --cached --check
rg -n -i 'BEGIN .*PRIVATE KEY|ocid1\.|ddns|api_key|password|token|secret|ssh -p' . --glob '!README.md' --glob '!*.example'
~~~

Never push .env. If the repository is ever made public, run a fresh security review and rotate credentials if necessary before publishing it.

## Repository maintenance

The repository includes a small set of maintenance controls:

- [CONTRIBUTING.md](CONTRIBUTING.md) explains the review and validation workflow.
- [SECURITY.md](SECURITY.md) explains how to report a suspected vulnerability privately.
- [.github/CODEOWNERS](.github/CODEOWNERS) assigns review ownership to the repository owner.
- [.github/dependabot.yml](.github/dependabot.yml) checks GitHub Actions references for updates.
- [.github/workflows/ci.yml](.github/workflows/ci.yml) validates shell syntax, Python syntax, and safe dry-run behavior on pushes and pull requests.

The CI workflow never receives OCI credentials and never creates cloud resources. It runs only against the safe `.env.example` configuration.

Before making this repository public, review the security policy, remove any account-specific examples, confirm that the history contains no secrets, and choose an appropriate open-source license if the project will be shared under one.

## Limitations

OCI does not guarantee a time window for OUT_OF_HOST_CAPACITY. Retrying increases the chance of catching a short availability window, but it does not create capacity and is not a queue or reservation mechanism.

For PAYG accounts, Always Free resources can still remain within Always Free limits. Budget alerts and compartment quotas should still be configured before using billable resources.

## Project status

The project is configuration-neutral: account-specific values belong in the local .env file, while GitHub should contain only code, documentation, and the safe .env.example template.
