#!/bin/bash
# Bannerlord Coop (modpacks) : etape d update, telechargee par le template.
#
# Ce fichier existe pour une raison precise : la logique vivait avant dans une
# chaine base64 embarquee dans le template, ou une modification ne se voyait pas
# et ou l on ne pouvait pas savoir quelle version avait tourne. Ici elle est lisible,
# versionnee, et le stage du template ne fait que la recuperer et l executer.
#
# Variables fournies par le template : ROOT, BASE, GAMEPORT, GAMEPORT2, GAME_VERSION,
# COOP_BUILD, COOP_COMMIT, STRICT_VERSION, MODPACK, PACKS_DIR, MODPACK_URL,
# MODPACK_SHA256, GAME_MODULES_DIR, GAME_MODULES_URL, GAME_MODULES_SHA256, ITEM, SRC, TAG.

set -u

echo "script d update : $(sha256sum "$0" 2>/dev/null | cut -c1-16)"

ROOT="${ROOT:-/AMP/bannerlordcoop/}"
BASE="${BASE:-${ROOT}CoopData/DedicatedServer/}"
ITEM="${ITEM:-3770450698}"
SRC="${SRC:-auto}"
TAG="${TAG:-latest}"

# Valeurs fournies par le panneau (template v2). Le port de jeu vient du panneau
# et non d une constante : si AMP renumero l instance, le serveur doit suivre.
GAMEPORT="${GAMEPORT:-4200}"
GAMEPORT2="${GAMEPORT2:-}"
GAME_VERSION="${GAME_VERSION:-}"
COOP_BUILD="${COOP_BUILD:-}"
COOP_COMMIT="${COOP_COMMIT:-}"
STRICT_VERSION="${STRICT_VERSION:-0}"

# Lecteur JSON tolerant, ecrit une fois et reutilise : Coop produit du JSONC
# (commentaires, virgules finales) et un fichier parfaitement valide echoue
# donc sur un json.load strict.
JSONC=$(mktemp /tmp/bl-jsonc.XXXXXX.py 2>/dev/null || echo /tmp/bl-jsonc.py)
cat > "$JSONC" <<'PYJSONC'
import json, re, sys


def sans_commentaires(texte):
    sortie, i, chaine, echap = [], 0, False, False
    while i < len(texte):
        c = texte[i]
        if chaine:
            sortie.append(c)
            if echap:
                echap = False
            elif c == "\\":
                echap = True
            elif c == '"':
                chaine = False
            i += 1
            continue
        if c == '"':
            chaine = True
            sortie.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < len(texte) and texte[i + 1] == "/":
            while i < len(texte) and texte[i] not in "\r\n":
                i += 1
            continue
        if c == "/" and i + 1 < len(texte) and texte[i + 1] == "*":
            i += 2
            while i + 1 < len(texte) and not (texte[i] == "*" and texte[i + 1] == "/"):
                i += 1
            i += 2
            continue
        sortie.append(c)
        i += 1
    return "".join(sortie)


def charge(chemin):
    try:
        texte = open(chemin, encoding="utf-8-sig").read()
    except Exception:
        return None
    try:
        return json.loads(texte)
    except Exception:
        texte = re.sub(r",\s*([}\]])", r"\1", sans_commentaires(texte))
        try:
            return json.loads(texte)
        except Exception:
            return None


mode, chemin = sys.argv[1], sys.argv[2]
if mode == "check":
    sys.exit(0 if charge(chemin) is not None else 1)
donnees = charge(chemin) or {}
valeur = donnees.get(sys.argv[3], "")
print("" if valeur is None else valeur)
PYJSONC

CRED="${ROOT}fb-creds.txt"
SU=""
SP=""
SG=""
if [ -f "$CRED" ]; then
    SU=$(sed -n 1p "$CRED")
    SP=$(sed -n 2p "$CRED")
    SG=$(sed -n 3p "$CRED")
    rm -f "$CRED"
fi

DEST="${ROOT}steamhome/Steam/steamapps/workshop/content/261550/${ITEM}/DedicatedServer"
CACHE="${ROOT}cache"
LOG="${ROOT}steamcmd-last.log"
WINE=$(command -v wine 2>/dev/null || echo /usr/bin/wine)
HORO=$(date +%Y%m%d-%H%M)

echo "============================================================"
echo "Bannerlord Coop : mise a jour du serveur"
echo "  source demandee : $SRC"
echo "  tag CDN         : $TAG"
echo "  objet atelier   : $ITEM"
echo "============================================================"

