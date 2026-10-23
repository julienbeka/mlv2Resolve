# mlv2dng

Edit Magic Lantern MLV footage directly in DaVinci Resolve: mlv2dng mounts your clips as CinemaDNG sequences on the fly — no conversion, no terminal.

Montez vos rushs Magic Lantern (MLV) directement dans DaVinci Resolve : mlv2dng les présente à la volée en séquences CinemaDNG, sans conversion ni terminal.

---

Application de barre des menus macOS qui monte des tournages Magic Lantern (MLV) en séquences CinemaDNG virtuelles, pour les monter dans DaVinci Resolve, sans conversion ni copie. Elle pilote le moteur MLVFS sur FUSE-T (FUSE sans extension noyau), sur Apple Silicon.

*A macOS menu-bar app that mounts Magic Lantern MLV shoots as virtual CinemaDNG sequences for DaVinci Resolve, using MLVFS on FUSE-T (Apple Silicon).*

L'interface suit la langue de macOS : anglais par défaut, français disponible. / *The app follows the macOS language: English by default, French available.*

## Téléchargement / Download

Téléchargez le dernier `mlv2dng-<version>-macos-arm64.zip` depuis la page [Releases](https://github.com/julienbeka/mlv2dng/releases) (Mac Apple Silicon, macOS 14+). Vérifiez l'empreinte avec le fichier `.sha256` joint : `shasum -a 256 -c <fichier>.sha256`.

*Download the latest `mlv2dng-<version>-macos-arm64.zip` from [Releases](https://github.com/julienbeka/mlv2dng/releases) (Apple Silicon, macOS 14+), and check it against the attached `.sha256`.*

1. Décompressez et placez `mlv2dng.app` dans `/Applications`. / *Unzip and move `mlv2dng.app` to `/Applications`.*
2. L'app n'est pas notarisée : au premier lancement, allez dans Réglages Système > Confidentialité et sécurité, cliquez sur **Ouvrir quand même** (*System Settings > Privacy & Security > **Open Anyway***).
3. FUSE-T est installé par l'app au premier lancement s'il manque. / *FUSE-T is installed by the app on first launch if missing.*

Pour compiler depuis les sources, voir [Compiler](#compiler).

## Installation

1. Ouvrez `mlv2dng.app` (placez-la dans `/Applications`).
2. Tant que l'application n'est pas notarisée, macOS refuse la première ouverture : faites un clic droit sur l'app puis **Ouvrir**, ou allez dans Réglages Système > Confidentialité et sécurité et cliquez sur **Ouvrir quand même**.
3. FUSE-T est géré par l'application : s'il manque, elle propose de le télécharger et de l'installer, puis continue toute seule.
4. Cliquez sur l'icône de la barre des menus, **Choisir un dossier…**, puis cliquez sur un tournage pour le monter. Les DNG apparaissent dans `~/MLV Mounts/<tournage>` (menu : « Afficher les DNG dans le Finder »). Les tournages montés sont remontés automatiquement au lancement et à la reconnexion du disque.

## Compiler

Prérequis : Xcode (outils en ligne de commande), [XcodeGen](https://github.com/yonaskolb/XcodeGen) et FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-app.sh       # produit build/mlv2dng.app (moteur + app, signature ad hoc)
    cd app && swift test       # tests du noyau

Le moteur seul : `scripts/build-engine.sh` (écrit `build/engine/mlvfs`).

## Crédits

- Inspiré de Switch par Danne.
- MLVFS par David Milligan ([dépôt](https://github.com/davidmilligan/MLVFS), intégré dans `engine/mlvfs/`).
- Cartes de focus pixels et décodeur LJ92 issus de MLV App (ilia3101 et contributeurs).

## Licence

Le code propre à ce dépôt (app, scripts, tests, ajouts au moteur) est sous licence
GPL-3.0-or-later. Voir `LICENSE`.

Le moteur (`engine/mlvfs/`) contient du code tiers, tout compatible GPL-3.0 :

- MLVFS (David Milligan) et le code Magic Lantern qu'il reprend (dual ISO, chroma smoothing,
  pattern noise…) : GPL-2.0-or-later, utilisé ici sous GPL-3.0-or-later.
- Code porté de MLV App (cartes de focus pixels, décodeur LJ92) et AMaZE (RawTherapee) : GPL-3.0.
- LZMA SDK (Igor Pavlov) : domaine public. En-têtes de tags DNG : licence Adobe DNG SDK (permissive).

Aucun composant GPL-2.0-only : le serveur web `mongoose/` (interface de réglage) et `slre/`
(expressions régulières), fournis avec MLVFS sous GPL-2.0-only, ont été retirés. Le mode dual ISO
se change désormais par signal (SIGUSR1 = montage fluide, SIGUSR2 = qualité étalonnage) et la
correspondance des noms de dossiers Resolve utilise `<regex.h>` POSIX. Le binaire `mlvfs` (et donc
l'application) est distribuable sous **GPL-3.0**.
