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
# MODPACK_SHA256, GAME_MODULES_DIR, GAME_MODULES_URL, GAME_MODULES_SHA256, ITEM, SRC, TAG,
# SERVER_MIRROR_URL, CLIENT_MIRROR_URL.

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
SERVER_MIRROR_URL="${SERVER_MIRROR_URL:-}"
CLIENT_MIRROR_URL="${CLIENT_MIRROR_URL:-}"

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

# Chemin prefere : le steamcmd d AMP et la session qu il a lui-meme ouverte.
# Mesure du 21/11 sur une instance AMP3 : AMP installe son steamcmd dans
# /amp/.amp/steamcmd et garde le home correspondant ; sa session en cache y est
# reutilisable telle quelle, sans mot de passe ni code. L objet Coop a ete
# telecharge par ce chemin : 6 481 424 135 octets, "Logging in using cached
# credentials".
SC_AMP=""
for cand in /amp/.amp/steamcmd/steamcmd.sh "${ROOT}../.amp/steamcmd/steamcmd.sh"; do
    if [ -x "$cand" ]; then SC_AMP="$cand"; break; fi
done
COMPTE_AMP=""
AMP_HOME=""
for h in "$HOME" /home/amp "${ROOT}../.amp/home" "${ROOT}.virtualhome"; do
    vdf="$h/Steam/config/config.vdf"
    [ -f "$vdf" ] || continue
    compte=$(sed -n '/"Accounts"/,/^[[:space:]]*}/p' "$vdf" | grep -oE '"[^"]+"' | sed -n '2p' | tr -d '"')
    if [ -n "$compte" ] && grep -q "ConnectCache" "$vdf"; then
        COMPTE_AMP="$compte"
        AMP_HOME="$h"
        break
    fi
done

DEST="${ROOT}steamhome/Steam/steamapps/workshop/content/261550/${ITEM}/DedicatedServer"
# PKG = ou le paquet vient d etre telecharge, DEST = ou le lancement le lit.
# Les deux ne coincident pas avec la session d AMP : steamcmd ecrit dans le home
# d AMP, alors que bannerlord-coop-launch.sh lit ${ROOT}steamhome/... Confondre
# les deux installe cinq gigots que personne ne lit, et le serveur refuse de
# demarrer avec « modules manquants » alors que tout est present ailleurs.
PKG=""
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

# ---- suivi des etapes longues --------------------------------------------
# Le panneau n affiche que ce que le script ecrit. Une etape de six gigots reste
# donc muette pendant trois minutes et ressemble exactement a un blocage — c est
# ce qui est arrive le 21/11, ou un telechargement d atelier en cours a ete pris
# pour une panne. Ce veilleur imprime une ligne toutes les quinze secondes, et
# seulement pendant l etape concernee.
SUIVI_PID=""
suivre() {
    ( while :; do
        sleep 15
        eval "$1" 2>/dev/null
      done ) &
    SUIVI_PID=$!
}
arreter_suivi() {
    if [ -n "${SUIVI_PID:-}" ]; then
        kill "$SUIVI_PID" 2>/dev/null
        wait "$SUIVI_PID" 2>/dev/null
        SUIVI_PID=""
    fi
}
trap 'arreter_suivi' EXIT INT TERM

lisible() {
    python3 -c 'import sys
n = float(sys.argv[1] or 0)
if n >= 1024 ** 3:
    print("%.1f Go" % (n / 1024 ** 3))
elif n >= 1024 ** 2:
    print("%.0f Mo" % (n / 1024 ** 2))
else:
    print("%.0f Ko" % (n / 1024))' "${1:-0}" 2>/dev/null || echo "? Mo"
}

