# mlv2dng — « Ouvrir Resolve » crée le projet du tournage

*Document de conception — 25 octobre 2026*

## Intention

Aujourd'hui, « Ouvrir Resolve » se contente de lancer Resolve. L'utilisateur doit créer le projet, régler la
timeline, importer les dossiers de DNG, appliquer la désanamorphose (préréglage « mlv2dng 1x3 », bouton
existant « Désanamorphoser dans Resolve ») puis, sur une timeline 16:9, appliquer à la main un zoom (0,76 dans
Transform) pour retrouver le cadre 2,39:1 d'origine. Il peut aussi ouvrir Resolve avant que la synchro gyro
ait écrit les `.gyroflow`.

**But :** un clic sur « Ouvrir Resolve » donne, pour chaque tournage monté, un projet Resolve prêt à monter :
timeline à la taille native désanamorphosée, réglages couleur de l'utilisateur, tous les plans dans le chutier
avec leur son et désanamorphosés. L'utilisateur voit si des `.gyroflow` sont encore en préparation.

## Objectifs

1. **Un projet par tournage monté**, nommé comme le tournage (ex. « 20261025 »). S'il existe déjà : le rouvrir
   et ajouter au chutier seulement les plans absents, sans rien toucher d'autre (réglages, clips, timelines).
