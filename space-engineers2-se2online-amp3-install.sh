#!/usr/bin/env bash
# Space Engineers 2 (SE2 Online) - installation et mise a jour pour AMP 3.
#
# Deux sources par artefact, dans cet ordre :
#   1. une archive deja deposee par l'operateur dans $BASE/packs, reconnue par son
#      nom, sa taille et son sha256 (le meme mecanisme que les packs de mods) ;
#   2. un telechargement par URL, verifie par taille et sha256 avant usage.
# Aucune etape ne suppose un dossier existant : tout est cree avec mkdir -p, et le
# script ne fait jamais cd dans un chemin qui peut manquer (c'est ce qui faisait
# echouer le template d'origine sur "cd: /amp/space-engineers2/: No such file").
set -uo pipefail

ROOT="${ROOT:-${1:-}}"
[ -n "$ROOT" ] || { echo "[se2] ROOT manquant : rien a installer"; exit 1; }
# ROOT est deja la racine du jeu (App.RootDir=./se2online/ cote kvp, resolue en
# /amp/<instance>/se2online). Y rajouter "se2online" creait /amp/<instance>/se2online/se2online :
# l installation ecrivait 18 fichiers la ou AMP attend /amp/<instance>/se2online/server, et
# l etape suivante declarait « aucun binaire ». On ne fait que normaliser la barre finale.
BASE="${ROOT%/}"
SRV="$BASE/server"
RT="$BASE/runtime"
PACKS="$BASE/${PACKS_DIR:-packs}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main}"
SELF="space-engineers2-se2online-amp3"

SERVER_URL="${SERVER_URL:-}"
SERVER_SHA256="${SERVER_SHA256:-}"
SERVER_SIZE="${SERVER_SIZE:-0}"
RUNTIME_URL="${RUNTIME_URL:-}"
RUNTIME_SHA256="${RUNTIME_SHA256:-}"
RUNTIME_SIZE="${RUNTIME_SIZE:-0}"
# AMP transmet les cases a cocher en "True"/"False", pas en "1" : une egalite stricte a "1"
# laissait le runtime desactive alors que la case etait cochee.
truthy() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
INSTALL_RUNTIME="${INSTALL_RUNTIME:-1}"
VERSION_PHP="${VERSION_PHP:-https://se2-online.yellow51.dev/version.php}"

log()  { printf '[se2] %s\n' "$*"; }
warn() { printf '[se2] ATTENTION : %s\n' "$*"; }
die()  { printf '[se2] ECHEC : %s\n' "$*"; exit 1; }

sha_of() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true; }
size_of() { [ -f "$1" ] && stat -c %s "$1" 2>/dev/null || echo 0; }

