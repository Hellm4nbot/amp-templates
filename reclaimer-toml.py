#!/usr/bin/env python3
"""Ecrit dedicated.toml pour Project Reclaimer depuis les reglages AMP.

Le moteur refuse un fichier invalide au demarrage et `dedicated check` dit
pourquoi, donc ce script n ecrit que des cles documentees, et seulement celles
qui ont un sens pour le mode choisi : un serveur campagne ne peut pas aussi
porter playlist, variant, map, game, base_map, odst ou reach.
"""
import json
import os
import re
import sys

E = os.environ


def b(nom, defaut=False):
    v = (E.get(nom) or '').strip().lower()
    if v in ('true', '1', 'yes', 'on'):
        return True
    if v in ('false', '0', 'no', 'off'):
        return False
    return defaut


def n(nom, defaut=0):
    v = (E.get(nom) or '').strip()
    try:
        return int(float(v))
    except ValueError:
        return defaut


def s(nom, defaut=''):
    v = (E.get(nom) or '').strip()
    return v if v else defaut


def liste(nom):
    brut = (E.get(nom) or '').replace('\n', ',').replace(';', ',')
    return [x.strip() for x in brut.split(',') if x.strip()]


def q(texte):
    """Chaine TOML, echappee comme il faut."""
    texte = str(texte).replace('\\', '\\\\').replace('"', '\\"')
    return '"' + texte + '"'


def tableau(valeurs):
    return '[' + ', '.join(q(v) for v in valeurs) + ']'


lignes = []


def ecrire(*lignes_a_ajouter):
    lignes.extend(lignes_a_ajouter)


mode = s('GMODE', 'multi').lower()
if mode in ('campagne', 'campaign', 'coop'):
    mode = 'campagne'
if mode in ('odst', 'reach'):
    pass
elif mode in ('multi', 'multijoueur', 'multiplayer'):
    mode = 'multi'
elif mode != 'campagne':
    print('mode de jeu inconnu : %s (attendu multi, campagne, odst ou reach)' % mode)
    raise SystemExit(1)

# ---------------------------------------------------------------- general
ecrire('game = "game"', 'content = "content"', 'data = "data"', 'bans = "bans.json"')
if s('HOST_NAME'):
    ecrire('host_name = ' + q(s('HOST_NAME')))
if s('PUBLIC_ADDRESS'):
    ecrire('public_address = ' + q(s('PUBLIC_ADDRESS')))
if s('BIND_ADDRESS'):
    ecrire('bind_address = ' + q(s('BIND_ADDRESS')))
ecrire('upnp = ' + ('true' if b('UPNP') else 'false'))
ecrire('auto_update = ' + ('true' if b('AUTO_UPDATE') else 'false'))
ecrire('auto_reload = ' + ('true' if b('AUTO_RELOAD', True) else 'false'))
admins = liste('ADMINS')
if admins:
    ecrire('admins = ' + tableau(admins))
modos = liste('MODERATORS')
if modos:
    ecrire('moderators = ' + tableau(modos))
immunises = liste('VOTE_KICK_IMMUNE')
if immunises:
    ecrire('vote_kick_immune = ' + tableau(immunises))
ecrire('stats_server = ' + q('' if b('STATS_REPORTING') else 'off'))
copies = liste('STATS_COPIES')
if copies:
    ecrire('stats_copies = ' + tableau(copies))
films = liste('FILM_RECEIVERS')
if films:
    ecrire('film_receivers = ' + tableau(films))
if n('FILM_UPLOAD_KBPS'):
    ecrire('film_upload_kbps = %d' % n('FILM_UPLOAD_KBPS'))

# ---------------------------------------------------------------- master
ecrire('', '[master]')
ecrire('enabled = ' + ('true' if b('MASTER_ENABLED', True) else 'false'))
ecrire('port = %d' % n('MASTER_PORT', 49175))
pairs = liste('MASTER_PEERS')
if pairs:
    ecrire('peers = ' + tableau(pairs))
if s('MASTER_ORIGIN'):
    ecrire('origin = ' + q(s('MASTER_ORIGIN')))

# ---------------------------------------------------------------- rcon
ecrire('', '[rcon]')
ecrire('password = ' + q(s('RCON_PASSWORD')))
ecrire('address = ' + q(s('RCON_ADDRESS', '127.0.0.1')))

