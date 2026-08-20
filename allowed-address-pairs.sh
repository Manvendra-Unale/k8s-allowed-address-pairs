#!/usr/bin/env bash
# Sheet CSV: Sr No,Kubernetes nodes,Location,Allowed Address Pairs (';'-separated CIDRs)
#
# For each VM in the sheet:
#   1. Find its vJailbreak Migration CR (by spec.vmName) to get the migration name.
#   2. Read that migration's log (/var/log/pf9/<migration-name>.log) and check
#      for vJailbreak's own "Port created successfully: MAC:<mac>" line - this
#      is the earliest, most reliable signal the port exists, since vJailbreak
#      creates the Neutron port BEFORE the Nova instance exists (so waiting on
#      `openstack server show` would miss this window).
#   3. Resolve each MAC to its Neutron port and merge the sheet's
#      allowed-address-pairs into it (never overwriting existing pairs).
#
# No port found yet -> logged and skipped; picked up automatically on the
# next run once vJailbreak's log confirms port creation.
set -uo pipefail

CSV="${1:-/opt/scripts/allowed-address-pairs.csv}"
LOG="${LOG_FILE:-/var/log/pf9/aap-sync.log}"
LOCK="/var/run/aap-sync.lock"
NAMESPACE="${AAP_NAMESPACE:-migration-system}"
MIG_LOG_DIR="${MIG_LOG_DIR:-/var/log/pf9}"

# Prevent two overlapping runs (e.g. a slow run still going when the next
# cron tick fires) from racing on the same port.
exec 200>"$LOCK"
flock -n 200 || { echo "Another run is already in progress - exiting"; exit 0; }

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

[[ -f "$CSV" ]] || { log "ERROR: CSV file not found: $CSV"; exit 1; }

# name<TAB>vmName for every Migration CR, fetched once per run (not per VM).
# Checked explicitly so a broken kubectl context/RBAC issue is reported as
# an error, rather than silently looking identical to "no VMs migrated yet".
if ! migrations=$(kubectl get migration -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.vmName}{"\n"}{end}' 2>>"$LOG"); then
  log "ERROR: 'kubectl get migration -n $NAMESPACE' failed - check kubectl context/RBAC access (see $LOG for details)"
  exit 1
fi

tail -n +2 "$CSV" | while IFS=, read -r sr vm loc pairs; do
  vm=$(echo "$vm" | xargs)
  pairs=$(echo "$pairs" | tr -d '\r' | xargs)
  [[ -z "$vm" || -z "$pairs" ]] && continue

  # Validate each entry looks like an IPv4 address/CIDR before using it.
  valid_pairs=()
  IFS=';' read -ra ip_list <<< "$pairs"
  for ip in "${ip_list[@]}"; do
    ip=$(echo "$ip" | xargs)
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
      valid_pairs+=("$ip")
    else
      log "WARN: VM '$vm': skipping invalid IP/CIDR '$ip'"
    fi
  done
  [[ ${#valid_pairs[@]} -eq 0 ]] && continue

  # Map VM name -> Migration CR name via the pre-fetched list (case-insensitive,
  # since sheet entries and spec.vmName casing aren't guaranteed to match exactly).
  migration_name=$(awk -F'\t' -v vm="$vm" 'tolower($2)==tolower(vm){print $1}' <<<"$migrations" | head -1)
  if [[ -z "$migration_name" ]]; then
    log "VM '$vm': no Migration found for this VM name - skipping"
    continue
  fi

  logfile="$MIG_LOG_DIR/${migration_name}.log"
  if [[ ! -f "$logfile" ]]; then
    log "VM '$vm' (migration $migration_name): migration log not found yet - skipping"
    continue
  fi

  # vJailbreak logs "Port created successfully: MAC:<mac> IP:..." once per
  # NIC as soon as the Neutron port exists - well before the Nova instance
  # does. Pull every MAC this VM's migration has logged so far. Note: if a
  # migration was retried after a failure, this log is append-only across
  # attempts, so a stale MAC from an earlier failed attempt's now-deleted
  # port may also appear here - harmless, since the port lookup below will
  # just find nothing for it and skip (logged, not an error).
  macs=$(grep -oP 'Port created successfully: MAC:\K[0-9A-Fa-f:]+' "$logfile" | sort -u)
  if [[ -z "$macs" ]]; then
    log "VM '$vm' (migration $migration_name): port not found in migration log yet - skipping"
    continue
  fi

  for mac in $macs; do
    port=$(openstack port list --insecure --mac-address "$mac" -f value -c ID)
    if [[ -z "$port" ]]; then
      log "VM '$vm' mac $mac: port not found in Neutron yet - skipping"
      continue
    fi

    existing=$(openstack port show "$port" --insecure -f value -c allowed_address_pairs | grep -oP "ip_address='\K[^']+")
    existing_sorted=$(printf '%s\n' $existing | sed '/^$/d' | sort -u)
    all_ips=$(printf '%s\n' $existing "${valid_pairs[@]}" | sed '/^$/d' | sort -u)

    # Skip the write entirely if the merged result is identical to what's
    # already on the port - still re-verified every run (self-healing if the
    # pairs ever drift or get removed by something else), just no wasted
    # write call when nothing actually needs to change.
    if [[ "$all_ips" == "$existing_sorted" ]]; then
      log "VM '$vm' port $port (mac $mac): already up to date - no change needed"
      continue
    fi

    args=""
    for ip in $all_ips; do args+=" --allowed-address ip-address=$ip"; done

    if openstack port set --insecure $args "$port" 2>>"$LOG"; then
      log "VM '$vm' port $port (mac $mac): applied allowed-address-pairs [$(echo "$all_ips" | tr '\n' ' ')]"
    else
      log "ERROR: VM '$vm' port $port (mac $mac): failed to apply allowed-address-pairs"
    fi
  done
done
