# -*- coding: utf-8 -*-
"""Fetch Flowseal zapret-discord-youtube strategies → OpenWrt .strategy files.

Each .strategy keeps the primary TCP hostlist profile (filter-tcp=80,443 + list-general),
which matches Skvoz nft (TCP 80/443 → nfqws). Full winws multi-profile is stored as comments.
"""
import json
import os
import re
import urllib.request
from pathlib import Path

REPO_API = "https://api.github.com/repos/Flowseal/zapret-discord-youtube/contents/"
RAW_BIN = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/bin/"
OUT = Path(__file__).resolve().parents[1] / "openwrt" / "usr" / "share" / "rvpn" / "zapret-strategies"
FAKE_OUT = Path(__file__).resolve().parents[1] / "openwrt" / "usr" / "share" / "rvpn" / "fake"
FAKES = [
    "stun.bin",
    "tls_clienthello_max_ru.bin",
    "tls_clienthello_www_google_com.bin",
    "tls_clienthello_4pda_to.bin",
    "quic_initial_www_google_com.bin",
    "quic_initial_dbankcloud_ru.bin",
]


def fetch_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "rvpn-import"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "rvpn-import"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def fetch_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "rvpn-import"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def slug(name: str) -> str:
    s = name.replace(".bat", "")
    s = re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_").lower()
    return s


def join_bat_continuation(text: str) -> str:
    """Collapse ^ continuations into one long start/winws command string."""
    lines = text.splitlines()
    buf = ""
    chunks = []
    for ln in lines:
        s = ln.rstrip()
        if s.endswith("^"):
            buf += s[:-1] + " "
            continue
        buf += s
        if buf.strip():
            chunks.append(buf)
        buf = ""
    if buf.strip():
        chunks.append(buf)
    for c in chunks:
        if "winws" in c.lower():
            return c
    return ""


def tokenize_args(cmd: str):
    # Drop windivert filter flags and start wrapper; keep --nfqws-like opts
    m = re.search(r"winws(?:\.exe)?\"?\s+(.+)$", cmd, flags=re.I)
    if not m:
        m = re.search(r"winws(?:\.exe)?\s+(.+)$", cmd, flags=re.I)
    rest = m.group(1) if m else cmd
    parts = re.findall(r'(?:--[^\s=]+(?:=(?:"[^"]*"|[^\s"]+))?)', rest)
    skip = ("--wf-", "--ssid")
    out = []
    for p in parts:
        if any(p.startswith(s) for s in skip):
            continue
        if "=" in p:
            k, v = p.split("=", 1)
            v = v.strip('"')
            v = v.replace("\\\\", "/").replace("\\", "/")
            # Expand bat vars to empty / skip game filter profiles
            if "%GameFilter" in v or "%BIN%" in v or "%LISTS%" in v:
                v = v.replace("%BIN%", "").replace("%LISTS%", "")
            base = os.path.basename(v)
            if v.endswith(".txt") or "list-" in base or "ipset-" in base:
                v = "LIST:" + base
            elif base.endswith(".bin"):
                v = "FAKE:" + base
            p = f"{k}={v}"
        out.append(p)
    return out


def split_profiles(args):
    profiles = []
    cur = []
    for a in args:
        if a == "--new":
            if cur:
                profiles.append(cur)
            cur = []
        else:
            cur.append(a)
    if cur:
        profiles.append(cur)
    return profiles


def is_primary_tcp_hostlist(prof):
    """Main website bypass: TCP 80,443 + list-general (not google-only, not ipset-only)."""
    ftcp = ""
    has_general = False
    has_google = False
    has_ipset = False
    for a in prof:
        if a.startswith("--filter-tcp="):
            ftcp = a.split("=", 1)[1]
        if "LIST:list-general" in a:
            has_general = True
        if "LIST:list-google" in a:
            has_google = True
        if a.startswith("--ipset=") and "LIST:" in a:
            has_ipset = True
    if has_ipset and not has_general:
        return False
    if has_google and not has_general:
        return False
    if "80" not in ftcp or "443" not in ftcp:
        return False
    return has_general or (not has_google and not has_ipset and "80" in ftcp)


