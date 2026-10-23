# mlv2dng

*[English version](README.md)*

Montez vos rushs Magic Lantern (MLV) directement dans DaVinci Resolve : mlv2dng les présente à la volée en séquences CinemaDNG, sans conversion ni terminal.

mlv2dng est une application de barre des menus macOS qui monte des tournages Magic Lantern (MLV) en séquences CinemaDNG virtuelles, pour les monter dans DaVinci Resolve sans conversion ni copie. Elle pilote le moteur MLVFS sur FUSE-T (FUSE sans extension noyau), sur Apple Silicon.

L'interface suit la langue de macOS (anglais par défaut, français disponible). Vous pouvez aussi choisir la langue dans **Réglages… → Langue**.

## Téléchargement

Téléchargez le dernier `mlv2dng-<version>-macos-arm64.zip` depuis la page [Releases](https://github.com/julienbeka/mlv2dng/releases) (Mac Apple Silicon, macOS 14 ou ultérieur). Vérifiez l'empreinte avec le fichier `.sha256` joint : `shasum -a 256 -c <fichier>.sha256`.

1. Décompressez et placez `mlv2dng.app` dans `/Applications`.
2. L'app n'est pas encore notarisée : au premier lancement, macOS la bloque. Ouvrez Réglages Système > Confidentialité et sécurité et cliquez sur **Ouvrir quand même**.
3. Si FUSE-T manque, l'app propose de le télécharger et de l'installer au premier lancement (votre mot de passe administrateur est demandé une fois), puis continue toute seule.

Pour compiler depuis les sources, voir [Compiler](#compiler).

## Utilisation

1. Cliquez sur l'icône de la barre des menus (ou double-cliquez sur l'app pour ouvrir la fenêtre mlv2dng si l'icône est cachée derrière l'encoche), puis **Choisir un dossier…**. Le dossier peut être un tournage ou un dossier parent contenant plusieurs tournages.
2. Cliquez sur un tournage pour le monter. Les DNG apparaissent dans `~/MLV Mounts/<tournage>` (**Afficher les DNG dans le Finder**). Importez-les dans Resolve depuis ce dossier.
3. Les tournages montés sont remontés automatiquement au lancement et à la reconnexion de leur disque, toujours au même chemin : Resolve retrouve ses plans.
4. **Dual ISO** : utilisez « Montage fluide » pendant le montage et « Qualité étalonnage » avant l'étalonnage. La bascule s'applique à chaud ; dans Resolve, sélectionnez les plans puis clic droit → Rafraîchir.
5. Rushs anamorphosés 1x3 : Resolve ignore le rapport de pixel inscrit dans les DNG et ses attributs du clip ne proposent pas de 3:1 ; désanamorphosez dans la page Color → Sizing → Input Sizing → **Width = 3** (Height reste à 1). L'app vous le rappelle au montage d'un tel tournage.

Vos fichiers MLV d'origine ne sont jamais modifiés : les montages sont en lecture seule et le moteur refuse toute écriture.

## Compiler

Prérequis : Xcode (outils en ligne de commande), [XcodeGen](https://github.com/yonaskolb/XcodeGen) et FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-app.sh       # produit build/mlv2dng.app (moteur + app, signature ad hoc)
    cd app && swift test       # tests du noyau

Le moteur seul : `scripts/build-engine.sh` (écrit `build/engine/mlvfs`).

Chaque push sur `main` est compilé et testé par GitHub Actions ; chaque étiquette `v*` publie une version avec l'app zippée.

## Crédits

- Inspiré de Switch par Danne.
- MLVFS par David Milligan ([dépôt](https://github.com/davidmilligan/MLVFS), intégré dans `engine/mlvfs/`).
- Cartes de focus pixels et décodeur LJ92 issus de MLV App (ilia3101 et contributeurs).

## Licence

Le code propre à ce dépôt (app, scripts, tests, ajouts au moteur) est sous licence GPL-3.0-or-later. Voir `LICENSE`.

Le moteur (`engine/mlvfs/`) contient du code tiers, tout compatible GPL-3.0 :

- MLVFS (David Milligan) et le code Magic Lantern qu'il reprend (dual ISO, chroma smoothing, pattern noise…) : GPL-2.0-or-later, utilisé ici sous GPL-3.0-or-later.
- Code porté de MLV App (cartes de focus pixels, décodeur LJ92) et AMaZE (RawTherapee) : GPL-3.0.
- LZMA SDK (Igor Pavlov) : domaine public. En-têtes de tags DNG : licence Adobe DNG SDK (permissive).

Aucun composant GPL-2.0-only : le serveur web `mongoose/` (interface de réglage) et `slre/` (expressions régulières), fournis avec MLVFS sous GPL-2.0-only, ont été retirés. Le mode dual ISO se change désormais par signal (SIGUSR1 = montage fluide, SIGUSR2 = qualité étalonnage) et la correspondance des noms de dossiers Resolve utilise `<regex.h>` POSIX. Le binaire `mlvfs` (et donc l'application) est distribuable sous **GPL-3.0**.
