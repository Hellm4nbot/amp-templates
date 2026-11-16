#!/bin/bash
# Lance l'outil Coodsz dans l'ecran virtuel monte par l'image coodsz-amp:amp3.
#
# Execute par l'agent AMP 3 avec les variables du template : DISPLAY=:99,
# WINEPREFIX=<racine de l'instance>.wine, WINEDEBUG=-all.
# Le prefixe Wine est prepare ici et non a la construction de l'image : il doit
# appartenir a l'utilisateur de l'instance et survivre aux recreations du
# conteneur.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
log() { echo "[coodsz] $*"; }

EXE="$(find "$ROOT/app" -maxdepth 3 -name 'Coodsz Coop Server Tool.exe' 2>/dev/null | head -1)"
if [ -z "$EXE" ]; then
    log "outil absent. Lance une mise a jour (Update) : l'archive officielle sera telechargee depuis GitHub."
    exit 1
fi

export DISPLAY="${DISPLAY:-:99}"
export WINEPREFIX="${WINEPREFIX:-$ROOT/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"
log "prefixe Wine : $WINEPREFIX"

# --- 1. Prefixe ---
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    log "creation du prefixe Wine"
    wineboot -i >/tmp/wineboot.log 2>&1
    wineserver -w 2>/dev/null
fi

# --- 2. Polices ---
# Sans les vraies Arial/Times/Courier, WPF meurt sur MapUnresolvedCharacters.
FD="$WINEPREFIX/drive_c/windows/Fonts"
mkdir -p "$FD"
# Garde sur un temoin, jamais sur arial.ttf : le repli Liberation ecrit ce meme
# fichier, donc un garde sur arial.ttf ferait sauter winetricks pour toujours
# apres un premier echec, et WPF replanterait sans que rien ne le signale.
STAMP="$WINEPREFIX/.corefonts-ok"
if [ ! -f "$STAMP" ]; then
    if command -v winetricks >/dev/null 2>&1; then
        log "installation des corefonts (winetricks), cela prend une minute"
        if winetricks -q corefonts >/tmp/corefonts.log 2>&1; then
            wineserver -w 2>/dev/null
            [ -f "$FD/arial.ttf" ] && touch "$STAMP"
        else
            log "winetricks a echoue, voir /tmp/corefonts.log"
        fi
    fi
fi
if [ ! -f "$STAMP" ]; then
    # Repli : Liberation est metriquement compatible et suffit a WPF pour demarrer.
    LIB=/usr/share/fonts/truetype/liberation
    log "corefonts indisponibles, repli sur Liberation"
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/arial.ttf"    2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/arialbd.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Italic.ttf"      "$FD/ariali.ttf"   2>/dev/null
    cp -f "$LIB/LiberationSans-BoldItalic.ttf"  "$FD/arialbi.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSerif-Regular.ttf"    "$FD/times.ttf"    2>/dev/null
    cp -f "$LIB/LiberationSerif-Bold.ttf"       "$FD/timesbd.ttf"  2>/dev/null
    cp -f "$LIB/LiberationMono-Regular.ttf"     "$FD/cour.ttf"     2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/segoeui.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/segoeuib.ttf" 2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/tahoma.ttf"   2>/dev/null
    cp -f "$LIB/LiberationSans-Regular.ttf"     "$FD/calibri.ttf"  2>/dev/null
    cp -f "$LIB/LiberationSans-Bold.ttf"        "$FD/calibrib.ttf" 2>/dev/null
fi
log "polices presentes : $(ls "$FD" 2>/dev/null | wc -l) fichiers"

# --- 2b. Mot de passe VNC : appliquer le reglage du panneau, et l'afficher ---
# L'entrypoint de l'image (PID 1) ne recoit pas les variables du template : il
# choisit le mot de passe sans jamais voir le reglage « VNC Password ». Ici elles
# arrivent, puisque c'est l'agent AMP qui nous lance avec App.EnvironmentVariables.
# Donc : quand le reglage est renseigne, on reecrit le fichier d'authentification
# et on redemarre Xvnc — necessaire, Xvnc ne lit son rfbauth qu'au demarrage.
# Sans reglage, on ne touche a rien : le mot de passe de l'entrypoint, conserve
# avec l'instance, reste en vigueur.
VNC_HOME="${HOME:-/home/amp}"
PW_FILE="$VNC_HOME/.coodsz-vnc.pass"
RFB_FILE="$VNC_HOME/.coodsz-vnc.rfbauth"
vncpw=""
origine=""

case "${COODSZ_VNC_PASSWORD:-}" in
    ''|*'{{'*)
        # vide, ou jeton que AMP n'a pas substitue : ne pas le prendre au mot
        ;;
    *)
        vncpw="$COODSZ_VNC_PASSWORD"
        origine="reglage VNC Password"
        ;;