mesure_atelier() {
    local base="$1" n=0 c v l
    # Deux endroits compte tenu de la facon dont steamcmd travaille : il ecrit dans
    # steamapps/downloading puis deplace l objet dans workshop/content. Mesurer
    # seulement le dossier final affichait « 0 Ko » pendant tout le telechargement,
    # ce qui se lit exactement comme une panne — vu le 21/11 sur une instance neuve.
    for c in "$base/Steam/steamapps/downloading" \
             "$base/Steam/steamapps/workshop/content/261550/${ITEM}"; do
        [ -e "$c" ] || continue
        v=$(du -sb "$c" 2>/dev/null | cut -f1)
        v=${v:-0}
        [ "$v" -gt "$n" ] && n="$v"
    done
    l=$(tail -1 "$LOG" 2>/dev/null | tr -d '\r' | cut -c1-64)
    if [ "$n" -gt 0 ]; then
        echo "      atelier : $(lisible "$n") ecrits — ${l}"
    else
        echo "      atelier : steamcmd ne publie pas d avancement (${l})"
    fi
}

mesure_telechargement() {
    local f t
    [ "${2:-0}" -gt 0 ] || return 0
    f=$(stat -c%s "$1" 2>/dev/null || echo 0)
    t="$2"
    echo "      telechargement : $((f * 100 / t)) % ($(lisible "$f") / $(lisible "$t"))"
}

mesure_extraction() {
    local n
    n=$(find "$1" -type f 2>/dev/null | wc -l)
    echo "      extraction : $n fichiers ecrits ($(lisible "$(du -sb "$1" 2>/dev/null | cut -f1)"))"
}

mesure_copie() {
    local a b
    b=$(du -sb "$1" 2>/dev/null | cut -f1)
    a=$(du -sb "$2" 2>/dev/null | cut -f1)
    [ "${b:-0}" -gt 0 ] || return 0
    echo "      copie : $((a * 100 / b)) % ($(lisible "$a") / $(lisible "$b"))"
}
# -------------------------------------------------------------------------

# --- 0. verification avant les six gigots ---------------------------------
# Le pack reclame des modules du jeu que le paquet serveur ne livre pas. Sans eux,
# l update echoue tout a la fin — apres avoir telecharge et extrait 6,5 Go pour rien
# (vu deux fois le 21/11 sur une instance neuve, ou game-modules etait vide). On
# regarde donc avant de commencer, et on s arrete avec la marche a suivre.
PACKSDIR="${PACKS_DIR:-${ROOT}packs}"
PACKJSON="${PACKSDIR}/${MODPACK:-vanilla}.json"
# raw.githubusercontent repond depuis un cache de cinq minutes : un Update lance juste
# apres un commit peut rejouer l ancienne version d un outil. C est pourquoi le script
# lui-meme est recupere par l API GitHub (cache d une minute, cf. le stage d update du
# kvp) et non par raw ; les outils et les packs, qui changent rarement, restent sur raw.
if [ ! -f "$PACKJSON" ]; then
    mkdir -p "$PACKSDIR" 2>/dev/null || true
    curl -fsSL --max-time 60 -o "${PACKJSON}.tmp" \
        "https://raw.githubusercontent.com/Hellm4nbot/amp-templates/main/modpacks/${MODPACK:-vanilla}.json" 2>/dev/null \
        && mv "${PACKJSON}.tmp" "$PACKJSON" || rm -f "${PACKJSON}.tmp"
fi
if [ -f "$PACKJSON" ]; then
    PREFLIGHT=$(python3 - "$PACKJSON" "${ROOT}game-modules" "${GAME_MODULES_URL:-}" <<'PY' 2>/dev/null
import json
import os
import sys

pack, dossier, url = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(pack, encoding="utf-8"))
except Exception:
    print("OK")
    raise SystemExit(0)
attendus = [m["id"] for m in d.get("modules", [])
            if isinstance(m.get("source"), dict) and m["source"].get("jeu")]
if not attendus:
    print("OK")
    raise SystemExit(0)
zips = []
if os.path.isdir(dossier):
    zips = [f for f in os.listdir(dossier) if f.lower().endswith(".zip")]
manquants = [m for m in attendus if not os.path.isdir(os.path.join(dossier, m))]
if not manquants or zips or url:
    print("OK")
    raise SystemExit(0)
