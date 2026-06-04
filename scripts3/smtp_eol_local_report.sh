#!/bin/bash
set -euo pipefail

# smtp_eol_local_report.sh
#
# Purpose:
#   Run locally on one legacy Postfix SMTP gateway and produce an EOL evidence report.
#
# What it identifies:
#   1) Outbound SMTP relay users still successfully sending through this gateway.
#   2) Inbound MX / routed recipient domains still active on this gateway.
#   3) MX records for those routed recipient domains.
#   4) Active-but-failing routed domains.
#   5) Inactive transport domains.
#
# Requirements:
#   - Run as root where possible.
#   - Uses standard shell tools plus awk.
#   - dig is preferred for MX checks; host is used as a fallback.
#
# Example:
#   chmod +x smtp_eol_local_report.sh
#   ./smtp_eol_local_report.sh
#
# Optional:
#   ./smtp_eol_local_report.sh --min-success 25 --outdir /var/tmp/smtp-eol
#
# Notes:
#   - This is a per-server report. Run it on each relay node.
#   - It does not prove contractual ownership.
#   - MX results should be reviewed before customer-facing statements.

MIN_SUCCESS=10
OUTDIR=""
LOG_GLOB="/var/log/maillog*"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --min-success)
      MIN_SUCCESS="$2"
      shift 2
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --log-glob)
      LOG_GLOB="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage:
  $0 [--min-success N] [--outdir DIR] [--log-glob '/var/log/maillog*']

Options:
  --min-success N   Minimum successful sent count for likely outbound clients.
                    Default: 10

  --outdir DIR      Output directory.
                    Default: ./smtp-eol-report-HOST-TIMESTAMP

  --log-glob GLOB   Mail log glob.
                    Default: /var/log/maillog*

Environment:
  MX_MATCH_REGEX    Optional regex used to flag MX records that appear to point
                    at your legacy platform, for example:
                    MX_MATCH_REGEX='lumison|pulsant|mail.lumison.net'

EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"

if [ -z "$OUTDIR" ]; then
  OUTDIR="./smtp-eol-report-${HOST}-${TS}"
fi

mkdir -p "$OUTDIR"

REPORT="$OUTDIR/ACTION_REPORT.md"
TECH_REPORT="$OUTDIR/TECHNICAL_REPORT.md"
METADATA="$OUTDIR/metadata.txt"
TRANSPORT_MAPS="$OUTDIR/transport-map-files.txt"
TRANSPORT_DOMAINS="$OUTDIR/transport-domains.tsv"
LOG_LIST="$OUTDIR/log-files.txt"

SUCCESSFUL_SENDERS="$OUTDIR/successful-sender-domains.tsv"
LIKELY_OUTBOUND="$OUTDIR/likely-outbound-smtp-users.tsv"
EXCLUDED_INTERNAL="$OUTDIR/excluded-internal-system-senders.tsv"
EXCLUDED_NOISY="$OUTDIR/excluded-noisy-external-senders.tsv"
BELOW_THRESHOLD="$OUTDIR/below-threshold-successful-senders.tsv"

SUCCESSFUL_FLOWS="$OUTDIR/successful-client-flows.tsv"
INBOUND_ROUTED="$OUTDIR/inbound-routed-recipient-domains.tsv"
ACTIVE_FAILING="$OUTDIR/active-but-failing-routed-domains.tsv"
INACTIVE_TRANSPORT="$OUTDIR/inactive-transport-domains.txt"
RECIPIENT_STATUS="$OUTDIR/recipient-status.tsv"
MX_CHECKS="$OUTDIR/mx-checks.tsv"

ALL_SENDERS="$OUTDIR/all-sender-domains.tsv"
ALL_CLIENT_IPS="$OUTDIR/all-client-ips.tsv"

TMPDIR_LOCAL="$OUTDIR/tmp"
mkdir -p "$TMPDIR_LOCAL"