esac

if [ -z "$vncpw" ]; then
    if [ -s "$PW_FILE" ]; then
        vncpw="$(cat "$PW_FILE")"
        origine="conserve avec l'instance"
    else
        vncpw="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)"
        printf '%s' "$vncpw" > "$PW_FILE"
        chmod 600 "$PW_FILE" 2>/dev/null
        origine="genere maintenant, conserve dans $PW_FILE"
    fi
fi

# Fiabilite d'abord : si le redemarrage de Xvnc ne prend pas, on le signale et on
# laisse le mot de passe precedent plutot que d'annoncer un mot de passe faux.
if [ "$origine" = "reglage VNC Password" ] && [ "$vncpw" != "$(cat "$PW_FILE" 2>/dev/null || true)" ]; then
    log "reglage VNC Password different de celui en vigueur : redemarrage de Xvnc"
    pkill -x fluxbox 2>/dev/null
    pkill -x Xvnc 2>/dev/null
    for _ in $(seq 1 20); do pgrep -x Xvnc >/dev/null 2>&1 || break; sleep 0.5; done
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null
    printf '%s\n' "$vncpw" | vncpasswd -f > "$RFB_FILE" 2>/dev/null
    chmod 600 "$RFB_FILE" 2>/dev/null
    Xvnc :99 -geometry 1280x900 -depth 24 -rfbport 5900 \
         -rfbauth "$RFB_FILE" -SecurityTypes VncAuth \
         -AlwaysShared -desktop coodsz >/tmp/xvnc.log 2>&1 &
    sleep 3
    if pgrep -x Xvnc >/dev/null 2>&1; then
        log "Xvnc redemarre : le reglage VNC Password est applique"
    else
        log "ATTENTION : Xvnc n'a pas redemarre (voir /tmp/xvnc.log) — mot de passe inchange"
        vncpw="$(cat "$PW_FILE" 2>/dev/null || echo '?')"
        origine="precedent, le redemarrage de Xvnc a echoue"
    fi
    fluxbox >/tmp/fluxbox.log 2>&1 &
    sleep 1
fi

# Adresse a afficher : celle que l'operateur ouvrira reellement. Le conteneur ne
# peut pas deviner le nom de domaine servi par un reverse proxy, d'ou le reglage
# « Public Address » ; a defaut on prend l'adresse liee a la route par defaut,
# qui est celle de la machine sur le LAN.
HOST_AFFICHE=""
case "${COODSZ_PUBLIC_HOST:-}" in
    ''|*'{{'*) ;;                       # vide, ou jeton non substitue
    *) HOST_AFFICHE="$COODSZ_PUBLIC_HOST" ;;
esac
if [ -z "$HOST_AFFICHE" ]; then
    HOST_AFFICHE="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
fi
if [ -z "$HOST_AFFICHE" ]; then
    # Repli sans iproute2 : premiere IPv4 non locale de la machine.
    HOST_AFFICHE="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -1)"
fi
[ -z "$HOST_AFFICHE" ] && HOST_AFFICHE="$(hostname 2>/dev/null || echo localhost)"

# Port de l'interface : celui de l'onglet Ports. AMP 3 publie 1:1, et l'image
# ecoute 8642 en dur ; la variable ne sert que si le template en declare un autre.
WEBPORT="${COODSZ_WEB_PORT:-8642}"
case "$WEBPORT" in ''|*'{{'*) WEBPORT=8642 ;; esac

log "=============================================================="
log " interface de l'outil : http://$HOST_AFFICHE:$WEBPORT/vnc.html"
log "   $WEBPORT = port TCP de l'onglet Ports de l'instance"
log "   autre adresse a afficher (domaine, IP publique) : reglage \"Public Address\""
log " mot de passe VNC : $vncpw"
log "   origine : $origine"
log "=============================================================="