# ---------------------------------------------------------------- vpn
ecrire('', '[vpn]')
listes = liste('VPN_LISTS')
if listes:
    ecrire('lists = ' + tableau(listes))
asns = liste('VPN_ASNS')
if asns:
    ecrire('asns = ' + tableau(asns))
if s('VPN_ASN_TABLE'):
    ecrire('asn_table = ' + q(s('VPN_ASN_TABLE')))
ecrire('fail_closed = ' + ('true' if b('VPN_FAIL_CLOSED') else 'false'))

# ---------------------------------------------------------------- workshop
atelier = liste('WORKSHOP_ITEMS')
if b('DOWNLOAD_WORKSHOP_ITEMS') and atelier:
    ecrire('', '[workshop]')
    ecrire('items = [' + ', '.join(atelier) + ']')
    steamcmd = s('WORKSHOP_STEAMCMD')
    utilisateur = s('WORKSHOP_USERNAME')
    # Sans chemin fourni : le steamcmd d'AMP et sa session en cache, ce qui evite
    # tout mot de passe. Le compte se lit dans le config.vdf du home d'AMP.
    if not steamcmd:
        for candidat in ('/amp/.amp/steamcmd/steamcmd.sh', os.path.join(os.path.dirname(os.getcwd()), '.amp/steamcmd/steamcmd.sh')):
            if os.access(candidat, os.X_OK):
                steamcmd = candidat
                break
    if steamcmd and not utilisateur:
        vdf = os.path.join(os.path.expanduser('~'), 'Steam/config/config.vdf')
        if os.path.isfile(vdf):
            bloc = []
            dedans = False
            for ligne in open(vdf, encoding='utf-8', errors='replace'):
                if '"Accounts"' in ligne:
                    dedans = True
                    continue
                if dedans:
                    trouve = re.search(r'"([^"]+)"', ligne)
                    if trouve:
                        utilisateur = trouve.group(1)
                        break
    if steamcmd:
        ecrire('steamcmd = ' + q(steamcmd))
    if utilisateur:
        ecrire('username = ' + q(utilisateur))
    if n('WORKSHOP_UPDATE_MINUTES'):
        ecrire('update_check_minutes = %d' % n('WORKSHOP_UPDATE_MINUTES', 60))

# ---------------------------------------------------------------- defaults
ecrire('', '[defaults]')
ecrire('max_players = %d' % n('MAX_PLAYERS', 16))
if n('MIN_PLAYERS', 1) > 1:
    ecrire('min_players = %d' % n('MIN_PLAYERS', 1))
if n('POST_GAME_SECONDS', 15) != 15:
    ecrire('post_game_seconds = %d' % n('POST_GAME_SECONDS', 15))
if n('START_COUNTDOWN_SECONDS', 3) != 3:
    ecrire('start_countdown_seconds = %d' % n('START_COUNTDOWN_SECONDS', 3))
if n('MAX_PING'):
    ecrire('max_ping = %d' % n('MAX_PING'))
if s('NETWORK_MODEL'):
    ecrire('network_model = ' + q(s('NETWORK_MODEL')))
if s('COOP_NETWORK'):
    ecrire('coop_network = ' + q(s('COOP_NETWORK')))
if s('TEAM_CHANGING'):
    ecrire('team_changing = ' + q(s('TEAM_CHANGING')))
ecrire('friendly_fire = ' + ('true' if b('FRIENDLY_FIRE', True) else 'false'))
ecrire('votes = ' + ('true' if b('VOTES', True) else 'false'))
ecrire('anti_cheat = ' + q(s('ANTI_CHEAT', 'enforce')))
ecrire('block_vpn = ' + ('true' if b('BLOCK_VPN', True) else 'false'))
ecrire('chat_log = ' + ('true' if b('CHAT_LOG', True) else 'false'))
if s('CAMERA'):
    ecrire('camera = ' + q(s('CAMERA')))
if s('FORCE_MODEL'):
    ecrire('force_model = ' + q(s('FORCE_MODEL')))
if b('MAP_HUD'):
    ecrire('map_hud = true')
if not b('STOCK_MAP_DEFAULTS', True):
    ecrire('stock_map_defaults = false')
if b('ROUND_OUTLASTS_LEAVERS'):
    ecrire('round_outlasts_leavers = true')
