#!/bin/bash
# Lanceur du serveur Coop pour le template « Bannerlord Coop (modpacks) ».
#
# Trois responsabilites, dans cet ordre :
#   1. importer une sauvegarde deposee dans le dossier d'import, apres avoir
#      verifie qu'elle a ete creee avec les modules du pack ;
#   2. choisir le chemin de lancement : ligne eprouvee du paquet quand le pack
#      n'ajoute aucun module, sinon starter .NET avec le jeton de modules ;
#   3. refuser de demarrer si le pack est incomplet.
#
# Le jeton a la forme `_MODULES_*Native*SandBoxCore*...*_MODULES_` et vient du
# manifeste, pas d'une liste codee en dur : le binaire du serveur ne fabrique pas
# cette liste (aucune trace de _MODULES_ dedans, verifie sur piece).

set -u

ROOT="${ROOT_DIR:-/amp/bannerlordcoop/}"
ROOT="${ROOT%/}"
WID="${WORKSHOP_ID:-3770450698}"
SERV="$ROOT/steamhome/Steam/steamapps/workshop/content/261550/$WID/DedicatedServer"
DATA="$ROOT/CoopData/DedicatedServer"
SAVES="$DATA/Game Saves"
MODULES="$SERV/engine/Modules"
# Les reglages de dossier sont saisis en chemin relatif (./bannerlordcoop/...), valable
# depuis la racine du shard pendant l Update, mais le serveur demarre avec un autre
# repertoire courant : « ./bannerlordcoop/packs » y designe un dossier inexistant, et le
# manifeste est annonce introuvable alors qu il est en place. On essaie donc les deux
# bases possibles et on garde celle qui existe.
resoudre() {
    # $1 = valeur du reglage, $2 = defaut a utiliser s il est vide
    v="$1"
    [ -n "$v" ] || { echo "$2"; return; }
    case "$v" in
        /*) echo "${v%/}"; return ;;
    esac
    rel="${v#./}"
    for base in "$ROOT" "$(dirname "$ROOT")"; do
        c="${base%/}/$rel"
        if [ -d "$c" ]; then echo "${c%/}"; return; fi
    done
    echo "$(dirname "$ROOT")/${rel%/}"
}
PACKS="$(resoudre "${PACKS_DIR:-}" "$ROOT/packs")"
IMPORT="$(resoudre "${IMPORT_DIR:-}" "$ROOT/import")"
PACK="${MODPACK:-vanilla}"
SAVE="${SAVE_NAME:-saveauto1}"
PORT="${ENGINE_PORT:-7210}"
REGION="${REGION:-EU}"
# AMP affiche la sortie du serveur dans son interface mais ne la conserve pas sur disque :
# apres un demarrage rate il ne reste que le journal de l agent, qui ne dit pas pourquoi.
# On duplique donc toute la sortie dans un fichier de l instance, en gardant les cinq
# derniers demarrages.
DOSSIER_JOURNAUX="$ROOT/logs"
mkdir -p "$DOSSIER_JOURNAUX" 2>/dev/null
JOURNAL="$DOSSIER_JOURNAUX/console-$(date +%Y%m%d-%H%M%S).log"
# Trace inconditionnelle : le 23/11 un demarrage a rempli ses journaux moteur sans laisser
# le moindre console-*.log cote lanceur, et il n y avait aucun moyen de savoir si le script
# avait tourne, avec quels reglages, ni ou il s etait arrete. Une ligne ici, toujours.
TRACE="$DOSSIER_JOURNAUX/trace-demarrage.log"
printf '%s  demarrage  pack=%s  monde=%s  port=%s  journal=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "${MODPACK:-?}" "${MONDE_URL:+url}" "${ENGINE_PORT:-?}" \
    "$(basename "$JOURNAL")" >> "$TRACE" 2>/dev/null
: >> "$JOURNAL" 2>/dev/null
# stderr du lanceur sur disque : sans cela, une erreur bash ou un refus d execution ne
# laisse aucune trace des que la console AMP ne la conserve pas (constate le 23/11).
ERRLOG="$DOSSIER_JOURNAUX/stderr-lanceur.log"
exec 2>>"$ERRLOG"
# Jalons : chaque grande etape laisse son nom dans la trace. Un arret sans ligne de journal
# devient alors localisable au lieu d etre un point d interrogation.
jalon() { printf '%s  etape  %s\n' "$(date '+%H:%M:%S')" "$1" >> "$TRACE" 2>/dev/null; }
jalon "demarrage du script"
if [ -s "$JOURNAL" ] || [ -w "$DOSSIER_JOURNAUX" ]; then
    # Le modele meteo vanilla decoupe la carte en une grille fixe ; la carte de TAOM la
    # depasse, et chaque parti hors grille leve une exception de tick, rattrapee par Coop,
    # repetee a chaque tick et pour chaque parti. Sans filtre, ce bruit atteint des millions
    # de lignes et noie tout le reste. On le compte au lieu de l ecrire.
    # Deux flux separes : la console recoit tout, sans filtre, et le fichier recoit la
    # version filtree. Le filtre passe par tee, donc s il meurt il ne fait plus tomber
    # le lanceur avec lui — un filtre qui casse ne doit pas empecher un serveur de demarrer.
    # awk ecrit lui-meme dans le journal, ligne par ligne, avec fflush. Passer par tee
    # ajoutait un tampon : sur un demarrage long il ne vidait rien, et le journal restait
    # a zero octet alors que le serveur tournait. Un seul ecrivain, pas de tampon.
    # Capture d incident : les boites « Would you like to always ignore this failure? »
    # sont la cause mesuree des gels cote joueur (une par 1,6 s), et le journal filtre ne
    # dit pas ce qui les declenche. On garde en memoire les 80 dernieres lignes brutes et,
    # aux cinq premieres boites, on les ecrit a part. Cinq captures suffisent a nommer la
    # cause sans ajouter de volume ensuite.
    # Plafond de journal. Mesure du 22/11 sur le Discord du mod : une erreur repetee a
    # 6,9 millions de lignes par minute a rempli 120 Go en quelques minutes chez un hote.
    # Le filtre ci-dessous reconnait le bruit connu, pas une erreur inedite : on borne donc
    # la taille du journal, et on continue a compter ce qui n est plus ecrit.
    JOURNAL_MAX_MO="${JOURNAL_MAX_MO:-64}"
    exec > >(awk -v J="$JOURNAL" -v E="$JOURNAL.etats" -v I="$JOURNAL.incidents" -v LIMITE="$((JOURNAL_MAX_MO * 1024 * 1024))" '
        function w(l) {
            if (plafond) { ecartees++; return }
            octets += length(l) + 1
            if (octets > LIMITE) {
                plafond = 1
                ecartees++
                print "[coop] journal plafonne a " LIMITE " octets : la suite n est plus ecrite, seul le compteur avance" > J
                fflush(J)
                return
            }
            print l > J
            fflush(J)
        }
        BEGIN { bruit = 0; n = 0; captures = 0; exml = 0; eev = 0; eop = 0; divers = 0; octets = 0; plafond = 0; ecartees = 0 }
        {
            tampon[n % 80] = $0
            n++
            # Les lignes @DS@{...} portent la vraie cause quand le serveur meurt : le
            # 23/11, « FileLoadException: Assembly with same name is already loaded »
            # n existait que la, dans une ligne que la rotation du journal avait emportee.
            # Elles vont donc dans leur propre fichier, qui n est jamais plafonne.
            if ($0 ~ /@DS@/) {
                print $0 > E
                fflush(E)
            }
            if ($0 ~ /Would you like to always ignore/ && captures < 5) {
                captures++
                print "=== capture " captures " ===" > I
                depart = (n > 80) ? n - 80 : 0
                for (i = depart; i < n; i++) print tampon[i % 80] > I
                fflush(I)
            }
        }
        /Failed to tick moving party|IndexOutOfRangeException: Index was outside/ \
        || /DefaultMapWeatherModel|IsBaseSpeedCacheInvalid|CalculateSpeed_Patch|ComputeNextMoveDistance/ \
        || /FillCurrentTickMoveDataForMovingMobileParty|ParallelTickMovingParties/ {
            bruit++
            if (bruit % 2000 == 1) {
                ligne = sprintf("[coop] bruit TAOM : %d incidents de tick ignores (partis hors grille meteo)", bruit)
                print ligne; fflush(); w(ligne)
            }
            next
        }
        /^[[:space:]]*$/ { next }
        /attribute is not declared|^Node: |^Line: |^XML Path/ {
            exml++
            w($0)
            if (exml % 200 == 1) {
                ligne = sprintf("[coop] bruit du mod : %d lignes XML ecartees de la console (gardees dans le journal)", exml)
                print ligne; fflush(); w(ligne)
            }
            next
        }
        /Could not find the event index/ {
            eev++
            w($0)
            if (eev % 500 == 1) {
                ligne = sprintf("[coop] bruit du mod : %d lignes « event index » ecartees de la console", eev)
                print ligne; fflush(); w(ligne)
            }
            next
        }
        /\[DedicatedServer Engine\] opening / {
            eop++
            w($0)
            next
        }
        /Voice def can not be found|Failed to get id for object of type|UnknownSaveId/ {
            divers++
            if (divers % 50 == 1) {
                ligne = sprintf("[coop] bruit du serveur : %d lignes « voice def », « failed to get id » et « UnknownSaveId » ecartees", divers)
                print ligne; fflush(); w(ligne)
            }
            next
        }
        { print; fflush(); w($0) }
        END {
            if (bruit > 0) {
                ligne = sprintf("[coop] bruit TAOM : %d incidents de tick au total", bruit)
                w(ligne)
            }
            ligne = sprintf("[coop] bruit du mod : %d lignes XML, %d « event index », %d ouvertures de fichiers et %d lignes serveur ecartees de la console", exml, eev, eop, divers)
            print ligne; fflush(); w(ligne)
            if (ecartees > 0) {
                ligne = sprintf("[coop] journal plafonne : %d ligne(s) non ecrite(s), %d octets au total", ecartees, octets)
                print ligne; fflush(); w(ligne)
            }
            if (captures > 0) {
                ligne = sprintf("[coop] captures d incident : %d dans %s.incidents", captures, J)
                w(ligne)
            }
        }
    ') 2>&1
    ls -1t "$DOSSIER_JOURNAUX"/console-*.log 2>/dev/null | tail -n +6 | while read -r vieux; do rm -f "$vieux"; done
    echo "sortie aussi ecrite dans : $JOURNAL"
fi

OUTIL="$ROOT/tools/modpack.py"
# Version de jeu annoncee aux joueurs. Elle vient du reglage, avec la valeur du template en
# secours : le bandeau est imprime avant tout le reste, donc la variable doit exister des ici
# (set -u fait echouer le script sur une variable non definie).
JEU="${GAME_VERSION:-1.5.7}"
COOP_ID="${COOP_BUILD:-0.1.8}"

log() {
    echo "[coop] $*"
    # Copie directe dans le journal, sans passer par le tube du filtre : le 23/11 le
    # journal restait a zero octet alors que le script allait jusqu a l exec, sans qu on
    # puisse dire si c etait le filtre ou le script qui se taisait. Le prefixe « #direct »
    # distingue les deux chemins quand tous les deux ecrivent.
    printf '#direct [coop] %s\n' "$*" >> "$JOURNAL" 2>/dev/null
}
erreur() { echo "[coop] ERREUR : $*" >&2; }

# Bandeau imprime avant de passer la main au serveur : une fois le pty en place,
# plus rien de ce script n'apparait dans la console.
banniere() {
    echo
    echo " COMMENT JOUER — prereglage « $PACK »"
    echo "   monde demande      : $SAVE (dans Game Saves)"
    echo "   port moteur        : $PORT (interne, les joueurs ne s y connectent pas)"
    echo "   cote joueurs       : Bannerlord $JEU (le numero de build peut differer) et le mod Coop $COOP_ID,"
    echo "                        identique ; plus les mods du prereglage s il en a"
    echo "   fiche du prereglage: $ROOT/PRESET-$PACK.md (modules, liens, manipulations)"
    echo
}

[ -d "$SERV" ] || { erreur "dossier du serveur introuvable : $SERV"; exit 1; }
[ -f "$OUTIL" ] || { erreur "outil modpack introuvable : $OUTIL"; exit 1; }

MANIFESTE="$PACKS/$PACK.json"
if [ ! -f "$MANIFESTE" ]; then
    erreur "manifeste du pack « $PACK » introuvable : $MANIFESTE"
    erreur "  dossier des packs : $PACKS"
    erreur "  (reglage « Dossier des packs » : chemin relatif resolu depuis $ROOT)"
    erreur "  lancer un Update du template (il recupere les manifestes du depot)"
    exit 1
fi

# Le moteur cherche ses donnees sous Documents du prefixe Wine ; le template les
# tient dans CoopData a la racine. Sans ce lien, la sauvegarde importee et les
# options de jeu ne seraient pas vues.
UTILISATEUR=$(id -un 2>/dev/null || echo root)
PREFIXE="${WINEPREFIX:-$ROOT.wine}"
DOCS="$PREFIXE/drive_c/users/$UTILISATEUR/Documents/Mount and Blade II Bannerlord"
# Le mod ne cherche PAS au meme niveau que le wrapper : il lit son dossier
# utilisateur dans Documents\...\CoopData\DedicatedServer, alors qu'un lien place sur
# CoopData pointait un cran trop haut — le mod ne trouvait alors aucune configuration
# et prenait ses valeurs par defaut (port 4200 au lieu du port publie, pas de mot de
# passe). On relie donc le niveau exact attendu, en laissant CoopData comme vrai
# dossier pour ce que le wrapper y depose.
CIDIR="$DOCS/CoopData"
if [ -L "$CIDIR" ]; then rm -f "$CIDIR" 2>/dev/null; fi
if [ -d "$DATA" ]; then
    mkdir -p "$CIDIR" 2>/dev/null || true
    if [ ! -e "$CIDIR/DedicatedServer" ]; then
        ln -sfn "$DATA" "$CIDIR/DedicatedServer" 2>/dev/null \
            && log "dossier utilisateur du mod relie a $DATA" \
            || log "lien CoopData/DedicatedServer impossible : le mod utilisera ses valeurs par defaut"
    fi
fi

# Coop lit ses reglages de jeu dans CoopData/mod-config.json, un niveau au-dessus de ses
# donnees. C'est ce fichier qui porte birthAndDeath : les naissances et les morts sont
# activees par ce reglage, sans le module DLC BirthAndDeath que Coop refuse.
MCFG="$CIDIR/mod-config.json"
if [ -f "$MCFG" ]; then
    log "reglages du mod : $MCFG ($(grep -o '"birthAndDeath"[[:space:]]*:[[:space:]]*[a-z]*' "$MCFG" 2>/dev/null | head -1))"
elif [ -f "$DATA/mod-config.json" ]; then
    cp -a "$DATA/mod-config.json" "$MCFG" 2>/dev/null \
        && log "reglages du mod mis en place : $MCFG" \
        || log "reglages du mod absents : Coop utilisera ses valeurs par defaut"
fi

# Reglages du mod exposes au panneau (warSails compris) : le panneau ne peut pas les
# ecrire lui-meme — AMP fusionne les champs « $.modOptions.* » dans server-config.json,
# ou ces chemins n existent pas (mesure du 21/11 : « 34 JSONPath target(s) not found »,
# et aucun mod-config.json cree). Chaque reglage arrive ici sous la forme d une variable
# MC_<section>_<cle> posee par le template ; tools/modconfig.py ecrit la cle dans le seul
# fichier que Coop lit, sans toucher aux commentaires, aux virgules finales ni au BOM.
OUTIL_CONFIG="$ROOT/tools/modconfig.py"
PAIRES="$ROOT/cache/reglages-mod.txt"
mkdir -p "$(dirname "$PAIRES")" 2>/dev/null || true
env | grep '^MC_' | sed 's/^MC_//' | sed 's/_/./' > "$PAIRES" 2>/dev/null || true
if [ -f "$OUTIL_CONFIG" ] && [ -s "$PAIRES" ]; then
    MC_MESSAGE=$(python3 "$OUTIL_CONFIG" ecrire "$MCFG" "$PAIRES" 2>&1)
    log "reglages du mod : $MC_MESSAGE"
    log "  fichier : $MCFG"
else
    log "reglages du mod : outil absent ($OUTIL_CONFIG), lancer un Update"
fi
if [ "${MC_modOptions_warSails:-false}" = "true" ]; then
    log "  War Sails actif : la campagne doit avoir ete creee avec la DLC."
    log "  une campagne normale s arrete sur Exit 9 dans ce mode, et inversement."
fi

jalon "monde : entree"

# --- 0. monde de depart du pack ---------------------------------------------
# Un pack a monde custom ne peut pas creer sa campagne sur un serveur dedie : le monde
# vient d une machine joueur. On en garde une copie vierge dans monde/, et on la remet
# en place quand la sauvegarde attendue est absente — l autosave ecrit dans la
# sauvegarde de jeu, il ne doit jamais manger le monde de depart.
MONDE="$ROOT/monde/$PACK-depart.sav"
MONDE_SHA="$ROOT/monde/$PACK-depart.sha256"
MONDE_SOURCE="$ROOT/monde/$PACK-depart.url"
CIBLE_MONDE="$SAVES/$SAVE.sav"

# Repartir de zero : le reglage du panneau (MondeReset) ou, pour les instances dont la
# configuration est figee, un fichier monde/RESET. La partie en cours est archivee avant
# d etre supprimee, et le monde de depart est reinstalle juste apres.
# AMP rend les cases a cocher en « True » / « False », pas en minuscules : comparer a
# "true" en dur laissait la case sans effet (constate le 21/11, reset demande, monde
# inchange). On accepte donc les deux casses et les formes usuelles.
vrai() {
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
        true|1|yes|oui|on) return 0 ;;
        *) return 1 ;;
    esac
}
RESET_DEMANDE=0
vrai "${MONDE_RESET:-false}" && RESET_DEMANDE=1
RESET_MARQUE="$ROOT/monde/.reset-fait"
if [ -f "$ROOT/monde/RESET" ] || [ "$RESET_DEMANDE" = "1" ]; then
    if [ "$RESET_DEMANDE" = "1" ] && [ -f "$RESET_MARQUE" ]; then
        log "monde deja remis a zero : decocher le reglage pour pouvoir le refaire"
    elif [ -f "$CIBLE_MONDE" ] || [ -f "$CIBLE_MONDE.json" ] || [ -f "$ROOT/monde/RESET" ]; then
        ARCHIVE="$ROOT/sauvegardes/$(date +%Y%m%d-%H%M)-reset"
        mkdir -p "$ARCHIVE" 2>/dev/null
        for f in "$CIBLE_MONDE" "$CIBLE_MONDE.json"; do
            [ -f "$f" ] && cp -a "$f" "$ARCHIVE/" 2>/dev/null
        done
        rm -f "$CIBLE_MONDE" "$CIBLE_MONDE.json" "$ROOT/monde/RESET"
        log "remise a zero : partie archivee dans sauvegardes/$(basename "$ARCHIVE")/ puis supprimee"
        [ "$RESET_DEMANDE" = "1" ] && : > "$RESET_MARQUE"
    else
        log "remise a zero demandee, mais aucune partie a archiver : rien a faire"
        # Marqueur pose quand meme : sans lui, la case restee cochee aurait archive et
        # supprime la premiere vraie partie au demarrage suivant.
        if [ "$RESET_DEMANDE" = "1" ]; then
            : > "$RESET_MARQUE"
        fi
    fi
elif [ -f "$RESET_MARQUE" ]; then
    rm -f "$RESET_MARQUE"
fi

# La sauvegarde en place appartient-elle bien au pack courant ? Un changement de Modpack
# (vanilla -> taom, ou l inverse) laisse une campagne d un autre monde : la charger ferait
# mourir la lecture du cache de distances en 0xC0000005, et noierait la cause sous un
# accident memoire. On verifie donc les modules de la sauvegarde contre le manifeste, et si
# elle vient d ailleurs elle est archivee au lieu d etre chargee.
if [ -f "$CIBLE_MONDE" ] && [ -f "$MANIFESTE" ]; then
    if ! python3 "$OUTIL" sauvegarde "$CIBLE_MONDE" "$MANIFESTE" >/dev/null 2>&1; then
        ARCHIVE="$ROOT/sauvegardes/$(date +%Y%m%d-%H%M)-autre-pack"
        mkdir -p "$ARCHIVE" 2>/dev/null
        for f in "$CIBLE_MONDE" "$CIBLE_MONDE.json"; do
            [ -f "$f" ] && cp -a "$f" "$ARCHIVE/" 2>/dev/null
        done
        rm -f "$CIBLE_MONDE" "$CIBLE_MONDE.json"
        log "la partie en place vient d un autre pack : archivee dans sauvegardes/$(basename "$ARCHIVE")/"
        log "  le pack $PACK repart de son propre monde"
    fi
fi

# D ou vient le monde : reglage du panneau (MondeUrl / MondeSha256), sinon fichier local
# monde/<pack>-depart.url (deux lignes : url puis empreinte). Le fichier local sert aux
# instances dont la configuration est figee et qui ne montrent pas encore ces reglages.
URL_MONDE="${MONDE_URL:-}"
SHA_MONDE="${MONDE_SHA256:-}"
if [ -z "$URL_MONDE" ] && [ -f "$MONDE_SOURCE" ]; then
    URL_MONDE=$(sed -n '1p' "$MONDE_SOURCE" | tr -d '\r' | tr -d ' ')
    [ -z "$SHA_MONDE" ] && SHA_MONDE=$(sed -n '2p' "$MONDE_SOURCE" | tr -d '\r' | tr -d ' ')
fi

# Autre sauvegarde proposee : si l empreinte declaree n est plus celle du fichier en place,
# la source a change et l ancienne copie est remplacee.
if [ -n "$URL_MONDE" ] && [ -n "$SHA_MONDE" ] && [ -f "$MONDE" ]; then
    ACTUEL=$(awk '/^[0-9a-f]{64}$/{print $1}' "$MONDE_SHA" 2>/dev/null | head -1)
    if [ -n "$ACTUEL" ] && [ "$ACTUEL" != "$SHA_MONDE" ]; then
        log "monde de depart : source differente de la copie en place, remplacement"
        rm -f "$MONDE" "$MONDE_SHA"
        [ -f "$CIBLE_MONDE" ] && : > "$ROOT/monde/$PACK-depart.neuf"
    fi
fi

if [ ! -f "$MONDE" ] && [ -n "$URL_MONDE" ]; then
    log "monde de depart : telechargement"
    mkdir -p "$ROOT/monde" 2>/dev/null
    if curl -fsSL --max-time 1800 -o "$MONDE.part" "$URL_MONDE"; then
        RECU=$(sha256sum "$MONDE.part" 2>/dev/null | awk '{print $1}')
        # le fichier recu est controle tout de suite : enregistrer l empreinte declaree sans
        # verifier reviendrait a signer un fichier qu on n a pas regarde
        if [ -n "$SHA_MONDE" ] && [ "$RECU" != "$SHA_MONDE" ]; then
            rm -f "$MONDE.part"
            erreur "monde de depart refuse : empreinte attendue $SHA_MONDE, obtenue $RECU"
            exit 1
        fi
        mv -f "$MONDE.part" "$MONDE"
        echo "$RECU" > "$MONDE_SHA"
        log "monde de depart telecharge : $(du -h "$MONDE" 2>/dev/null | cut -f1), empreinte $RECU"
    else
        rm -f "$MONDE.part"
        erreur "telechargement du monde de depart impossible : $URL_MONDE"
        exit 1
    fi
fi

# « Game Saves » n existe pas dans une instance neuve : le serveur ne le cree qu une fois
# une partie lancee. Copier le monde avant ce moment echouait sur « No such file or
# directory » et le demarrage s arretait la (constate le 23/11, premiere instance TAOM).
mkdir -p "$SAVES" 2>/dev/null

if [ ! -f "$CIBLE_MONDE" ] && [ -f "$MONDE" ]; then
    ATTENDU=$(awk '/^[0-9a-f]{64}$/{print $1}' "$MONDE_SHA" 2>/dev/null | head -1)
    OBTENU=$(sha256sum "$MONDE" 2>/dev/null | awk '{print $1}')
    if [ -n "$ATTENDU" ] && [ "$ATTENDU" != "$OBTENU" ]; then
        erreur "monde de depart corrompu : empreinte attendue $ATTENDU, obtenue $OBTENU"
        exit 1
    fi
    [ -z "$ATTENDU" ] && echo "$OBTENU" > "$MONDE_SHA"
    if python3 "$OUTIL" sauvegarde "$MONDE" "$MANIFESTE" >/dev/null 2>&1; then
        cp -a "$MONDE" "$CIBLE_MONDE" \
            && log "monde de depart installe : $PACK-depart.sav devient $SAVE.sav" \
            || { erreur "copie du monde de depart impossible"; exit 1; }
        # La sauvegarde d une partie Coop va par deux : le .sav et le .json qui porte les
        # personnages des joueurs. Le FAQ du mod est explicite, « grab both when moving a
        # save » : sans le .json, tout le monde repart de la creation de personnage. On
        # tente donc le fichier jumeau a cote de l URL, sans en faire une condition.
        JSON_MONDE="$(dirname "$MONDE")/$PACK-depart.json"
        if [ ! -f "$JSON_MONDE" ]; then
            if curl -fsSL --max-time 300 -o "$JSON_MONDE.part" "${URL_MONDE%.sav}.json" 2>/dev/null; then
                mv -f "$JSON_MONDE.part" "$JSON_MONDE"
            else
                rm -f "$JSON_MONDE.part"
            fi
        fi
        if [ -f "$JSON_MONDE" ]; then
            cp -a "$JSON_MONDE" "$CIBLE_MONDE.json" \
                && log "  sidecar installe : $SAVE.json (personnages des joueurs conserves)" \
                || log "  sidecar present mais non copie : les joueurs recreeront leur personnage"
        else
            log "  pas de .json a cote de l URL : sauvegarde de solo,"
            log "    les joueurs creeront leur personnage a la premiere connexion"
        fi
    else
        erreur "monde de depart refuse : ses modules ne correspondent pas au pack $PACK"
        exit 1
    fi
elif [ -f "$CIBLE_MONDE" ]; then
    log "monde existant repris : $SAVE.sav (monde de depart conserve dans monde/)"
    if [ -f "$ROOT/monde/$PACK-depart.neuf" ]; then
        log "  un nouveau monde de depart est pret : supprimer $SAVE.sav de Game Saves pour repartir de lui"
        rm -f "$ROOT/monde/$PACK-depart.neuf"
    fi
fi

jalon "monde : fin"

# --- 1. import d'une sauvegarde ---------------------------------------------
# Le monde d'un overhaul se cree sur une machine joueur : sans ce chemin, il
# faudrait aller copier des fichiers a la main au fond du conteneur.
if [ -d "$IMPORT" ]; then
    SAV=""
    for f in "$IMPORT"/*.sav; do
        [ -f "$f" ] || continue
        if [ -z "$SAV" ] || [ "$f" -nt "$SAV" ]; then SAV="$f"; fi
    done
    if [ -n "$SAV" ]; then
        log "sauvegarde trouvee dans l import : $(basename "$SAV")"
        if python3 "$OUTIL" sauvegarde "$SAV" "$MANIFESTE"; then
            mkdir -p "$SAVES" || { erreur "creation de $SAVES impossible"; exit 1; }
            CIBLE="$SAVES/$SAVE.sav"
            if [ -f "$CIBLE" ]; then
                HORO=$(date +%Y%m%d-%H%M%S)
                cp -a "$CIBLE" "$CIBLE.avant-$HORO" && log "sauvegarde precedente conservee : $(basename "$CIBLE").avant-$HORO"
            fi
            cp -a "$SAV" "$CIBLE" || { erreur "copie de la sauvegarde impossible"; exit 1; }
            SIDECAR="${SAV%.sav}.json"
            if [ -f "$SIDECAR" ]; then
                cp -a "$SIDECAR" "$SAVES/$SAVE.json" && log "sidecar importe : $SAVE.json (personnages joueurs conserves)"
            else
                log "pas de sidecar .json : sauvegarde de solo, les joueurs creeront leur personnage"
            fi
            HORO=$(date +%Y%m%d-%H%M%S)
            mv "$SAV" "$IMPORT/importe-$HORO-$(basename "$SAV")" 2>/dev/null
            [ -f "$SIDECAR" ] && mv "$SIDECAR" "$IMPORT/importe-$HORO-$(basename "$SIDECAR")" 2>/dev/null
            log "sauvegarde installee sous le nom « $SAVE »"
        else
            erreur "sauvegarde refusee : elle n a pas ete creee avec les modules du pack $PACK"
            erreur "  creer le monde avec exactement ces modules, ou choisir un autre pack"
            exit 1
        fi
    fi
fi

jalon "imports : fin"

# --- 2. modules supplementaires ? -------------------------------------------
SUPPLEMENTAIRES=$(python3 - "$MANIFESTE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
print(sum(1 for e in m.get("modules", []) if e.get("source") != "engine"))
PY
) || { erreur "manifeste illisible : $MANIFESTE"; exit 1; }

jalon "modules : fin"

# --- 3a. pack sans module ajoute : ligne eprouvee du paquet -----------------
if [ "${SUPPLEMENTAIRES:-0}" = "0" ]; then
    log "pack $PACK : aucun module supplementaire, lancement par l exe du paquet"
    log "port moteur $PORT, region $REGION, donnees $DATA"
    banniere
    cd "$SERV" || exit 1
    exec /usr/bin/wine BannerlordCoopServer.exe --no-tui --data-dir "Z:$DATA" -p "$PORT" --region "$REGION"
fi

# Copies parasites du module Coop : le FAQ du mod cite « Coop.11 » comme la cause d un
# joueur qui tombe juste apres s etre connecte, et le serveur ne dit rien — il en charge
# une au hasard. On met les vraies copies de cote et on repare un dezippage d un niveau
# de trop, avant que les modules ne soient lus.
DOUBLONS=$(python3 "$OUTIL" doublons "$MODULES" 2>&1 || true)
case "$DOUBLONS" in
    *copie*|*imbrique*|*renommee*) echo "$DOUBLONS" | while IFS= read -r l; do log "  $l"; done ;;
esac

# --- 3b. pack modde : starter .NET avec le jeton ----------------------------
# Sous-modules inutilisables sur un serveur sans ecran (MCM et consorts), declares par le
# pack : ils sont neutralises dans le SubModule.xml avant le chargement des modules.
MASQ_MESSAGE=$(python3 "$OUTIL" masquer "$MANIFESTE" "$MODULES" 2>&1 || true)
case "$MASQ_MESSAGE" in
    *desactive*) log "$MASQ_MESSAGE" ;;
esac

# Paquets que seul le serveur lit (squelettes des creatures d un overhaul) : le moteur charge
# <module>/DsAssetPackages, le client jamais. Deposes dans le dossier paquets/ du pack.
ASSETS_MESSAGE=$(python3 "$OUTIL" assets "$MANIFESTE" "$MODULES" "$ROOT/paquets" 2>&1 || true)
case "$ASSETS_MESSAGE" in
    *"assets du serveur :"*) echo "$ASSETS_MESSAGE" | while IFS= read -r l; do log "$l"; done ;;
esac

# Actions liees a des clips que le serveur ne peut pas resoudre : elles n ouvrent que des
# modales qui gelent le tick. On ne garde que ce que le jeu de base declare.
ACTIONS_MESSAGE=$(python3 "$OUTIL" actions "$MANIFESTE" "$MODULES" 2>&1 || true)
case "$ACTIONS_MESSAGE" in
    *"action(s)"*) echo "$ACTIONS_MESSAGE" | while IFS= read -r l; do log "$l"; done ;;
esac

# Assemblies d interface reclamees par le pack (mods d UI) : le serveur tourne depuis son
# propre bin, qui n en contient pas. Le manifeste dit lesquelles ; on ne copie que celles-la.
ASM_MESSAGE=$(python3 "$OUTIL" assemblies "$MANIFESTE" "$MODULES" "$SERV/engine/bin/Win64_Shipping_Server" 2>&1 || true)
if [ -n "$ASM_MESSAGE" ]; then
    echo "$ASM_MESSAGE" | while IFS= read -r l; do [ -n "$l" ] && log "$l"; done
fi

# Le cache de distances de la carte : l hote dedie le lit en dur dans SandBox. Un pack qui
# change la carte declare son fournisseur dans le manifeste, et on le met en place ici —
# sinon campagne et cache decrivent deux mondes (0xC0000005 a la lecture).
CACHE_MESSAGE=$(python3 "$OUTIL" cache "$MANIFESTE" "$MODULES" 2>/dev/null || true)
[ -n "$CACHE_MESSAGE" ] && log "$CACHE_MESSAGE"

# Declarations de modules : les bibliotheques que TAOM reclame sans les livrer comme
# modules. Le client Coop refuse la connexion si le serveur ne les declare pas.
DECL_MESSAGE=$(python3 "$OUTIL" declarations "$MANIFESTE" "$MODULES" 2>&1 || true)
[ -n "$DECL_MESSAGE" ] && log "$DECL_MESSAGE"
JETON=$(python3 "$OUTIL" jeton "$MANIFESTE" "$MODULES")
CODE=$?
if [ "$CODE" != "0" ]; then
    erreur "modules incomplets pour le pack $PACK : demarrage refuse"
    erreur "  $JETON"
    erreur "  lancer un Update : il installe les modules manquants"
    exit 1
fi

log "pack $PACK : $SUPPLEMENTAIRES module(s) supplementaire(s)"
log "jeton de modules : $JETON"
log "port moteur $PORT, region $REGION"

BIN="$SERV/engine/bin/Win64_Shipping_Server"
STARTER="TaleWorlds.Starter.DotNetCore.dll"
DOTNET="$SERV/engine/dotnet/dotnet.exe"
[ -f "$BIN/$STARTER" ] || { erreur "starter .NET absent : $BIN/$STARTER"; exit 1; }
[ -f "$DOTNET" ] || { erreur "dotnet embarque absent : $DOTNET"; exit 1; }

# Le repertoire de travail est celui du starter : c'est de la que le moteur
# resout ses assemblies, pas de la racine du serveur.
cd "$BIN" || exit 1

banniere

export DOTNET_ROOT="Z:$SERV/engine/dotnet"
export DOTNET_MULTILEVEL_LOOKUP=0
export COOP_DATA_DIR="C:\\users\\$UTILISATEUR\\Documents\\Mount and Blade II Bannerlord\\CoopData"

# --- relais du journal du mod dans la console AMP --------------------------
# Le moteur se tait une fois la campagne chargee et le mod ecrit ses reperes dans son
# propre fichier : sans ce relais la console d AMP ne dit jamais que le serveur ecoute
# alors que Coop_server.log affiche « Server listening on UDP port 4206 ». On relit donc
# la fin de ce fichier et on ne reemet que les lignes qui comptent.
LOGCOOP="$DATA/logs/Coop_server.log"
relais_journal() {
    # Lecture par sondage, pas par tail -F : sur cette instance le tail suivait bien le
    # bon fichier sans jamais rien remettre (console figee alors que le journal du mod
    # venait d ecrire « Server listening on UDP port 4206 »). On lit donc les octets
    # ajoutes toutes les trois secondes, en reperant le fichier par son inode : quand le
    # mod fait tourner son journal (.prev.log), l inode change et on relit depuis zero.
    f="$1"
    marque=""
    pos=0
    while :; do
        if [ -f "$f" ]; then
            ino=$(stat -c%i "$f" 2>/dev/null || echo 0)
            taille=$(stat -c%s "$f" 2>/dev/null || echo 0)
            if [ -z "$marque" ]; then
                marque="$ino"        # premier passage : on repart de la fin du fichier
                pos="$taille"
            elif [ "$ino" != "$marque" ]; then
                marque="$ino"        # journal remplace : on le lit depuis le debut
                pos=0
            fi
            if [ "$taille" -gt "$pos" ]; then
                tail -c +$((pos + 1)) "$f" 2>/dev/null | while IFS= read -r l; do
                    l=${l%$'\r'}
                    case "$l" in
                        *"Server listening on UDP"*) echo "[coop] ===== SERVEUR PRET : ecoute sur UDP $PORT =====" ;;
                        *"is changing to MapState"*) echo "[coop] campagne chargee" ;;
                        *ServerRunningState*)        echo "[coop] etat : en marche, en attente de joueurs" ;;
                        *"difficulty (effective)"*)  echo "[coop] $(printf '%s' "${l#*] }" | cut -c1-150)" ;;
                        *" ERR "*)                   echo "[coop] ERREUR MOD : $(printf '%s' "${l#*] }" | cut -c1-150)" ;;
                        *"Mission state:"*)          echo "[coop] battement : $(printf '%s' "${l#*] }" | cut -c1-120)" ;;
                    esac
                done
                pos="$taille"
            fi
        fi
        sleep 3
    done
}
relais_journal "$LOGCOOP" &
log "reperes du mod relayes ici, journal complet : $LOGCOOP"

# /no_watchdog est obligatoire des qu'un mod est present : le moteur signale ses
# avertissements a un programme de surveillance de bureau ; sans ecran, le premier
# avertissement tue le serveur. Le jeu de base n'avertit pas, les mods si.
jalon "exec wine (starter .NET)"
log "commande : wine $DOTNET $STARTER <jeton> /dedicatedcustomserver $PORT $REGION 0 /no_watchdog"
# La sortie du serveur part dans un fichier a part, par un tube simple (| tee) et non par
# une substitution de processus : le 23/11 le filtre awk ne recevait rien du tout et tout ce
# que le serveur disait — dont la ligne @DS@ qui nomme la cause d arret — disparaissait.
# tee ecrit au fur et a mesure, et la console AMP continue de tout recevoir.
exec /usr/bin/wine "$DOTNET" "$STARTER" "$JETON" /dedicatedcustomserver "$PORT" "$REGION" 0 /no_watchdog 2>&1 | tee -a "$JOURNAL.raw"
