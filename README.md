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

Au premier lancement : entre l'IP du PC (affichée dans **Remote Control**
côté JARVIS) et le code à 6 caractères généré par ce même bouton. Les
lancements suivants se reconnectent automatiquement.
