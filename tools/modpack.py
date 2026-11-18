#!/usr/bin/env python3
"""Manifestes de modpack : verification des modules et construction du jeton.

Le serveur Coop dedie recoit la liste des modules a charger en argument, sous la
forme :

    _MODULES_*Native*SandBoxCore*SandBox*Coop*_MODULES_

Ce fichier construit ce jeton depuis un manifeste ordonne et verifie, avant de
lancer quoi que ce soit, que chaque module annonce est reellement present et que
son identifiant correspond a celui declare dans son SubModule.xml.

Usage :
    modpack.py etat     <manifeste.json> <dossier Modules>
    modpack.py verifier <manifeste.json> <dossier Modules>
    modpack.py jeton    <manifeste.json> <dossier Modules>
    modpack.py compat   <compatibilite.json> [<manifeste.json>]
    modpack.py plan     <manifeste.json> <dossier Modules>
    modpack.py extraire <manifeste.json> <archive.zip> <dossier Modules>
    modpack.py sources  <manifeste.json>
    modpack.py modules  <manifeste.json> <cle|jeu|engine>
    modpack.py surcharger <manifeste> <sortie> <url> [sha256] [taille] [cle]
    modpack.py cles     <manifeste.json>
    modpack.py sauvegarde <fichier.sav> [<manifeste.json>]
    modpack.py fiche    <manifeste.json> [<compatibilite.json>]
    modpack.py apparence <manifeste.json> <dossier Modules>
    modpack.py copier-jeu <manifeste.json> <dossier Modules> <dossier Modules du jeu>
    modpack.py deballer <archive.zip> <dossier destination>

Codes de sortie : 0 tout va bien, 1 module manquant ou incoherent, 2 manifeste
illisible.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import time
import zipfile
import xml.etree.ElementTree as ET



def charger_avec_base(chemin):
    """Charge un manifeste en completant depuis le manifeste du pack s il est derive.

    Un manifeste derive (<pack>.local.json) est ecrit par l update quand le panneau fournit
    une URL : il recopie le manifeste du moment. Si le pack gagne ensuite une cle
    (assemblies_interface, cache_distances…), le fichier derive la masque et le reglage est
    ignore sans le dire. On complete donc les cles absentes depuis <pack>.json.
    """
    manifeste = charger(chemin)
    if chemin.endswith(".local.json"):
        base = chemin[:-len(".local.json")] + ".json"
        if os.path.isfile(base):
            try:
                reference = charger(base)
            except (OSError, ValueError):
                reference = {}
            for cle, valeur in reference.items():
                manifeste.setdefault(cle, valeur)
    return manifeste


def _taille(octets):
    for unite in ("o", "Ko", "Mo", "Go"):
        if octets < 1024 or unite == "Go":
            return ("%d %s" % (octets, unite)) if unite == "o" else ("%.1f %s" % (octets, unite))
        octets /= 1024.0

def charger(chemin):
    with open(chemin, encoding="utf-8-sig") as f:
        return json.load(f)


def _valeur(racine, balise):
    """Valeur d'une balise de SubModule.xml.

    Bannerlord ecrit indifferemment <Id value="Coop"/> (attribut value) ou
    <Id>Coop</Id> (texte) : les deux formes existent selon les mods, et un
    parseur qui ne lit qu'une des deux annonce « identifiant absent » sur un mod
    parfaitement valide.
    """
    noeud = racine.find(balise)
    if noeud is None:
        return ""
    valeur = noeud.get("value")
    if valeur is None:
        valeur = noeud.text
    return (valeur or "").strip()


def identifiant_module(dossier):
    """Identifiant declare par SubModule.xml, ou None si absent/illisible."""
    chemin = os.path.join(dossier, "SubModule.xml")
    if not os.path.isfile(chemin):
        return None
    try:
        racine = ET.parse(chemin).getroot()
    except ET.ParseError:
        return None
    for balise in ("Id", "Name"):
        valeur = _valeur(racine, balise)
        if valeur:
            return valeur
    return None


def version_module(dossier):
    chemin = os.path.join(dossier, "SubModule.xml")
    if not os.path.isfile(chemin):
        return ""
    try:
        racine = ET.parse(chemin).getroot()
    except ET.ParseError:
        return ""
    return _valeur(racine, "Version")


def source_decrite(source):
    """Resume lisible de la provenance d'un module."""
    if source == "engine":
        return "paquet du serveur"
    if isinstance(source, dict):
        if "atelier" in source:
            return "atelier %s" % source["atelier"]
        if "archive" in source:
            return "archive %s/%s" % (source["archive"], source.get("dossier", "?"))
        if source.get("jeu"):
            return "modules du jeu (copie locale)"
        if "dossier_packs" in source:
            return "dossier de packs : %s" % source["dossier_packs"]
    return "provenance inconnue"


def etat(manifeste, modules_dir):
    lignes = []
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        source = entree.get("source", "")
        dossier_attendu = ident
        if isinstance(source, dict) and source.get("dossier"):
            dossier_attendu = source["dossier"]
        chemin = os.path.join(modules_dir, dossier_attendu)
        if not os.path.isdir(chemin):
            chemin = os.path.join(modules_dir, ident)
        # Un dossier vide n'est pas un module installe : c'est ce qui arrive quand une
        # extraction a ete interrompue, et le compter comme present produit un serveur
        # qui demarre sans le mod.
        present = os.path.isdir(chemin) and os.path.isfile(os.path.join(chemin, "SubModule.xml"))
        incomplet = os.path.isdir(chemin) and not present
        reel = identifiant_module(chemin) if present else None
        lignes.append(
            {
                "id": ident,
                "dossier": dossier_attendu,
                "present": present,
                "incomplet": incomplet,
                "id_reel": reel,
                "version": version_module(chemin) if present else "",
                "source": source_decrite(source),
                # Bannerlord compare les identifiants de module sans tenir compte de la
                # casse (le paquet declare « Sandbox » la ou le manifeste dit « SandBox »,
                # et les sauvegardes ecrivent « Sandbox »). Une difference de casse n est
                # donc pas une incoherence ; un identifiant different, si.
                "coherent": present and (reel is None or reel.lower() == ident.lower()),
            }
        )
    return lignes


def _normalise(texte):
    return "".join(c for c in (texte or "").lower() if c.isalnum())