# --- 3. Registre : substitutions de polices et rendu WPF sans GPU ---
for paire in "Segoe UI:Liberation Sans" "Arial:Liberation Sans" "Calibri:Liberation Sans" "Tahoma:Liberation Sans" "Times New Roman:Liberation Serif" "Courier New:Liberation Mono"; do
    nom=${paire%%:*}
    remp=${paire#*:}
    wine reg add "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "$nom" /d "$remp" /f >/dev/null 2>&1
done
wine reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" /v DisableHWAcceleration \
    /t REG_DWORD /d 1 /f >/dev/null 2>&1

# --- 3b. Dossier serveur prerempli dans host.json ---
# L'outil garde ses reglages dans %LOCALAPPDATA%\Coodsz\Coop\host.json, et le
# chemin du serveur dedie est la cle ServerExecutable (bouton « Set server
# folder »). Le preremplir evite la boite de dialogue de fichiers sous Wine, qui
# est penible en VNC. Rien n'est touche si l'operateur a deja choisi un chemin
# valide, ni si le fichier n'existe pas encore (l'outil le cree a son premier
# lancement : le preremplissage prend effet au demarrage suivant).
SERVER_EXE="$ROOT/server/DedicatedServer/BannerlordCoopServer.exe"
HOST_JSON="$WINEPREFIX/drive_c/users/$(id -un 2>/dev/null || echo amp)/AppData/Local/Coodsz/Coop/host.json"
# Les modules vivent a deux endroits selon l'age de l'installation : Modules/ a la
# racine du serveur (copie d'origine, souvent vide) et engine/Modules (la ou
# l'outil range les modules qu'il gere). Ne regarder que le premier fait croire a
# tort que le module Sandbox manque.
MODULES="$ROOT/server/DedicatedServer/Modules"
MODULES_ENGINE="$ROOT/server/DedicatedServer/engine/Modules"

# 3b-0. Premiere instance, prefixe neuf : l'outil n'a pas encore ecrit host.json.
# Sans ce squelette, il s'ouvre avec un dossier serveur vide (erreur rouge
# « DedicatedServer.exe missing »), ses propres ports (4200/7210) et notre
# alignement n'a rien a corriger. On ecrit donc l'ossature AVANT de le lancer :
# il la relit, la complete, et garde les valeurs du panneau.
if [ -f "$SERVER_EXE" ] && [ ! -f "$HOST_JSON" ] && command -v python3 >/dev/null 2>&1; then
    mkdir -p "$(dirname "$HOST_JSON")" 2>/dev/null
    ZWIN="Z:$(printf '%s' "$SERVER_EXE" | tr '/' '\\')"
    python3 - "$HOST_JSON" "$ZWIN" "${COODSZ_GAME_PORT:-4200}" "${COODSZ_ENGINE_PORT:-7210}" <<'PYSEED'
import json
import sys

chemin, exe, jeu, moteur = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
profil = {
    "Name": "Default",
    "SaveName": "",
    "NewCampaign": False,
    "EnginePort": int(moteur),
    "CoopPort": int(jeu),
    "Region": "EU",
    "SteamLobbyName": "",
    "ServerAddress": "",
    "CampaignMap": "Vanilla",
    "Password": None,
    "AutosaveMinutes": 5,
    "McmFolder": "",
    "PlayersOwnSettings": [],
    "Locked": False,
    "ModuleOrder": ["Native", "DedicatedServer.Windows", "SandBoxCore", "SandBox", "Coop"],
    "DisabledModules": [],
    "Rbm": None,
    "RestartOnCrash": False,
}
squelette = {
    "GamePath": "",
    "ServerExecutable": exe,
    "AccessMode": "Banlist",
    "ActiveProfile": "Default",
    "AcceptedEulaSha256": "",
    "OpenRouterPort": True,
    "SteamLobbyAutoOn": False,
    "StreamerMode": False,
    "AutoRestartSaved": False,
    "Broadcasts": [],
    "FavouriteCheats": [],
    "RecentCommands": [],
    "Profiles": [profil],
}
try:
    with open(chemin, "w", encoding="utf-8", newline="\r\n") as f:
        json.dump(squelette, f, indent=2, ensure_ascii=False)
    print("[coodsz] host.json absent : squelette ecrit (dossier serveur, ports %s/%s)" % (jeu, moteur))
except Exception as e:
    print("[coodsz] impossible d ecrire host.json : %s" % e)
PYSEED
fi
if [ -f "$SERVER_EXE" ] && [ -f "$HOST_JSON" ] && command -v python3 >/dev/null 2>&1; then
    ZWIN="Z:$(printf '%s' "$SERVER_EXE" | tr '/' '\\\\')"
    python3 - "$HOST_JSON" "$ZWIN" "$MODULES" "$MODULES_ENGINE" <<'PYSQL'
import json, os, sys
chemin, exe, modules, modules_engine = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    d = json.load(open(chemin))
except Exception as e:
    print("[coodsz] host.json illisible (%s) : laisse tel quel" % e)
    raise SystemExit(0)

modifie = False

# 1. Dossier serveur : « Set server folder », evite la boite de dialogue sous Wine.
actuel = d.get("ServerExecutable") or ""
# Z: est la racine du conteneur : un chemin deja renseigne se verifie sur place.
if actuel and os.path.exists(actuel.replace("Z:", "", 1).replace("\\", "/")):
    print("[coodsz] dossier serveur deja renseigne : %s" % actuel)
else:
    d["ServerExecutable"] = exe
    modifie = True
    print("[coodsz] dossier serveur prerempli dans host.json : %s" % exe)

# 2. Carte de campagne : sans elle, « Demarrer le serveur » refuse de partir.
# Le module Sandbox fournit la carte Vanilla ; on ne remplit que les profils qui
# n'ont rien choisi, un choix explicite de l'operateur n'est jamais ecrase.
def dossier_module(nom, bases):
    """Trouve un module sans tenir compte de la casse : TaleWorlds ecrit SandBox
    (majuscule au B) alors que l'outil affiche Sandbox, et Linux distingue."""
    for base in bases:
        try:
            entrees = os.listdir(base)
        except Exception:
            continue
        for e in entrees:
            if e.lower() == nom.lower() and os.path.isdir(os.path.join(base, e)):
                return os.path.join(base, e)
    return None

carte_ok = dossier_module("sandbox", (modules, modules_engine)) is not None
remplis = []
for profil in d.get("Profiles") or []:
    if not (profil.get("CampaignMap") or "").strip():
        if carte_ok:
            profil["CampaignMap"] = "Vanilla"
            remplis.append(profil.get("Name") or "?")
if remplis:
    modifie = True
    print("[coodsz] carte de campagne reglee sur Vanilla : %s" % ", ".join(remplis))
elif not carte_ok:
    print("[coodsz] module Sandbox introuvable (Modules et engine/Modules) : carte non reglee")

if modifie:
    tmp = chemin + ".tmp"
    json.dump(d, open(tmp, "w"), indent=2)
    os.replace(tmp, chemin)
PYSQL
fi

# --- 3c. Diagnostic du dossier serveur ---
# Un serveur qui demarre puis sort avec le code 0 ne dit rien dans la console de
# l'outil : on imprime donc ici, a chaque demarrage, ce sans quoi il ne peut pas
# tourner. Trois lignes courtes, lisibles dans la console AMP.
DS="$ROOT/server/DedicatedServer"
if [ -d "$DS" ]; then
    api="absent"
    [ -n "$(find "$DS" -maxdepth 3 -name 'steam_api64.dll' 2>/dev/null | head -1)" ] && api="present"
    nb_mods=$(find "$DS/Modules" "$DS/engine/Modules" -maxdepth 3 -name 'SubModule.xml' 2>/dev/null | wc -l)
    noms_mods="$(find "$DS/Modules" "$DS/engine/Modules" -maxdepth 3 -name 'SubModule.xml' 2>/dev/null | sed 's#/[^/]*$##; s#.*/##' | sort -u | tr '\n' ' ')"
    log "verif : steam_api64.dll $api, $nb_mods modules, exe $([ -f "$DS/BannerlordCoopServer.exe" ] && echo present || echo ABSENT)"
    [ -n "$noms_mods" ] && log "verif : modules presents : $noms_mods"
    # Le runtime .NET utile est celui que le serveur embarque : engine/dotnet/dotnet.exe.
    # Interroger « dotnet » tout court ne prouve rien (absent du prefixe).
    if [ -f "$DS/engine/dotnet/dotnet.exe" ] && command -v wine >/dev/null 2>&1; then
        dv="$(WINEPREFIX="$WINEPREFIX" wine "$DS/engine/dotnet/dotnet.exe" --list-runtimes 2>/dev/null | tr -d '\r' | grep -oE 'Microsoft\.NETCore\.App [0-9.]+' | sort -u | tr '\n' ' ')"
        log "verif : runtime .NET embarque : ${dv:-aucun}"
    else
        log "verif : runtime .NET embarque absent (engine/dotnet/dotnet.exe)"
    fi
    dernier="$(find "$DS" "$WINEPREFIX/drive_c/users" -name '*.log' -newermt '-2 days' 2>/dev/null | head -3 | tr '\n' ' ')"
    [ -n "$dernier" ] && log "verif : journaux recents : $dernier"
fi
# 3d. Versions et ports reellement utilises. Sans ce garde-fou, une mise a jour de
# l'atelier change le socle en silence : le jour ou Coop passera en 1.5.7, le script
# de Coodsz lancera un moteur et des modules d'une autre version sans que personne
# ne l'ait decide.
REL_INFO="$ROOT/server/DedicatedServer/release-info.txt"
if [ -f "$REL_INFO" ]; then
    VERSION_PAQUET="$(tr -d '\r' < "$REL_INFO" | grep -E '^(Built|Paired Coop|Game version):' | tr '\n' ' ')"
    log "version du paquet Coop : ${VERSION_PAQUET:-illisible}"
    # Le paquet d'atelier identifie le Coop par un commit, pas par « 0.1.7 » : la
    # comparaison precedente annoncait donc un ecart a chaque demarrage, y compris
    # sur le paquet officiel. On nomme le build, et on n'alerte que si le jeu
    # n'est pas la version attendue.
    COOP_LIGNE="$(tr -d '\r' < "$REL_INFO" | sed -n 's/^Paired Coop:[[:space:]]*//p' | head -1)"
    JEU_LIGNE="$(tr -d '\r' < "$REL_INFO" | sed -n 's/^Game version:[[:space:]]*//p' | head -1)"
    COOP_SHA="$(printf '%s' "$COOP_LIGNE" | sed -n 's/.*commit[[:space:]]\{1,\}\([0-9a-f]\{7,\}\).*/\1/p')"
    JEU_NORM="$(printf '%s' "$JEU_LIGNE" | sed 's/^.*: Bannerlord[[:space:]]*//; s/^[[:space:]]*[vV]//; s/[[:space:]]*$//')"
    if [ -n "$COOP_SHA" ]; then
        log "build Coop du paquet : commit $(printf '%s' "$COOP_SHA" | cut -c1-8)"
    fi
    if [ -n "$JEU_NORM" ] && [ "$JEU_NORM" != "1.4.8" ]; then
        log "ATTENTION : paquet construit pour le jeu ${JEU_NORM}, la version validee est 1.4.8"
        log "  les sauvegardes et les modules d'une autre version peuvent ne pas correspondre."
    fi
fi
CFG_SERVEUR="$WINEPREFIX/drive_c/users/$(printf '%s' "$HOST_JSON" | sed 's#.*/drive_c/users/\([^/]*\)/.*#\1#')/Documents/Mount and Blade II Bannerlord/CoopData/DedicatedServer/server-config.json"

# --- 3e. Ports : aligner l'outil et le serveur sur ce que le panneau publie ---
# AMP 3 publie les ports en 1:1 : le numero du panneau doit etre celui que le
# serveur ecoute. L'outil garde les siens dans host.json (profil actif) et le
# serveur dans server-config.json. Sans cet alignement, un serveur qui affiche
# SERVING reste injoignable parce qu'il ecoute a cote de la publication. On ecrit
# AVANT de lancer l'outil : il relit host.json a son demarrage et ecraserait
# sinon nos valeurs.
PANNEAU_JEU="${COODSZ_GAME_PORT:-}"
PANNEAU_JEU2="${COODSZ_GAME_PORT2:-}"
PANNEAU_MOTEUR="${COODSZ_ENGINE_PORT:-}"
if [ -n "$PANNEAU_JEU" ] || [ -n "$PANNEAU_MOTEUR" ]; then
    python3 - "$HOST_JSON" "$CFG_SERVEUR" "$PANNEAU_JEU" "$PANNEAU_MOTEUR" <<'PYA'
import json
import os
import re
import shutil
import sys
import time

hote_p, conf_p, jeu, moteur = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
horo = time.strftime("%Y%m%d-%H%M")


def sans_commentaires(texte):
    sortie, i, chaine, echappe = [], 0, False, False
    while i < len(texte):
        c = texte[i]
        if chaine:
            sortie.append(c)
            if echappe:
                echappe = False
            elif c == "\\":
                echappe = True
            elif c == '"':
                chaine = False
        elif c == '"':
            chaine = True
            sortie.append(c)
        elif c in "/" and i + 1 < len(texte) and texte[i + 1] == "/":
            while i < len(texte) and texte[i] != "\n":
                i += 1
            continue
        else:
            sortie.append(c)
        i += 1
    return "".join(sortie)


def charge(p):
    try:
        return json.load(open(p, encoding="utf-8-sig"))
    except Exception:
        try:
            t = sans_commentaires(open(p, encoding="utf-8-sig").read())
            t = re.sub(r",\s*([}\]])", r"\1", t)
            return json.loads(t)
        except Exception:
            return None


def ecrit(p, d):
    shutil.copy2(p, "%s.ports-%s.bak" % (p, horo))
    with open(p, "w", encoding="utf-8", newline="\r\n") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)