mkdir -p "$ROOT" "$DEST" "$CACHE" "${ROOT}steamhome" || exit 1

steam_ok=0
raison=""

if [ "$SRC" != "cdn" ]; then
    echo
    echo "--- 1. atelier Steam ---"
    if [ ! -x "${ROOT}steamcmd.sh" ]; then
        echo "    installation de SteamCMD"
        wget -qO "${ROOT}steamcmd.tar.gz" https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
            && tar -xzf "${ROOT}steamcmd.tar.gz" -C "$ROOT" \
            && rm -f "${ROOT}steamcmd.tar.gz"
    fi
    # Mesure du 16/11 dans un conteneur propre : l objet d atelier Coop n est PAS
    # telechargeable en anonyme. SteamCMD se connecte, puis repond
    # "ERROR! Download item 3770450698 failed (Failure)" - un objet d atelier
    # rattache a un jeu exige une copie possedee. L anonyme reste donc tente
    # seulement quand aucun compte n est renseigne, ou il ne coute rien : sans lui
    # le script partait deja sur le CDN.
    atelier() {
        HOME="${ROOT}steamhome" "${ROOT}steamcmd.sh" "$@" \
            +workshop_download_item 261550 "$ITEM" validate +quit 2>&1 | tee "$LOG" | tail -4
        grep -q "Success. Downloaded item" "$LOG"
    }
    decide_raison() {
        raison="SteamCMD n a pas confirme le telechargement"
        if grep -qiE "Two-factor code mismatch|Invalid Two-factor" "$LOG"; then
            raison="code Steam Guard perime ou errone (inutile quand la session existe : vider le champ et relancer)"
        elif grep -qiE "Steam Guard code required|Two-factor code required|need two-factor" "$LOG"; then
            raison="Steam demande un code Steam Guard et aucun n est renseigne (premiere connexion sur cette instance)"
        elif grep -qiE "Invalid Password|Cached credentials not found|Account Logon Denied|Two-factor|Rate Limit" "$LOG"; then
            raison="authentification Steam refusee"
        elif grep -qiE "Download item [0-9]+ failed" "$LOG"; then
            raison="compte sans copie du jeu, ou objet non publie"
        elif grep -qiE "not available|Failure" "$LOG"; then
            raison="objet d atelier indisponible ou en attente d approbation"
        fi
    }
    if [ -x "${ROOT}steamcmd.sh" ]; then
        if [ -n "$SU" ]; then
            # Compte renseigne : on va droit au but. Mesure du 16/11 : l anonyme
            # ne suffit PAS pour cet objet (SteamCMD repond "Download item ...
            # failed (Failure)"), l atelier Coop exige une copie possedee du jeu.
            echo "    connexion avec le compte Steam"
            if [ -n "$SP" ]; then
                atelier +login "$SU" "$SP" && steam_ok=1
            else
                atelier +login "$SU" && steam_ok=1
            fi
            # Un code Steam Guard n est demande qu a la premiere connexion : les
            # fichiers de sentry conserves dans steamhome rendent les suivantes
            # gratuites. L envoyer d office casse donc une session valide - mesure
            # du 16/11 : "ERROR (Two-factor code mismatch)" sur une instance ou la
            # meme connexion sans code venait de reussir. On ne presente le code
            # que si Steam le reclame, et une seule fois.
            if [ "$steam_ok" != "1" ] && [ -n "$SG" ] \
                && grep -qiE "Two-factor code required|Steam Guard code|need two-factor|Enter the current code" "$LOG" \
                && ! grep -qiE "Two-factor code mismatch|Invalid Two-factor" "$LOG"; then
                echo "    Steam demande un code : nouvelle tentative avec le code fourni"
                if [ -n "$SP" ]; then
                    atelier +login "$SU" "$SP" "$SG" && steam_ok=1
                else
                    atelier +login "$SU" "$SG" && steam_ok=1
                fi
            fi
            if [ "$steam_ok" = "1" ]; then
                echo "    atelier : OK (compte)"
            else
                decide_raison
            fi
        else
            echo "    aucun compte renseigne, tentative anonyme"
            if atelier +login anonymous; then
                steam_ok=1
                echo "    atelier : OK (anonyme)"
            else
                raison="aucun compte Steam renseigne"
                echo "    anonyme refuse (l atelier Coop exige une copie du jeu) : $raison"
            fi
        fi
    else
        raison="SteamCMD introuvable"
    fi
    if [ "$steam_ok" = "1" ] && [ ! -f "$DEST/BannerlordCoopServer.exe" ]; then
        steam_ok=0
        raison="serveur absent apres le telechargement"
    fi
    if [ "$steam_ok" = "1" ]; then
        echo "    atelier : OK"
    else
        [ -z "$raison" ] && raison="echec inconnu"
        echo "    atelier : ECHEC ($raison)"
    fi
