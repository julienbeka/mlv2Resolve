# DaVinci Resolve gratuit ou Studio

*[English version](resolve-free-vs-studio.md)*

mlv2Resolve fonctionne avec les deux éditions de DaVinci Resolve. La différence porte surtout sur **la façon**
de piloter Resolve, plus une limite de résolution. Cette page indique ce qui est identique, ce qui change et ce qu'il
faut faire à la main avec la version gratuite.

## Pourquoi il y a une différence

mlv2Resolve communique avec Resolve par son API de scripting Lua. Blackmagic ne permet le scripting **externe**
(un programme extérieur à Resolve, ici `fuscript`, qui se connecte au Resolve ouvert) qu'avec **Studio**. La version
gratuite exécute quand même les scripts lancés **depuis Resolve** par **Workspace → Scripts**.

mlv2Resolve fait donc le même travail dans les deux cas, mais :

- **Studio :** l'app lance le script elle-même. Un clic dans mlv2Resolve suffit.
- **Gratuit :** l'app écrit le script dans le dossier de scripts de Resolve
  (`~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility`) et vous le lancez
  depuis le menu de Resolve.

## Identique dans les deux éditions

Ces fonctions s'exécutent dans mlv2Resolve ou sur le disque. L'édition de Resolve ne change rien :

| Fonction | Remarques |
| --- | --- |
| Montage des MLV en CinemaDNG virtuels (FUSE-T) | Les rushs apparaissent dans `~/MLV Mounts/<tournage>`. |
| Fichiers WAV associés | Servis à côté de chaque séquence DNG. |
| Modes Dual ISO (Montage fluide / Qualité étalonnage) | Basculés en direct par le moteur ; utilisez **Refresh** dans Resolve. |
| Synchro gyro SenseFlow A1 et fichiers `.gyroflow` | Générés par l'app. |
| Vignettes et aperçus désanamorphosés | Affichés dans l'app. |
| **Ouvrir Resolve** | Lance seulement Resolve. |

Ces fonctions sont réalisées par le script de projet. **La version gratuite exécute le même script** et obtient donc le
même résultat une fois le script lancé depuis le menu Workspace :

| Fonction | Remarques |
| --- | --- |
| Créer un projet nommé à partir de tous les tournages montés | Même script dans les deux éditions. |
| Importer les séquences CinemaDNG et les WAV, puis synchroniser le son par timecode | |
| Cadence du projet (automatique ou manuelle) | |
| Gestion couleur (DWG / Intermediate, groupe couleur **All**, CST de pré-groupe et post-groupe, option Kodak 2383) | Faite avec des nœuds, CST et LUT standard. |
| Timeline **All shots**, ou timeline vide avec les étalonnages de groupe | |
| Nœud Gyroflow(NiYien) sur chaque plan | mlv2Resolve ne vérifie pas l'édition de Resolve ici. Le plugin OFX doit être installé et accepter votre édition de Resolve. |
| Ajout de nouveaux plans à un projet lié, **Ouvrir le projet** | |
| Désanamorphose des plans de la timeline | Faite avec le préréglage Input Sizing du plan ou un zoom sur l'élément de timeline. Voir les limites de taille de timeline ci-dessous. |

## Ce qui change avec la version gratuite

### 1. Chaque action se lance depuis Resolve

La marche à suivre est la même pour chaque action (**Créer le projet**, **Ouvrir le projet**, ajout de nouveaux plans) :

1. Attendez la fin de la synchro gyro si vous utilisez un SenseFlow A1.
2. Ouvrez Resolve (le bouton **Ouvrir Resolve** fonctionne).
3. Dans mlv2Resolve, cliquez sur l'action voulue. Avec la version gratuite, l'app ne peut pas se connecter et affiche
   le guide pas à pas. Elle a déjà écrit le script de cette action.
4. Dans Resolve, lancez **Workspace → Scripts → mlv2Resolve**. Le script exécute l'action choisie à l'étape 3.

