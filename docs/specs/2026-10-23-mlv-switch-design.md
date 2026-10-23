# MLV Switch : monter ses MLV en DNG dans Resolve, sans terminal

*Document de conception, version 1 — 23 octobre 2026*

## Intention

Les cinéastes Magic Lantern (ici : Canon EOS M, 12 bits, 4.8K 1x3) veulent monter directement leurs
rushs MLV dans DaVinci Resolve sous forme de séquences DNG, sans conversion préalable (pas de passage
par MLV App) et sans bricolage technique. Aujourd'hui, MLVFS rend cela possible, mais il faut
installer macFUSE (qui impose de réduire la sécurité de démarrage sur Apple Silicon) et passer par le
terminal ou par les menus bash de Switch (Danne).

MLV Switch est une app Mac moderne, inspirée de Switch, qui fait tout cela en arrière-plan.
**L'expérience visée :** l'app tourne déjà, l'utilisateur choisit son dossier de rushs, coche les
tournages, et ouvre Resolve : les DNG sont là.

Le porteur du projet l'utilise d'abord pour lui ; si elle fonctionne, il la partagera avec la
communauté Magic Lantern. Elle doit donc être conçue dès le départ pour être installée par d'autres.

## Objectifs (version 1)

1. **Montage MLVFS en un clic** de tournages MLV situés sur le disque interne ou sur un SSD externe.
2. **Aucune manipulation technique** : pas de terminal, pas de réduction de la sécurité système.
   L'app installe et gère elle-même ce dont elle a besoin.
3. **Projets Resolve stables** : un tournage remonté réapparaît toujours au même chemin, pour que
   Resolve ne voie pas ses plans « hors ligne » d'une session à l'autre.
4. **Traitement des DNG automatique** et adapté à l'EOS M, avec détection du dual ISO clip par clip.
5. **Lecture fluide pendant le montage, qualité maximale pour l'étalonnage**, par une bascule simple.

## Hors périmètre de la version 1 (prévu ensuite, dans cet ordre indicatif)

- Gestion de la stabilisation gyro (NiYien SenseFlow A1 → Gyroflow), y compris l'intégration
  éventuelle de l'app NiYien (https://www.niyien.com/v2/en/download.html). Les acquis de la preuve de
  concept sont dans `poc/NOTES.md` : format du log A1 décodé, synchro par le signal fiable ; le rendu
  Gyroflow testé recadrait trop et a été jugé inutilisable.
- Création automatique d'un projet Resolve avec timeline (nécessite Resolve Studio).
- Copie des rushs depuis la carte SD vers un disque.
- Mac Intel, et versions de macOS antérieures à celle retenue (voir Contraintes).
- Export / conversion (ProRes, DNG physiques) : ce n'est pas le rôle de l'app.

## Anti-objectifs (ce qui ferait échouer le projet même si « ça marche »)

- Demander à l'utilisateur d'ouvrir le terminal, de taper une commande ou de réduire la sécurité de
  démarrage.
- Des plans qui passent « hors ligne » dans Resolve parce que le chemin a changé.
- Une lecture qui saccade dans Resolve en mode montage sur des clips normaux (non dual ISO).
- Modifier, déplacer ou écrire quoi que ce soit dans les dossiers de rushs d'origine.
- Une interface chargée de réglages techniques visibles par défaut.

## Expérience utilisateur

### Forme : une icône dans la barre des menus (choix de l'utilisateur)

- L'app vit dans la barre des menus, sans fenêtre principale. Elle se lance à l'ouverture de session
  (option activée par défaut, désactivable).
- L'icône indique le nombre de tournages montés et passe à un état d'alerte en cas de problème
  (disque débranché, outil manquant, erreur de montage).
- Le menu affiche :
  - le dernier dossier choisi (mémorisé) ;
  - la liste des tournages trouvés, chacun avec nombre de clips et taille, et une pastille indiquant
    s'il est monté ; un clic monte ou démonte le tournage ;
  - « Choisir un dossier… », « Ouvrir Resolve », « Afficher les DNG dans le Finder », « Tout
    démonter » ;
  - la bascule **Dual ISO : montage fluide / qualité étalonnage** ;
  - « Réglages… » (petite fenêtre).