echo "[*] Writing metadata..."
{
  echo "host=$HOST"
  echo "timestamp=$TS"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "uid=$(id -u 2>/dev/null || true)"
  echo "uname=$(uname -a)"
  echo "date_rfc=$(date -R)"
  echo
  echo "=== postconf -n ==="
  postconf -n 2>/dev/null || true
  echo
  echo "=== postmulti -l ==="
  postmulti -l 2>/dev/null || true
  echo
  echo "=== local IPv4 addresses ==="
  ip addr 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || /sbin/ifconfig 2>/dev/null | awk '/inet addr:/ {print $2}' | sed 's/addr://'
} > "$METADATA"

echo "[*] Locating transport map files..."
: > "$TRANSPORT_MAPS"

transport_maps="$(postconf -h transport_maps 2>/dev/null || true)"

if [ -n "$transport_maps" ]; then
  echo "$transport_maps" | tr ',' ' ' | tr ' ' '\n' | while read -r item; do
    [ -z "$item" ] && continue

    path="$item"

    case "$path" in
      hash:*|regexp:*|pcre:*|cidr:*|btree:*|dbm:*)
        path="${path#*:}"
        ;;
    esac

    path="${path%.db}"

    if [ -f "$path" ]; then
      echo "$path" >> "$TRANSPORT_MAPS"
    fi
  done
fi

# Fallbacks based on the legacy platform layout we have seen.
for candidate in \
  /etc/postfix/net/smtp/all_transport \
  /etc/postfix/transport \
  /etc/postfix/net/incoming-mail/transport \
  /etc/postfix/net/maildelivery/transport
do
  if [ -f "$candidate" ]; then
    grep -qxF "$candidate" "$TRANSPORT_MAPS" 2>/dev/null || echo "$candidate" >> "$TRANSPORT_MAPS"
  fi
done

sort -u "$TRANSPORT_MAPS" -o "$TRANSPORT_MAPS"

echo "[*] Extracting transport domains..."
{
  echo -e "domain\tdestination\tmap_file"
  while read -r mapfile; do
    [ -z "$mapfile" ] && continue
    [ ! -f "$mapfile" ] && continue

    awk -v mf="$mapfile" '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      NF >= 2 {
        domain=tolower($1)
        dest=""
        for (i=2; i<=NF; i++) {
          dest = dest (dest ? " " : "") $i
        }
        print domain "\t" dest "\t" mf
      }
    ' "$mapfile"
  done < "$TRANSPORT_MAPS"
} > "$TRANSPORT_DOMAINS"

echo "[*] Locating mail logs..."
: > "$LOG_LIST"

# shellcheck disable=SC2086
for f in $(ls -1tr $LOG_GLOB 2>/dev/null || true); do
  [ -f "$f" ] && echo "$f" >> "$LOG_LIST"
done

if [ ! -s "$LOG_LIST" ]; then
  echo "ERROR: no maillog files found using: $LOG_GLOB" >&2
  exit 2
fi

emit_logs() {
  while read -r f; do
    [ -z "$f" ] && continue
    [ ! -f "$f" ] && continue

    case "$f" in
      *.gz)
        gzip -cd "$f" 2>/dev/null || true
        ;;
      *)
        cat "$f" 2>/dev/null || true
        ;;
    esac
  done < "$LOG_LIST"
}

echo "[*] Analysing logs..."
emit_logs | awk \
  -v tfile="$TRANSPORT_DOMAINS" \
  -v min_success="$MIN_SUCCESS" \
  -v out_successful_senders="$SUCCESSFUL_SENDERS" \
  -v out_likely="$LIKELY_OUTBOUND" \
  -v out_internal="$EXCLUDED_INTERNAL" \
  -v out_noisy="$EXCLUDED_NOISY" \
  -v out_below="$BELOW_THRESHOLD" \
  -v out_flows="$SUCCESSFUL_FLOWS" \
  -v out_inbound="$INBOUND_ROUTED" \
  -v out_failing="$ACTIVE_FAILING" \
  -v out_inactive="$INACTIVE_TRANSPORT" \
  -v out_recipient_status="$RECIPIENT_STATUS" \
  -v out_all_senders="$ALL_SENDERS" \
  -v out_all_client_ips="$ALL_CLIENT_IPS" '
BEGIN {
  FS="\n"

  while ((getline line < tfile) > 0) {
    if (line ~ /^domain\t/) {
      continue
    }

    split(line, a, "\t")
    d=a[1]
    if (d != "") {
      transport[d]=1
      transport_dest[d]=a[2]
      transport_file[d]=a[3]
    }
  }
  close(tfile)
}