Si vous lancez le script avant de choisir une action, il affiche *« Choose an action in mlv2Resolve first. »*

**Désanamorphoser dans Resolve** a son propre script, **Workspace → Scripts → mlv2Resolve Desqueeze**. mlv2Resolve le
met à jour à chaque montage ou démontage d'un tournage : aucun clic préalable dans l'app n'est nécessaire. Lancez-le
avec le projet ouvert.

### 2. Taille de timeline limitée à l'UHD

Resolve gratuit n'accepte pas de timeline plus grande que **3840×2160**. Avec **Taille du projet : Automatique**,
Studio utilise la taille native désanamorphosée des rushs. Par exemple, un tournage 4.8K en 1x3 donne 4800×2008.
La version gratuite limite le projet à **3840×2160** et l'image entière y est ajustée, avec des bandes si nécessaire.

Les réglages **UHD** et **HD** fonctionnent de la même façon dans les deux éditions.

### 3. Cadrage des plans anamorphosés d'un autre rapport d'image

Avec Studio, un plan dont le rapport désanamorphosé diffère de la timeline reçoit un préréglage spécial,
**`mlv2Resolve 1x<N> Fit …`**. Ce préréglage contient déjà la réduction : l'image entière est visible dans le
Media Pool et sur toutes les timelines.

Avec la version gratuite, le script utilise le préréglage simple **`mlv2Resolve 1x<N>`**. Sur les timelines qu'il crée,
il règle le **Zoom X / Zoom Y** du plan pour que l'image tienne. Le résultat est identique sur ces timelines. Si vous
glissez vous-même ces plans sur une nouvelle timeline, il faudra peut-être réajuster le zoom ou l'**Input Sizing**.

### 4. Désanamorphose manuelle en dernier recours

Si aucun script ne peut tourner, réglez la désanamorphose à la main. Utilisez le facteur indiqué par mlv2Resolve
pour le tournage :

> **Page Color → Sizing → Input Sizing → Width = N** (par exemple 3 pour du 1x3)

L'app affiche ce rappel la première fois que vous montez un tournage anamorphosé.

## Ce que Studio demande

Studio fait tout directement depuis mlv2Resolve, mais il faut autoriser une fois le scripting externe :

> **DaVinci Resolve → Preferences → System → General → External scripting using: Local**

Ensuite :

- Resolve doit être ouvert, et **Désanamorphoser dans Resolve** demande un projet ouvert.
- **Créer le projet** et **Ouvrir le projet** fonctionnent depuis l'app, tout comme l'ajout de nouveaux plans à un
  projet lié.
- Si Resolve ne répond pas, mlv2Resolve rappelle ce réglage. En attendant, la méthode du script Workspace décrite
  plus haut reste utilisable. Elle fonctionne aussi avec Studio.

## Résumé

| | Resolve gratuit | Resolve Studio |
| --- | --- | --- |
| Montage, Dual ISO, synchro gyro, aperçus | ✅ | ✅ |
| Lancer les actions | Clic dans l'app, puis **Workspace → Scripts → mlv2Resolve** | Un clic dans l'app |
| Création du projet, synchro son, gestion couleur, timeline All shots | ✅ (par le script) | ✅ |
| Nœud Gyroflow(NiYien) | ✅ si le plugin est installé et accepte votre édition | ✅ si le plugin est installé |
| Taille de projet automatique au-delà de l'UHD | ❌ limitée à 3840×2160 | ✅ taille native désanamorphosée |
| Préréglages anamorphiques « Fit » pour les autres rapports | ❌ (zoom de timeline à la place) | ✅ |
| Désanamorphoser dans Resolve | **Workspace → Scripts → mlv2Resolve Desqueeze** | Un clic dans l'app |
| Réglage initial | Aucun | **External scripting using: Local** |

> Les essais réels ont été faits avec Resolve **Studio** 21.1.1. La version gratuite utilise le même script, avec les
> variantes décrites ci-dessus, mais aucune vérification visuelle complète dans Resolve gratuit n'est encore documentée.