def compatibilite(chemin_compat, chemin_manifeste=None):
    """Rapporte ce que les joueurs ont constate, sans rien deduire.

    Deux champs changent tout pour un serveur dedie : un mod heberge « jeu du
    joueur » ne tourne pas sur une instance AMP, et un mod « non teste » n'est pas
    un mod compatible. Les deux sont signales ici plutot que decouverts au
    demarrage.
    """
    try:
        with open(chemin_compat, encoding="utf-8-sig") as f:
            compat = json.load(f)
    except (OSError, ValueError) as e:
        print("compatibilite illisible : %s" % e)
        return 2

    mods = compat.get("mods", [])
    if chemin_manifeste:
        try:
            manifeste = charger(chemin_manifeste)
        except (OSError, ValueError) as e:
            print("manifeste illisible : %s" % e)
            return 2
        connus = {_normalise(m.get("nom")): m for m in mods}
        print("pack %s — rapports connus pour ses modules :" % manifeste.get("nom", "?"))
        trouve = 0
        for entree in manifeste.get("modules", []):
            nom = entree.get("mod") or entree.get("id")
            rapport = connus.get(_normalise(nom))
            if not rapport:
                continue
            trouve += 1
            alertes = []
            if rapport.get("etat") == "non teste":
                alertes.append("NON TESTE")
            if rapport.get("hebergement") == "jeu du joueur":
                alertes.append("heberge par le jeu du joueur : pas de serveur dedie")
            if rapport.get("war_sails") is False:
                alertes.append("War Sails requis desactive")
            print("  %-28s %s" % (nom, "; ".join(alertes) if alertes else "rien a signaler"))
            print("      source : %s" % rapport.get("source_rapport", "?"))
        if not trouve:
            print("  aucun rapport pour ce pack")
        return 0

    print("rapports connus au %s (%s)" % (compat.get("maj", "?"), compat.get("source", "?")))
    for m in mods:
        print(
            "  %-28s etat=%-10s hebergement=%-16s jeu=%s"
            % (m.get("nom", "?"), m.get("etat", "?"), m.get("hebergement", "?"), m.get("jeu", "?"))
        )
    return 0


def extraire(chemin_manifeste, archive, modules_dir):
    """Extrait d'une archive les seuls dossiers de modules du manifeste.

    L'archive TAOM fait 18 Go pour quatre modules : tout decompacter puis trier
    couterait le double d'espace et de temps. On lit le repertoire central du zip
    et on n'extrait que les prefixes utiles, sous le nom d'identifiant attendu
    (le dossier de l'archive ne porte pas toujours cet identifiant).
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    sources = manifeste.get("sources", {})
    try:
        zf = zipfile.ZipFile(archive)
    except (OSError, zipfile.BadZipFile) as e:
        print("archive illisible : %s" % e)
        return 2

    code = 0
    with zf:
        noms = zf.namelist()
        for entree in manifeste.get("modules", []):
            ident = (entree.get("id") or "").strip()
            source = entree.get("source", "")
            if not ident or not isinstance(source, dict) or "archive" not in source:
                continue
            description = sources.get(source["archive"], {})
            prefixe = (description.get("prefixe") or "").strip("/")
            dossier = source.get("dossier", ident)
            base = "/".join(p for p in (prefixe, dossier) if p) + "/"
            cible = os.path.join(modules_dir, ident)
            if os.path.isfile(os.path.join(cible, "SubModule.xml")):
                print("%s : deja en place, non extrait" % ident)
                continue
            if os.path.isdir(cible):
                print("%s : dossier present mais sans SubModule.xml, extraction pour le completer" % ident)
            membres = [n for n in noms if n.startswith(base)]
            if not membres:
                print("%s : dossier %s introuvable dans l archive" % (ident, base))
                code = 1
                continue
            fichiers = 0
            total_octets = 0
            for nom in membres:
                if not nom.endswith("/"):
                    try:
                        total_octets += zf.getinfo(nom).file_size
                    except KeyError:
                        pass
            faits = 0
            debut = time.time()
            dernier = debut
            for nom in membres:
                relatif = nom[len(base):]
                if ".." in relatif.split("/"):
                    print("%s : entree refusee (chemin relatif) : %s" % (ident, nom))
                    code = 1
                    continue
                destination = os.path.join(cible, relatif)
                if not relatif or nom.endswith("/"):
                    os.makedirs(destination, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                with zf.open(nom) as source_f, open(destination, "wb") as cible_f:
                    shutil.copyfileobj(source_f, cible_f, 8 * 1024 * 1024)
                fichiers += 1
                faits += zf.getinfo(nom).file_size
                maintenant = time.time()
                if total_octets and maintenant - dernier >= 10.0:
                    dernier = maintenant
                    ecoule = max(maintenant - debut, 0.001)
                    debit = faits / ecoule
                    reste = (total_octets - faits) / max(debit, 1.0)
                    print("  %s : %d %% (%s / %s, %.0f Mo/s, reste ~%d min)"
                          % (ident, faits * 100 // total_octets, _taille(faits),
                             _taille(total_octets), debit / 1048576.0, reste / 60))
                    sys.stdout.flush()
            print("%s : %d fichiers extraits vers %s" % (ident, fichiers, cible))
    return code


def plan(chemin_manifeste, modules_dir):
    """Liste, pour chaque module absent, le dossier a extraire de son archive.

    Sortie : une ligne par module a installer, champs separes par une tabulation :
        <id>\t<dossier dans l'archive>\t<destination>
    Les modules deja en place ne sortent pas, et les modules « engine » ne
    s'installent pas : ils viennent avec le paquet du serveur.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    reste = []
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        source = entree.get("source", "")
        if not ident or source == "engine":
            continue
        if not isinstance(source, dict) or "archive" not in source:
            print(
                "module %s : provenance non installable (%r) — a deposer a la main dans le dossier de packs"
                % (ident, source),
                file=sys.stderr,
            )
            reste.append(ident)
            continue
        destination = os.path.join(modules_dir, ident)
        if os.path.isfile(os.path.join(destination, "SubModule.xml")):
            continue
        print("%s\t%s\t%s" % (ident, source.get("dossier", ident), destination))
    return 1 if reste else 0