### Choix des dossiers (décidé par l'utilisateur)

- L'utilisateur choisit un dossier à chaque fois ; le dernier choisi est mémorisé.
- Ce dossier peut être un tournage (contenant directement des MLV) ou un dossier parent contenant
  plusieurs tournages dans des sous-dossiers. Si plusieurs tournages sont trouvés, l'app propose de
  choisir lesquels monter.
- *Choix du concepteur :* un « tournage » est le dossier choisi lui-même s'il contient des MLV, sinon
  chaque sous-dossier direct qui en contient (un seul niveau). Les clips découpés (`.MLV`, `.M00`,
  `.M01`…) forment un seul clip.

### Remontage

- Relancer l'app et cliquer suffit (minimum accepté par l'utilisateur).
- *Souhaité, prévu en v1 :* au démarrage, l'app remonte les tournages qui l'étaient à la fermeture,
  si leur disque est présent ; quand un SSD externe est rebranché, ses tournages se remontent seuls.

### Premier lancement

- Une fenêtre d'accueil unique explique ce qui va être installé et guide l'installation de FUSE-T
  (une autorisation système et le mot de passe administrateur, une seule fois). C'est la seule
  étape « système » visible ; tout le reste est embarqué.
- Si Resolve n'est pas installé, l'app le signale sans bloquer.

## Traitement des DNG

- Tout est automatique par défaut, adapté à l'EOS M : correction des focus pixels, des pixels morts,
  et traitement dual ISO pour les clips qui en contiennent.
- **Dual ISO détecté clip par clip** : dans un même tournage, certains clips sont en dual ISO et
  d'autres non (fait confirmé par l'utilisateur).
- **Deux modes, décidés par l'utilisateur :** « montage fluide » (traitement dual ISO rapide) pendant
  le montage, « qualité étalonnage » (traitement complet) avant l'étalonnage. La bascule ne doit pas
  changer le chemin des DNG. *À vérifier :* le comportement du cache de Resolve après bascule, et
  s'il faut demander à l'utilisateur de rafraîchir les plans.
- Un menu « Avancé » dans les réglages pourra plus tard permettre de désactiver une correction.
- Les clips sont compressés en LJ92 (classe vidéo 0x21) ; l'anamorphose 1x3 (1600×2040 enregistré,
  4800×2040 affiché) doit être correctement signalée à Resolve (rapport de pixel 3:1 dans les DNG),
  si MLVFS le permet. *À vérifier.*

## Comment c'est construit

### Décisions prises avec l'utilisateur