2. **Réglages du projet** à la création :
   - Préréglage de projet Resolve nommé **« mlv2dng »** appliqué s'il existe (`Project:SetPreset`). Il porte
     les réglages Camera Raw de l'utilisateur, non pilotables par script (vérifié : absents des 160 clés de
     `GetSetting`). Exemple de l'utilisateur : Camera Raw P3 D60, gamma Linear, Highlight Recovery et Apply Pre
     Tone Curve cochés.
   - Puis, par script : `colorScienceMode` = `davinciYRGB`, `colorSpaceTimeline` = `P3-D60`,
     `colorSpaceOutput` = `Linear` (réglages de l'utilisateur, vérifiés acceptés), cadence de timeline = fps des
     plans (`timelineFrameRate`), `timelineInputResMismatchBehavior` = `scaleToFit`.
   - Taille de timeline (Studio) : taille native désanamorphosée = largeur RAWI × anamorphose (après la
     correction automatique de la tâche 10) × hauteur. 4.8K 1x3 → 4800×2008 ; 5.2K 1x3 (1736×2178) →
     5208×2178. Tournage mélangé : la résolution désanamorphosée la plus représentée l’emporte ; en cas d’égalité, la plus grande taille est choisie. Les autres plans sont mis
     à l'échelle pour tenir (scaleToFit) — vérifié : un 5.2K remplit une timeline 4800×2008.
   - Version gratuite : timeline UHD 3840×2160 ; chaque plan est vu en entier avec bandes noires en haut et en
     bas (zoom = largeur timeline / largeur que donnerait le remplissage en hauteur, ex. 0,744 pour du 4.8K
     1x3 ; vérifié en appliquant `ZoomX/ZoomY` à un plan de timeline).
3. **Chutier** : chaque dossier de plan monté importé comme une séquence de DNG (motif `…_%06d.dng`, début/fin
   explicites), avec son **WAV** recollé au plan par la synchro audio de Resolve (`MediaPool:AutoSyncAudio`,
   mode timecode, appelée pour chaque paire DNG + WAV : tous les timecodes valent 00:00:00:00, une synchro
   groupée serait ambiguë — vérifié par paire). Ne pas importer `_PREVIEW.gif` ni le `.log` du dossier. Le
   `.gyroflow` n'est pas importé (le plugin Gyroflow le trouve à côté des DNG).
4. **Désanamorphose** dès le chutier : `SetClipProperty("Input Sizing Preset", "mlv2dng 1x<N>")` (préréglages
   déjà créés par mlv2dng, vérifié sur 4.8K et 5.2K), en respectant la règle existante (un clip sur un autre
   préréglage est laissé tel quel). Un plan anamorphique d’un autre rapport utilise une variante « mlv2dng 1x<N> Fit … » portant aussi la réduction nécessaire pour tenir dans la timeline native.
5. **Indicateur de synchro gyro** : dans la barre de menu (icône animée) et la fenêtre (« Synchro gyro : 3/6
   plans »), tant qu'une tâche tourne. Clic sur « Ouvrir Resolve » pendant une synchro : avertissement
   « Des fichiers .gyroflow sont encore en préparation » avec « Attendre » / « Ouvrir quand même ». Ordre de
   grandeur mesuré : premier plan 12–30 s (recherche dans tout le log de 26 min), suivants 1–3 s.
6. **Resolve déjà ouvert sur un autre projet** : demander confirmation avant de basculer (Resolve proposera
   d'enregistrer le projet en cours).
7. **Version gratuite** (pas de script externe — `fuscript` ne fonctionne qu'avec Studio) : « Ouvrir Resolve »
   lance Resolve et affiche un guide pas à pas dans mlv2dng ; l'utilisateur lance depuis Resolve
   *Workspace > Scripts > mlv2dng* un script installé par mlv2dng (mécanisme existant
   `installMenuScript`) qui fait le même travail (projet, préréglage, timeline UHD, import, son,
   désanamorphose, cadrage). Le guide rappelle aussi d'attendre la fin de la synchro gyro.
8. **Préréglage « mlv2dng » absent** : le projet est créé quand même ; mlv2dng l'indique et explique comment
   l'enregistrer une fois (Resolve → Project Settings → réglages Camera Raw et couleurs → Presets → Save As
   « mlv2dng »). Le guide s'affiche aussi au premier usage.

## Hors périmètre

- Créer une timeline de montage avec Studio (le chutier suffit).
- Rendu, export, LUT, réglages de livraison.
- Synchronisation audio externe (le WAV de chaque plan uniquement).
- Écrire les réglages Camera Raw autrement que par le préréglage de l'utilisateur.

## Anti-objectifs

- Modifier un projet existant au-delà de l'ajout des plans absents.
- Basculer de projet ou fermer celui de l'utilisateur sans confirmation.
- Supprimer ou renommer quoi que ce soit dans Resolve.
- Bloquer l'interface de mlv2dng pendant que Resolve travaille.

## Constats vérifiés le 25/10/2026 (Resolve Studio 21.1.1, tournage 20261025)

- `SetSetting` accepte : `timelineResolutionWidth/Height`, `timelineFrameRate`, `colorScienceMode`,
  `colorSpaceTimeline` = « P3-D60 », `colorSpaceOutput` = « Linear », `timelineInputResMismatchBehavior`.
  `timelinePlaybackFrameRate` refusé (reste 24) — à ne pas compter dessus.
- `GetProductName()` → « DaVinci Resolve Studio » : détection Studio possible par script.
- Import d'un dossier de plan entier → 3 éléments séparés (séquence DNG, WAV, `_PREVIEW.gif`) : il faut
  importer explicitement la séquence et le WAV.
- Timecode des DNG et des WAV : 00:00:00:00.
- `AutoSyncAudio({dng, wav}, {mode timecode, retain video metadata})` → true, le clip a ensuite 2 canaux audio.
- `Project:SetPreset("nom absent")` → false (permet de détecter l'absence du préréglage).
- Timeline UHD + scaleToFit + préréglage 1x3 : l'image remplit la hauteur et est rognée sur les côtés ; un
  zoom de 0,744 sur l'élément de timeline donne l'image entière avec bandes noires.
- `ProjectManager:CreateProject`, `CloseProject`, `DeleteProject` fonctionnent.

## Précisions après relecture

- **Tournage** = le `Shoot` déjà défini par mlv2dng (dossier contenant des MLV, monté comme une unité) ; le nom du
  projet est le nom de ce dossier. Plusieurs tournages montés → un projet chacun (traités l'un après l'autre).
- **Ordre des réglages** : le préréglage « mlv2dng » est appliqué d'abord ; les réglages posés ensuite par script
  (taille, cadence, couleurs, mise à l'échelle) l'emportent sur ce qu'il contient.
- **Avancement de la synchro gyro** : déjà disponible dans les états par plan du coordinateur
  (`GyroSyncCoordinator.states`) ; le compteur se calcule à partir d'eux.
- *Choix du concepteur* — **cadences différentes dans un tournage** : la timeline prend la cadence majoritaire ;
  les autres plans sont importés quand même et signalés dans le compte rendu.
- *Choix du concepteur* — **plans 1x1** : pas de préréglage de dimensionnement à appliquer ; la règle de taille de
  timeline s'applique au rapport majoritaire (un plan d'un autre rapport est vu en entier, scaleToFit).
- *Choix du concepteur* — **plan sans WAV ou synchro audio refusée** : la séquence DNG est importée seule et le plan
  est signalé ; il compte comme présent (pas de nouvel import au clic suivant).
- *Choix du concepteur* — **Resolve pas encore lancé** : mlv2dng le lance puis attend la connexion du script
  (délai borné, ex. 60 s). Pas de connexion : si l'app installée est Studio, message existant expliquant
  d'activer *Preferences → System → General → External scripting using: Local* ; sinon, guide de la version
  gratuite.

## Laissé au constructeur

- Cadrage UHD (version gratuite) : préférer une variante du préréglage de dimensionnement portant le zoom
  (« mlv2dng 1x3 UHD ») pour que le cadre soit juste dès le chutier ; si Resolve ne le permet pas, le script
  crée une timeline « Rushs » avec tous les plans et applique `ZoomX/ZoomY`.
- Détection de la version gratuite sans script (échec de connexion `fuscript`, bundle de Resolve…).
- Textes exacts (EN/FR), présentation du guide et de l'indicateur.
- Reconnaissance des plans déjà présents dans le projet (chemin du fichier, nom du dossier de plan).
- Ordre des étapes du script et gestion des erreurs partielles (un plan qui échoue n'arrête pas les autres).

## Critères de réussite

- Studio, tournage 20261025 (6 plans 4.8K dont M25-1745 corrigé + 2 plans 5.2K) : un clic crée le projet
  « 20261025 », timeline 4800×2008 (résolution majoritaire : 6 plans 4.8K contre 2 plans 5.2K), 25 i/s, couleurs P3-D60 / Linear,
  préréglage « mlv2dng » appliqué s'il existe, 8 plans dans le chutier avec leur son, désanamorphosés, plus aucun
  zoom manuel.
- Second clic après ajout d'un plan : seul ce plan est ajouté.
- Version gratuite : le guide mène au même résultat en UHD avec bandes noires.
- Pendant une synchro gyro, l'indicateur est visible et « Ouvrir Resolve » avertit.

## Ajustement du 25/10/2026

La résolution la plus représentée remplace la plus grande résolution au rapport majoritaire. Ainsi, 5 rushs 4.8K et 2 rushs 5.2K donnent une timeline 4800×2008. En cas d’égalité du nombre de plans, la plus grande résolution est retenue.