fi

if [ "$steam_ok" = "0" ]; then
    if [ "$SRC" = "steam" ]; then
        echo
        echo "ECHEC : source demandee = atelier seul, et il a echoue."
        echo "  raison : $raison"
        echo "  passez la source a auto ou cdn pour utiliser le repli."
        exit 1
    fi

    echo
    echo "--- 2. repli sur le CDN de la team ---"

    if [ "$TAG" = "latest" ] || [ -z "$TAG" ]; then
        TAG=$(python3 - <<'PY'
import json
import urllib.request

req = urllib.request.Request(
    "https://api.github.com/repos/Bannerlord-Coop-Team/BannerlordCoop/releases/latest",
    headers={"User-Agent": "amp-bannerlord-coop-cdn"})
print(json.load(urllib.request.urlopen(req, timeout=60))["tag_name"])
PY
)
        if [ -z "$TAG" ]; then
            echo "    impossible de resoudre la derniere release"
            exit 1
        fi
        echo "    tag resolu : $TAG"
    fi

    MURL="https://github.com/Bannerlord-Coop-Team/BannerlordCoop/releases/download/${TAG}/manifest.json"
    echo "    manifeste : $MURL"
    INFO=$(python3 - "$MURL" <<'PY'
import json
import sys
import urllib.request

req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "amp-bannerlord-coop-cdn"})
d = json.load(urllib.request.urlopen(req, timeout=120))
w = d.get("windows") or {}
c = d.get("client") or {}
if not w.get("url"):
    sys.exit("manifeste sans archive windows")
print("TAGX=%s" % d.get("tag", ""))
print("URLX=%s" % w["url"])
print("SHAX=%s" % w["sha256"])
print("NAMEX=%s" % w["name"])
print("CLIENTX=%s" % c.get("url", ""))
PY
)
    if [ -z "$INFO" ]; then
        echo "    manifeste illisible"
        exit 1
    fi
    lire() {
        printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -1
    }
    AURL=$(lire URLX)
    ASHA=$(lire SHAX)
    ANAME=$(lire NAMEX)
    CLIENT=$(lire CLIENTX)
    ATAG=$(lire TAGX)
    if [ -z "$AURL" ] || [ -z "$ASHA" ] || [ -z "$ANAME" ]; then
        echo "    manifeste incomplet"
        exit 1
    fi
    echo "    release : $ATAG"

    ARCH="${CACHE}/${ANAME}"
    if [ -f "$ARCH" ] && [ "$(sha256sum "$ARCH" | cut -d' ' -f1)" = "$ASHA" ]; then
        echo "    archive deja en cache, empreinte conforme"
    else
        if [ -f "$ARCH" ]; then
            echo "    archive en cache non conforme, retelechargement"
        fi
        echo "    telechargement de $(basename "$AURL")"
        wget -qO "${ARCH}.part" "$AURL"
        if [ ! -f "${ARCH}.part" ]; then
            echo "    telechargement echoue"
            exit 1
        fi
        mv -f "${ARCH}.part" "$ARCH"
    fi

    GOT=$(sha256sum "$ARCH" | cut -d' ' -f1)
    if [ "$GOT" != "$ASHA" ]; then
        echo "    EMPREINTE DIFFERENTE : attendu $ASHA"
        echo "                          obtenu $GOT"
        rm -f "$ARCH"
        exit 1
    fi
    echo "    empreinte SHA-256 verifiee"

    SEVEN="${CACHE}/7zr.exe"
    # trois sources, la premiere est la release officielle 7-Zip sur GitHub.
    # 7-zip.org peut etre injoignable : son DNS renvoyait SERVFAIL au moment
    # de l ecriture, y compris depuis un resolveur public.
    if [ -s "$SEVEN" ] && [ "$(wc -c < "$SEVEN")" -lt 100000 ]; then
        rm -f "$SEVEN"
    fi
    if [ ! -s "$SEVEN" ]; then
        echo "    recuperation de 7zr.exe"
        for SRC7 in \
            "https://github.com/ip7z/7zip/releases/latest/download/7zr.exe" \
            "https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main/tools/7zr.exe" \
            "https://www.7-zip.org/a/7zr.exe"; do
            if python3 - "$SRC7" "$SEVEN" <<'PY'
import sys
import urllib.request