- Mac Apple Silicon d'abord.
- **FUSE-T** plutôt que macFUSE (pas d'extension noyau, pas de réduction de sécurité).
- Pas de compte Apple Developer au départ : l'app est compilée localement pour l'usage du porteur
  du projet ; la signature Developer ID et la notarisation seront ajoutées au moment de partager
  (99 $/an), sans changer le reste.
- Partage prévu avec la communauté → open source, licence **GPL** (imposée par MLVFS, mlv_dump et
  Switch dont on s'inspire). Danne et les auteurs de MLVFS sont crédités ; prévenir Danne avant
  publication.

### Choix du concepteur (modifiables)

- **App native SwiftUI**, `MenuBarExtra`, macOS 14 minimum (l'utilisateur est sous macOS 26).
- **Outils embarqués** dans le bundle de l'app, compilés en arm64 : MLVFS (lié à la libfuse de
  FUSE-T), mlv_dump, exiftool ; ffmpeg seulement s'il sert en v1 (sinon reporté avec Gyroflow).
  Gyroflow n'est pas installé en v1.
- **FUSE-T** installé à partir de son paquet officiel signé (`fuse-t-macos-installer-*.pkg`,
  v1.2.6 au 23/10/2026), téléchargé ou embarqué, et lancé via le programme d'installation macOS.
  L'app vérifie sa présence et sa version à chaque lancement.
- **Point de montage stable** : un dossier par tournage sous un emplacement fixe propre à l'app,
  `~/MLV Switch/<nom du dossier du tournage>`. Le chemin dépend du nom du dossier, pas du disque :
  un tournage copié sur un autre disque, ou un SSD renommé, garde donc le même chemin et Resolve
  retrouve ses plans. Si deux tournages montés en même temps portent le même nom, le second reçoit
  le nom de son disque en suffixe et l'app le signale. Renommer le dossier d'un tournage change son
  chemin, ce qui est accepté.
- **Bascule dual ISO** : globale (tous les tournages montés). Si Resolve garde des images en cache
  après la bascule, il est acceptable que l'app affiche une consigne claire, par exemple « Dans
  Resolve : clic droit sur les plans → Rafraîchir », plutôt que de changer de conception.
- **Fork de MLVFS autorisé** : l'app peut embarquer une version modifiée de MLVFS (compatibilité
  FUSE-T, rapport de pixel 3:1, modes dual ISO), publiée sous GPL avec le reste. On propose les
  corrections utiles au projet d'origine quand c'est possible.
- **Lecture seule** : les MLV d'origine ne sont jamais modifiés.
- Un processus MLVFS par tournage monté (isolation : un plantage n'emporte pas les autres), supervisé
  par l'app (redémarrage, démontage propre à la fermeture et à l'éjection du disque).

### Laissé au constructeur

- Arborescence exacte du projet Xcode, gestion des processus, journalisation.
- Choix du backend FUSE-T (NFS, SMB ou FSKit) selon les performances mesurées avec Resolve.
- Méthode de réglage des modes MLVFS (options de lancement, interface web locale de MLVFS…).

### Repli si FUSE-T ne convient pas (décidé par l'utilisateur)

D'abord, essayer les autres backends de FUSE-T (SMB, FSKit). Si aucun ne donne un montage stable et
une lecture fluide dans Resolve, l'app propose **macFUSE en option**, explicitement choisie par
l'utilisateur qui accepte de réduire la sécurité de démarrage. FUSE-T reste le choix par défaut ;
l'app explique clairement le compromis et guide l'utilisateur pas à pas, sans terminal. MLVFS doit
donc pouvoir fonctionner avec l'un ou l'autre, choisi au lancement.

## Risques et inconnues à lever en premier

1. **MLVFS + FUSE-T + Resolve** : MLVFS est prévu pour macFUSE. Il faut vérifier qu'il compile et
   fonctionne avec la libfuse de FUSE-T, et que Resolve lit les séquences DNG du montage de façon
   fluide (débit, latence du serveur NFS local). C'est la première chose à prouver.
2. **Stabilité de FUSE-T** : des utilisateurs signalent des montages qui tombent sous forte charge,
   et des régressions sur certaines versions de macOS. Il faut tester sur un vrai montage long.
3. **LJ92 et dual ISO dans MLVFS** : confirmer la prise en charge des clips compressés et des deux
   modes dual ISO, et mesurer la vitesse de chaque mode.
4. **Anamorphose 1x3** dans Resolve.
5. **Installation de FUSE-T sans compte développeur** : vérifier que l'app peut lancer
   l'installation du paquet officiel proprement depuis une app non notarisée.

## Critères de réussite (version 1)

- Sur le Mac du porteur du projet, avec les clips de test (`M29-0615.MLV`, `M23-1246.MLV`) :
  premier lancement → FUSE-T installé via l'app sans terminal ; choix d'un dossier parent → les
  tournages listés ; un clic → les DNG visibles dans le Finder et importables dans Resolve.
- Lecture fluide dans Resolve en mode montage sur un clip non dual ISO en 4.8K 1x3. Mesure
  retenue (choix du concepteur) : Mac du porteur du projet (Apple M4, 24 Go), timeline à 25 i/s,
  lecture en temps réel sans image perdue avec la qualité de lecture « Half » de Resolve, sans
  proxy ni cache de rendu. La pleine résolution en temps réel est un plus, pas une exigence.
- Fermer Resolve et l'app, redémarrer le Mac, relancer : le projet Resolve retrouve tous ses plans.
- Débrancher puis rebrancher le SSD : l'app le gère sans erreur et remonte les tournages.