hote = charge(hote_p)
if isinstance(hote, dict):
    nom = hote.get("ActiveProfile") or ""
    profil = next((x for x in (hote.get("Profiles") or []) if x.get("Name") == nom), None)
    if profil is None:
        print("[coodsz] host.json : profil actif introuvable, ports non alignes")
    else:
        avant = (profil.get("CoopPort"), profil.get("EnginePort"))
        neuf = False
        if jeu and str(profil.get("CoopPort")) != str(jeu):
            profil["CoopPort"] = int(jeu)
            neuf = True
        if moteur and str(profil.get("EnginePort")) != str(moteur):
            profil["EnginePort"] = int(moteur)
            neuf = True
        if neuf:
            ecrit(hote_p, hote)
            print("[coodsz] ports de l'outil alignes sur le panneau : jeu %s -> %s, moteur %s -> %s"
                  % (avant[0], profil.get("CoopPort"), avant[1], profil.get("EnginePort")))
        else:
            print("[coodsz] ports de l'outil deja conformes : jeu %s, moteur %s"
                  % (profil.get("CoopPort"), profil.get("EnginePort")))
else:
    print("[coodsz] host.json illisible : l'outil gardera ses propres ports")

conf = charge(conf_p)
if isinstance(conf, dict) and jeu and str(conf.get("port")) != str(jeu):
    ancien = conf.get("port")
    conf["port"] = int(jeu)
    ecrit(conf_p, conf)
    print("[coodsz] port du serveur aligne : %s -> %s (server-config.json)" % (ancien, jeu))