req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "amp-bannerlord-coop-cdn"})
donnees = urllib.request.urlopen(req, timeout=180).read()
if len(donnees) < 100000 or donnees[:2] != b"MZ":
    raise SystemExit(1)
with open(sys.argv[2], "wb") as f:
    f.write(donnees)
PY
            then
                echo "    telecharge depuis : $SRC7"
                break
            else
                echo "    source injoignable : $SRC7"
            fi
        done
    fi
    if [ ! -s "$SEVEN" ]; then
        echo "    7zr.exe introuvable sur toutes les sources"
        exit 1
    fi

    mkdir -p "${CACHE}/xdg"
    if ! WINEPREFIX="${ROOT}.wine" WINEDEBUG="-all" XDG_CACHE_HOME="${CACHE}/xdg" \
         XDG_CONFIG_HOME="${CACHE}/xdg" "$WINE" "$SEVEN" 2>&1 | grep -qi "7-Zip"; then
        echo "    7zr.exe ne repond pas sous wine, abandon"
        rm -f "$SEVEN"
        exit 1
    fi

    STAGE="${CACHE}/stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    echo "    extraction en cours, comptez trois minutes pour 4,5 Go"
    mkdir -p "${CACHE}/xdg"
    WINEPREFIX="${ROOT}.wine" WINEDEBUG="-all" XDG_CACHE_HOME="${CACHE}/xdg" \
        XDG_CONFIG_HOME="${CACHE}/xdg" "$WINE" "$SEVEN" x "$ARCH" -o"$STAGE" -y \
        > "${CACHE}/7z.log" 2>&1
    if [ ! -f "${STAGE}/BannerlordCoopServer.exe" ]; then
        echo "    extraction echouee"
        tail -12 "${CACHE}/7z.log"
        exit 1
    fi
    echo "    extraction OK"

    echo
    echo "--- 3. sauvegarde avant remplacement ---"
    BK="$(dirname "$ROOT")/Backups"
    OLDVER=$(grep -m1 "Built:" "$DEST/release-info.txt" 2>/dev/null | tr -d "\r" | sed "s/.*Built: *//; s/ .*//")
    OLDVER="${OLDVER:-inconnue}"
    if [ -d "$BASE/Game Saves" ] && [ -n "$(ls -A "$BASE/Game Saves" 2>/dev/null)" ]; then
        DEJA=$(ls -1d "$BK/pre-update-${OLDVER}-"* 2>/dev/null | head -1)
        if [ -n "$DEJA" ]; then
            echo "sauvegarde de la version $OLDVER deja presente : $DEJA"
        else
            CIBLE="$BK/pre-update-${OLDVER}-${HORO}"
            mkdir -p "$CIBLE"
            cp -a "$BASE/Game Saves" "$CIBLE/"
            CPTE="Game Saves/"
            for f in server-config.json eula.txt; do
                if [ -f "$BASE/$f" ]; then
                    cp -a "$BASE/$f" "$CIBLE/"
                    CPTE="$CPTE $f"
                fi
            done
            MODWINE="${ROOT%/}/.wine/drive_c/users/$(id -un 2>/dev/null || echo ${HOME##*/})/Documents/Mount and Blade II Bannerlord/CoopData/mod-config.json"
            MODSRC=""
            if [ -f "$MODWINE" ]; then
                MODSRC="$MODWINE"
            elif [ -f "$BASE/mod-config.json" ]; then
                MODSRC="$BASE/mod-config.json"
            fi
            if [ -n "$MODSRC" ]; then
                cp -a "$MODSRC" "$CIBLE/mod-config.json"
                CPTE="$CPTE mod-config.json"
                NOTE_MOD="mod-config.json pris dans $MODSRC"
            else
                NOTE_MOD="mod-config.json introuvable, reglages de mods non sauvegardes"
            fi
            SAVENAME=$(python3 - "$BASE/server-config.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        print(json.load(f).get("saveName", "?"))
except Exception:
    print("?")
PY
)
            {
                echo "Sauvegarde avant mise a jour Bannerlord Coop"
                echo "date            : $(date '+%Y-%m-%d %H:%M')"
                echo "version sortante: $OLDVER (Built de release-info.txt)"
                echo "version entrante: ${ATAG:-inconnue}"
                echo "monde joue      : ${SAVENAME:-?} (saveName de server-config.json)"
                echo "contenu         : $CPTE"
                MODS_LISTE="aucun"
                if [ -d "$DEST/engine/Modules" ]; then
                    ML=""
                    for d in "$DEST/engine/Modules"/*; do
                        [ -d "$d" ] || continue
                        nom=$(basename "$d")
                        [ -d "${STAGE}/engine/Modules/$nom" ] && continue
                        ML="$ML $nom"
                    done
                    [ -n "$ML" ] && MODS_LISTE="$ML"
                fi
                echo "mods installes   : $MODS_LISTE"
                echo "mod-config.json : $NOTE_MOD"
                echo "restauration    : Game Saves, server-config et eula dans CoopData/DedicatedServer/ ;"
                echo "                  mod-config.json dans le prefixe Wine, Documents/Mount and Blade II Bannerlord/CoopData/"
            } > "$CIBLE/LISEZ-MOI.txt"
            ls -1dt "$BK"/pre-update-* 2>/dev/null | tail -n +4 | while read -r vieux; do rm -rf "$vieux"; done
            echo "sauvegarde : $CIBLE"
        fi
    else
        echo "aucune sauvegarde a faire, pas encore de monde dans Game Saves"
    fi

    if [ -d "$DEST/server-data" ]; then
        rm -rf "${CACHE}/server-data-sauve"
        cp -a "$DEST/server-data" "${CACHE}/server-data-sauve"
    fi
    rm -rf "${CACHE}/mods-sauve"
    MODS_SAUVE=""
    if [ -d "$DEST/engine/Modules" ]; then
        for d in "$DEST/engine/Modules"/*; do
            [ -d "$d" ] || continue
            nom=$(basename "$d")
            [ -d "${STAGE}/engine/Modules/$nom" ] && continue
            mkdir -p "${CACHE}/mods-sauve"
            if ! cp -a "$d" "${CACHE}/mods-sauve/"; then
                echo "    ERREUR : mise a l ecart du mod $nom impossible, update annule"
                exit 1
            fi
            MODS_SAUVE="$MODS_SAUVE $nom"
        done
    fi
    [ -n "$MODS_SAUVE" ] && echo "    mods mis a l ecart :$MODS_SAUVE"
    find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    if ! cp -a "${STAGE}/." "$DEST/"; then
        echo "    copie vers $DEST echouee"
        exit 1
    fi
    if [ -n "$MODS_SAUVE" ]; then
        mkdir -p "$DEST/engine/Modules"
        for nom in $MODS_SAUVE; do
            cp -a "${CACHE}/mods-sauve/$nom" "$DEST/engine/Modules/" || {
                echo "    ERREUR : remise en place du mod $nom echouee"
                exit 1
            }
        done
        MANQUE=""
        for nom in $MODS_SAUVE; do
            [ -d "$DEST/engine/Modules/$nom" ] || MANQUE="$MANQUE $nom"
        done
        rm -rf "${CACHE}/mods-sauve"
        if [ -n "$MANQUE" ]; then
            echo "    ERREUR : mods absents apres la copie :$MANQUE"
            exit 1
        fi
        echo "    mods remis en place :$MODS_SAUVE"
    fi
    if [ -d "${CACHE}/server-data-sauve" ]; then
        mkdir -p "$DEST/server-data"
        if ! cp -a "${CACHE}/server-data-sauve/." "$DEST/server-data/"; then
            echo "    ERREUR : restauration de server-data echouee, donnees a recuperer dans ${CACHE}server-data-sauve"
            exit 1
        fi
        if [ -n "$(ls -A "${CACHE}/server-data-sauve" 2>/dev/null)" ] && [ -z "$(ls -A "$DEST/server-data" 2>/dev/null)" ]; then
            echo "    ERREUR : server-data vide apres restauration, arret"
            exit 1
        fi
        rm -rf "${CACHE}/server-data-sauve"
        echo "    server-data restaure"
    fi
    echo "    fichiers mis en place"

    rm -rf "$STAGE"
    rm -f "$ARCH"

    echo
    echo "    version installee :"
    grep -E "Built:|Paired Coop:|Game version:" "$DEST/release-info.txt" 2>/dev/null | sed 's/^/      /'
    if [ -n "$CLIENT" ]; then
        echo "      client pour les joueurs, meme build : $CLIENT"
    fi
fi

if [ ! -f "$DEST/BannerlordCoopServer.exe" ]; then
    echo
    echo "ECHEC : BannerlordCoopServer.exe absent de $DEST"
    exit 1
fi

# server-config.json : le creer s'il manque, le reparer s'il est illisible.
# Le template CDN ne le creait pas, et l ecriture par AMP d un fichier absent
# produit un JSON que son propre lecteur refuse ("/" is invalid after a value).
#
# Deux precautions ajoutees en v2 :
# - lecture tolerante au JSONC, pour ne pas prendre un fichier valide pour un
#   fichier casse ;
# - jamais de reinitialisation quand une campagne existe : le fichier est laisse
#   intact et l update s arrete, sinon les joueurs repartiraient sur un monde vide.
CFG="$BASE/server-config.json"
cfg_valide() {
    if command -v python3 >/dev/null 2>&1; then
        python3 "$JSONC" check "$1" 2>/dev/null
    else
        grep -q '"saveName"' "$1" 2>/dev/null
    fi
}
cfg_valeur() {
    python3 "$JSONC" get "$1" "$2" 2>/dev/null
}
if ! cfg_valide "$CFG"; then
    if [ -f "$CFG" ]; then
        MONDE=""
        for d in "$BASE/Game Saves" "${ROOT}server-data/Game Saves"; do
            if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
                MONDE="$d"
                break
            fi
        done
        if [ -n "$MONDE" ]; then
            echo
            echo "ECHEC : server-config.json illisible alors qu une campagne existe."
            echo "  fichier conserve intact : $CFG"
            echo "  campagne trouvee        : $MONDE"
            echo "  le reinitialiser enverrait les joueurs dans un monde vide."
            echo "  corrigez le JSON (commentaire ou virgule en trop) puis relancez l update."
            exit 1
        fi
        mv -f "$CFG" "${CFG}.illisible-${HORO}"
        echo "    server-config.json illisible : conserve en ${CFG}.illisible-${HORO}"
    fi
    mkdir -p "$(dirname "$CFG")" 2>/dev/null
    TMPCFG="${CFG}.tmp-$$"
    # AMP 3 publie les ports en 1:1 : le numero du panneau doit etre celui que le
    # serveur ecoute. On ecrit donc ce fichier au premier update, avec les memes
    # valeurs par defaut que le mod (steam a true, comme son propre exemple) et de
    # quoi comprendre le fichier quand on l ouvre six mois plus tard.
    cat > "$TMPCFG" 2>/dev/null <<'CFGEOF'
{
  // Ecrit par le template AMP au premier update : le serveur doit ecouter le port
  // que le panneau publie, et AMP 3 publie les ports en 1:1 (4202 dehors = 4202
  // dedans). Le mod complete ce fichier au premier demarrage et le garde ensuite.
  // Documentation complete des cles : voir l exemple livré dans le paquet serveur.
  "saveName": "saveauto1",
  "autosaveMinutes": 5,
  "password": "",
  "port": PORT_ICI,
  "logFile": true,
  "steam": true,
  "traceTick": false,
  "tracePublish": false,
  "traceBandits": false,
}
CFGEOF
    sed -i "s/PORT_ICI/${GAMEPORT}/" "$TMPCFG" 2>/dev/null
    if [ -s "$TMPCFG" ] && mv -f "$TMPCFG" "$CFG" 2>/dev/null; then
        echo "    server-config.json initialise (port ${GAMEPORT})"
    else
        rm -f "$TMPCFG" 2>/dev/null
        echo "    AVERTISSEMENT : ecriture impossible dans $(dirname "$CFG")"
        echo "      le serveur creera son propre fichier au premier demarrage,"
        echo "      au port par defaut (4200) et non a celui du panneau (${GAMEPORT})."
    fi
fi

echo
# Garde-fou de version : une mise a jour d atelier peut changer le socle sans que
# personne ne l ait decide. On l annonce, et on bloque si le reglage le demande.
ECART=""
REL_INFO="$DEST/release-info.txt"
if [ -f "$REL_INFO" ]; then
    # Le paquet atelier identifie le Coop par un commit, le paquet CDN par un tag de
    # release. Comparer l un a l autre produisait un faux ecart a chaque update : une
    # instance installee par l atelier annoncait "commit ecd4c479 au lieu de 0.1.7".
    # On ramene donc chaque identite a ce qu elle est et on ne compare que du
    # comparable : commit contre CoopCommit, tag contre CoopBuild.
    COOP_LIGNE=$(tr -d '\r' < "$REL_INFO" | sed -n 's/^Paired Coop:[[:space:]]*//p' | head -1)
    JEU_LIGNE=$(tr -d '\r' < "$REL_INFO" | sed -n 's/^Game version:[[:space:]]*//p' | head -1)
    COOP_SHA=$(printf '%s' "$COOP_LIGNE" | sed -n 's/.*commit[[:space:]]\{1,\}\([0-9a-f]\{7,\}\).*/\1/p')
    COOP_VER=$(printf '%s' "$COOP_LIGNE" | sed -n 's/^[[:space:]]*[vV]\{0,1\}\([0-9][0-9.]*\).*/\1/p')
    JEU_SHA=""
    JEU_NORM=$(printf '%s' "$JEU_LIGNE" | sed 's/^.*: Bannerlord[[:space:]]*//; s/^[[:space:]]*[vV]//; s/[[:space:]]*$//')
    JEU_ATTENDU=$(printf '%s' "$GAME_VERSION" | sed 's/^[[:space:]]*[vV]//; s/[[:space:]]*$//')
    TAG_NORM=$(printf '%s' "$TAG" | sed 's/^[[:space:]]*[vV]//; s/[[:space:]]*$//')
    ACCROCHE=""
    [ -n "$COOP_SHA" ] && ACCROCHE="Coop commit $(printf '%s' "$COOP_SHA" | cut -c1-8)"
    [ -n "$COOP_VER" ] && ACCROCHE="${ACCROCHE:+$ACCROCHE / }Coop $COOP_VER"
    COOP_ID=""
    [ -n "$COOP_SHA" ] && COOP_ID="commit $(printf '%s' "$COOP_SHA" | cut -c1-8)"
    [ -z "$COOP_ID" ] && [ -n "$COOP_VER" ] && COOP_ID="$COOP_VER"
    echo "  version installee : jeu ${JEU_NORM:-?}${ACCROCHE:+ / $ACCROCHE}"
    if [ -n "$JEU_ATTENDU" ] && [ -n "$JEU_NORM" ] && [ "$JEU_NORM" != "$JEU_ATTENDU" ]; then
        ECART="jeu ${JEU_NORM} au lieu de ${JEU_ATTENDU}"
    fi
    if [ "$steam_ok" = "1" ]; then
        if [ -n "$COOP_COMMIT" ] && [ -n "$COOP_SHA" ]; then
            case "$COOP_SHA" in
                "$COOP_COMMIT"*) ;;
                *) ECART="${ECART:+$ECART ; }Coop commit $(printf '%s' "$COOP_SHA" | cut -c1-8) au lieu de $(printf '%s' "$COOP_COMMIT" | cut -c1-8)" ;;
            esac
        fi
    elif [ -n "$COOP_BUILD" ] && [ -n "$TAG_NORM" ]; then
        if [ "$TAG_NORM" != "$COOP_BUILD" ]; then
            ECART="${ECART:+$ECART ; }Coop ${TAG_NORM} au lieu de ${COOP_BUILD}"
        fi
    fi
