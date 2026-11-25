#!/usr/bin/env bash
# Space Engineers 2 (SE2 Online) - lanceur pour AMP 3.
#
# Ce script est le point d'entree de l'instance : il applique les reglages du
# panneau dans server/server.json, retrouve le binaire reellement installe (son nom
# n'est pas suppose : il est lu dans server/.launch-exe, ecrit par l'installation)
# puis lance le serveur sous Wine.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$ROOT"   # ROOT est deja la racine du jeu (voir install.sh)
SRV="$BASE/server"
RT="$BASE/runtime"
LOG_PREFIX="[se2]"

say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ECHEC : %s\n' "$LOG_PREFIX" "$*"; exit 1; }

[ -d "$SRV" ] || die "dossier serveur absent ($SRV) : lancez Update"
[ -d "$RT/Game2" ] || say "ATTENTION : runtime absent ($RT/Game2) - le serveur ne demarrera pas"

export WINEPREFIX="$ROOT/.wine"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export DOTNET_ROOT="$RT/dotnet"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export SteamAppId=1133870
[ -d "$DOTNET_ROOT" ] && export PATH="$DOTNET_ROOT:$PATH"

# ---------------------------------------------------------------- reglages
# server.json appartient au serveur : on ne remplace que les cles que le panneau
# pilote, le reste (mods, monde, cles ajoutees a la main) est conserve tel quel.
if [ -f "$SRV/server.json" ]; then
python3 - "$SRV/server.json" <<'PY'
import json,os,sys
p=sys.argv[1]
def b(v,d=None):
    if v is None or v=="": return d
    return str(v).strip().lower() in ("1","true","yes","on")
def i(v,d=None):
    try: return int(float(str(v).strip()))
    except Exception: return d
def f(v,d=None):
    try: return float(str(v).strip())
    except Exception: return d
def s(v,d=None):
    v=(v or "").strip()
    return v if v else d
try:
    d=json.load(open(p))
except Exception as e:
    print("[se2] server.json illisible (%s) : reglages du panneau non appliques"%e); raise SystemExit(0)
net=d.get("Network")
if not isinstance(net,dict):
    net={}; d["Network"]=net
def setk(env,node,key,cast,default=None):
    if env in os.environ:
        v=cast(os.environ[env],default)
        if v is not None: node[key]=v
setk("SE2_SESSION_NAME",net,"SessionName",s)
setk("SE2_MAX_PLAYERS",net,"MaxPlayers",i)
setk("SE2_PASSWORD",net,"Password",s,"")
setk("SE2_ADVERTISE",net,"Advertise",b)
setk("SE2_PVP",net,"Pvp",b)
setk("SE2_LISTEN_PORT",net,"ListenPort",i)
setk("SE2_STREAMING_RADIUS",net,"StreamingRadiusMeters",i)
setk("SE2_SERVERS_DIRECTORY",net,"ServersDirectory",s)
setk("SE2_WORLD_NAME",d,"WorldName",s)
setk("SE2_MOTD",d,"Motd",s,"")
setk("SE2_AUTOSAVE",d,"EnableAutosave",b)
setk("SE2_SAVE_INTERVAL",d,"SaveIntervalSeconds",i)
setk("SE2_SHUTDOWN_COUNTDOWN",d,"ShutdownCountdownSeconds",i)
setk("SE2_RCON_ENABLED",d,"RconEnabled",b)
setk("SE2_RCON_PASSWORD",d,"RconPassword",s,"")
setk("SE2_RCON_PORT",d,"RconPort",i)
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n")
print("[se2] server.json : session=%r port=%s joueurs=%s rcon=%s/%s"%(
    net.get("SessionName"),net.get("ListenPort"),net.get("MaxPlayers"),
    d.get("RconEnabled"),d.get("RconPort")))
PY
else
  say "server.json absent : le serveur ecrira le sien avec ses valeurs par defaut"
fi

# ---------------------------------------------------------------- binaire
EXE="$(cat "$SRV/.launch-exe" 2>/dev/null || true)"
if [ -z "$EXE" ] || [ ! -f "$SRV/$EXE" ]; then
    EXE=$(python3 - "$SRV" <<'PY'
import os,sys
d=sys.argv[1]; c=[]
for root,_,files in os.walk(d):
    if root.count(os.sep)-d.count(os.sep)>1: continue
    for x in files:
        if x.lower().endswith('.exe'): c.append(os.path.relpath(os.path.join(root,x),d))
c.sort(key=lambda p:(0 if 'dedicatedserver' in p.lower() else 1,0 if 'y51' in p.lower() else 1,p.count(os.sep),len(p)))
print(c[0] if c else "")
PY
)
    [ -n "$EXE" ] || die "aucun .exe dans $SRV : lancez Update"
    printf '%s\n' "$EXE" > "$SRV/.launch-exe"
    say "binaire retrouve : $EXE"
fi
[ -f "$SRV/server.json" ] || [ -f "$SRV/server.example.json" ]

# Le panneau ecrit ses commandes (dont "stop") sur l'entree standard ; le
# serveur les lit sur sa console. wine transmet stdin tel quel.
cd "$SRV" || die "impossible d'entrer dans $SRV"
say "demarrage : $EXE"
exec wine "$EXE"