PYA
    if [ -n "$PANNEAU_JEU2" ] && [ -n "$PANNEAU_JEU" ] && [ "$PANNEAU_JEU2" != "$((PANNEAU_JEU + 1))" ]; then
        log "ATTENTION : le deuxieme port publie est $PANNEAU_JEU2, le serveur utilisera $((PANNEAU_JEU + 1))."
        log "  corriger l'onglet Ports : le second port doit valoir le premier + 1."
    fi
    if [ -z "$PANNEAU_JEU2" ]; then
        log "ATTENTION : aucun second port publie : la moitie des connexions echouera."
        log "  recreer l'instance (ou rafraichir sa definition) pour publier $((PANNEAU_JEU + 1))."
    fi
fi
python3 - "$HOST_JSON" "$CFG_SERVEUR" <<'PYV'
import json, re, sys


def sans_commentaires(texte):
    """Retire les commentaires // et /* */ sans toucher a l'interieur des chaines."""
    sortie = []
    i = 0
    dans_chaine = False
    echappe = False
    while i < len(texte):
        c = texte[i]
        if dans_chaine:
            sortie.append(c)
            if echappe:
                echappe = False
            elif c == "\\":
                echappe = True
            elif c == '"':
                dans_chaine = False
            i += 1
            continue
        if c == '"':
            dans_chaine = True
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
        texte = sans_commentaires(texte)
        texte = re.sub(r",\s*([}\]])", r"\1", texte)
        try:
            return json.loads(texte)
        except Exception:
            return None


