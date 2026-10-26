# mlv2Resolve 0.2 — validation des correctifs

- 266 tests Swift, aucun échec ; 9 tests ignorés faute de rushs/fixtures de référence.
- Application Release arm64, macOS 14 minimum, SDK 26.2 ; icône fournie avec coins transparents.
- Revue indépendante du correctif : aucun défaut matériel confirmé. Les deux vérifications complémentaires demandées ont été effectuées ci-dessous.

## Vérifications réelles — Resolve Studio 21.1.1

Deux dossiers et trois séquences Bayer DNG synthétiques, 1600 × 2008, facteur horizontal 3 :

- un seul projet nommé, deux associations de dossiers vers le même projet ;
- cadence majoritaire 25 i/s (sources 24/25/25), puis second projet avec choix manuel 29,97 i/s ;
- paramètres du projet HD 1920 × 1080, espace de travail **DaVinci WG / DaVinci Intermediate**, sortie **DaVinci WG / DaVinci Intermediate** ;
- timeline `All shots` héritant du projet (`useCustomSettings=0`), avec trois clips ;
- CST 01 P3-D60 / Linear → DWG / Intermediate actif ; CST 02 DWG / Intermediate → Rec.709 / Rec.709-A désactivé ;
- Gyroflow(NiYien) présent sur le graphe Color de chaque clip ; modèle temporaire supprimé ;
- sans aucun préréglage Input Sizing : ZoomX=2,231111111 et ZoomY=0,743703704, rapport 3 et image entièrement visible ;
- action Desqueeze sur les clips ramenés à leur zoom initial : `applied=3`, puis `already=3` au second passage ;
- projet utilisateur sauvegardé avant les essais et rouvert après chaque validation.

Résultats confirmés par les sentinelles `COMBINED_FIXES_INTEGRATION_OK`, `DESQUEEZE_BUTTON_INTEGRATION_OK`, `ORIGINAL_RESTORED`.

Sur un véritable DNG monté 1600 × 2008, ImageIO produit une vignette 765 × 960, avec ou sans transformation activée. Il n’applique pas déjà DefaultScale : l’ajustement de rapport horizontal dans l’aperçu SwiftUI est nécessaire et ne double pas la désanamorphose.

## Modèles portables

Resolve refuse de définir `DaVinci Intermediate` via le setter du gamma de sortie dans la version testée. Un **projet DRP vide sans timeline** contient donc les réglages couleur exacts ; sa cadence reste modifiable. Après choix de la cadence, une timeline vide provisoire empêche les imports DRT de réinitialiser les paramètres du projet. Le script importe ensuite le modèle de nœud Gyroflow et la timeline CST, supprime les éléments provisoires et impose l’héritage du projet.

Le nœud Gyroflow préparé par l’utilisateur a été copié sur une image synthétique puis exporté. Les chemins, projet/profil optique chargé, identifiant d’instance, caches et vignettes ont été retirés des ressources distribuées, y compris dans les réglages compressés. Son import et sa copie fonctionnent même quand l’image synthétique de référence est hors ligne. **Load for current file** reste l’action qui charge le fichier `.gyroflow` du clip dans le plugin.

Aucun appel `ApplyGradeFromDRX` n’est utilisé : cette voie avait provoqué un plantage pendant les premiers essais.

## Limites

Le plugin NiYien doit être installé ; son absence est signalée. Une timeline vide ne contient naturellement aucun nœud de clip. Les clips seulement dans le Media Pool peuvent nécessiter un préréglage Input Sizing ; le correctif par zoom s’applique aux occurrences en timeline et préserve les cadrages personnalisés.

Les nouveaux réglages concernent les créations de projets ; ouvrir un projet lié ne modifie pas son contenu. Resolve Free n’est pas installé ici : son script de menu et la conservation de l’action sélectionnée sont couverts par les tests. Les essais synthétiques ne constituent pas une validation de stabilisation ou de décodage sur tous les modes caméra. Les ressources sont validées sur Resolve 21.1.1 ; une version incompatible produit une erreur.

La release publique v0.2 n’est pas publiée automatiquement.

## Nettoyage du média de modèle

Resolve ignore parfois `importIntoSubFolderName` pour le DRT Gyroflow et importe `TEST_[000000-000002].dng` à la racine. Le script conserve désormais l’objet MediaPool exact retourné par le clip modèle et le supprime après copie du grade et suppression de la timeline temporaire. Aucun nettoyage par nom n’est utilisé. Une vérification récursive réelle de tout le Media Pool a confirmé `MODEL_POOL_CLEANUP_INTEGRATION_OK`. Les messages de cadence affichent maintenant les valeurs source et projet, plutôt que le suffixe ambigu `(fps)`.

## CST — Forward OOTF

À la demande de l’utilisateur, `Apply Forward OOTF` est activé sur le premier CST. Un seul octet du paramètre booléen `doFwdOOTF` a changé dans le grade du modèle, les autres réglages restant identiques. Un import/export réel dans un projet temporaire Resolve confirme la conservation de cette valeur ; le projet temporaire a été supprimé et le projet utilisateur rouvert. Le second CST conserve son état désactivé à la création.

## Dock et cadence de lecture

L’application utilise `LSUIElement=false` pour être visible dans le Dock et Commande-Tab ; MenuBarExtra reste disponible.

Le SDK Resolve 21.1.1 marque `timelinePlaybackFrameRate` en lecture seule. Le régler via SetSetting interrompt la création : cet appel est supprimé. Le modèle DRP vide est préparé localement avant import pour contenir la cadence de lecture choisie. Le paramètre float32 (champ protobuf 248) a été identifié en comparant deux exports du même projet de diagnostic, avant/après la seule modification manuelle de Playback frame rate. Les autres paramètres sont conservés.

Le modèle utilise un bloc Zstandard brut standard, permettant de modifier ce champ sans codec tiers. La préparation emploie Foundation et les outils macOS ditto/unzip, sans Python requis chez l’utilisateur. Les modèles sont conservés dans `Application Support/mlv2Resolve/Resolve Models`, avec une empreinte du modèle et de la cadence ; les scripts Workspace restent donc utilisables après redémarrage ou nettoyage des fichiers temporaires.

Vérification réelle : import des modèles préparés à 25 et 29,97 i/s, puis imports CST/Gyroflow, avec lecture identique avant et après. Une création complète à 29,97 i/s confirme import de trois plans, cadences de projet et de lecture, CST, Gyroflow et absence de TEST dans le Media Pool. Un refus de réglage volontaire dans un projet distinct confirme également le nettoyage des modèles, médias et timelines temporaires (`FAILURE_CLEANUP_INTEGRATION_OK`). Les autres projets utilisateur restent intacts.

Suite complète : 266 tests, 9 ignorés faute de fixtures, aucun échec. Revue indépendante : un défaut de durée de vie du cache temporaire corrigé en stockant les modèles dans les données de l’application.

## Icône Tahoe

Un fichier Icon Composer natif `AppIcon.icon` utilise le dessin fourni, normalisé en 1024 × 1024, sans la marge additionnelle de 100 pixels et sans nouvelle découpe des coins. La compilation Apple produit les couches natives dans Assets.car ainsi que les variantes pour macOS 14 et 15. Les aperçus par défaut, sombre et de repli conservent le contour multicolore sans plaque grise extérieure. L’app conserve son nom et son identité de bundle pour les préférences existantes.