print("MANQUE " + " ".join(manquants))
PY
)
    case "${PREFLIGHT:-OK}" in
        MANQUE*)
            echo
            echo "ECHEC avant tout telechargement : modules du jeu absents pour le pack ${MODPACK:-vanilla}."
            echo "  attendus : ${PREFLIGHT#MANQUE }"
            echo "  remede 1 : deposer jeu-modules-1.5.7.zip dans ${ROOT}game-modules/"
            echo "             (un zip pose la est deballe automatiquement)"
            echo "  remede 2 : renseigner « URL des modules du jeu » et son empreinte dans le panneau"
            echo "  rien n a ete telecharge."
            exit 1
            ;;
    esac
fi


steam_ok=0
raison=""

if [ "$SRC" != "cdn" ]; then
    echo
    echo "--- 1. atelier Steam ---"
    suivre "mesure_atelier \"${AMP_HOME:-/home/amp}/Steam/steamapps/workshop/content/261550/${ITEM}\""
    if [ ! -x "${ROOT}steamcmd.sh" ] && [ -z "$SC_AMP" ]; then
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
    atelier_amp() {
        HOME="$AMP_HOME" "$SC_AMP" +login "$COMPTE_AMP" \
            +workshop_download_item 261550 "$ITEM" +quit 2>&1 | tee "$LOG" | tail -4
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
    if [ -n "$SC_AMP" ] && [ -n "$COMPTE_AMP" ]; then
        echo "    session Steam d AMP reutilisee : $COMPTE_AMP"
        if atelier_amp; then
            steam_ok=1
            PKG="$AMP_HOME/Steam/steamapps/workshop/content/261550/${ITEM}/DedicatedServer"
            echo "    atelier : OK (session AMP)"
        else
            decide_raison
            echo "    session AMP insuffisante : $raison"
        fi
    fi
    if [ "$steam_ok" = "0" ] && [ -x "${ROOT}steamcmd.sh" ]; then
        if [ -n "$SU" ]; then
            # Compte renseigne : on va droit au but. Mesure du 16/11 : l anonyme
            # ne suffit PAS pour cet objet (SteamCMD repond "Download item ...
            # failed (Failure)"), l atelier Coop exige une copie possedee du jeu.
            echo "    connexion avec le compte Steam"
            echo "    si Steam demande un code de verification, il s affiche sur le mobile"
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
    if [ "$steam_ok" = "1" ] && [ ! -f "${PKG:-$DEST}/BannerlordCoopServer.exe" ]; then
        steam_ok=0
        raison="serveur absent apres le telechargement"
    fi
    # Le paquet d atelier retarde sur les releases : le 21/11/2026 l atelier servait
    # encore 0.1.7 (jeu 1.4.8) alors que 0.1.8 (jeu 1.5.7) etait publiee sur le CDN et
    # en attente de revue Steam. Sans ce controle, « auto » prefere silencieusement le
    # build le plus vieux : le telechargement reussit, donc rien ne signale l ecart, et
    # le serveur installe est celui que la garde de version refusera ensuite.
    # On lit la seule chose que le paquet dit de lui-meme — « Game version: » — et on
    # laisse le repli CDN faire son travail quand elle ne correspond pas a l epingle.
    if [ "$steam_ok" = "1" ] && [ -n "$GAME_VERSION" ] && [ -f "${PKG:-$DEST}/release-info.txt" ]; then
        JEU_ATELIER=$(tr -d '\r' < "${PKG:-$DEST}/release-info.txt" \
            | sed -n 's/^Game version:[[:space:]]*//p' | head -1 \
            | sed 's/^.*: Bannerlord[[:space:]]*//; s/^[[:space:]]*[vV]//; s/[[:space:]]*$//')
        JEU_VOULU=$(printf '%s' "$GAME_VERSION" | sed 's/^[[:space:]]*[vV]//; s/[[:space:]]*$//')
        if [ -n "$JEU_ATELIER" ] && [ -n "$JEU_VOULU" ] && [ "$JEU_ATELIER" != "$JEU_VOULU" ]; then
            echo "    atelier : paquet en jeu ${JEU_ATELIER}, l epingle demande ${JEU_VOULU} — build d atelier ecarte"
            steam_ok=0
            raison="paquet d atelier en jeu ${JEU_ATELIER} alors que ${JEU_VOULU} est epingle (l atelier retarde sur les releases)"
        fi
    fi
    # Le paquet d atelier descend dans le home de steamcmd : on le rapatrie a
    # l emplacement que lit bannerlord-coop-launch.sh. La copie ecrase les fichiers
    # du paquet et laisse le reste — les mods ajoutes a la main survivent.
    if [ "$steam_ok" = "1" ]; then
        [ -z "$PKG" ] && PKG="$DEST"
        if [ "$PKG" != "$DEST" ] && [ -d "$PKG" ]; then
            mkdir -p "$DEST"
            if cp -a "$PKG/." "$DEST/" 2>/dev/null; then
                echo "    paquet rapatrie dans ${DEST}"
            else
                steam_ok=0
                raison="copie du paquet d atelier vers ${DEST} impossible"
            fi
        fi
    fi
    if [ "$steam_ok" = "1" ]; then
        echo "    atelier : OK"
    else
        [ -z "$raison" ] && raison="echec inconnu"
        echo "    atelier : ECHEC ($raison)"
    fi
    arreter_suivi
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
    TAILLE_ARCH=$(curl -fsSLI --max-time 60 "$AURL" 2>/dev/null | tr -d '\r' \
        | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
    if [ -f "$ARCH" ] && [ "$(sha256sum "$ARCH" | cut -d' ' -f1)" = "$ASHA" ]; then
        echo "    archive deja en cache, empreinte conforme"
    else
        if [ -f "$ARCH" ]; then
            echo "    archive en cache non conforme, retelechargement"
        fi
        TEL=0
        for U in "$AURL" "$SERVER_MIRROR_URL"; do
            [ -n "$U" ] || continue
            if [ "$U" = "$AURL" ]; then
                echo "    telechargement de $(basename "$U")"
            else
                echo "    source de secours : $U"
            fi
            rm -f "${ARCH}.part"
            suivre "mesure_telechargement \"${ARCH}.part\" \"${TAILLE_ARCH:-0}\""
            wget -qO "${ARCH}.part" "$U"
            arreter_suivi
            if [ ! -s "${ARCH}.part" ]; then
                echo "    source injoignable"
                continue
            fi
            H=$(sha256sum "${ARCH}.part" | cut -d' ' -f1)
            if [ "$H" != "$ASHA" ]; then
                echo "    empreinte differente : $H"
                echo "    archive ecartee (un miroir doit servir exactement l archive de la release)"
                rm -f "${ARCH}.part"
                continue
            fi
            mv -f "${ARCH}.part" "$ARCH"
            TEL=1
            break
        done
        if [ "$TEL" != "1" ]; then
            echo "    telechargement echoue sur toutes les sources"
            exit 1
        fi
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
    suivre "mesure_extraction \"$STAGE\""
    mkdir -p "${CACHE}/xdg"
    WINEPREFIX="${ROOT}.wine" WINEDEBUG="-all" XDG_CACHE_HOME="${CACHE}/xdg" \
        XDG_CONFIG_HOME="${CACHE}/xdg" "$WINE" "$SEVEN" x "$ARCH" -o"$STAGE" -y \
        > "${CACHE}/7z.log" 2>&1
    arreter_suivi
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
    suivre "mesure_copie \"$STAGE\" \"$DEST\""
    if ! cp -a "${STAGE}/." "$DEST/"; then
        arreter_suivi
        echo "    copie vers $DEST echouee"
        exit 1
    fi
    arreter_suivi
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
    if [ -n "${CLIENT_MIRROR_URL:-}" ]; then
        echo "      client pour les joueurs (build libre, mod Coop identique) : $CLIENT_MIRROR_URL"
        [ -n "$CLIENT" ] && echo "      source officielle de la release : $CLIENT"
    elif [ -n "$CLIENT" ]; then
        echo "      client pour les joueurs (build libre, mod Coop identique) : $CLIENT"
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
  "saveName": "saveauto1",
  "autosaveMinutes": 5,
  "password": "",
  "port": PORT_ICI,
  "logFile": true,
  "steam": true,
  "traceTick": false,
  "tracePublish": false,
  "traceBandits": false
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
# AMP relit ce fichier pour y appliquer les reglages de l onglet, en JSON strict. Un
# commentaire ou une virgule finale le font echouer au demarrage (« '/' is invalid after
# a value »), donc le serveur ne demarre pas du tout. On repare un fichier ecrit par une
# version precedente du template plutot que de le laisser bloquant.
if [ -f "$CFG" ] && command -v python3 >/dev/null 2>&1 \
    && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG" >/dev/null 2>&1; then
    cp -f "$CFG" "${CFG}.invalide.bak" 2>/dev/null
    sed -i '/^[[:space:]]*\/\//d' "$CFG" 2>/dev/null
    awk '{ if ($0 ~ /^[[:space:]]*}/ && prev ~ /,[[:space:]]*$/) { sub(/,[[:space:]]*$/, "", prev) } if (prev != "") print prev; prev = $0 } END { print prev }' \
        "$CFG" > "${CFG}.tmp" 2>/dev/null && mv -f "${CFG}.tmp" "$CFG"
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG" >/dev/null 2>&1; then
        echo "    server-config.json repare : commentaires et virgule finale retirees"
        echo "      original conserve : ${CFG}.invalide.bak"
    else
        echo "    AVERTISSEMENT : server-config.json reste illisible pour AMP"
        echo "      le demarrage echouera tant que ce fichier n est pas du JSON valide"
    fi
fi

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
echo "  cote joueur : Bannerlord ${JEU_NORM:-1.5.7} (numero de build libre), mod Coop ${COOP_ID:-0.1.8} identique"
echo "                l adresse se saisit dans l ecran de connexion du client Coop"
echo "  journaux serveur : CoopData/DedicatedServer/logs (le plus recent et Coop_server.log)"
echo "                     dans le dossier de donnees de cette instance"
echo "  journal joueur   : bin/Win64_Shipping_Client/Coop_client.log, chez le joueur"
echo "                     c est celui qu on demande quand une connexion echoue"

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
for f in tools/modpack.py tools/modconfig.py tools/modpack-install.sh bannerlord-coop-launch.sh; do
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
echo "  rappel   : le mod Coop doit etre identique cote client ; le numero de build de Bannerlord peut differer"

# ---------------------------------------------------------------------------
# Normalisation finale de server-config.json.
#
# AMP relit ce fichier pour y fusionner ses reglages, et il le fait en JSON strict :
# un commentaire // ou une virgule finale et le demarrage est refuse avant meme que le
# serveur soit lance (« '/' is invalid after a value »). Plutot que de supposer que
# personne n ecrira jamais un fichier commente, on le remet en forme ici, en dernier,
# quelle que soit son origine. L original est conserve.
CFG_FINAL="$BASE/server-config.json"
if [ -f "$CFG_FINAL" ]; then
    RESULTAT=$(python3 - "$CFG_FINAL" <<'PYNORM'
import json, os, re, sys
chemin = sys.argv[1]
brut = open(chemin, encoding="utf-8-sig").read()
try:
    json.loads(brut)
    print("ok")
    sys.exit(0)
except Exception:
    pass
sans = re.sub(r'^\s*//.*$', '', brut, flags=re.M)
sans = re.sub(r',(\s*[}\]])', r'\1', sans)
try:
    donnees = json.loads(sans)
except Exception as e:
    print("echec: %s" % e)
    sys.exit(1)
os.replace(chemin, chemin + ".avant-normalisation")
json.dump(donnees, open(chemin, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("repare")
PYNORM
)
    case "$RESULTAT" in
        ok) : ;;
        repare)
            echo "    server-config.json remis en JSON strict (original en .avant-normalisation)"
            chown 1001:1001 "$CFG_FINAL" "${CFG_FINAL}.avant-normalisation" 2>/dev/null || true
            ;;
        *)
            echo "    AVERTISSEMENT : server-config.json reste illisible ($RESULTAT)"
            echo "      AMP refusera de demarrer tant qu il n est pas corrige a la main."
            ;;
    esac
fi
