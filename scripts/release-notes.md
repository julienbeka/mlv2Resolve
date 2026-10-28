## English

### Changes in @VERSION@

- **Color Management choice:** Resolve settings now offer Rec709-A Conversion (default) and Kodak 2383. The choice is remembered for new projects and works with both direct creation and Workspace scripts.
- **Rec709-A Conversion:** one active timeline CST, P3-D60 / Linear → DaVinci Wide Gamut / Rec.709-A.
- **Kodak 2383:** two active timeline nodes: CST P3-D60 / Linear → Rec.709 / Cineon Film Log, then Resolve’s built-in Rec709 Kodak 2383 D60 LUT. An explicit error is shown if the LUT is unavailable.
- **Project color settings:** both modes use DaVinci WG/Intermediate for the timeline and Rec.709-A for output. CinemaDNG decoding remains Project / P3 D60 / Linear, with Forward OOTF disabled on the CST. Existing projects keep their settings.

**Requirements:** Apple Silicon Mac, macOS 14 or later; Resolve 21.1.1 tested for the timeline model. Resolve Studio supports direct scripting; Resolve Free uses Workspace → Scripts → mlv2Resolve after choosing the action in the app. FUSE-T is offered on first launch if missing.

**Install:** unzip, move `mlv2Resolve.app` to `/Applications`, open it. The app is not notarized: for the first launch use **System Settings → Privacy & Security → Open Anyway**.

Verify: `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- **Choix de gestion des couleurs :** les réglages Resolve proposent Conversion Rec709-A (par défaut) et Kodak 2383. Le choix est mémorisé pour les nouveaux projets et transmis aux créations directes comme aux scripts Workspace.
- **Conversion Rec709-A :** un CST actif sur la timeline, P3-D60 / Linear → DaVinci Wide Gamut / Rec.709-A.
- **Kodak 2383 :** deux nœuds actifs sur la timeline : CST P3-D60 / Linear → Rec.709 / Cineon Film Log, puis LUT Rec709 Kodak 2383 D60 intégrée à Resolve. Une erreur explicite est affichée si la LUT est indisponible.
- **Réglages couleur du projet :** les deux modes utilisent DaVinci WG/Intermediate pour la timeline et Rec.709-A en sortie. Le décodage CinemaDNG reste Project / P3 D60 / Linear, avec Forward OOTF désactivé sur le CST. Les projets existants conservent leurs réglages.

**Prérequis :** Mac Apple Silicon, macOS 14 ou ultérieur ; modèle de timeline testé avec Resolve 21.1.1. Scripting direct avec Resolve Studio ; avec Resolve gratuit, lancez Workspace → Scripts → mlv2Resolve après avoir choisi l’action dans l’app. FUSE-T est proposé au premier lancement s’il manque.

**Installation :** décompressez, placez `mlv2Resolve.app` dans `/Applications`, ouvrez-la. L’app n’est pas notarisée : au premier lancement, utilisez **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

Vérification : `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