fi
if [ -n "$ECART" ]; then
    echo
    echo "ATTENTION : ecart de version -> $ECART"
    echo "  les sauvegardes et les modules peuvent ne plus correspondre a ce build."
    echo "  pour rester sur la version validee : Update source = cdn, Release tag = le tag attendu."
    case "$STRICT_VERSION" in
        1 | true | True | TRUE | yes)
            echo "  REFUS : le reglage Refuser en cas d ecart de version est actif."
            rm -f "$JSONC"
            exit 1
            ;;
    esac
fi

# Garde-fou de ports : le serveur ecoute "port" et "port+1". Si l onglet Ports ne
# publie pas cette paire, la moitie des connexions echouera sans message clair.
# Le port du fichier est la seule valeur qui decide ou le serveur ecoute vraiment :
# le panneau publie GAMEPORT, mais le mod lit "port" dans server-config.json. Un
# desaccord laisse un serveur injoignable qui affiche pourtant SERVING. On aligne
# donc le fichier sur le panneau, en gardant une copie et en le disant.
PORT_CFG=$(cfg_valeur "$CFG" port)
if [ -n "$PORT_CFG" ] && [ "$PORT_CFG" != "$GAMEPORT" ]; then
    cp -f "$CFG" "${CFG}.port-${HORO}.bak" 2>/dev/null
    sed -i "s/^\([[:space:]]*\"port\"[[:space:]]*:[[:space:]]*\)[0-9]\+/\1${GAMEPORT}/" "$CFG" 2>/dev/null
    PORT_APRES=$(cfg_valeur "$CFG" port)
    if [ "$PORT_APRES" = "$GAMEPORT" ]; then
        echo "    port du fichier aligne sur le panneau : ${PORT_CFG} -> ${GAMEPORT}"
        echo "      copie de l ancien fichier : ${CFG}.port-${HORO}.bak"
    else
        echo "AVERTISSEMENT : server-config.json annonce le port ${PORT_APRES:-?} et n a pas pu etre aligne"
        echo "  sur le panneau (${GAMEPORT}) : les joueurs doivent utiliser ${PORT_APRES:-?}."
    fi
