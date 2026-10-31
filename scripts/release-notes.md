## English

### Changes in @VERSION@

- **Playback cache:** replace the four-frame limit with a 256 MiB idle-frame budget and least-recently-used eviction. Resolve’s read-ahead window can be reused without retaining every open DNG frame indefinitely.

- **Detailed preparation progress:** mounted DNG discovery now reports each clip and a counter, followed by script preparation, Resolve connection and project opening. Progress no longer moves backwards between phases. Linked projects scan only their associated mounted folders.

- **Bounded decoded-frame cache:** keeping DNG files open in Resolve no longer retains every decoded frame in memory. Idle pixel buffers are evicted while active reads remain protected; re-decoding preserves the handle’s Dual ISO mode.

- **Existing project updates:** new clips can optionally be appended to All shots and assigned to the All color group. Detailed progress is restored when opening and updating a linked project.
- **Moved footage:** verified per-clip gyro excerpts are reconnected automatically on mount after a folder move, including when the local ownership history is missing. Original sidecars are backed up; synchronization and stabilization settings are preserved.

- **New clips in existing Resolve projects:** opening a linked project now offers to import missing clips and apply desqueeze and audio sync. Declining opens the project without adding clips; existing media, timelines and settings are preserved.

- **Kodak Group Post Clip:** the preset now contains only the DWG/Intermediate → Rec.709/Cineon CST and Kodak 2383 D60 LUT. The final Rec.709-A conversion node is removed. Forward and Inverse OOTF are disabled; White Point Adaptation remains enabled. Applies to newly created projects.

- **Faster Gyro sync remounts:** unchanged no-log, insufficient-motion and ambiguous results are remembered across restarts. New clips are processed normally; changes to source files, gyro logs or settings invalidate the cached result. Regenerate always forces a new attempt. Existing synchronized clips no longer appear to undergo motion analysis during validation.

- **Large Resolve projects:** preparation now continues while progress is reported, saves every 25 clips, and isolates individual clip failures. A live task label, clip counter and percentage accompany the spinner. Five minutes without progress produces an explicit timeout message.

- **Group color pipeline:** all timeline clips share the All group, with input CST in Group Pre Clip and Rec709-A or two-node Kodak output in Group Post Clip. The Timeline graph stays empty. This applies to new projects; existing grades are preserved.

- **Dual ISO preview memory fix:** Smooth Editing now releases its temporary histograms when Dual ISO detection fails, preventing memory accumulation during repeated frame reads.
- **Gyroflow playback:** each clip now uses a lossless SenseFlow log excerpt with ten-second handles instead of loading the full session log in every node.
- **Existing shoots:** app-generated Gyroflow files are optimized automatically on remount, with backups; foreign projects and original logs are preserved. Keep the hidden `.mlv2resolve-gyro` folder with the footage. Restart Resolve after migration to release old gyro caches.

**Requirements:** Apple Silicon Mac, macOS 14 or later; Resolve 21.1.1 tested for the timeline model. Resolve Studio supports direct scripting; Resolve Free uses Workspace → Scripts → mlv2Resolve after choosing the action in the app. FUSE-T is offered on first launch if missing.

**Install:** unzip, move `mlv2Resolve.app` to `/Applications`, open it. The app is not notarized: for the first launch use **System Settings → Privacy & Security → Open Anyway**.