function domain_of(addr, x) {
  addr=tolower(addr)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", addr)

  if (addr == "" || addr == "<>") {
    return ""
  }

  if (addr !~ /@/) {
    return addr
  }

  x=addr
  sub(/^.*@/, "", x)
  return x
}

function is_internal_filter_relay(relay) {
  relay=tolower(relay)
  if (relay ~ /127\.0\.0\.1/ && relay ~ /:(10025|10026|10027|10028|20025)/) {
    return 1
  }
  return 0
}

function is_internal_domain(d) {
  d=tolower(d)

  if (d == "lumison.net" || d ~ /\.lumison\.net$/) {
    return 1
  }

  if (d == "pulsant.com" || d ~ /\.pulsant\.com$/) {
    return 1
  }

  if (d == "piiplat.net" || d ~ /\.piiplat\.net$/) {
    return 1
  }

  if (d == "localhost") {
    return 1
  }

  return 0
}

function is_noisy_sender(d) {
  d=tolower(d)

  if (d ~ /bounce\./) return 1
  if (d ~ /bounces\./) return 1
  if (d ~ /mailer/) return 1
  if (d ~ /mailjet/) return 1
  if (d ~ /hubspotemail/) return 1
  if (d ~ /constantcontact/) return 1
  if (d ~ /newsletter/) return 1
  if (d ~ /marketing/) return 1
  if (d ~ /email\./) return 1
  if (d ~ /^em\./) return 1
  if (d ~ /^em-/) return 1
  if (d ~ /e\.costco/) return 1
  if (d ~ /tomtom/) return 1
  if (d ~ /marksandspencer/) return 1
  if (d ~ /hollandandbarrett/) return 1
  if (d ~ /paypal/) return 1
  if (d == "gmail.com") return 1
  if (d == "hotmail.com") return 1
  if (d == "hotmail.co.uk") return 1
  if (d == "outlook.com") return 1
  if (d == "icloud.com") return 1
  if (d == "yahoo.com") return 1
  if (d == "yahoo.co.uk") return 1
  if (d == "google.com") return 1
  if (d ~ /googleusercontent\.com$/) return 1
  if (d ~ /rsgsv\.net$/) return 1

  return 0
}

function classify_sender(d, sent) {
  if (is_internal_domain(d)) {
    return "internal_system"
  }

  if (is_noisy_sender(d)) {
    return "noisy_external"
  }

  if (sent < min_success) {
    return "below_threshold"
  }

  return "likely_client"
}

function sort_cmd_numeric_desc(file) {
  return "sort -t\"\t\" -k2,2nr " file " -o " file
}

