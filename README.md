# JARVIS — appli iOS (v7)

Un seul écran : l'orbe au centre, trois boutons en bas.

- **Orbe** : touche-le (ou le bouton du bas) pour lancer la conversation vocale.
  JARVIS t'écoute avec le micro du téléphone et répond avec le haut-parleur du
  téléphone (Gemini Live). Tu peux l'interrompre en parlant.
- **Micro** (bouton de gauche) : coupe/rétablit ton micro sans fermer la session.
- **Bulle** (bouton de droite) : historique + saisie au clavier.
- **Pastille « PC »** (en haut à droite) : réglages. Tu y saisis UNE FOIS l'adresse
  Tailscale du PC (100.x.x.x). Le téléphone y récupère la clé Gemini, puis marche
  aussi PC éteint.

Le téléphone et le PC sont deux JARVIS indépendants : le téléphone ne pilote pas
le PC, et le PC ne parle pas à la place du téléphone.

## Compiler / installer
Voir v6 : déposer les fichiers dans `Sources/JarvisApp` sur GitHub, attendre le
build vert (onglet Actions), télécharger l'artefact `JarvisApp-ipa`, installer avec
Sideloadly (réinstallation tous les 7 jours avec un Apple ID gratuit).

## Réglages dans le code
- Modèle vocal : `LiveVoiceClient.model` (actuellement `gemini-3.8-live`).
- Voix : `LiveVoiceClient.voiceName` (`Charon`).
- Personnalité vocale : `LiveVoiceClient.systemPrompt()`.
- Couleurs : `Theme` dans `OrbView.swift`.