# Le manifeste publie par l'auteur donne version, URL, taille et sha256 des deux
# artefacts. Il sert de defaut quand le panneau ne fixe rien, et de temoin de
# version dans le rapport final. Aucun secret n'y figure.
read_manifest() {
    local json kf
    json=$(curl -fsSL --max-time 30 "$VERSION_PHP" 2>/dev/null) || json=""
    [ -n "$json" ] || { warn "version.php injoignable : je m'appuie uniquement sur le panneau et le dossier packs"; return 0; }
    kf=$(mktemp) || return 0
    if printf '%s' "$json" | python3 -c '
import json,shlex,sys
d=json.load(sys.stdin)
s=d.get("server") or {}
r=d.get("runtimes") or {}
rt=r.get(s.get("engine") or "") or {}
vals={
 "MANIFEST_PLUGIN_VERSION": d.get("version",""),
 "MANIFEST_SERVER_URL": s.get("url",""),
 "MANIFEST_SERVER_SHA256": s.get("sha256",""),
 "MANIFEST_SERVER_SIZE": s.get("size",0),
 "MANIFEST_RUNTIME_URL": rt.get("url",""),
 "MANIFEST_RUNTIME_SHA256": rt.get("sha256",""),
 "MANIFEST_RUNTIME_SIZE": rt.get("size",0),
 "MANIFEST_RUNTIME_VERSION": rt.get("version", s.get("engine","")),
}
for k,v in vals.items(): print("%s=%s"%(k,shlex.quote(str(v))))
' > "$kf" 2>/dev/null; then
        # shellcheck disable=SC1090
        . "$kf"
    else
        warn "version.php illisible : manifeste ignore"
    fi
    rm -f "$kf"
    [ -n "${SERVER_URL:-}" ]  || SERVER_URL="${MANIFEST_SERVER_URL:-}"
    [ -n "${SERVER_SHA256:-}" ] || SERVER_SHA256="${MANIFEST_SERVER_SHA256:-}"
    [ "${SERVER_SIZE:-0}" != 0 ] || SERVER_SIZE="${MANIFEST_SERVER_SIZE:-0}"
    [ -n "${RUNTIME_URL:-}" ] || RUNTIME_URL="${MANIFEST_RUNTIME_URL:-}"
    [ -n "${RUNTIME_SHA256:-}" ] || RUNTIME_SHA256="${MANIFEST_RUNTIME_SHA256:-}"
    [ "${RUNTIME_SIZE:-0}" != 0 ] || RUNTIME_SIZE="${MANIFEST_RUNTIME_SIZE:-0}"
}