fi
if [ -n "$GAMEPORT2" ] && [ "$GAMEPORT2" != "$((GAMEPORT + 1))" ]; then
    echo "ATTENTION : le deuxieme port publie est $GAMEPORT2 alors que le serveur utilisera $((GAMEPORT + 1))."
    echo "  corrigez le deuxieme port du panneau : il doit toujours valoir le premier + 1."
fi

rm -f "$JSONC"

echo
# Comment jouer. AMP 3 affiche deja les adresses publique et locale de chaque port,
# mais pas comment le client s en sert : le mod Coop ne s enregistre sur aucun
# schema d URL, donc un lien steam://connect serait un bouton mort. On donne donc
# l information la ou elle est lue, dans le journal de l update.
echo "COMMENT JOUER"
echo "  adresse a donner aux joueurs : celle affichee par le panneau pour cette instance, port ${GAMEPORT}"
echo "    reseau local pour les joueurs chez vous, adresse publique pour les autres"
echo "    ne pas confondre avec le port moteur, qui ne sert pas aux joueurs"
echo "  ports a ouvrir sur le routeur : ${GAMEPORT} et $((GAMEPORT + 1)), en UDP, vers cette machine"
echo "  cote joueur : Bannerlord ${JEU_NORM:-1.4.8}, mod Coop ${COOP_ID:-0.1.7}, meme build que le serveur"
echo "                l adresse se saisit dans l ecran de connexion du client Coop"