if b('SHARE_MODS'):
    ecrire('share_mods = true')
    if n('SHARE_RATE', 20):
        ecrire('share_rate = %d' % n('SHARE_RATE', 20))
if s('JOINS'):
    ecrire('joins = ' + q(s('JOINS')))
portes = liste('JOIN_GATES')
if portes:
    ecrire('join_gates = ' + tableau(portes))
for cle, nom in (('QUEUE_MAX', 'queue_max'), ('VIP_QUEUE_MAX', 'vip_queue_max'),
                 ('VIP_PRIORITY', 'vip_priority'), ('QUEUE_STARVE_AFTER', 'queue_starve_after'),
                 ('QUEUE_MAX_WAIT', 'queue_max_wait')):
    if E.get(cle, '').strip() != '':
        ecrire('%s = %d' % (nom, n(cle)))
if s('FORGE_EDIT'):
    ecrire('forge_edit = ' + q(s('FORGE_EDIT')))
if not b('FORGE_PRIMITIVES', True):
    ecrire('forge_primitives = false')
for cle, nom, defaut in (('ODST_OBJECTS', 'odst_objects', False), ('HALO3_OBJECTS', 'halo3_objects', True)):
    if b(cle, defaut) != defaut:
        ecrire('%s = %s' % (nom, 'true' if b(cle, defaut) else 'false'))

# ---------------------------------------------------------------- le serveur
ecrire('', '[[server]]')
ecrire('name = ' + q(s('SERVER_NAME', 'Project Reclaimer')))
ecrire('port = %d' % n('GAME_PORT', 49176))
ecrire('hidden = ' + ('true' if b('HIDDEN') else 'false'))
if s('JOIN_PASSWORD'):
    ecrire('password = ' + q(s('JOIN_PASSWORD')))
bienvenue = [x.strip() for x in (E.get('WELCOME') or '').split('|') if x.strip()][:5]
if bienvenue:
    ecrire('welcome = ' + tableau(bienvenue) if len(bienvenue) > 1 else 'welcome = ' + q(bienvenue[0]))
# Les bots combattants n existent qu en multijoueur : le moteur refuse un serveur
# coop qui en porte ("combat_bots are for multiplayer games only"). On les ecrit
# donc dans le bloc du serveur, et seulement en multijoueur.
if b('ALLOW_BOTS'):
    ecrire('allow_bots = true')
if mode == 'multi' and n('COMBAT_BOTS'):
    ecrire('combat_bots = %d' % n('COMBAT_BOTS'))
    if n('BOT_PILOTS'):
        ecrire('bot_pilots = %d' % n('BOT_PILOTS'))
if n('RCON_PORT'):
    ecrire('rcon_port = %d' % n('RCON_PORT'))
if s('RCON_PASSWORD'):
    ecrire('rcon_password = ' + q(s('RCON_PASSWORD')))
if s('METRICS_HTTP'):
    ecrire('metrics_http = ' + q(s('METRICS_HTTP')))
if n('TICK_RATE', 60) == 30:
    ecrire('tick_rate = 30')
if s('NETWORK_MODEL'):
    ecrire('network_model = ' + q(s('NETWORK_MODEL')))
if s('COOP_NETWORK'):
    ecrire('coop_network = ' + q(s('COOP_NETWORK')))
if b('TRUST_PLAYER_GAMES', True) is False:
    ecrire('trust_player_games = false')
if n('CAMPAIGN_SKIP_VOTE', 33) != 33:
    ecrire('campaign_skip_vote_percent = %d' % n('CAMPAIGN_SKIP_VOTE', 33))
if n('LOAD_TIMEOUT', 30) != 30:
    ecrire('load_timeout = %d' % n('LOAD_TIMEOUT', 30))