Verify: `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Source (GPL-3.0-or-later): https://github.com/@REPO@/tree/@TAG@

## Français

### Nouveautés de @VERSION@

- **Cache de lecture :** la limite de quatre images est remplacée par un budget de 256 Mio pour les images inactives, avec éviction des moins récemment lues. Les lectures anticipées de Resolve sont réutilisées sans retenir indéfiniment toutes les images des DNG ouverts.

- **Progression détaillée :** l’analyse des DNG montés affiche chaque plan et un compteur, puis distingue la préparation des scripts, la connexion et l’ouverture dans Resolve. La progression ne recule plus entre les étapes. Seuls les dossiers associés au projet lié sont analysés.

- **Cache des images décodées borné :** les fichiers DNG conservés ouverts par Resolve ne retiennent plus toutes leurs images en mémoire. Les images inactives sont libérées sans interrompre les lectures ; leur redécodage conserve le mode Dual ISO du fichier ouvert.

- **Mise à jour des projets existants :** les nouveaux plans peuvent être ajoutés à All shots et affectés au groupe couleur All. La progression détaillée est rétablie à l’ouverture et pendant la mise à jour d’un projet lié.
- **Rushs déplacés :** les extraits gyro vérifiés sont reconnectés automatiquement au montage après déplacement du dossier, même sans historique local de propriété. Les fichiers originaux sont sauvegardés ; les réglages de synchronisation et de stabilisation sont conservés.

- **Nouveaux plans dans les projets Resolve existants :** à l’ouverture d’un projet lié, une modale propose d’importer les plans manquants avec désanamorphosage et synchronisation audio. En cas de refus, le projet s’ouvre sans ajout ; les médias existants, timelines et réglages sont conservés.

- **Group Post Clip Kodak :** le preset conserve uniquement le CST DWG/Intermediate → Rec.709/Cineon et la LUT Kodak 2383 D60. Le dernier nœud de conversion Rec.709-A est supprimé. Forward et Inverse OOTF sont désactivés ; White Point Adaptation reste activée. Ce changement concerne les nouveaux projets.

- **Remontage Gyro sync accéléré :** les résultats sans journal, sans mouvement suffisant ou ambigus sont mémorisés entre les redémarrages. Les nouveaux plans sont traités normalement ; toute modification des fichiers sources, des journaux gyro ou des réglages invalide le résultat mémorisé. Regenerate force toujours un nouvel essai. Les plans synchronisés ne sont plus affichés comme en cours d’analyse pendant leur vérification.

- **Gros projets Resolve :** la préparation continue tant qu’elle progresse, sauvegarde tous les 25 plans et isole les erreurs individuelles. La roue est accompagnée de la tâche en cours, du compteur de plans et d’un pourcentage. Cinq minutes sans progression déclenchent un message explicite.

- **Couleurs par groupe :** tous les plans de la timeline rejoignent All, avec CST d’entrée en Group Pre Clip et sortie Rec709-A ou Kodak à deux nœuds en Group Post Clip. Le graphe Timeline reste vide. Ce changement concerne les nouveaux projets ; les étalonnages existants sont conservés.

- **Correction mémoire de la prévisualisation Dual ISO :** Smooth Editing libère désormais ses histogrammes temporaires lorsque la détection Dual ISO échoue, évitant une accumulation mémoire lors des lectures répétées.
- **Lecture Gyroflow :** chaque plan utilise un extrait SenseFlow sans perte, avec dix secondes de marge, au lieu de charger le journal de toute la séance dans chaque nœud.
- **Tournages existants :** les fichiers Gyroflow générés par l’app sont optimisés automatiquement au remontage, avec sauvegarde ; les fichiers externes et les journaux originaux sont conservés. Gardez le dossier caché `.mlv2resolve-gyro` avec les rushs. Redémarrez Resolve après migration pour libérer ses anciens caches gyro.

**Prérequis :** Mac Apple Silicon, macOS 14 ou ultérieur ; modèle de timeline testé avec Resolve 21.1.1. Scripting direct avec Resolve Studio ; avec Resolve gratuit, lancez Workspace → Scripts → mlv2Resolve après avoir choisi l’action dans l’app. FUSE-T est proposé au premier lancement s’il manque.

**Installation :** décompressez, placez `mlv2Resolve.app` dans `/Applications`, ouvrez-la. L’app n’est pas notarisée : au premier lancement, utilisez **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**.

Vérification : `shasum -a 256 -c mlv2Resolve-@VERSION@-macos-arm64.zip.sha256`

Code source (GPL-3.0-or-later) : https://github.com/@REPO@/tree/@TAG@