# Cherche dans le dossier packs une archive dont le sha256 correspond. Le nom
# attendu passe en premier, mais l'empreinte fait foi : un fichier renomme par
# l'operateur reste accepte, un fichier altere est refuse.
pack_by_sha() {
    local want="$1" prefer="${2:-}" f
    [ -n "$want" ] || return 1
    if [ -n "$prefer" ] && [ -f "$PACKS/$prefer" ] && [ "$(sha_of "$PACKS/$prefer")" = "$want" ]; then
        printf '%s\n' "$PACKS/$prefer"; return 0
    fi
    for f in "$PACKS"/*.zip; do
        [ -f "$f" ] || continue
        if [ "$(sha_of "$f")" = "$want" ]; then printf '%s\n' "$f"; return 0; fi
    done
    return 1
}

# Telecharge vers .part, verifie taille ET sha256, puis renomme. Une archive
# refusee ne remplace jamais une archive valide deja en place.
fetch_verified() {
    local url="$1" want="$2" size="$3" dest="$4"
    [ -n "$url" ] || return 1
    if [ -f "$dest" ] && { [ -z "$want" ] || [ "$(sha_of "$dest")" = "$want" ]; }; then
        log "deja present : $(basename "$dest")"; return 0
    fi
    log "telechargement : $url"
    if ! curl -fL --retry 3 --retry-delay 5 --max-time 3600 \
              --progress-bar -o "$dest.part" "$url"; then
        rm -f "$dest.part"; warn "telechargement echoue : $url"; return 1
    fi
    if [ "$size" != 0 ] && [ "$(size_of "$dest.part")" != "$size" ]; then
        warn "taille inattendue pour $(basename "$dest") : $(size_of "$dest.part") au lieu de $size"
        rm -f "$dest.part"; return 1
    fi
    if [ -n "$want" ] && [ "$(sha_of "$dest.part")" != "$want" ]; then
        warn "sha256 inattendu pour $(basename "$dest") : $(sha_of "$dest.part") au lieu de $want"
        rm -f "$dest.part"; return 1
    fi
    mv -f "$dest.part" "$dest"
    log "verifie : $(basename "$dest") ($(size_of "$dest") octets, sha256 ${want:-non fourni})"
}

unzip_to() {
    local zip="$1" dest="$2"
    mkdir -p "$dest" || die "impossible de creer $dest"
    python3 - "$zip" "$dest" <<'PY' || return 1
import os,sys,zipfile
z,dest=sys.argv[1],os.path.abspath(sys.argv[2])
n=0
with zipfile.ZipFile(z) as zf:
    for i in zf.infolist():
        p=os.path.abspath(os.path.join(dest,i.filename))
        if not p.startswith(dest+os.sep): raise SystemExit("entree hors du dossier: "+i.filename)
    for i in zf.infolist():
        zf.extract(i,dest); n+=1
print("[se2] %d entree(s) extraite(s) dans %s"%(n,dest))
PY
}

free_kb() { df -Pk "$BASE" 2>/dev/null | awk 'NR==2{print $4}'; }

discover_exe() {
    python3 - "$SRV" <<'PY'
import os,sys
d=sys.argv[1]; cands=[]
for root,_,files in os.walk(d):
    if root.count(os.sep)-d.count(os.sep)>1: continue
    for f in files:
        if f.lower().endswith('.exe'):
            cands.append(os.path.relpath(os.path.join(root,f),d))
def rank(p):
    l=p.lower()
    return (0 if 'dedicatedserver' in l else 1, 0 if 'y51' in l else 1, p.count(os.sep), len(p))
cands.sort(key=rank)
print(cands[0] if cands else "")
PY
}

mkdir -p "$BASE" "$SRV" "$RT" "$PACKS" || die "impossible de creer $BASE"
log "dossier d'instance : $BASE"
read_manifest

# ---------------------------------------------------------------- serveur (45 Mo)
SERVER_ZIP=""
if [ -n "$SERVER_SHA256" ] && SERVER_ZIP=$(pack_by_sha "$SERVER_SHA256" "Y51_SE2Online-DedicatedServer.zip"); then
    log "archive du serveur fournie par l'operateur : $SERVER_ZIP"
else
    # Nettoyage de l ancien defaut : les premieres versions empilaient la racine et ecrivaient
    # dans $BASE/se2online. Ce dossier ne sert plus, et ses tampons d etat fausseraient la suite.
    if [ -d "$BASE/se2online" ] && { [ -f "$BASE/se2online/.etat-server" ] || [ -d "$BASE/se2online/server" ]; }; then
        rm -rf "$BASE/se2online" && log "ancien dossier double supprime : $BASE/se2online"
    fi

    fetch_verified "$SERVER_URL" "$SERVER_SHA256" "$SERVER_SIZE" "$BASE/server.zip" \
        || die "aucune archive serveur utilisable : deposez le zip dans $PACKS (nom, taille et sha256 verifies) ou renseignez ServerZipUrl"
    SERVER_ZIP="$BASE/server.zip"
fi
SERVER_SHA_NOW=$(sha_of "$SERVER_ZIP")
if [ "$(cat "$BASE/.etat-server" 2>/dev/null)" != "$SERVER_SHA_NOW" ] || [ ! -f "$SRV/.launch-exe" ]; then
    log "installation du serveur SE2 Online"
    unzip_to "$SERVER_ZIP" "$SRV" || die "extraction impossible de $SERVER_ZIP"
    printf '%s\n' "$SERVER_SHA_NOW" > "$BASE/.etat-server"
else
    log "serveur deja installe pour cette empreinte, rien a extraire"
fi

# ---------------------------------------------------------------- runtime (7.4 Go)
# L archive du runtime contient un dossier "runtime/" a sa racine : extraite dans $RT, elle
# donne $RT/runtime/Game2 et le controle $RT/Game2 echoue — le serveur refuse alors de
# demarrer en annoncant un runtime absent, alors que 9 Go viennent d etre extraits.
# On remonte le contenu d un niveau au lieu de retelecharger 7,4 Go.
normaliser_runtime() {
    [ -d "$RT/Game2" ] && return 0
    g=$(find "$RT" -maxdepth 4 -type d -name Game2 2>/dev/null | head -1)
    [ -n "$g" ] || return 1
    parent=$(dirname "$g")
    [ "$parent" = "$RT" ] && return 0
    log "runtime imbrique dans ${parent#"$BASE"/} : contenu remonte a la racine"
    shopt -s dotglob nullglob
    mv -f "$parent"/* "$RT"/ 2>/dev/null
    shopt -u dotglob nullglob
    rmdir "$parent" 2>/dev/null || true
    [ -d "$RT/Game2" ]
}
if [ -d "$RT" ]; then normaliser_runtime || true; fi
if truthy "$INSTALL_RUNTIME"; then
    # Deja installe ? L archive est supprimee apres extraction, donc sans ce test chaque
    # Update retelechargeait 7,4 Go alors que Game2 est sur le disque et que l empreinte
    # enregistree correspond a celle du manifeste. Un seul cas doit retelecharger : une
    # empreinte differente, c est-a-dire une version publiee plus recente.
    if [ -d "$RT" ]; then normaliser_runtime || true; fi
    ETAT_RT=$(cat "$BASE/.etat-runtime" 2>/dev/null || true)
    if [ -d "$RT/Game2" ] && [ -n "$ETAT_RT" ] && { [ -z "$RUNTIME_SHA256" ] || [ "$ETAT_RT" = "$RUNTIME_SHA256" ]; }; then
        log "runtime deja installe : Game2 present, empreinte ${ETAT_RT} identique au manifeste, rien a telecharger"
    else
    RT_ZIP=""
    if [ -n "$RUNTIME_SHA256" ] && RT_ZIP=$(pack_by_sha "$RUNTIME_SHA256" "Y51_SE2Online-DedicatedRuntime.zip"); then
        log "archive runtime fournie par l'operateur : $RT_ZIP"
    elif [ -f "$BASE/runtime.zip" ] && { [ -z "$RUNTIME_SHA256" ] || [ "$(sha_of "$BASE/runtime.zip")" = "$RUNTIME_SHA256" ]; }; then
        RT_ZIP="$BASE/runtime.zip"; log "runtime deja telecharge"
    else
        need=7600000
        avail=$(free_kb); avail=${avail:-0}
        if [ "$avail" -lt "$need" ]; then
            die "espace insuffisant pour le runtime : ${avail} Ko libres, ~${need} Ko necessaires sur $BASE"
        fi
        if fetch_verified "$RUNTIME_URL" "$RUNTIME_SHA256" "$RUNTIME_SIZE" "$BASE/runtime.zip"; then
            RT_ZIP="$BASE/runtime.zip"
        else
            warn "runtime indisponible : le serveur ne demarrera pas sans lui. Deposez le zip dans $PACKS et relancez Update."
        fi
    fi
    if [ -n "$RT_ZIP" ]; then
        RT_SHA_NOW=$(sha_of "$RT_ZIP")
        if [ "$(cat "$BASE/.etat-runtime" 2>/dev/null)" != "$RT_SHA_NOW" ] || [ ! -d "$RT/Game2" ]; then
            log "installation du runtime SE2 (long : plusieurs minutes)"
            unzip_to "$RT_ZIP" "$RT" || die "extraction impossible du runtime"
            normaliser_runtime || warn "Game2 reste introuvable apres extraction du runtime"
            printf '%s\n' "$RT_SHA_NOW" > "$BASE/.etat-runtime"
            # L archive reste sur disque : la supprimer apres une extraction reussie faisait
            # retelecharger 7,4 Go au prochain update. Elle est remplacee par la suivante et
            # ne part qu en cas d echec d extraction (voir plus haut).
            [ "$RT_ZIP" = "$BASE/runtime.zip" ] && log "archive runtime conservee pour les prochains updates"
        else
            log "runtime deja installe pour cette empreinte"
        fi
    fi
    fi
else
    log "runtime non demande (InstallRuntime desactive) : utilisation d'une copie fournie dans $RT"
fi

# ------------------------------------------------------- bibliotheques Steam (3 DLL)
# Le runtime embarque steam_api64.dll mais pas le client Steam : les trois DLL
# viennent du client Steam ou de SteamCMD installes sur la machine. On les accepte
# deposees dans $PACKS/steamlibs, sinon on amorce SteamCMD pour Windows sous Wine.
STEAM_LIBS="steamclient64.dll tier0_s64.dll vstdlib_s64.dll"

# --- bloc bibliotheques Steam ------------------------------------------------
# L operateur peut fournir un zip des trois DLL (URL + sha256 dans le panneau) :
# c est la voie normale, SteamCMD anonyme ne peut rien telecharger pour un jeu payant.
if [ -n "${STEAM_URL:-}" ]; then
    if fetch_verified "$STEAM_URL" "${STEAM_SHA256:-}" 0 "$BASE/steamlibs.zip"; then
        rm -rf "$BASE/.steamlibs"
        if unzip_to "$BASE/steamlibs.zip" "$BASE/.steamlibs" >/dev/null 2>&1; then
            got=0
            for l in "steamclient64.dll" "tier0_s64.dll" "vstdlib_s64.dll"; do
                src=$(find "$BASE/.steamlibs" -type f -iname "$l" 2>/dev/null | head -1)
                [ -n "$src" ] || { warn "absente de l archive : $l"; continue; }
                cp -f "$src" "$SRV/$l" && chmod 644 "$SRV/$l" && got=$((got+1))
                if [ -d "$RT/Game2" ]; then cp -f "$src" "$RT/Game2/$l" && chmod 644 "$RT/Game2/$l"; fi
            done
            log "$got bibliotheque(s) Steam posee(s) depuis l archive"
            rm -rf "$BASE/.steamlibs"
        else
            warn "extraction de l archive de bibliotheques Steam impossible"
        fi
    fi
fi
# --- fin bloc bibliotheques Steam --------------------------------------------
# Les DLL doivent etre a cote de l exe ET a cote de steam_api64.dll (runtime/Game2) :
# presentes au seul endroit du serveur, elles laissaient le runtime sans client Steam.
steam_manquantes() {
    for l in $STEAM_LIBS; do
        [ -f "$SRV/$l" ] || { printf '%s ' "$l"; continue; }
        if [ -d "$RT/Game2" ] && [ ! -f "$RT/Game2/$l" ]; then printf '%s ' "$l"; fi
    done
}
missing_steam=$(steam_manquantes)
if [ -n "$missing_steam" ]; then
    libdir="$PACKS/steamlibs"
    copied=0
    for l in $STEAM_LIBS; do
        [ -f "$libdir/$l" ] || continue
        cp -f "$libdir/$l" "$SRV/$l" && chmod 644 "$SRV/$l" && copied=$((copied+1))
        if [ -d "$RT/Game2" ]; then cp -f "$libdir/$l" "$RT/Game2/$l" && chmod 644 "$RT/Game2/$l"; fi
    done
    [ "$copied" -gt 0 ] && log "$copied bibliotheque(s) Steam copiee(s) depuis $libdir"
    missing_steam=$(steam_manquantes)
fi
if [ -n "${missing_steam:-}" ]; then
    if [ ! -x "$BASE/steamcmd/steamcmd.exe" ] && command -v wine >/dev/null 2>&1; then
        log "amorcage de SteamCMD pour Windows (fournit steamclient64.dll)"
        mkdir -p "$BASE/steamcmd"
        if curl -fsSL --max-time 300 -o "$BASE/steamcmd.zip" https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip; then
            unzip_to "$BASE/steamcmd.zip" "$BASE/steamcmd" >/dev/null 2>&1 || warn "extraction de steamcmd.zip impossible"
            rm -f "$BASE/steamcmd.zip"
        else
            warn "steamcmd.zip inaccessible"
        fi
        if [ -x "$BASE/steamcmd/steamcmd.exe" ]; then
            WINEPREFIX="$ROOT/.wine" WINEARCH=win64 WINEDEBUG=-all \
                timeout 900 wine "$BASE/steamcmd/steamcmd.exe" +quit >"$BASE/steamcmd.log" 2>&1 \
                || warn "SteamCMD n'a pas rendu 0 : voir $BASE/steamcmd.log (l'amorcage peut demander deux passages)"
        fi
    fi
    for l in $STEAM_LIBS; do
        if [ -f "$BASE/steamcmd/$l" ] && [ ! -f "$SRV/$l" ]; then cp -f "$BASE/steamcmd/$l" "$SRV/$l"; fi
    done
    missing_steam=""
    for l in $STEAM_LIBS; do [ -f "$SRV/$l" ] || missing_steam="$missing_steam $l"; done
    if [ -n "$missing_steam" ]; then
        warn "bibliotheques Steam absentes :$missing_steam"
        warn "deposez-les dans $libdir (ou laissez SteamCMD finir) puis relancez Update : sans elles le serveur demarre mais ne s'annonce pas sur Steam"
    fi
fi

# ---------------------------------------------------------------- runner.json
python3 - "$SRV" "$RT" <<'PY'
import json,os,sys
srv,rt=sys.argv[1],sys.argv[2]
p=os.path.join(srv,'runner.json')
game="../runtime/Game2" if os.path.isdir(os.path.join(rt,'Game2')) else ""
cfg={"GameDirectory":game,"Configuration":"server.json","Profile":"profile",
     "Plugin":"Y51_SE2Online.dll","ShowWindow":False,"Headless":True}
cur={}
if os.path.isfile(p):
    try: cur=json.load(open(p))
    except Exception: cur={}
# On ne corrige que les cles que l'on maitrise : un GameDirectory choisi par
# l'operateur pour une installation Steam existante est conserve.
cur.setdefault("Configuration","server.json"); cur.setdefault("Profile","profile")
cur.setdefault("Plugin","Y51_SE2Online.dll"); cur.setdefault("ShowWindow",False); cur.setdefault("Headless",True)
if not cur.get("GameDirectory"): cur["GameDirectory"]=game
json.dump(cur,open(p,'w'),indent=2); open(p,'a').write("\n")
print("[se2] runner.json : GameDirectory=%r"%(cur.get("GameDirectory") or "<vide>"))
PY

# server.json : cree depuis l'exemple livre, jamais ecrase s'il existe deja.
if [ ! -f "$SRV/server.json" ] && [ -f "$SRV/server.example.json" ]; then
    cp -f "$SRV/server.example.json" "$SRV/server.json"
    log "server.json cree depuis server.example.json"
fi

# ---------------------------------------------------------------- verification
EXE=$(discover_exe)
if [ -z "$EXE" ]; then
    die "$SRV ne contient aucun .exe : l'archive n'est pas le serveur SE2 Online"
fi
printf '%s\n' "$EXE" > "$SRV/.launch-exe"
log "binaire detecte : $EXE"
[ -f "$SRV/Y51_SE2Online.dll" ] || warn "Y51_SE2Online.dll absent de $SRV"
if [ ! -d "$RT/Game2" ]; then
    warn "runtime absent ($RT/Game2) : le serveur refusera de demarrer tant qu'il n'est pas installe"
fi

# Le lanceur du depot est rapatrie ici pour que l'instance n'en garde pas une
# copie divergente.
if curl -fsSL --max-time 60 -o "$ROOT/${SELF}-launch.sh.tmp" \
        "$SOURCE_URL/${SELF}-launch.sh" 2>/dev/null; then
    mv -f "$ROOT/${SELF}-launch.sh.tmp" "$ROOT/${SELF}-launch.sh"
    chmod +x "$ROOT/${SELF}-launch.sh"
    log "lanceur mis a jour depuis $SOURCE_URL"
else
    rm -f "$ROOT/${SELF}-launch.sh.tmp"
    warn "lanceur non rapatrie (reseau) : celui deja en place est conserve"
fi

log "termine. version du manifeste : ${MANIFEST_PLUGIN_VERSION:-inconnue}, runtime ${MANIFEST_RUNTIME_VERSION:-inconnu}"
exit 0