def modificateurs(ennemis=True):
    """Modifiers communs a la campagne Halo 3 et a la campagne ODST."""
    mods = []
    if ennemis:
        if n('MOD_HEALTH', 100) != 100:
            mods.append('health_percent = %d' % n('MOD_HEALTH', 100))
        if n('MOD_DAMAGE', 100) != 100:
            mods.append('damage_percent = %d' % n('MOD_DAMAGE', 100))
        if n('MOD_HEALTH_PER_PLAYER'):
            mods.append('health_per_player_percent = %d' % n('MOD_HEALTH_PER_PLAYER'))
        if n('MOD_DAMAGE_PER_PLAYER'):
            mods.append('damage_per_player_percent = %d' % n('MOD_DAMAGE_PER_PLAYER'))
        if s('MOD_SCORING'):
            mods.append('scoring = ' + q(s('MOD_SCORING')))
    if n('MOD_SKULLS'):
        mods.append('skulls = %d' % n('MOD_SKULLS'))
    if b('MOD_SPRINT'):
        mods.append('sprint = true')
        if n('MOD_SPRINT_STAMINA'):
            mods.append('sprint_stamina_seconds = %d' % n('MOD_SPRINT_STAMINA'))
    return mods


if mode == 'multi':
    if s('PLAYLIST_FILE'):
        ecrire('playlist = ' + q(s('PLAYLIST_FILE')))
    else:
        ecrire('map = ' + q(s('MAP_NAME', 'guardian')))
        ecrire('game = ' + q(s('GAME_TYPE', 'Slayer')))
    if s('VARIANT_FILE'):
        ecrire('variant = ' + q(s('VARIANT_FILE')))
elif mode == 'campagne':
    parties = ['campaign = ' + q(s('CAMPAIGN_GAME', 'halo3')),
               'mission = ' + q(s('CAMPAIGN_MISSION', 'Sierra 117')),
               'difficulty = ' + q(s('CAMPAIGN_DIFFICULTY', 'normal'))]
    if n('CAMPAIGN_INSERTION') > 0:
        parties.append('insertion = %d' % n('CAMPAIGN_INSERTION'))
    if b('CAMPAIGN_CUSTOM_CHARACTERS'):
        parties.append('custom_characters = true')
    mods = modificateurs()
    if mods:
        parties.append('modifiers = { ' + ', '.join(mods) + ' }')
    ecrire('campaign = { ' + ', '.join(parties) + ' }')
elif mode == 'odst':
    parties = ['mission = ' + q(s('ODST_MISSION', 'Tayari Plaza')),
               'difficulty = ' + q(s('ODST_DIFFICULTY', 'normal'))]
    if s('ODST_MODE') == 'firefight':
        parties.insert(0, 'mode = "firefight"')
        if s('ODST_VARIANT'):
            parties.append('variant = ' + q(s('ODST_VARIANT')))
    if n('ODST_INSERTION') > 0:
        parties.append('insertion = %d' % n('ODST_INSERTION'))
    if s('ODST_MODE') == 'firefight':
        # En Firefight, seuls le sprint et le tir allie comptent : les cranes
        # passent par les options, pas par les modifiers.
        mods = modificateurs(ennemis=False)
        if mods:
            parties.append('modifiers = { ' + ', '.join(mods) + ' }')
        options = []
        for morceau in (s('ODST_OPTIONS') or '').replace(';', ',').split(','):
            if '=' not in morceau:
                continue
            cle, valeur = morceau.split('=', 1)
            cle = cle.strip().strip('"')
            valeur = valeur.strip()
            if not cle:
                continue
            try:
                float(valeur)
                options.append('"%s" = %s' % (cle, valeur))
            except ValueError:
                options.append('"%s" = %s' % (cle, q(valeur)))
        if options:
            parties.append('options = { ' + ', '.join(options) + ' }')
    else:
        if not b('ODST_STORY_CHARACTERS', True):
            parties.append('story_characters = false')
        mods = modificateurs()
        if mods:
            parties.append('modifiers = { ' + ', '.join(mods) + ' }')
    ecrire('odst = { ' + ', '.join(parties) + ' }')
elif mode == 'reach':
    parties = ['map = ' + q(s('REACH_MAP', 'm10')), 'campaign = true']
    if s('REACH_FIREFIGHT'):
        parties.append('firefight = ' + q(s('REACH_FIREFIGHT')))
    ecrire('reach = { ' + ', '.join(parties) + ' }')

texte = '\n'.join(lignes) + '\n'
cible = sys.argv[1] if len(sys.argv) > 1 else 'dedicated.toml'
with open(cible, 'w', encoding='utf-8') as f:
    f.write(texte)

if '--quiet' not in sys.argv:
    print('dedicated.toml ecrit : mode %s, port %s' % (mode, n('GAME_PORT', 49176)))
    print(texte)