def normalize_for_skvoz(prof):
    """Replace LIST:list-general* with HOSTLIST marker; drop user/exclude lists for router merge."""
    out = []
    for a in prof:
        if a.startswith("--hostlist=LIST:list-general"):
            out.append("--hostlist=HOSTLIST")
            continue
        if a.startswith("--hostlist=LIST:list-general-user"):
            continue
        if a.startswith("--hostlist-exclude="):
            continue
        if a.startswith("--ipset-exclude="):
            continue
        if a.startswith("--ipset="):
            continue
        if "%GameFilter" in a:
            continue
        out.append(a)
    # dedupe consecutive HOSTLIST
    dedup = []
    for a in out:
        if a == "--hostlist=HOSTLIST" and dedup and dedup[-1] == a:
            continue
        dedup.append(a)
    return dedup


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    raw_dir = OUT / "_raw_bats"
    raw_dir.mkdir(exist_ok=True)
    FAKE_OUT.mkdir(parents=True, exist_ok=True)

    data = fetch_json(REPO_API)
    bats = [x for x in data if x["name"].startswith("general") and x["name"].endswith(".bat")]
    print("bats", len(bats))

    ok = 0
    for x in bats:
        name = x["name"]
        try:
            text = fetch_text(x["download_url"])
        except Exception as e:
            print("FAIL", name, e)
            continue
        (raw_dir / name).write_text(text, encoding="utf-8")
        cmd = join_bat_continuation(text)
        args = tokenize_args(cmd)
        sid = slug(name)
        if not args:
            print("NOARGS", name)
            continue
        profiles = split_profiles(args)
        primary = None
        for p in profiles:
            if is_primary_tcp_hostlist(p):
                primary = normalize_for_skvoz(p)
                break
        if not primary:
            # fallback: first filter-tcp=80,443 profile
            for p in profiles:
                joined = " ".join(p)
                if "--filter-tcp=" in joined and "80" in joined and "443" in joined:
                    primary = normalize_for_skvoz(p)
                    break
        if not primary:
            print("NOPRIMARY", name, "profiles", len(profiles))
            continue

        body = [
            f"# source: Flowseal/zapret-discord-youtube {name}",
            f"# id={sid}",
            "# profile: primary TCP hostlist (Skvoz)",
        ]
        body.extend(primary)
        body.append("")
        body.append("# --- full profiles (reference) ---")
        for i, p in enumerate(profiles):
            body.append(f"# profile[{i}]: {' '.join(p)}")
        (OUT / f"{sid}.strategy").write_text("\n".join(body) + "\n", encoding="utf-8")
        print("OK", sid, "args", len(primary), "profiles", len(profiles))
        ok += 1

    # lists
    try:
        lists = fetch_json(REPO_API + "lists")
        ld = OUT / "lists"
        ld.mkdir(exist_ok=True)
        for f in lists:
            if f["type"] == "file" and f["name"].endswith(".txt"):
                (ld / f["name"]).write_bytes(fetch_bytes(f["download_url"]))
                print("LIST", f["name"])
    except Exception as e:
        print("lists fail", e)

    # fake bins
    for name in FAKES:
        dest = FAKE_OUT / name
        try:
            data_b = fetch_bytes(RAW_BIN + name)
            dest.write_bytes(data_b)
            print("FAKE", name, len(data_b))
        except Exception as e:
            print("FAKE fail", name, e)

    ids = sorted(p.stem for p in OUT.glob("*.strategy"))
    (OUT / "INDEX").write_text("\n".join(ids) + "\n", encoding="utf-8")
    meta = {
        "source": "https://github.com/Flowseal/zapret-discord-youtube",
        "strategies": ids,
        "count": len(ids),
    }
    (OUT / "META.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print("done strategies=", ok, "->", OUT)


if __name__ == "__main__":
    main()