hote = charge(sys.argv[1]) or {}
conf = charge(sys.argv[2]) or {}
nom = hote.get("ActiveProfile") or ""
profil = next((x for x in (hote.get("Profiles") or []) if x.get("Name") == nom), {})
print("[coodsz] ports de l'outil : jeu=%s moteur=%s" % (
    profil.get("CoopPort") or "?", profil.get("EnginePort") or "?"))
if conf:
    print("[coodsz] ports du serveur : jeu=%s monde=%s (server-config.json)" % (
        conf.get("port", "?"), conf.get("saveName", "?")))
else:
    print("[coodsz] server-config.json absent ou illisible")
PYV

log "lancement de $EXE"
cd "$(dirname "$EXE")" || exit 1

# --- 5. Lancement du serveur Coop par le template (option) ---
# Pourquoi ce detour : le bouton « Demarrer le serveur » de l'outil lance
# ServerExecutable avec des arguments PowerShell. Or PowerShell 7 sous Wine exige
# une console : sans pty, ConsoleHost leve une NullReferenceException et le
# process sort en code 0 en 55 ms, sans rien faire (mesure). L'outil redirigeant
# les flux, son bouton ne peut pas fonctionner ici. On lance donc le serveur
# nous-memes, avec un pty, tout en laissant l'outil comme interface.
# Active par defaut : c'est le seul moyen d'avoir un serveur qui tourne, le
# bouton de l'outil ne pouvant pas aboutir sous Wine.
# Seules deux choses l'empechent, et elles sont explicites : la valeur « 0 » ou le
# fichier disable-server-autostart. Toute autre valeur laisse le serveur demarrer,
# y compris « False » — un AMP qui a la definition en cache passe la case decochee
# sous cette forme, et la prendre pour un arret rendait la correction inoperante.
case "${COODSZ_SERVER_AUTOSTART:-1}" in
    0) AUTOSTART=0 ;;
    *) AUTOSTART=1 ;;
esac
if [ -f "$ROOT/disable-server-autostart" ]; then
    AUTOSTART=0
    log "serveur non lance : fichier disable-server-autostart present"
fi

if [ "$AUTOSTART" != "1" ]; then
    log "autostart desactive : l'outil seul est lance"
    exec wine "$EXE"
fi
log "autostart actif : le serveur Coop sera lance par le template"

