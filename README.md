# JARVIS — appli iOS

Client natif SwiftUI pour se connecter au serveur JARVIS qui tourne sur ton PC
(voir `dashboard/server.py` dans le projet principal).

## Compiler sans Mac (via GitHub Actions)

1. Crée un dépôt GitHub (public ou privé) et pousse ce dossier dedans.
2. Va dans l'onglet **Actions** du dépôt → workflow **Build JARVIS iOS app** →
   **Run workflow** (ou pousse simplement un commit sur `main`, ça se lance
   tout seul).
3. Une fois le job vert, ouvre le run terminé → en bas, télécharge
   l'artefact **JarvisApp-ipa** (fichier `JarvisApp.ipa`).

## Installer sur l'iPhone (sans compte développeur payant)

1. Sur ton PC Windows, installe **Sideloadly** (gratuit) :
   https://sideloadly.io
2. Branche l'iPhone en USB, ouvre Sideloadly.
3. Glisse `JarvisApp.ipa` dedans, connecte-toi avec un Apple ID gratuit
   (un compte dédié, pas forcément ton compte principal), lance
   l'installation.
4. Sur l'iPhone : Réglages → Général → VPN et gestion de l'appareil →
   fais confiance au certificat développeur affiché.
5. L'appli JARVIS apparaît sur l'écran d'accueil.

⚠️ Avec un Apple ID gratuit, l'appli doit être réinstallée (même procédure,
2 minutes) tous les 7 jours — c'est une limite d'Apple, pas de Sideloadly.

## Utilisation

1. Tailscale doit être actif sur le PC **et** sur l'iPhone (même compte).
2. Au premier lancement, touche le bloc **JARVIS**. Si l'appli ne trouve pas le
   PC toute seule, elle te demande **une seule fois** l'adresse Tailscale du PC
   (`100.x.x.x`). Aucun code à saisir : le PC accepte l'appairage automatique
   depuis Tailscale.
3. Ensuite, il suffit de toucher le bloc **JARVIS** : la connexion se fait
   toute seule, en Wi-Fi comme en 4G/5G.

## Mode autonome (PC éteint ou Jarvis non lancé)

Si le PC ne répond pas, l'appli passe toute seule en **MODE AUTONOME** : tu
discutes avec JARVIS directement depuis le téléphone (via Gemini), et l'appli
retrouve le PC toute seule dès qu'il revient (essai toutes les 20 s).

- La clé Gemini est récupérée automatiquement la première fois que le
  téléphone se connecte au PC **par Tailscale** (le PC la refuse sur le Wi-Fi
  local, où le trafic n'est pas chiffré). Elle est gardée dans le Trousseau de
  l'iPhone.
- En mode autonome, JARVIS ne peut pas agir sur le PC (ouvrir une appli,
  contrôler l'ordinateur…) et n'a pas accès à internet en direct.
- La personnalité de JARVIS dans ce mode se règle dans `GeminiClient.swift`
  (`systemPrompt()`), et le modèle dans `GeminiClient.models`.
- Il faut avoir remplacé `dashboard/server.py` par la version qui contient la
  route `/api/standalone-config`.

## Si le workflow GitHub est rouge

Ouvre le run raté → clique sur l'étape qui a échoué → copie les lignes
d'erreur (en rouge) et envoie-les pour correction.
