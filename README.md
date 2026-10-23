# MLV Switch

Application de barre des menus macOS qui monte des tournages Magic Lantern (MLV) en séquences CinemaDNG virtuelles, pour les monter dans DaVinci Resolve, sans conversion ni copie. Elle pilote le moteur MLVFS sur FUSE-T (FUSE sans extension noyau), sur Apple Silicon.

*A macOS menu-bar app that mounts Magic Lantern MLV shoots as virtual CinemaDNG sequences for DaVinci Resolve, using MLVFS on FUSE-T (Apple Silicon).*

## Installation

1. Ouvrez `MLV Switch.app` (placez-la dans `/Applications`).
2. Tant que l'application n'est pas notarisée, macOS refuse la première ouverture : faites un clic droit sur l'app puis **Ouvrir**, ou allez dans Réglages Système > Confidentialité et sécurité et cliquez sur **Ouvrir quand même**.
3. FUSE-T est géré par l'application : s'il manque, elle propose de le télécharger et de l'installer, puis continue toute seule.
4. Cliquez sur l'icône de la barre des menus, **Choisir un dossier…**, puis cliquez sur un tournage pour le monter. Les DNG apparaissent dans `~/MLV Switch/<tournage>` (menu : « Afficher les DNG dans le Finder »). Les tournages montés sont remontés automatiquement au lancement et à la reconnexion du disque.

## Compiler

Prérequis : Xcode (outils en ligne de commande), [XcodeGen](https://github.com/yonaskolb/XcodeGen) et FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-app.sh       # produit build/MLV Switch.app (moteur + app, signature ad hoc)
    cd app && swift test       # tests du noyau

Le moteur seul : `scripts/build-engine.sh` (écrit `build/engine/mlvfs`).

## Crédits

- Inspiré de Switch par Danne.
- MLVFS par David Milligan ([dépôt](https://github.com/davidmilligan/MLVFS), intégré dans `engine/mlvfs/`).
- Cartes de focus pixels et décodeur LJ92 issus de MLV App (ilia3101 et contributeurs).

## Licence

Logiciel libre sous licence GPL-3.0-or-later. Voir `LICENSE`.
