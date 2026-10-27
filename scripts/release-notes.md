## English

### Changes in @VERSION@

- **CinemaDNG defaults:** new projects decode using Project settings, P3 D60 / Linear. These settings are included in all bundled Resolve models.
- **CST correction:** Apply Forward OOTF is disabled on the first timeline CST (P3-D60 / Linear → DaVinci Wide Gamut / Intermediate). The Rec.709 export CST remains disabled until needed.
- **Project title:** a permanent label identifies the project title field. Its initial name is My Project; saved custom names are preserved.

**Requirements:** Apple Silicon Mac, macOS 14 or later; Resolve 21.1.1 tested for the timeline model. Resolve Studio supports direct scripting; Resolve Free uses Workspace → Scripts → mlv2Resolve after choosing the action in the app. FUSE-T is offered on first launch if missing.

**Install:** unzip, move `mlv2Resolve.app` to `/Applications`, open it. The app is not notarized: for the first launch use **System Settings → Privacy & Security → Open Anyway**.

Verify: `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- **Réglages CinemaDNG :** les nouveaux projets utilisent le décodage Project, P3 D60 / Linear. Ces valeurs sont intégrées à tous les modèles Resolve embarqués.
- **Correction du CST :** Apply Forward OOTF est désactivé sur le premier CST de timeline (P3-D60 / Linear → DaVinci Wide Gamut / Intermediate). Le CST d’export Rec.709 reste désactivé jusqu’à son utilisation.
- **Titre du projet :** un libellé permanent identifie le champ. Le titre initial est My Project ; les noms personnalisés enregistrés sont conservés.

**Prérequis :** Mac Apple Silicon, macOS 14 ou ultérieur ; modèle de timeline testé avec Resolve 21.1.1. Scripting direct avec Resolve Studio ; avec Resolve gratuit, lancez Workspace → Scripts → mlv2Resolve après avoir choisi l’action dans l’app. FUSE-T est proposé au premier lancement s’il manque.

**Installation :** décompressez, placez `mlv2Resolve.app` dans `/Applications`, ouvrez-la. L’app n’est pas notarisée : au premier lancement, utilisez **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

Vérification : `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
