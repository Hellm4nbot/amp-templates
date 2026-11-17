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
    modpack.py surcharger <manifeste> <sortie> <url> [sha256] [taille]
    modpack.py sauvegarde <fichier.sav> [<manifeste.json>]

Codes de sortie : 0 tout va bien, 1 module manquant ou incoherent, 2 manifeste
illisible.
"""

import json
import os
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET


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
                "coherent": present and (reel is None or reel == ident),
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
        print(
            "%s\t%s\t%s\t%s\t%s"
            % (cle, url, d.get("sha256") or "", d.get("taille") or "", nom)
        )
    return 0


def surcharger(chemin_manifeste, sortie, url, sha256="", taille=""):
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


def main(argv):
    if len(argv) >= 3 and argv[1] == "compat":
        return compatibilite(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) == 4 and argv[1] == "plan":
        return plan(argv[2], argv[3])

    if len(argv) == 5 and argv[1] == "extraire":
        return extraire(argv[2], argv[3], argv[4])

    if len(argv) == 3 and argv[1] == "sources":
        return sources(argv[2])

    if len(argv) >= 3 and argv[1] == "sauvegarde":
        return sauvegarde(argv[2], argv[3] if len(argv) > 3 else None)

    if len(argv) >= 6 and argv[1] == "surcharger":
        return surcharger(argv[2], argv[3], argv[4],
                          argv[5] if len(argv) > 5 else "",
                          argv[6] if len(argv) > 6 else "")

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
        if manquants or incoherents:
            print(
                "REFUS : %d module(s) manquant(s), %d incoherent(s) sur %d"
                % (len(manquants), len(incoherents), len(lignes))
            )
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