echo
# --- modpack ----------------------------------------------------------------
# Le serveur Coop recoit la liste de ses modules en argument. Le manifeste du pack
# la produit, et un module manquant doit faire echouer l update ICI plutot qu au
# demarrage : un serveur qui demarre sans le mod est le pire des cas.
echo
echo "--- modpack ---"
OUTILS="${ROOT}tools"
PACKSDIR="${PACKS_DIR:-${ROOT}packs}"
mkdir -p "$OUTILS" "$PACKSDIR" || { echo "[modpack] ERREUR : creation de $OUTILS impossible"; exit 1; }
DEPOT="https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main"
for f in tools/modpack.py tools/modpack-install.sh bannerlord-coop-launch.sh; do
    cible="${ROOT}${f}"
    mkdir -p "$(dirname "$cible")" 2>/dev/null || true
    if curl -fsSL --max-time 60 -o "$cible.tmp" "$DEPOT/$f"; then
        mv "$cible.tmp" "$cible"
    else
        rm -f "$cible.tmp"
        echo "[modpack] ERREUR : $f introuvable dans le depot"
        exit 1
    fi
done
chmod 755 "${ROOT}tools/modpack-install.sh" "${ROOT}bannerlord-coop-launch.sh" 2>/dev/null || true
for m in vanilla taom compatibilite; do
    curl -fsSL --max-time 60 -o "${PACKSDIR}/$m.json.tmp" "$DEPOT/modpacks/$m.json" || rm -f "${PACKSDIR}/$m.json.tmp"
    [ -f "${PACKSDIR}/$m.json.tmp" ] && mv "${PACKSDIR}/$m.json.tmp" "${PACKSDIR}/$m.json"