# 5a. PowerShell 7 dans le prefixe (une seule fois, ~110 Mo)
PWSH_DIR="$WINEPREFIX/drive_c/pwsh"
PWSH_WIN='C:\pwsh\pwsh.exe'
if [ ! -f "$PWSH_DIR/pwsh.exe" ]; then
    ZIP="$ROOT/pwsh-win-x64.zip"
    if [ ! -s "$ZIP" ]; then
        log "installation de PowerShell 7 dans le prefixe (110 Mo, une fois)"
        curl -fsSL -o "$ZIP" \
            https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.zip \
            || { log "telechargement de PowerShell echoue : server non lance"; exec wine "$EXE"; }
    fi
    mkdir -p "$PWSH_DIR"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$ZIP" "$PWSH_DIR" \
        || { log "extraction de PowerShell echouee : serveur non lance"; exec wine "$EXE"; }
    log "PowerShell 7 en place : $PWSH_WIN"
fi

# 5b. Outil en tache de fond — avant toute lecture de host.json, parce que c'est
# lui qui reecrit ce fichier a son demarrage : mesure sur l'instance, SaveName
# vide juste apres un Update, rempli des que l'outil tourne. Lire avant lui, c'est
# lire un etat perime et refuser de demarrer alors qu'une sauvegarde existe.
wine "$EXE" >/tmp/coodsz-tool.log 2>&1 &
TOOL_PID=$!
trap 'kill "$TOOL_PID" 2>/dev/null' EXIT INT TERM
log "outil lance en tache de fond (journal : /tmp/coodsz-tool.log)"

# 5c. Attente du choix de sauvegarde, 40 s au plus.
lit_save_actif() {
    python3 - "$HOST_JSON" <<'PYSAVE'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
nom = d.get("ActiveProfile") or ""
p = next((x for x in (d.get("Profiles") or []) if x.get("Name") == nom), {})
print((p.get("SaveName") or "").strip())
PYSAVE
}
attente=0
while [ "$attente" -lt 20 ]; do
    [ -n "$(lit_save_actif)" ] && break
    kill -0 "$TOOL_PID" 2>/dev/null || break
    sleep 2
    attente=$((attente + 1))
done
[ "$attente" -gt 0 ] && log "sauvegarde disponible apres $((attente * 2)) s d'attente"

# 5d. Parametres du profil actif, lus dans host.json
PS1_WIN="Z:$(printf '%s' "$ROOT/server/DedicatedServer/Coodsz-Start-ModdedServer.ps1" | tr '/' '\\')"
PROFIL="$(python3 - "$HOST_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("|7210|EU|"); raise SystemExit(0)
nom = d.get("ActiveProfile") or ""
p = next((x for x in (d.get("Profiles") or []) if x.get("Name") == nom), {})
save = (p.get("SaveName") or "").strip()
neuf = "1" if p.get("NewCampaign") else ""
print("%s|%s|%s|%s" % (save, p.get("EnginePort") or 7210, p.get("Region") or "EU", neuf))
PY
)"
SAVE_HJ="${PROFIL%%|*}"; RESTE="${PROFIL#*|}"
PORT="${RESTE%%|*}"; RESTE="${RESTE#*|}"
REGION="${RESTE%%|*}"; NEUF_HJ="${RESTE#*|}"
# Le port moteur fait foi depuis le panneau : l'outil reecrit host.json avec ses
# propres valeurs au demarrage, et le serveur finissait par ecouter 7210 quand le
# panneau publiait 7212.
[ -n "${COODSZ_ENGINE_PORT:-}" ] && PORT="$COODSZ_ENGINE_PORT"

# 5b-bis. D'ou vient la sauvegarde a charger, par ordre de fiabilite :
# 1. le reglage Save Name (il vit avec l'instance, pas avec l'outil) ;
# 2. le profil actif de host.json ;
# 3. la memoire du dernier demarrage reussi, ecrite ici.
# L'outil vide SaveName dans host.json a chaque remise de ses fichiers (mesure :
# quatre profils, tous a vide, apres un Update) ; sans ces deux replis, un Update
# oblige a rechoisir la sauvegarde a la main a chaque fois.
SAVE=""; ORIGINE=""
case "${COODSZ_SAVE_NAME:-}" in
    ""|*"{{"*) : ;;
    *) SAVE="${COODSZ_SAVE_NAME}"; ORIGINE="reglage Save Name" ;;
esac
if [ -z "$SAVE" ] && [ -n "$SAVE_HJ" ]; then
    SAVE="$SAVE_HJ"; ORIGINE="profil actif de l'outil"
fi
if [ -z "$SAVE" ] && [ -s "$ROOT/.coodsz-save" ]; then
    SAVE="$(head -1 "$ROOT/.coodsz-save" | tr -d '\r\n')"
    ORIGINE="dernier demarrage enregistre"
