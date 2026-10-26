## English

### Changes in @VERSION@

- **mlv2Resolve:** new name and four workflow sections: Footage, Gyro Sync, Editing, Settings. Native mount switches, an in-window left settings drawer, and Tahoe styling. The native app icon fills its Tahoe frame; the menu bar uses a matching monochrome ML camera. The window opens at launch, with Dock and Command-Tab support.
- **Gyro previews:** identify shots with thumbnails and enlarged previews before assigning a lens. A settings link appears when no lens is declared. Dual ISO moves to Settings with explanations of fast preview and full-quality interpolation.
- **Separate Resolve actions:** create one named project combining all mounted folders, open a linked project, launch Resolve, or desqueeze. Cached links can be removed without deleting Resolve projects or footage.
- **Timeline control:** Automatic, UHD or HD sizing, with the entire anamorphic image visible. Use the majority footage frame rate or select a different one; project timeline and playback cadence match. Optionally populate the timeline with all shots; its default name, **All shots**, is editable.
- **Portable timeline color setup:** project working and output space DaVinci Wide Gamut / Intermediate. Timeline CST 01 converts P3-D60 / Linear to DWG / Intermediate with Apply Forward OOTF enabled. CST 02 converts DWG / Intermediate to Rec.709 / Rec.709-A and starts disabled; enable it only before a Rec.709 export. The empty timeline model is bundled with the app and tested in Resolve 21.1.1. Existing projects keep their grades and settings.
- **Automatic clip setup:** desqueezed previews, desqueezed timeline clips with full-frame fit even without presets, and a Gyroflow(NiYien) Color node on each clip when the plugin is installed. Use **Load for current file** in the plugin.
- **Migration:** existing preferences, lenses and calibrated profiles are preserved. The bundle identity and virtual footage paths stay compatible.

**Requirements:** Apple Silicon Mac, macOS 14 or later; Resolve 21.1.1 tested for the timeline model. Resolve Studio supports direct scripting; Resolve Free uses Workspace → Scripts → mlv2Resolve after choosing the action in the app. FUSE-T is offered on first launch if missing.

**Install:** unzip, move `mlv2Resolve.app` to `/Applications`, open it. The app is not notarized: for the first launch use **System Settings → Privacy & Security → Open Anyway**.

Verify: `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- **mlv2Resolve :** nouveau nom et quatre sections : Rushs, Synchro gyro, Montage, Réglages. Interrupteurs de montage natifs, réglages dans un tiroir gauche intégré à la fenêtre, apparence Tahoe.
- **Aperçus gyro :** identifiez les plans par leurs vignettes et aperçus agrandis avant d’attribuer un objectif. Un lien vers les réglages apparaît si aucun objectif n’est déclaré. Le Dual ISO passe dans les réglages, avec explications des modes aperçu rapide et interpolation complète.
- **Actions Resolve séparées :** créer un seul projet nommé réunissant les dossiers montés, ouvrir un projet lié, lancer Resolve ou désanamorphoser. Les liens mémorisés peuvent être effacés sans supprimer les projets ni les rushs.
- **Timeline personnalisable :** taille Automatique, UHD ou HD, avec l’image anamorphique entière. Cadence majoritaire des rushs ou cadence choisie, identique pour la timeline du projet et sa lecture. Option pour ajouter tous les plans à la timeline, nommée **All shots** par défaut et renommable.
- **Couleur de timeline portable :** espace de travail et de sortie du projet DaVinci Wide Gamut / Intermediate. Le CST 01 convertit P3-D60 / Linear vers DWG / Intermediate avec Apply Forward OOTF activé. Le CST 02 convertit DWG / Intermediate vers Rec.709 / Rec.709-A et reste désactivé au départ ; activez-le uniquement avant un export Rec.709. Le modèle vide est inclus dans l’app et testé avec Resolve 21.1.1. Les projets existants conservent leurs grades et réglages.
- **Préparation des plans :** aperçus désanamorphosés, plans de timeline désanamorphosés avec l’image entière même sans préréglage, et nœud Color Gyroflow(NiYien) sur chaque plan si le plugin est installé. Utilisez **Load for current file** dans le plugin.
- **Migration :** conservation des préférences, objectifs et profils calibrés. L’identité applicative et les chemins des rushs virtuels restent compatibles.

**Prérequis :** Mac Apple Silicon, macOS 14 ou ultérieur ; modèle de timeline testé avec Resolve 21.1.1. Scripting direct avec Resolve Studio ; avec Resolve gratuit, lancez Workspace → Scripts → mlv2Resolve après avoir choisi l’action dans l’app. FUSE-T est proposé au premier lancement s’il manque.

**Installation :** décompressez, placez `mlv2Resolve.app` dans `/Applications`, ouvrez-la. L’app n’est pas notarisée : au premier lancement, utilisez **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

Vérification : `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
