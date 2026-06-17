
#!/usr/bin/env bash
#
# fix-responder.sh
# ----------------------------------------------------------------------
# Run this against a Responder install transferred onto an offline/
# segmented host (e.g. via Ligolo-ng pivot during a pentest engagement).
#
# Problem it solves:
#   Kali's Responder unconditionally imports aioquic in utils.py (only
#   actually used by the optional QUIC poisoner) and calls sys.exit()
#   if it's missing. On a host with no internet access this kills the
#   entire tool, even though QUIC is set to Off in Responder.conf.
#   This script neutralizes that hard dependency so Responder starts
#   normally. It also flags any TCP ports Responder can't bind to
#   because another local service already owns them.
#
# Usage:
#   ./fix-responder.sh [path-to-responder-dir] [path-to-real-Responder.conf]
#   (responder-dir defaults to current directory if no path given)
#
#   The second argument is optional. If given, it's copied in to replace
#   Responder.conf whenever the one in responder-dir is a broken symlink
#   or missing entirely -- this is the file you grabbed from
#   /etc/responder/Responder.conf on your attack box.
# ----------------------------------------------------------------------

set -euo pipefail

RESP_DIR="${1:-.}"
REAL_CONF="${2:-}"
UTILS_FILE="$RESP_DIR/utils.py"
CONF_FILE="$RESP_DIR/Responder.conf"

echo "[*] Target Responder directory: $RESP_DIR"

# ---- 1. Sanity check ---------------------------------------------------
if [ ! -f "$UTILS_FILE" ]; then
    echo "[-] $UTILS_FILE not found. Point this script at the extracted Responder folder."
    exit 1
fi

# ---- 2. Fix a broken/missing Responder.conf -----------------------------
# Kali ships Responder.conf as a symlink to /etc/responder/Responder.conf.
# If you tar the responder/ folder without -h/--dereference, the symlink
# survives but its target usually doesn't exist on the new host. A missing
# config doesn't make Responder error out at startup -- configparser just
# silently sees zero sections, and you only find out when it crashes later
# on "NoSectionError: No section: 'Responder Core'". So this is treated as
# a hard blocker, not just a warning.
conf_broken=0
if [ -L "$CONF_FILE" ] && [ ! -e "$CONF_FILE" ]; then
    conf_broken=1
    echo "[!] $CONF_FILE is a broken symlink (target missing)."
elif [ ! -f "$CONF_FILE" ]; then
    conf_broken=1
    echo "[!] $CONF_FILE not found at all."
fi

if [ "$conf_broken" -eq 1 ]; then
    if [ -n "$REAL_CONF" ] && [ -f "$REAL_CONF" ]; then
        rm -f "$CONF_FILE"
        cp "$REAL_CONF" "$CONF_FILE"
        echo "[+] Installed real config from $REAL_CONF -> $CONF_FILE"
    else
        echo "    No real config supplied (or path doesn't exist). Pull it from your attack box:"
        echo "       attack box : cd /etc/responder && python3 -m http.server 8081"
        echo "       this host  : curl http://<attacker-ip>:8081/Responder.conf -o /tmp/Responder.conf.real"
        echo "    Then re-run this script with the second argument:"
        echo "       ./fix-responder.sh '$RESP_DIR' /tmp/Responder.conf.real"
        exit 1
    fi
fi

# ---- 3. Make sure QUIC is off in the config (cosmetic / consistency) ---
if [ -f "$CONF_FILE" ]; then
    if grep -qiE '^QUIC[[:space:]]*=[[:space:]]*On' "$CONF_FILE"; then
        sed -i -E 's/^(QUIC[[:space:]]*=[[:space:]]*)On/\1Off/I' "$CONF_FILE"
        echo "[+] Set QUIC = Off in Responder.conf"
    fi
fi

# ---- 4. Patch the unconditional aioquic import in utils.py -------------
if grep -q "aioquic check disabled" "$UTILS_FILE"; then
    echo "[*] utils.py already patched, skipping."
else
    backup="$UTILS_FILE.bak.$(date +%s)"
    cp "$UTILS_FILE" "$backup"
    echo "[*] Backed up original to $backup"

    python3 - "$UTILS_FILE" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

pattern = re.compile(
    r"try:\n[ \t]*import aioquic\nexcept:\n[ \t]*sys\.exit\(.*?aioquic.*?\)\n",
    re.DOTALL,
)

replacement = (
    "try:\n"
    "\timport aioquic  # aioquic check disabled, not needed for LLMNR/NBT-NS/MDNS/SMB poisoning\n"
    "except:\n"
    "\tpass\n"
)

patched, count = pattern.subn(replacement, src)

if count == 0:
    print("[-] Could not locate the expected aioquic try/except block.")
    print("    utils.py may differ from the version this script targets.")
    print("    Search manually with: grep -n aioquic utils.py")
    sys.exit(1)

with open(path, "w") as f:
    f.write(patched)

print(f"[+] Patched {count} block(s) in {path}")
PYEOF
fi

# ---- 5. Verify the file still parses cleanly ----------------------------
if python3 -c "import ast; ast.parse(open('$UTILS_FILE').read())"; then
    echo "[+] utils.py syntax OK"
else
    echo "[-] utils.py has a syntax error after patching."
    echo "    Restore from the .bak file and patch manually."
    exit 1
fi

# ---- 6. Report which Responder-relevant ports are already in use -------
echo ""
echo "[*] Checking for services already bound to common Responder ports..."
if ! command -v ss >/dev/null 2>&1; then
    echo "[!] 'ss' not found on this host, skipping port-conflict check."
    echo "    (try 'netstat -ltnp' manually if you need this info)"
else
    PORTS="21 25 53 80 110 137 138 139 143 389 443 445 993 1433 3389 5355"
    found_conflict=0
    for p in $PORTS; do
        owner=$(ss -ltnp 2>/dev/null | awk -v port="$p" '{n=split($4,a,":"); if (a[n]==port) print}' || true)
        if [ -n "$owner" ]; then
            found_conflict=1
            echo "[!] Port $p in use:"
            echo "    $owner"
        fi
    done
    if [ "$found_conflict" -eq 0 ]; then
        echo "[+] No conflicts found on common Responder ports."
    fi
fi

echo ""
echo "[*] Ports already owned by another service will make Responder skip"
echo "    just that one server ('Error starting TCP server on port N') --"
echo "    LLMNR/NBT-NS/MDNS poisoning and any free ports still work fine."
echo ""
echo "[+] Done. Run Responder with, e.g.:"
echo "    python3 $RESP_DIR/Responder.py -I <interface> -wf"