done

if bash "${ROOT}tools/modpack-install.sh" "${MODPACK:-vanilla}" "${DEST}/engine/Modules" "$PACKSDIR" "${ROOT}cache"; then
    echo "[modpack] pack « ${MODPACK:-vanilla} » installe et verifie"
    FICHE="${ROOT}PRESET-${MODPACK:-vanilla}.md"
    if python3 "${ROOT}tools/modpack.py" fiche "${PACKSDIR}/${MODPACK:-vanilla}.json" \
            "${PACKSDIR}/compatibilite.json" > "$FICHE" 2>/dev/null; then
        echo "[modpack] fiche du prereglage ecrite : $FICHE"
        echo "[modpack]   modules du serveur, mods a installer chez les joueurs, manipulations"
        head -14 "$FICHE" | sed 's/^/    /'
    else
        rm -f "$FICHE"
    fi
else
    echo "[modpack] ERREUR : le pack « ${MODPACK:-vanilla} » est incomplet"
    echo "[modpack]   le serveur refusera de demarrer : corriger la cause ci-dessus, puis relancer l update"
    exit 1
fi

echo "TERMINE : serveur Bannerlord Coop pret"
echo "  binaires : $DEST"
echo "  donnees  : $BASE"
echo "  licence  : eula.txt conserve, rien a refaire si le texte n a pas change"
echo "  rappel   : client et serveur doivent etre sur le meme build Coop"