{
  line=$0

  # Accepted queue/client line
  if (match(line, /postfix\/smtpd\[[0-9]+\]: ([A-Z0-9]+): client=.*\[([0-9a-fA-F:.]+)\]/, m)) {
    qid=m[1]
    ip=m[2]
    client_ip[qid]=ip
    all_client_ips[ip]++
    next
  }

  # Sender line
  if (match(line, /postfix\/[^[]+\[[0-9]+\]: ([A-Z0-9]+): from=<([^>]*)>/, m)) {
    qid=m[1]
    from_addr=m[2]
    fd=domain_of(from_addr)

    if (fd != "") {
      from_domain[qid]=fd
      all_senders[fd]++
    }
    next
  }

  # Recipient/delivery status line
  if (match(line, /postfix\/[^[]+\[[0-9]+\]: ([A-Z0-9]+): to=<([^>]*)>.*relay=([^, ]+).*status=([A-Za-z_]+)/, m)) {
    qid=m[1]
    to_addr=m[2]
    relay=m[3]
    status=m[4]

    td=domain_of(to_addr)
    fd=from_domain[qid]
    ip=client_ip[qid]

    if (td != "" && (td in transport)) {
      transport_hits[td]++

      if (!is_internal_filter_relay(relay)) {
        transport_attempts[td]++
        transport_status[td, status]++
      }
    }

    if (is_internal_filter_relay(relay)) {
      next
    }

    if (td != "") {
      recipient_status[td, status]++
    }

    if (status == "sent" && fd != "") {
      successful_sender[fd]++
      flow_key=fd "\t" td "\t" (ip == "" ? "unknown" : ip)
      successful_flow[flow_key]++
    }

    next
  }
}

END {
  print "sender_domain\tsuccessful_sent\tclassification" > out_successful_senders
  print "sender_domain\tsuccessful_sent\tclassification" > out_likely
  print "sender_domain\tsuccessful_sent\tclassification" > out_internal
  print "sender_domain\tsuccessful_sent\tclassification" > out_noisy
  print "sender_domain\tsuccessful_sent\tclassification" > out_below

  for (d in successful_sender) {
    c=classify_sender(d, successful_sender[d])
    print d "\t" successful_sender[d] "\t" c >> out_successful_senders

    if (c == "likely_client") {
      print d "\t" successful_sender[d] "\t" c >> out_likely
    } else if (c == "internal_system") {
      print d "\t" successful_sender[d] "\t" c >> out_internal
    } else if (c == "noisy_external") {
      print d "\t" successful_sender[d] "\t" c >> out_noisy
    } else {
      print d "\t" successful_sender[d] "\t" c >> out_below
    }
  }

  print "sender_domain\trecipient_domain\tclient_ip\tsuccessful_sent" > out_flows
  for (k in successful_flow) {
    split(k, a, "\t")
    print a[1] "\t" a[2] "\t" a[3] "\t" successful_flow[k] >> out_flows
  }

  print "recipient_domain\tstatus\thits\tattempts\tsent\tdeferred\tbounced\tdestination\tmap_file" > out_inbound
  print "recipient_domain\thits\tattempts\tsent\tdeferred\tbounced\tdestination\tmap_file" > out_failing

  for (d in transport) {
    sent=transport_status[d, "sent"] + 0
    deferred=transport_status[d, "deferred"] + 0
    bounced=transport_status[d, "bounced"] + 0
    attempts=transport_attempts[d] + 0
    hits=transport_hits[d] + 0

    if (hits > 0 || attempts > 0) {
      if (sent > 0) {
        st="active_with_success"
      } else if (deferred > 0 && sent == 0) {
        st="active_but_failing"
      } else {
        st="active_seen_review"
      }

      print d "\t" st "\t" hits "\t" attempts "\t" sent "\t" deferred "\t" bounced "\t" transport_dest[d] "\t" transport_file[d] >> out_inbound

      if (st == "active_but_failing") {
        print d "\t" hits "\t" attempts "\t" sent "\t" deferred "\t" bounced "\t" transport_dest[d] "\t" transport_file[d] >> out_failing
      }
    } else {
      inactive[d]=1
    }
  }

  for (d in inactive) {
    print d >> out_inactive
  }

  print "recipient_domain\tsent\tdeferred\tbounced" > out_recipient_status
  for (d in recipient_status) {
    split(d, a, SUBSEP)
  }

  # recipient_status is indexed by domain,status, so output by scanning transport and all recipient domains seen.
  for (key in recipient_status) {
    split(key, a, SUBSEP)
    rd=a[1]
    recipient_seen[rd]=1
  }

  for (rd in recipient_seen) {
    print rd "\t" (recipient_status[rd, "sent"] + 0) "\t" (recipient_status[rd, "deferred"] + 0) "\t" (recipient_status[rd, "bounced"] + 0) >> out_recipient_status
  }

  print "sender_domain\taccepted_count" > out_all_senders
  for (d in all_senders) {
    print d "\t" all_senders[d] >> out_all_senders
  }

  print "client_ip\taccepted_queue_count" > out_all_client_ips
  for (ip in all_client_ips) {
    print ip "\t" all_client_ips[ip] >> out_all_client_ips
  }
}
'

# Sort output files for readability.
for f in \
  "$SUCCESSFUL_SENDERS" \
  "$LIKELY_OUTBOUND" \
  "$EXCLUDED_INTERNAL" \
  "$EXCLUDED_NOISY" \
  "$BELOW_THRESHOLD"
do
  if [ -s "$f" ]; then
    header="$(head -n 1 "$f")"
    tail -n +2 "$f" | sort -t "$(printf '\t')" -k2,2nr > "$f.sorted" || true
    {
      echo "$header"
      cat "$f.sorted"
    } > "$f"
    rm -f "$f.sorted"
  fi
done

if [ -s "$SUCCESSFUL_FLOWS" ]; then
  header="$(head -n 1 "$SUCCESSFUL_FLOWS")"
  tail -n +2 "$SUCCESSFUL_FLOWS" | sort -t "$(printf '\t')" -k4,4nr > "$SUCCESSFUL_FLOWS.sorted" || true
  {
    echo "$header"
    cat "$SUCCESSFUL_FLOWS.sorted"
  } > "$SUCCESSFUL_FLOWS"
  rm -f "$SUCCESSFUL_FLOWS.sorted"
fi

if [ -s "$INBOUND_ROUTED" ]; then
  header="$(head -n 1 "$INBOUND_ROUTED")"
  tail -n +2 "$INBOUND_ROUTED" | sort -t "$(printf '\t')" -k5,5nr -k3,3nr > "$INBOUND_ROUTED.sorted" || true
  {
    echo "$header"
    cat "$INBOUND_ROUTED.sorted"
  } > "$INBOUND_ROUTED"
  rm -f "$INBOUND_ROUTED.sorted"
fi

if [ -s "$INACTIVE_TRANSPORT" ]; then
  sort -u "$INACTIVE_TRANSPORT" -o "$INACTIVE_TRANSPORT"
fi

echo "[*] Performing MX checks for active routed recipient domains..."
{
  echo -e "recipient_domain\taction_status\tmx_records\tmx_regex_match\tlocal_ip_match"
  tail -n +2 "$INBOUND_ROUTED" | while IFS="$(printf '\t')" read -r domain action_status hits attempts sent deferred bounced dest mapfile; do
    [ -z "$domain" ] && continue

    mx_records=""

    if command -v dig >/dev/null 2>&1; then
      mx_records="$(dig +short MX "$domain" 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
    elif command -v host >/dev/null 2>&1; then
      mx_records="$(host -t MX "$domain" 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
    else
      mx_records="MX_CHECK_TOOL_NOT_FOUND"
    fi

    mx_regex_match="unknown"
    if [ -n "${MX_MATCH_REGEX:-}" ]; then
      if echo "$mx_records" | grep -Eiq "$MX_MATCH_REGEX"; then
        mx_regex_match="yes"
      else
        mx_regex_match="no"
      fi
    fi

    local_ip_match="unknown"
    local_ips="$( (ip addr 2>/dev/null || true) | awk '/inet / {print $2}' | cut -d/ -f1 | tr '\n' ' ' )"

    if command -v dig >/dev/null 2>&1 && [ -n "$mx_records" ]; then
      local_ip_match="no"

      echo "$mx_records" | tr ';' '\n' | awk '{print $NF}' | sed 's/\.$//' | while read -r mxhost; do
        [ -z "$mxhost" ] && continue
        dig +short A "$mxhost" 2>/dev/null || true
      done > "$TMPDIR_LOCAL/mx-a-records.tmp"

      while read -r mxip; do
        [ -z "$mxip" ] && continue
        for lip in $local_ips; do
          if [ "$mxip" = "$lip" ]; then
            local_ip_match="yes"
          fi
        done
      done < "$TMPDIR_LOCAL/mx-a-records.tmp"
    fi

    echo -e "${domain}\t${action_status}\t${mx_records}\t${mx_regex_match}\t${local_ip_match}"
  done
} > "$MX_CHECKS"

count_rows() {
  f="$1"
  if [ ! -s "$f" ]; then
    echo 0
    return
  fi
  n="$(($(wc -l < "$f") - 1))"
  [ "$n" -lt 0 ] && n=0
  echo "$n"
}

LIKELY_COUNT="$(count_rows "$LIKELY_OUTBOUND")"
INBOUND_COUNT="$(count_rows "$INBOUND_ROUTED")"
FAILING_COUNT="$(count_rows "$ACTIVE_FAILING")"
INACTIVE_COUNT="$(wc -l < "$INACTIVE_TRANSPORT" 2>/dev/null || echo 0)"
INTERNAL_COUNT="$(count_rows "$EXCLUDED_INTERNAL")"
NOISY_COUNT="$(count_rows "$EXCLUDED_NOISY")"
BELOW_COUNT="$(count_rows "$BELOW_THRESHOLD")"

echo "[*] Writing reports..."

{
  echo "# SMTP Gateway EOL Action Report"
  echo
  echo "Generated: $TS"
  echo
  echo "Host analysed: \`$HOST\`"
  echo
  echo "## Purpose"
  echo
  echo "This report identifies likely remaining users of this legacy Postfix SMTP gateway."
  echo
  echo "It separates two different usage types:"
  echo
  echo "1. **Outbound SMTP relay users** — systems sending mail through this gateway."
  echo "2. **Inbound MX / routed recipient domains** — domains receiving mail via this gateway."
  echo
  echo "## Executive summary"
  echo
  echo "- Likely outbound SMTP relay users: $LIKELY_COUNT"
  echo "- Outbound threshold: successful_sent >= $MIN_SUCCESS"
  echo "- Active inbound/routed recipient domains: $INBOUND_COUNT"
  echo "- Active but failing routed domains: $FAILING_COUNT"
  echo "- Inactive transport domains: $INACTIVE_COUNT"
  echo "- Excluded internal/system senders: $INTERNAL_COUNT"
  echo "- Excluded noisy external senders: $NOISY_COUNT"
  echo "- Below-threshold successful senders: $BELOW_COUNT"
  echo
  echo "## 1. Outbound SMTP relay users to contact"
  echo
  echo "These sender domains had successful deliveries through this gateway and were not classified as internal/system or obvious noisy external sender traffic."
  echo
  if [ "$LIKELY_COUNT" -gt 0 ]; then
    echo "| Sender domain | Successful sent | Classification |"
    echo "|---|---:|---|"
    tail -n +2 "$LIKELY_OUTBOUND" | while IFS="$(printf '\t')" read -r sender sent class; do
      echo "| \`$sender\` | $sent | $class |"
    done
  else
    echo "No likely outbound SMTP relay users found using current rules."
  fi

  echo
  echo "## 2. Inbound MX / routed recipient domains to review"
  echo
  echo "These are configured recipient/transport domains that were active on this gateway."
  echo
  echo "This does **not** mean POP/IMAP is hosted here. It means SMTP mail addressed to these domains was handled, attempted, routed, or delivered by Postfix."
  echo
  echo "Use the MX records as supporting evidence, but confirm before customer-facing statements."
  echo
  if [ "$INBOUND_COUNT" -gt 0 ]; then
    echo "| Recipient/routed domain | Status | Hits | Sent | Deferred | Bounced | MX records |"
    echo "|---|---|---:|---:|---:|---:|---|"
    tail -n +2 "$INBOUND_ROUTED" | while IFS="$(printf '\t')" read -r domain status hits attempts sent deferred bounced dest mapfile; do
      mx="$(awk -F'\t' -v d="$domain" 'NR>1 && $1==d {print $3; exit}' "$MX_CHECKS")"
      [ -z "$mx" ] && mx="not found"
      echo "| \`$domain\` | \`$status\` | $hits | $sent | $deferred | $bounced | $mx |"
    done
  else
    echo "No active inbound/routed recipient domains found."
  fi

  echo
  echo "## 3. Active but failing routed domains"
  echo
  echo "These domains are still being attempted but had no successful final delivery in the analysed logs."
  echo
  if [ "$FAILING_COUNT" -gt 0 ]; then
    echo "| Domain | Hits | Attempts | Sent | Deferred | Bounced |"
    echo "|---|---:|---:|---:|---:|---:|"
    tail -n +2 "$ACTIVE_FAILING" | while IFS="$(printf '\t')" read -r domain hits attempts sent deferred bounced dest mapfile; do
      echo "| \`$domain\` | $hits | $attempts | $sent | $deferred | $bounced |"
    done
  else
    echo "None found."
  fi

  echo
  echo "## 4. Decommission candidates"
  echo
  echo "$INACTIVE_COUNT transport domains had no log hits on this gateway."
  echo
  echo "Use:"
  echo
  echo "\`\`\`text"
  echo "inactive-transport-domains.txt"
  echo "\`\`\`"
  echo
  echo "Do not use this single-server inactive list as final cluster-wide evidence unless all relay nodes show the same result."
  echo
  echo "## Important interpretation notes"
  echo
  echo "- \`successful_sent\` means Postfix logged successful SMTP delivery/handoff."
  echo "- Sender-domain evidence identifies likely outbound SMTP relay use."
  echo "- Recipient-domain evidence identifies inbound/routed mail handling."
  echo "- MX records are checked live at report time and should be reviewed before customer-facing statements."
  echo "- Client IP may be unreliable after local content filtering/re-injection."
  echo "- Run this script on each legacy relay node and compare the reports before enforcing shutdown."
  echo
  echo "## Output files"
  echo
  echo "| File | Purpose |"
  echo "|---|---|"
  echo "| \`likely-outbound-smtp-users.tsv\` | Primary outbound SMTP contact list for this node |"
  echo "| \`inbound-routed-recipient-domains.tsv\` | Inbound/routed recipient domains active on this node |"
  echo "| \`mx-checks.tsv\` | Live MX records for inbound/routed domains |"
  echo "| \`active-but-failing-routed-domains.tsv\` | Active but failing routed domains |"
  echo "| \`inactive-transport-domains.txt\` | Per-node inactive transport domains |"
  echo "| \`successful-client-flows.tsv\` | Successful sender to recipient flows |"
  echo "| \`TECHNICAL_REPORT.md\` | Detailed evidence report |"
} > "$REPORT"

{
  echo "# SMTP Gateway EOL Technical Report"
  echo
  echo "Generated: $TS"
  echo
  echo "Host analysed: \`$HOST\`"
  echo
  echo "## Metadata"
  echo
  echo "\`\`\`text"
  cat "$METADATA"
  echo "\`\`\`"
  echo
  echo "## Transport map files"
  echo
  echo "\`\`\`text"
  cat "$TRANSPORT_MAPS"
  echo "\`\`\`"
  echo
  echo "## Log files analysed"
  echo
  echo "\`\`\`text"
  cat "$LOG_LIST"
  echo "\`\`\`"
  echo
  echo "## Likely outbound SMTP relay users"
  echo
  echo "\`\`\`text"
  cat "$LIKELY_OUTBOUND"
  echo "\`\`\`"
  echo
  echo "## Inbound/routed recipient domains"
  echo
  echo "\`\`\`text"
  cat "$INBOUND_ROUTED"
  echo "\`\`\`"
  echo
  echo "## MX checks"
  echo
  echo "\`\`\`text"
  cat "$MX_CHECKS"
  echo "\`\`\`"
  echo
  echo "## Active but failing routed domains"
  echo
  echo "\`\`\`text"
  cat "$ACTIVE_FAILING"
  echo "\`\`\`"
  echo
  echo "## Excluded internal/system senders"
  echo
  echo "\`\`\`text"
  cat "$EXCLUDED_INTERNAL"
  echo "\`\`\`"
  echo
  echo "## Excluded noisy external senders"
  echo
  echo "\`\`\`text"
  cat "$EXCLUDED_NOISY"
  echo "\`\`\`"
  echo
  echo "## Below-threshold successful senders"
  echo
  echo "\`\`\`text"
  cat "$BELOW_THRESHOLD"
  echo "\`\`\`"
  echo
  echo "## Successful client flows"
  echo
  echo "\`\`\`text"
  head -n 200 "$SUCCESSFUL_FLOWS"
  echo "\`\`\`"
  echo
  echo "## Inactive transport domains"
  echo
  echo "\`\`\`text"
  cat "$INACTIVE_TRANSPORT"
  echo "\`\`\`"
} > "$TECH_REPORT"

echo
echo "[OK] Wrote EOL report bundle:"
echo "  $OUTDIR"
echo
echo "[OK] Action report:"
echo "  $REPORT"
echo
echo "[OK] Technical report:"
echo "  $TECH_REPORT"
echo
echo "Read the action report with:"
echo "  cat \"$REPORT\""
echo
echo "Primary outbound SMTP contact file:"
echo "  $LIKELY_OUTBOUND"
echo
echo "Primary inbound/MX routed-domain review file:"
echo "  $INBOUND_ROUTED"
echo
echo "MX evidence file:"
echo "  $MX_CHECKS"