fi
if [ -z "$SAVE" ]; then
    log "aucune sauvegarde connue : serveur non lance"
    log "choisis une sauvegarde dans l'outil, ou renseigne le reglage Save Name"
    exec wine "$EXE"
fi
printf '%s\n' "$SAVE" > "$ROOT/.coodsz-save" 2>/dev/null || true

# La campagne demandee existe-t-elle deja sur le disque ? Le drapeau NewCampaign
# de l'outil reste a true apres la creation du monde (mesure : campagne « test »
# creee, drapeau toujours true), et le script de Coodsz refuse alors avec « A
# server campaign named 'test' already exists ». On tranche donc sur le fichier :
# presence de <nom>.sav dans l'un des deux dossiers de sauvegardes.
UTILISATEUR_WINE="$(printf '%s' "$HOST_JSON" | sed 's#.*/drive_c/users/\([^/]*\)/.*#\1#')"
SAVES_COOP="$WINEPREFIX/drive_c/users/$UTILISATEUR_WINE/Documents/Mount and Blade II Bannerlord/CoopData/DedicatedServer/Game Saves"
SAVES_SRV="$ROOT/server/DedicatedServer/server-data/Game Saves"
SAVE_DEJA=""
if [ -f "$SAVES_COOP/$SAVE.sav" ] || [ -f "$SAVES_SRV/$SAVE.sav" ]; then
    SAVE_DEJA="1"
fi

SAVEOPT="-SaveName"
if [ -z "$SAVE_DEJA" ] && [ "$NEUF_HJ" = "1" ] && [ "$SAVE" = "$SAVE_HJ" ]; then
    SAVEOPT="-NewSaveName"
fi
log "serveur Coop : sauvegarde=$SAVE ($([ -n "$SAVE_DEJA" ] && echo 'deja sur le disque, chargement' || echo 'nouvelle campagne')) origine : $ORIGINE"
log "serveur Coop : port moteur=$PORT region=$REGION"

# 5e. Serveur au premier plan sous un pty : c'est la seule facon de faire
# demarrer ConsoleHost, et donc PowerShell 7 sous Wine.
# Licence du serveur Coop : sans DS_ACCEPT_EULA le serveur demande « Accept the
# EULA? [y/N] » au premier demarrage. Le template repond a la place de
# l'exploitant : c'est sa propre instance, et l'outil a deja fait accepter ses
# conditions. Une fois acceptee, le serveur ecrit eula=true dans son dossier de
# donnees et ne redemande plus. Pour refuser : retirer cette ligne.
export DS_ACCEPT_EULA=true
# Sans le script de lancement du paquet, pwsh repond « not recognized as the
# name of a script file » et rend 64 : mieux vaut le dire que laisser croire a une
# panne PowerShell.
if [ ! -f "$ROOT/server/DedicatedServer/Coodsz-Start-ModdedServer.ps1" ]; then
    log "Coodsz-Start-ModdedServer.ps1 absent de $ROOT/server/DedicatedServer"
    log "  ce script n'est pas dans le paquet d'atelier : c'est l'outil qui l'ecrit quand on"
    log "  clique une fois sur « Demarrer le serveur » dans son interface."
    log "  clic unique a faire dans l'interface de l'outil :"
    log "    http://$HOST_AFFICHE:$WEBPORT/vnc.html"
    log "  l'outil signalera ensuite une erreur PowerShell : c'est normal sous Wine, le script"
    log "  sera ecrit. Relance Start ici, le template prendra le relais."
    exit 1
fi
exec python3 - wine "$PWSH_WIN" -NoProfile -ExecutionPolicy Bypass -File "$PS1_WIN" \
    -NoPrompt -Port "$PORT" -Region "$REGION" "$SAVEOPT" "$SAVE" <<'PYP'
import os, pty, select, sys

args = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(args[0], args)
    finally:
        os._exit(127)

# Sortie du serveur vers la console, et saisie de la console vers le serveur :
# sans ce second sens, une invite (« Accept the EULA? [y/N] ») bloquerait le
# demarrage sans qu'on puisse y repondre depuis AMP.
os.set_blocking(fd, False)
entrees = [fd, 0]
while entrees:
    lisibles, _, _ = select.select(entrees, [], [])
    for source in lisibles:
        if source == fd:
            try:
                data = os.read(fd, 8192)
            except OSError:
                data = b""
            if not data:
                entrees.remove(fd)
                continue
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()
        else:
            frappe = os.read(0, 1024)
            if not frappe:
                entrees.remove(0)
                continue
            try:
                os.write(fd, frappe)
            except OSError:
                entrees.remove(0)

_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))
PYP