def modules_de(manifeste, cle):
    """Identifiants des modules d'une provenance donnee.

    Sert a retirer proprement une version precedente : quand l'archive change,
    les dossiers qu'elle avait installes doivent partir, sinon les fichiers des
    deux builds cohabitent et le serveur charge un melange.
    """
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        source = entree.get("source", "")
        if not ident:
            continue
        if cle == "engine" and source == "engine":
            print(ident)
        elif cle == "jeu" and isinstance(source, dict) and source.get("jeu"):
            print(ident)
        elif isinstance(source, dict) and source.get("archive") == cle:
            print(ident)
    return 0


def sources(chemin_manifeste):
    """Une ligne par source d'archive : cle, url, sha256, taille, nom de fichier.

    Sortie tabulee, destinee au shell : il n'a pas a relire le JSON, et une
    source sans url ni empreinte est signalee comme telle plutot que devinee.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    for cle, d in (manifeste.get("sources") or {}).items():
        if not isinstance(d, dict):
            continue
        url = d.get("url") or ""
        nom = url.rsplit("/", 1)[-1] if url else ""
        # Un champ vide entre deux tabulations disparait au « read » du shell (la
        # tabulation est un blanc) : on emet des sentinelles plutot que du vide.
        print(
            "%s\t%s\t%s\t%s\t%s\t%s"
            % (cle, url or "-", d.get("sha256") or "-", d.get("taille") or 0, nom or "-",
               d.get("destination") or "modules")
        )
    return 0


def cles(chemin_manifeste):
    """Une ligne par source : cle et destination (« modules » ou « game-modules »)."""
    manifeste = charger(chemin_manifeste)
    for cle, d in (manifeste.get("sources") or {}).items():
        if isinstance(d, dict):
            print("%s\t%s" % (cle, d.get("destination") or "modules"))
    return 0


def surcharger(chemin_manifeste, sortie, url, sha256="", taille="", cle_seule=""):
    """Ecrit une copie du manifeste avec une autre source d'archive.

    Un nouveau build de TAOM ne doit pas demander une modification du depot : le
    panneau fournit l'url (et l'empreinte si elle est connue), et la copie obtenue
    est utilisee a la place du manifeste d'origine. L'original reste intact, donc
    revenir en arriere = vider le champ.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    sources = manifeste.get("sources") or {}
    if not sources:
        print("manifeste sans source d archive : rien a surcharger")
        return 2
    touchees = 0
    for cle, d in sources.items():
        if not isinstance(d, dict):
            continue
        if cle_seule and cle != cle_seule:
            continue
        d["url"] = url
        d["sha256"] = sha256
        try:
            d["taille"] = int(taille) if taille else 0
        except ValueError:
            d["taille"] = 0
        touchees += 1
        print("source %s : url remplacee par %s" % (cle, url))
    if touchees > 1:
        print("attention : %d sources d archive ont recu la meme url" % touchees)
    with open(sortie, "w", encoding="utf-8") as f:
        json.dump(manifeste, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("manifeste derive : %s" % sortie)
    return 0


def entete_sauvegarde(chemin):
    """En-tete d'une sauvegarde Bannerlord : longueur sur 4 octets, puis du JSON.

    Il porte la liste des modules et leurs versions : c'est ce qui permet de dire
    si une sauvegarde a ete creee avec le meme montage que le serveur, au lieu de
    le decouvrir quand le monde refuse de se charger.
    """
    with open(chemin, "rb") as f:
        brut = f.read(4)
        if len(brut) < 4:
            raise ValueError("fichier trop court")
        taille = int.from_bytes(brut, "little")
        if taille <= 0 or taille > 4 * 1024 * 1024:
            raise ValueError("longueur d en-tete invraisemblable (%d)" % taille)
        charge = f.read(taille)
    return json.loads(charge.decode("utf-8", "replace"))


def modules_sauvegarde(entete):
    brut = (entete.get("List") or {}).get("Modules") or ""
    return [m for m in brut.split(";") if m]


def sauvegarde(chemin_sav, chemin_manifeste=None):
    try:
        entete = entete_sauvegarde(chemin_sav)
    except (OSError, ValueError) as e:
        print("sauvegarde illisible : %s (%s)" % (chemin_sav, e))
        return 2
    liste = entete.get("List") or {}
    modules = modules_sauvegarde(entete)
    sidecar = os.path.splitext(chemin_sav)[0] + ".json"
    a_sidecar = os.path.isfile(sidecar)
    print("sauvegarde : %s" % os.path.basename(chemin_sav))
    print("  jeu        : %s" % liste.get("ApplicationVersion", "?"))
    print("  personnage : %s" % liste.get("CharacterName", "?"))
    print("  modules    : %s" % ";".join(modules))
    print("  sidecar    : %s" % ("present (%s)" % os.path.basename(sidecar) if a_sidecar else "absent"))
    if not a_sidecar:
        print("  consequence : sauvegarde de solo, sans personnages joueurs —")
        print("                les joueurs repartiront de la creation de personnage a la premiere session")

    if chemin_manifeste:
        try:
            manifeste = charger(chemin_manifeste)
        except (OSError, ValueError) as e:
            print("manifeste illisible : %s" % e)
            return 2
        # Les modules d'infrastructure du serveur (DedicatedServer.*) n'existent pas
        # chez un joueur : une sauvegarde creee sur une machine joueur ne les liste
        # donc pas. Les comparer ferait refuser toute sauvegarde legitime.
        def infrastructure(m):
            return m.lower().startswith("dedicatedserver.")

        ignores = sorted({m for m in modules if infrastructure(m)})
        if ignores:
            print("  ignore dans la comparaison (modules serveur) : %s" % ", ".join(ignores))
        attendus = [e["id"] for e in manifeste.get("modules", [])
                    if e.get("id") and not infrastructure(e["id"])]
        cote_save = [m for m in modules if not infrastructure(m)]
        manquants = [m for m in attendus if m.lower() not in {x.lower() for x in cote_save}]
        en_trop = [m for m in cote_save if m.lower() not in {x.lower() for x in attendus}]
        if manquants:
            print("  REFUS : modules du pack absents de la sauvegarde : %s" % ", ".join(manquants))
        if en_trop:
            print("  REFUS : modules de la sauvegarde absents du pack : %s" % ", ".join(en_trop))
        if manquants or en_trop:
            print("  une sauvegarde doit etre creee avec exactement les modules du pack")
            return 1
        print("  modules conformes au pack %s" % manifeste.get("nom", "?"))
    return 0


def empreinte_fichier(chemin, intervalle=10.0):
    """sha256 d un gros fichier, avec avancement sur la sortie d erreur.

    Un sha256 de 19 Go prend des dizaines de minutes sur un disque charge, sans rien
    afficher : l operateur ne peut pas distinguer un calcul lent d un blocage. On annonce
    donc le pourcentage, le debit et le temps restant a intervalle regulier — l empreinte
    elle-meme reste seule sur la sortie standard, pour rester capturable.
    """
    total = os.path.getsize(chemin)
    h = hashlib.sha256()
    lus = 0
    debut = time.time()
    dernier = debut
    with open(chemin, "rb") as f:
        while True:
            bloc = f.read(64 * 1024 * 1024)
            if not bloc:
                break
            h.update(bloc)
            lus += len(bloc)
            maintenant = time.time()
            if maintenant - dernier >= intervalle and total:
                dernier = maintenant
                ecoule = max(maintenant - debut, 0.001)
                debit = lus / ecoule
                reste = (total - lus) / max(debit, 1.0)
                sys.stderr.write(
                    "  empreinte : %d %% (%s / %s, %.0f Mo/s, reste ~%d min)\n"
                    % (lus * 100 // total, _taille(lus), _taille(total), debit / 1048576.0, reste / 60))
                sys.stderr.flush()
    if total:
        sys.stderr.write("  empreinte : 100 %% (%s)\n" % _taille(total))
        sys.stderr.flush()
    print(h.hexdigest())
    return 0


def assemblies_interface(chemin_manifeste, modules_dir, bin_dir):
    """Copie dans le bin du serveur les assemblies d interface que reclame un pack.

    Le serveur Coop tourne depuis engine/bin/Win64_Shipping_Server, mais les assemblies
    d interface (GauntletUI, TwoDimension, view models) ne sont livrees que dans le bin du
    module Coop. Un pack qui ajoute un mod d interface echoue alors sur
    « Could not load TaleWorlds.GauntletUI ». Le manifeste liste donc ce qui doit etre
    visible du serveur : on ne copie que ces noms, jamais les assemblies des modules
    (Coop.dll, Common.dll, GameInterface.dll…), dont la provenance est verifiee au demarrage.
    """
    try:
        manifeste = charger_avec_base(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    noms = manifeste.get("assemblies_interface") or []
    if not noms:
        return 0
    if not os.path.isdir(bin_dir):
        print("bin du serveur introuvable : %s" % bin_dir)
        return 1
    copies = 0
    sources = []
    if os.path.isdir(modules_dir):
        for dossier in sorted(os.listdir(modules_dir)):
            candidat = os.path.join(modules_dir, dossier, "bin", "Win64_Shipping_Server")
            if os.path.isdir(candidat):
                sources.append(candidat)
    manquants = []
    for nom in noms:
        if os.path.exists(os.path.join(bin_dir, nom)):
            continue
        trouve = None
        for source in sources:
            if os.path.exists(os.path.join(source, nom)):
                trouve = os.path.join(source, nom)
                break
        if not trouve:
            manquants.append(nom)
            continue
        shutil.copy2(trouve, os.path.join(bin_dir, nom))
        copies += 1
    if copies:
        print("assemblies d interface : %d copiee(s) dans le bin du serveur" % copies)
    if manquants:
        print("assemblies introuvables : %s" % ", ".join(manquants))
    return 0


def masquer_sous_modules(chemin_manifeste, modules_dir):
    """Retire d un SubModule.xml les sous-modules declares inutilisables sur un serveur.

    MCM construit une interface : sur un hote sans ecran il charge, puis echoue sans
    message utile (0xE0434352 avec Bannerlord.MBOptionScreen dans la pile). Le manifeste
    du pack liste donc, par module, les sous-modules a neutraliser.

    Les blocs sont supprimes, pas commentes : un commentaire XML qui contient lui-meme un
    commentaire (TAOM en seme dans ses blocs) produit un fichier invalide, et Bannerlord
    refuse alors le module entier — « Module … can't be loaded, there are some errors ».
    Mesure : ce defaut a fait rejeter TAOM.Dependencies au chargement, donc disparaitre des
    modules annonces au client. L original est conserve en .orig, et la liste de ce qui a
    ete retire dans .sous-modules-retires.txt.
    """
    try:
        manifeste = charger_avec_base(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    plan = manifeste.get("sous_modules_desactives") or {}
    for module, noms in plan.items():
        chemin = os.path.join(modules_dir, module, "SubModule.xml")
        if not os.path.isfile(chemin):
            print("%s : SubModule.xml introuvable, rien a masquer" % module)
            continue
        with open(chemin, encoding="utf-8-sig") as f:
            lignes = f.readlines()
        garde, retires = [], []
        i = 0
        while i < len(lignes):
            if lignes[i].lstrip().startswith("<SubModule>"):
                bloc = []
                while i < len(lignes):
                    bloc.append(lignes[i])
                    if "</SubModule>" in lignes[i]:
                        i += 1
                        break
                    i += 1
                concerne = ""
                for ligne in bloc:
                    for nom in noms:
                        if '<Name value="%s"' % nom in ligne:
                            concerne = nom
                if concerne:
                    retires.append(concerne)
                    continue
                garde.extend(bloc)
                continue
            garde.append(lignes[i])
            i += 1
        if not retires:
            continue
        if not os.path.isfile(chemin + ".orig"):
            shutil.copy2(chemin, chemin + ".orig")
        with open(chemin, "w", encoding="utf-8") as f:
            f.writelines(garde)
        with open(chemin + ".sous-modules-retires.txt", "w", encoding="utf-8") as f:
            f.write("retires par le pack %s : %s\n" % (module, ", ".join(retires)))
        print("%s : %d sous-module(s) desactive(s) (%s)" % (module, len(retires), ", ".join(retires)))
    return 0


def filtrer_actions(chemin_manifeste, modules_dir):
    """Ne garder, cote serveur, que les actions dont l animation existe dans le jeu de base.

    Un serveur sans rendu ne resout pas les clips propres a un mod : chaque `<action>` qui les
    reference leve un `Could not find animation`, et chaque avertissement ouvre une modale qui
    gele le tick (mesure : une toutes les 2,2 s, 1 432 avertissements en huit minutes). On garde
    donc les animations que les modules de base declarent (Native, SandBoxCore, SandBox,
    CustomBattle, DedicatedServer.Windows) et on retire les autres, ainsi que les actions dont
    le type n est defini nulle part (`Trying to use undefined action`).

    Regle, jamais une liste de noms observes : le mod invente une famille par version
    (rider_warg_*, howdah_*, anim_hill_troll_*, an_spi_*…), et chaque campagne revelerait la
    suivante. Les fichiers d origine restent en .orig, et le filtrage repart toujours d eux,
    donc il est idempotent. Toute ecriture invalide est annulee.
    """
    try:
        manifeste = charger_avec_base(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    plan = manifeste.get("actions_serveur") or {}
    if isinstance(plan, str):
        plan = {"mode": plan, "modules": []}
    if plan.get("mode") != "vanilla-seulement":
        return 0
    cibles_modules = plan.get("modules") or []
    base_modules = ("Native", "SandBoxCore", "SandBox", "CustomBattle", "DedicatedServer.Windows")
    motif_anim = re.compile(r'animation="([^"]*)"')
    motif_type = re.compile(r'<action\s+type="([^"]+)"')
    debut = re.compile(r'<action(?=[\s/>])')
    vanilla = set()
    for module in base_modules:
        chemin = os.path.join(modules_dir, module, "ModuleData", "action_sets.xml")
        if os.path.isfile(chemin):
            with open(chemin, encoding="utf-8-sig", errors="replace") as f:
                vanilla.update(motif_anim.findall(f.read()))
    if not vanilla:
        print("actions du serveur : aucun jeu d actions de base lisible, filtrage annule")
        return 1
    definis = set()
    for module in os.listdir(modules_dir):
        md = os.path.join(modules_dir, module, "ModuleData")
        if not os.path.isdir(md):
            continue
        for racine, _, fichiers in os.walk(md):
            for f in fichiers:
                if "action_types" in f and f.lower().endswith((".xml", ".xslt")):
                    with open(os.path.join(racine, f), encoding="utf-8-sig", errors="replace") as fh:
                        definis.update(re.findall(r'<action\s+name="([^"]+)"', fh.read()))

    def decouper(lignes):
        garde, retires, i, commentaire = [], 0, 0, False
        while i < len(lignes):
            ligne = lignes[i]
            nue = ligne.lstrip()
            if commentaire:
                garde.append(ligne)
                if "-->" in ligne:
                    commentaire = False
                i += 1
                continue
            if nue.startswith("<!--"):
                if "-->" not in ligne:
                    commentaire = True
                garde.append(ligne)
                i += 1
                continue
            if "<!--" in ligne or "-->" in ligne:
                garde.append(ligne)
                i += 1
                continue
            if debut.search(nue):
                bloc, j = [ligne], i + 1
                while "/>" not in bloc[-1] and j < len(lignes) and "<!--" not in lignes[j]:
                    bloc.append(lignes[j])
                    j += 1
                if "/>" in bloc[-1]:
                    texte = "".join(bloc)
                    m = motif_anim.search(texte)
                    if m and m.group(1) not in vanilla:
                        retires += 1
                        i = j
                        continue
                    mt = motif_type.search(texte)
                    if mt and mt.group(1) not in definis:
                        retires += 1
                        i = j
                        continue
                garde.extend(bloc)
                i = j
                continue
            garde.append(ligne)
            i += 1
        return garde, retires

    total = 0
    for module in cibles_modules:
        md = os.path.join(modules_dir, module, "ModuleData")
        if not os.path.isdir(md):
            continue
        for racine, _, fichiers in os.walk(md):
            for f in sorted(fichiers):
                if not f.startswith("action_sets") or not f.endswith((".xml", ".xslt")):
                    continue
                chemin = os.path.join(racine, f)
                orig = chemin + ".orig"
                if not os.path.isfile(orig):
                    shutil.copy2(chemin, orig)
                with open(orig, encoding="utf-8-sig", errors="replace") as fh:
                    lignes = fh.readlines()
                garde, retires = decouper(lignes)
                if not retires:
                    continue
                resultat = "".join(garde)
                with open(chemin, encoding="utf-8", errors="replace") as fh:
                    if fh.read() == resultat:
                        continue
                with open(chemin, "w", encoding="utf-8") as fh:
                    fh.write(resultat)
                try:
                    ET.parse(chemin)
                except ET.ParseError as e:
                    shutil.copy2(orig, chemin)
                    print("actions du serveur : %s invalide apres filtrage (%s), original remis" % (f, e))
                    continue
                total += retires
                print("actions du serveur : %s/%s, %d action(s) retiree(s)" % (module, f, retires))
    if total:
        print("actions du serveur : %d action(s) retirees au total (jeu de base : %d animations)"
              % (total, len(vanilla)))
    return 0


def poser_assets_serveur(chemin_manifeste, modules_dir, dossier_sources):
    """Copier dans <module>/DsAssetPackages les paquets que le serveur dedie doit voir.

    Le moteur charge <module>/DsAssetPackages/*.tpac pour chaque module et le client ne lit
    jamais ce dossier : c est la le seul endroit sur pour un paquet que seul l hote consomme.
    Sans lui, les squelettes de creatures manquent, chaque recherche d os echoue et ouvre une
    modale (mesure : 149 asserts, chargement des monstres a 8 minutes).
    """
    try:
        manifeste = charger_avec_base(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    for paquet in manifeste.get("assets_serveur") or []:
        nom = paquet.get("fichier")
        module = paquet.get("module")
        attendu = (paquet.get("sha256") or "").lower()
        if not nom or not module:
            continue
        cible = os.path.join(modules_dir, module, "DsAssetPackages", nom)
        source = os.path.join(dossier_sources, nom)
        if os.path.isfile(cible):
            with open(cible, "rb") as f:
                actuel = hashlib.sha256(f.read()).hexdigest()
            if not attendu or actuel == attendu:
                continue
        if not os.path.isfile(source):
            print("assets du serveur : %s absent du dossier paquets/, %s reste sans paquet" % (nom, module))
            continue
        with open(source, "rb") as f:
            donnees = f.read()
        if attendu and hashlib.sha256(donnees).hexdigest() != attendu:
            print("assets du serveur : %s ne correspond pas a l empreinte annoncee, ignore" % nom)
            continue
        os.makedirs(os.path.dirname(cible), exist_ok=True)
        shutil.copy2(source, cible)
        print("assets du serveur : %s pose dans %s/DsAssetPackages" % (nom, module))
    return 0


def cache_distances(chemin_manifeste, modules_dir):
    """Pose le cache de distances du fournisseur de carte declare par le manifeste.

    L hote dedie lit en dur Modules/SandBox/ModuleData/DistanceCaches/*.bin. Un pack qui
    change la carte fournit son propre cache : sans lui, la campagne chargee et le cache
    decrivent deux mondes, et la lecture du cache tombe en 0xC0000005. Le manifeste declare
    donc le module fournisseur ("cache_distances") ; l original est conserve en .vanilla
    pour pouvoir revenir a un pack sans carte custom.
    """
    nom = "settlements_distance_cache_Default.bin"
    cible = os.path.join(modules_dir, "SandBox", "ModuleData", "DistanceCaches", nom)
    original = cible + ".vanilla"
    try:
        manifeste = charger_avec_base(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    fournisseur = manifeste.get("cache_distances") or ""
    if not fournisseur:
        if os.path.exists(original) and os.path.exists(cible):
            if open(original, "rb").read() != open(cible, "rb").read():
                shutil.copy2(original, cible)
                print("cache de distances : celui d origine remis en place")
        return 0
    source = os.path.join(modules_dir, fournisseur, "ModuleData", "DistanceCaches", nom)
    if not os.path.exists(source):
        print("cache de distances : %s n en fournit pas" % fournisseur)
        return 0
    if not os.path.exists(cible):
        print("cache de distances : %s introuvable cote SandBox" % cible)
        return 1
    if not os.path.exists(original):
        shutil.copy2(cible, original)
    if open(source, "rb").read() != open(cible, "rb").read():
        shutil.copy2(source, cible)
        print("cache de distances : celui de %s (%s)" % (fournisseur, _taille(os.path.getsize(cible))))
    return 0


def deballer(archive, destination):
    """Deballe une archive de modules dans un dossier, sans chemin relatif.

    Sert au dossier des modules du jeu : l'operateur y depose un zip (ses propres
    fichiers de jeu, jamais redistribues) et l'update l'ouvre lui-meme.
    """
    os.makedirs(destination, exist_ok=True)
    try:
        zf = zipfile.ZipFile(archive)
    except (OSError, zipfile.BadZipFile) as e:
        print("archive illisible : %s" % e)
        return 2
    fichiers = 0
    with zf:
        for nom in zf.namelist():
            if ".." in nom.split("/"):
                print("entree refusee (chemin relatif) : %s" % nom)
                return 1
            cible = os.path.join(destination, nom)
            if nom.endswith("/"):
                os.makedirs(cible, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(cible), exist_ok=True)
            with zf.open(nom) as src, open(cible, "wb") as dst:
                shutil.copyfileobj(src, dst)
            fichiers += 1
    print("%s : %d fichiers deballes dans %s" % (os.path.basename(archive), fichiers, destination))
    return 0


def copier_jeu(chemin_manifeste, modules_dir, jeu_dir):
    """Copie depuis une installation du jeu les modules que le paquet ne livre pas.

    Le paquet serveur Coop ne contient que cinq modules. Un serveur modde a besoin
    de modules du jeu (StoryMode, CustomBattle...) : un hote TAOM+Coop qui
    fonctionne les a bien dans engine\\Modules. On les copie depuis les fichiers du
    jeu de l'operateur, sans jamais les redistribuer.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    if not os.path.isdir(jeu_dir):
        manquants = [e.get("id") for e in manifeste.get("modules", [])
                     if isinstance(e.get("source"), dict) and e["source"].get("jeu")]
        if manquants:
            print("dossier des modules du jeu absent : %s" % jeu_dir)
            print("  modules attendus de ce dossier : %s" % ", ".join(m for m in manquants if m))
            print("  deposer les dossiers du jeu dans ce chemin, ou renseigner le reglage")
            return 1
        return 0

    codes = 0
    for entree in manifeste.get("modules", []):
        source = entree.get("source")
        if not isinstance(source, dict) or not source.get("jeu"):
            continue
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        dossier_jeu = os.path.join(jeu_dir, source.get("dossier", ident))
        cible = os.path.join(modules_dir, ident)
        if not os.path.isdir(dossier_jeu):
            print("%s : absent du dossier du jeu (%s)" % (ident, dossier_jeu))
            codes = 1
            continue
        if os.path.isfile(os.path.join(cible, "SubModule.xml")):
            print("%s : deja en place" % ident)
            continue
        shutil.copytree(dossier_jeu, cible, dirs_exist_ok=True)
        version = version_module(cible)
        print("%s : copie depuis le jeu (%s)" % (ident, version or "version inconnue"))
        if identifiant_module(cible) not in (None, ident):
            print("  identifiant inattendu : %s" % identifiant_module(cible))
            codes = 1
    return codes


def apparence(chemin_manifeste, modules_dir):
    """Cree les modules declares « stub » dans le manifeste.

    Un module d'apparence satisfait une dependance DECLAREE, pas un besoin reel :
    il n'a ni assembly ni donnees. Utile quand un overhaul exige un module du jeu
    que le paquet serveur ne livre pas (CustomBattle dans le paquet Coop) et que
    le serveur n'ouvre jamais la fonction correspondante. Ce n'est pas neutre :
    si le code appelait vraiment ce module, l'echec surviendrait a l'execution.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2
    crees = 0
    for entree in manifeste.get("modules", []):
        if not entree.get("stub"):
            continue
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        cible = os.path.join(modules_dir, ident)
        chemin = os.path.join(cible, "SubModule.xml")
        if os.path.isfile(chemin):
            print("%s : module d apparence deja present" % ident)
            continue
        os.makedirs(cible, exist_ok=True)
        version = entree.get("version") or "v1.0.0.0"
        with open(chemin, "w", encoding="utf-8") as f:
            f.write(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                "<!-- Module d apparence cree par le template : il satisfait une dependance\n"
                "     declaree par un autre module, sans assembly ni donnees. -->\n"
                "<Module>\n"
                '  <Name value="%s"/>\n'
                '  <Id value="%s"/>\n'
                '  <Version value="%s"/>\n'
                "  <DefaultModule value=\"false\"/>\n"
                "  <ModuleCategory value=\"Singleplayer\"/>\n"
                "  <DependedModules/>\n"
                "</Module>\n" % (ident, ident, version)
            )
        print("%s : module d apparence cree (%s)" % (ident, version))
        crees += 1
    print("%d module(s) d apparence en place" % crees)
    return 0


def fiche(chemin_manifeste, chemin_compat=None):
    """Rend la fiche d'un prereglage : ce que le serveur charge, ce que les joueurs
    installent, et les manipulations a faire. Destinee a etre ecrite dans
    l'instance puis lue par l'operateur, pas a rester dans le depot.
    """
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible : %s" % e)
        return 2

    nom = manifeste.get("nom", "?")
    print("# Prereglage « %s » — %s" % (nom, manifeste.get("libelle", "")))
    print()
    print("Bannerlord %s, Coop %s." % (manifeste.get("jeu", "?"), manifeste.get("coop", "?")))
    if manifeste.get("monde") == "prepare":
        print()
        print("**Monde a creer ailleurs.** %s" % manifeste.get("note_monde", ""))
    print()

    print("## Modules charges par le serveur, dans cet ordre")
    print()
    for i, entree in enumerate(manifeste.get("modules", []), 1):
        source = entree.get("source", "")
        origine = source_decrite(source)
        print("%d. **%s** — %s" % (i, entree.get("id", "?"), origine))
    print()

    joueurs = manifeste.get("joueurs") or {}
    if joueurs:
        print("## A installer chez chaque joueur (memes versions)")
        print()
        for m in joueurs.get("installer", []):
            lien = m.get("lien") or ""
            print("- **%s** %s — %s%s" % (m.get("nom", "?"), m.get("version", ""),
                                          m.get("ou", ""), (" : " + lien) if lien else ""))
        print()
        etapes = joueurs.get("etapes") or []
        if etapes:
            print("## Manipulations")
            print()
            for i, e in enumerate(etapes, 1):
                print("%d. %s" % (i, e))
            print()
    else:
        print("## Cote joueurs")
        print()
        print("Aucun mod supplementaire : le client Coop du meme build suffit.")
        print()

    if chemin_compat:
        try:
            with open(chemin_compat, encoding="utf-8-sig") as f:
                compat = json.load(f)
        except (OSError, ValueError):
            compat = None
        if compat:
            connus = {_normalise(m.get("nom")): m for m in compat.get("mods", [])}
            lignes = []
            for entree in manifeste.get("modules", []):
                nom_mod = entree.get("mod") or entree.get("id")
                rapport = connus.get(_normalise(nom_mod))
                if rapport and rapport not in lignes:
                    lignes.append(rapport)
            if lignes:
                print("## Ce que les joueurs ont constate")
                print()
                for r in lignes:
                    print("- **%s** : etat=%s, hebergement=%s (source : %s)"
                          % (r.get("nom", "?"), r.get("etat", "?"), r.get("hebergement", "?"),
                             r.get("source_rapport", "?")))
                    if r.get("details"):
                        print("  %s" % r["details"])
                print()
    return 0


def exigences_module(dossier):
    """Dependances et versions epinglees declarees par un SubModule.xml.

    Bannerlord declare ses besoins de deux facons : <DependedModules> (liste
    simple) et <DependedModuleMetadatas> (avec ordre, version epinglee et
    optional). Seule la seconde porte les versions, et une dependance non
    optionnelle absente empeche le module de se charger : c'est exactement le cas
    qui produit un serveur qui demarre sans le mod.
    """
    chemin = os.path.join(dossier, "SubModule.xml")
    exigences = []
    if not os.path.isfile(chemin):
        return exigences
    try:
        racine = ET.parse(chemin).getroot()
    except ET.ParseError:
        return exigences

    vus = set()
    for balise, cle_id in (("DependedModules/DependedModule", "Id"),
                           ("DependedModuleMetadatas/DependedModuleMetadata", "id")):
        for noeud in racine.findall(balise):
            ident = (noeud.get(cle_id) or "").strip()
            if not ident:
                continue
            optionnel = (noeud.get("optional") or "").lower() == "true"
            exigences.append({
                "id": ident,
                "optionnel": optionnel,
                "version": (noeud.get("version") or "").strip(),
                "ordre": (noeud.get("order") or "").strip(),
            })
            vus.add(ident.lower())
    # une dependance citee dans les deux blocs ne compte qu'une fois, mais on garde
    # la version epinglee si elle existe
    fusion = {}
    for e in exigences:
        cle = e["id"].lower()
        if cle in fusion:
            if not fusion[cle]["version"] and e["version"]:
                fusion[cle]["version"] = e["version"]
            if e["optionnel"] is False:
                fusion[cle]["optionnel"] = False
        else:
            fusion[cle] = dict(e)
    return list(fusion.values())


def version_compatible(version_module, motif):
    """Compare « v1.4.8.118999 » a un motif du type « v1.4.8.* »."""
    if not motif or not version_module:
        return True
    import fnmatch
    v, m = version_module.strip(), motif.strip()
    if fnmatch.fnmatch(v, m):
        return True
    # « v1.4.8.* » veut dire « n importe quel build de 1.4.8 », et certains modules
    # publient « v1.4.8 » sans numero de build : l epingle doit donc l accepter.
    # Une epingle reellement differente (v1.4.5.* contre v1.4.8) reste un ecart.
    if m.endswith(".*"):
        base = m[:-2]
        return v == base or v.startswith(base + ".")
    return False


def controler_dependances(manifeste, modules_dir):
    """Verifie que chaque module du pack trouve ses dependances non optionnelles."""
    presents = {}
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        dossier = os.path.join(modules_dir, ident)
        if os.path.isfile(os.path.join(dossier, "SubModule.xml")):
            presents[ident.lower()] = (ident, version_module(dossier))

    problemes = []
    for entree in manifeste.get("modules", []):
        ident = (entree.get("id") or "").strip()
        if not ident:
            continue
        dossier = os.path.join(modules_dir, ident)
        if not os.path.isfile(os.path.join(dossier, "SubModule.xml")):
            continue
        for ex in exigences_module(dossier):
            if ex["id"].lower() in ("native", "sandboxcore", "sandbox", "storymode",
                                    "custombattle", "birthanddeath"):
                pass
            if ex["optionnel"]:
                continue
            if ex["id"].lower() not in presents:
                problemes.append(("bloquant", "%s exige %s — absent du pack" % (ident, ex["id"])))
                continue
            if ex["version"]:
                _, version_reelle = presents[ex["id"].lower()]
                if not version_compatible(version_reelle, ex["version"]):
                    # Un module absent ne se charge pas ; une version epinglee
                    # obsolete, si : les builds trainent des epingles perimees
                    # (LOTRLOME_Armory demande encore Native v1.4.5.* dans une
                    # archive 2.0.29.5). Avertir, sans bloquer.
                    problemes.append(
                        ("avertissement",
                         "%s epingle %s %s — version presente %s"
                         % (ident, ex["id"], ex["version"], version_reelle or "inconnue")))
    return problemes


def main(argv):
    if len(argv) >= 3 and argv[1] == "compat":
        return compatibilite(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) == 4 and argv[1] == "plan":
        return plan(argv[2], argv[3])

    if len(argv) == 5 and argv[1] == "extraire":
        return extraire(argv[2], argv[3], argv[4])

    if len(argv) == 4 and argv[1] == "modules":
        return modules_de(charger(argv[2]), argv[3])

    if len(argv) == 3 and argv[1] == "sources":
        return sources(argv[2])

    if len(argv) == 4 and argv[1] == "deballer":
        return deballer(argv[2], argv[3])

    if len(argv) == 5 and argv[1] == "copier-jeu":
        return copier_jeu(argv[2], argv[3], argv[4])

    if len(argv) == 4 and argv[1] == "apparence":
        return apparence(argv[2], argv[3])

    if len(argv) in (3, 4) and argv[1] == "fiche":
        return fiche(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) == 4 and argv[1] == "actions":
        return filtrer_actions(argv[2], argv[3])

    if len(argv) == 5 and argv[1] == "assets":
        return poser_assets_serveur(argv[2], argv[3], argv[4])

    if len(argv) == 4 and argv[1] == "masquer":
        return masquer_sous_modules(argv[2], argv[3])

    if len(argv) == 5 and argv[1] == "assemblies":
        return assemblies_interface(argv[2], argv[3], argv[4])

    if len(argv) == 3 and argv[1] == "empreinte":
        return empreinte_fichier(argv[2])

    if len(argv) == 4 and argv[1] == "cache":
        return cache_distances(argv[2], argv[3])

    if len(argv) >= 3 and argv[1] == "sauvegarde":
        return sauvegarde(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) >= 6 and argv[1] == "surcharger":
        return surcharger(argv[2], argv[3], argv[4],
                          argv[5] if len(argv) > 5 else "",
                          argv[6] if len(argv) > 6 else "",
                          argv[7] if len(argv) > 7 else "")

    if len(argv) == 3 and argv[1] == "cles":
        return cles(argv[2])

    if len(argv) != 4 or argv[1] not in ("etat", "verifier", "jeton"):
        print(__doc__.strip().splitlines()[0])
        print("usage : modpack.py {etat|verifier|jeton} <manifeste> <dossier Modules>")
        return 2
    _, action, chemin_manifeste, modules_dir = argv
    try:
        manifeste = charger(chemin_manifeste)
    except (OSError, ValueError) as e:
        print("manifeste illisible (%s) : %s" % (chemin_manifeste, e))
        return 2

    lignes = etat(manifeste, modules_dir)
    presents = [l for l in lignes if l["coherent"]]
    manquants = [l for l in lignes if not l["present"]]
    incoherents = [l for l in lignes if l["present"] and not l["coherent"]]

    if action == "etat":
        print(json.dumps(lignes, ensure_ascii=False, indent=2))
        return 0

    if action == "verifier":
        print("pack %s — %s" % (manifeste.get("nom", "?"), manifeste.get("libelle", "")))
        print("jeu attendu %s / Coop %s" % (manifeste.get("jeu", "?"), manifeste.get("coop", "?")))
        print("%-26s %-9s %-10s %s" % ("module", "present", "version", "provenance"))
        for l in lignes:
            if l["coherent"]:
                etat_txt = "oui"
            elif not l["present"] and l.get("incomplet"):
                etat_txt = "INCOMPLET"
            elif not l["present"]:
                etat_txt = "ABSENT"
            else:
                etat_txt = "INCOHERENT"
            print(
                "%-26s %-9s %-10s %s"
                % (
                    l["id"],
                    etat_txt,
                    (l["version"] or "-")[:10],
                    l["source"] if l["present"] else l["source"],
                )
            )
        if incoherents:
            for l in incoherents:
                print(
                    "  identifiant different : %s attendu, %s trouve dans le dossier %s"
                    % (l["id"], l["id_reel"] or "aucun SubModule.xml", l["dossier"])
                )
        problemes = controler_dependances(manifeste, modules_dir)
        bloquants = [t for niveau, t in problemes if niveau == "bloquant"]
        avertissements = [t for niveau, t in problemes if niveau == "avertissement"]
        if problemes:
            print("dependances declarees par les modules :")
            for t in bloquants:
                print("  BLOQUANT : %s" % t)
            for t in avertissements:
                print("  avertissement : %s" % t)
            if bloquants:
                if manifeste.get("tolerer_dependances_absentes"):
                    print("  (pack marque comme tolerant ces manques : demarrage possible mais NON VERIFIE)")
                else:
                    print("  un module dont une dependance obligatoire manque ne se charge pas")
                    print("  le serveur demarrerait sans le mod : demarrage refuse")

        if manquants or incoherents:
            print(
                "REFUS : %d module(s) manquant(s), %d incoherent(s) sur %d"
                % (len(manquants), len(incoherents), len(lignes))
            )
            return 1
        if bloquants and not manifeste.get("tolerer_dependances_absentes"):
            return 1
        print("OK : %d modules verifies" % len(lignes))
        return 0

    # jeton
    if manquants or incoherents:
        noms = ", ".join(l["id"] for l in manquants + incoherents)
        print("jeton impossible, modules manquants ou incoherents : %s" % noms)
        return 1
    jeton = "_MODULES_" + "".join("*" + l["id"] for l in presents) + "*_MODULES_"
    print(jeton)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        # sortie redirigee vers head : ce n'est pas une erreur du script
        sys.stderr.close()
        sys.exit(0)
