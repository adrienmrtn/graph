# Projet : moteur de bets fondé sur un graphe du secteur semi-conducteurs

Projet personnel d'Adrien. Objectif : un moteur 24 h/24 qui lit les news, comprend leurs
conséquences en chaîne grâce à un graphe appris du secteur, et propose des bets chiffrés.
L'humain valide chaque bet. Pas d'argent réel avant les critères de la section 8.5 du plan.

- Plan complet (référence) : https://app.notion.com/p/Bet-404241308d6680049491edd20046312b
- Carte interactive v0 (lecture IA + banc à blanc) : https://claude.ai/artifact/4KAiTJvNhaNF7q5ueftrSW

## Règles non négociables

1. **Tout est daté (point-in-time).** Chaque lien, document, prédiction porte la date à laquelle
   l'information est devenue publique (`filing_date`, `acceptance`, heure de première vue).
   Aucun calcul de test ne doit utiliser une information postérieure à sa date.
2. **Citation exacte obligatoire.** Un lien extrait par un LLM n'est accepté que si sa citation
   existe mot pour mot dans le document source (la base refuse aussi une citation introuvable).
   Sinon : « inféré ».
3. **Le LLM raisonne, le code calcule.** Le LLM choisit le sens et le mécanisme, à partir des
   faits fournis par le graphe. Les montants (mouvement attendu, espérance, taille) sont calculés
   par du code ou le modèle appris, jamais par le LLM.
4. **Aucune information d'Omnes Capital** (deals, due diligences, participations) dans le projet.
5. **Tests LLM uniquement sur des événements postérieurs à juin 2026** (date de connaissance de
   Claude), sinon le modèle « connaît la suite ».
6. **SEC** : en-tête User-Agent avec e-mail (`SEC_CONTACT_EMAIL`), moins de 10 requêtes/s.
   Le HTML n'est jamais stocké, seulement le texte compressé.
7. Style : code et commentaires en français, phrases courtes, pas de tirets cadratins.
8. **Un lien ne compte qu'à partir de sa première citation datée.** Un arbre ou une liste proposés
   par Claude ne sont que des candidats. Droit : on garde les faits et de courtes citations,
   jamais les articles entiers ; on ne contourne pas les sites payants. Le texte complet de la
   presse n'est lu que le temps de l'extraction. Pour la presse archivée par Common Crawl, on
   garde l'adresse de l'enregistrement (fichier et position) pour pouvoir revérifier une citation.

## Où peut être l'edge (section 3.2 bis du plan)

La vitesse de réaction ne dépend pas du sens du lien (latéral ou vertical) mais de sa
**visibilité**. Une chaîne célèbre (« IA → cuivre ») saute en quelques minutes, même à quatre
étages de distance. Un mouvement a deux morceaux :

- **Saut thématique** : immédiat, tout le thème monte, exposés comme simples étiquettes. Il
  mesure l'attention. Le moteur ne court pas après.
- **Dérive fondamentale** : lente, elle suit les chiffres (prix, CA mensuel, marges). Elle
  mesure l'exposition réelle.

Cinq sources d'edge possibles, chacune testée seule à l'étape 2 (test A bis) :

1. **Liens peu visibles** : cités dans un 10-K, un rapport japonais ou une annonce MOPS, jamais
   dans la presse grand public.
2. **Tri à l'intérieur d'un thème** : le saut soulève tout le monde pareil, le graphe sait qui
   est vraiment exposé.
3. **Perdants oubliés** : clients écrasés par un goulot (signe −1 selon le rôle).
4. **Suite du saut** : retournement (excès) ou continuation (manque de réaction). Jamais supposée,
   estimée sur l'historique.
5. **Fin d'un goulot**, remarquée plus lentement que son début.

Horizon visé (hypothèse de départ, l'étape 2 tranche) : 2 à 5 jours pour la suite du saut,
3 jours à 2 semaines pour le tri dans un thème, 2 à 4 semaines pour les liens peu visibles,
les perdants oubliés et la fin d'un goulot. Jamais plus d'un mois : au-delà, on mesure sans
trader. Les marchés asiatiques tradent pendant la nuit à Paris : un ticket validé dans la
journée part à la séance suivante.

Conséquences pour le code : chaque lien porte une **visibilité datée** (célèbre, connu des
spécialistes, caché), calculée sur les co-citations dans la presse publiées avant la date.
Les **thèmes** (ensembles de sociétés que le marché achète ensemble) ont des membres datés.
Les tests mesurent le saut (J0) et la dérive (J+1 à J+20, J+60 pour information) à part,
depuis le premier prix réellement accessible.

## Architecture : Supabase, app web, agent d'enquête (sections 3.8 et 5.1 bis du plan)

Partage des rôles : le graphe est la mémoire datée, l'agent enquête, le code chiffre.

- **Supabase stocke tout** : Postgres (schéma de l'annexe A), pgvector, PGroonga (plein texte
  chinois, japonais, coréen), Storage (textes compressés des dépôts, jamais le HTML), Auth.
  Pas de base de graphe dédiée : Postgres et des requêtes récursives suffisent.
- **Projet** « Graphs » (`lyanycbhuhxmsptwxnap`, eu-west-1). Le schéma vit dans
  `supabase/migrations/` : toute modification passe par une nouvelle migration, jamais à la
  main. `tests/sql/test_regles.sql` vérifie les règles portées par la base (résultat attendu :
  une erreur « TESTS OK », qui annule les données de test).
- **La base refuse elle-même** : un lien ou une observation « cité » dont la citation n'est pas
  mot pour mot dans son passage ; un fait daté avant la publication de son document ; un
  extrait de presse de plus de 600 caractères. `publie_le` d'un passage est recopié du document
  par un déclencheur. Une fin de lien ne compte qu'à partir de `fin_connue_le`.
- **Thèmes et clients anonymes sont des nœuds** (`type` = `theme`, `anonyme`). Appartenance à un
  thème : lien `MEMBRE_DE` (poids = exposition réelle). Résolution d'un « Customer A » : lien
  `RESOLU_EN`. Chacun daté et cité comme tout lien.
- **Accès** : fonctions Postgres datées appelées en RPC (`graphe_a_date()`, `voisins()`,
  `proches()`, `etat()`, `goulots()`, `visibilite()`, `theme()`, `recherche()`). Aucune ne
  renvoie une information publiée après la date demandée.
- **Sécurité** : RLS sur toutes les tables. L'app web lit avec le compte connecté, seulement si
  ce compte figure dans `public.acces`. L'écriture passe par le serveur avec la clé de service,
  qui n'apparaît jamais dans l'app web ni dans le dépôt.
- **App web privée en ligne dès l'étape 1** : graphe à une date, fiche d'un nœud avec
  citations, historique d'état, goulots, recherche datée. Tickets et enquêtes ensuite.
- **Agent d'enquête** (étape 3) : pour chaque news routée, une heure au plus, outils datés
  (`recherche()`, lecture d'une section, `etat()`, `voisins()`, prix), note au format imposé
  avec citations vérifiées par le code. Ni montant ni taille. Rejeu sans web, corpus coupé
  à la date de la news. Évalué seulement sur les news postérieures à juin 2026.

## État actuel (26 octobre 2026)

On repart de zéro sur la nouvelle architecture : le code du pilote n'est pas conservé. Le
pilote (56 sociétés, dernier rapport de chacune) a servi à apprendre. Ses constats restent :

- Les grands groupes anonymisent leurs clients (« Customer A ») ; les petits fournisseurs les
  nomment (AAOI → Microsoft ; Credo, Astera Labs → bons de souscription Amazon). Ce sont des
  liens peu visibles, première source d'edge plausible.
- Repérer client et fournisseur par mots-clés donne des étiquettes brutes et souvent fausses :
  l'extraction passe par Claude, avec citation vérifiée.
- Sans lecture par un LLM, la similarité de texte confond vocabulaire et causalité
  (« Amazon fait faillite » ramenait Tesla et HP).
- Les rapports américains citent rarement les maillons profonds (tissu de verre T-glass,
  feuille de cuivre HVLP, substrats InP). Les plus gros mouvements viennent pourtant de ces
  goulots : voir la section 3.2 bis du plan.

Fait : schéma Supabase de l'étape 1 (`supabase/migrations/`), règles vérifiées par
`tests/sql/test_regles.sql`. Suite : environnement Python et `requirements.txt`, collecteur
TDnet, arbre des produits, univers, collecte de l'historique.

Réseau : les sessions Claude dans le cloud ne joignent une source que si son domaine est
autorisé dans les réglages de l'environnement (Network access).

## Feuille de route : 7 étapes, chacune livre un composant fini

**Règle.** Chaque étape livre un composant dans sa version définitive : code, données, tests,
documentation et mise à jour automatique. On ne passe à l'étape suivante que lorsque tous ses
critères de fin sont cochés. Seule exception : les critères de durée (14 jours sans
intervention) courent en fond pendant l'étape suivante. Pas d'ébauche à reprendre plus tard. Détail complet : section 10 du plan.

| Étape | Livre | Durée estimée |
|---|---|---|
| 1. Le graphe | Couche 1 complète (liens, état des goulots, visibilité, recherche datée), dans Supabase, avec l'explorateur en ligne | 6 à 8 semaines |
| 2. Le moteur d'impact | Prix, événements historiques, tests A et A bis, étage D | 3 à 4 semaines |
| 3. La décision | Couche 3 complète, exécution en papier | 3 semaines |
| 4. Les yeux | Couche 2 complète, en direct | 3 semaines |
| 5. L'exploitation | Déploiement 24 h/24, bot Telegram, app web privée | 2 semaines |
| 6. Papier en réel | Tickets réels sans argent, critères 8.5 | 8 semaines |
| 7. Argent réel | Petite taille, revue mensuelle | 3 mois |

### Étape 1 (en cours) : le graphe, version finale

Contenu :
- **Univers** : toutes les sociétés US des codes SIC du secteur (semi-conducteurs, équipements,
  test, optique, stockage, circuits imprimés, composants), radiées comprises depuis 2010 ;
  clients et voisins (hyperscalers, serveurs, réseau, logiciels de conception, énergie des
  datacenters) ; émetteurs 20-F (TSMC, ASML, UMC, ASE…) ;
  Corée via DART ; Japon via EDINET et TDnet ; Taïwan via MOPS (TWSE et TPEx) ; producteurs des
  matériaux critiques (Nittobo, Mitsui Kinzoku, Resonac, Ajinomoto, AXT…). Fabricants chinois
  cotés (feuille de cuivre, stratifiés) : nœuds de signal, pas de trade.
- **Historique 2010 à aujourd'hui** : tout par `edgartools` pour la SEC (couvre 1994 à
  aujourd'hui : 10-K, 20-F, 8-K, 13F, XBRL). Identité SEC via `SEC_CONTACT_EMAIL`. Nos tests
  contrôlent le découpage par section. EDGAR-CORPUS abandonné.
  Presse : Common Crawl News (news-please ou Fundus) et fichiers bruts GDELT.
- **Ontologie complète** (sections 3.2 et 3.2 bis du plan) : sociétés, produits, matériaux,
  usines, pays, règles, et tous les types de liens, signés selon le rôle dans un goulot, avec
  dates de validité, preuve et confiance.
- **Produits et matériaux au cœur** : pour chaque maillon critique (T-glass, HVLP4, substrats
  InP, ABF, CoWoS, HBM…), producteurs et parts de marché, substituts, clients servis et évincés.
  Source : presse spécialisée (anglais, chinois, japonais) et ses archives, avec citation.
- **État daté des nœuds** : observations (prix, délai, utilisation, capacité, manque prévu,
  allocation) agrégées en état, historique tiré des archives de presse. Volumes et prix
  propagés séparément.
- **Visibilité et thèmes** : visibilité datée de chaque lien (célèbre, spécialistes, caché),
  calculée sur les co-citations dans la presse ; thèmes et leurs membres, datés.
- **Extraction** par Claude : citation vérifiée mot pour mot, tableaux gardés entiers,
  réflexion sur les passages ambigus, liens lus des deux côtés, clients anonymes conservés
  puis résolus quand c'est possible.
- **Couches complémentaires** : concurrence (texte), co-détention (13F), brevets.
- **Résolution des entités** : Splink, alias anglais, chinois, japonais, coréens.
- **Base** Supabase (Postgres, pgvector, PGroonga, Storage, Auth) selon l'annexe A et la
  section 3.8 du plan, tout daté.
- **Recherche datée** : plein texte en 4 langues et vecteurs, qui ne renvoie jamais un document
  publié après la date demandée. Outil principal de l'agent d'enquête.
- **Vecteurs** : étages A et B, recalculés par photos trimestrielles datées. L'étage C sort de
  l'étape 1 (optionnel, après l'étape 2).
- **Mise à jour automatique** : nouveaux dépôts toutes les 10 min (EDGAR, DART, EDINET, TDnet,
  MOPS), extraction et indexation la nuit, vecteurs recalculés chaque semaine.
- **Accès pour les autres couches** : `voisins()`, `proches()`, `graphe_a_date()`, `etat()`,
  `goulots()`, `visibilite()`, `theme()`, `recherche()`, en fonctions Postgres (RPC).
- **Explorateur** : app web privée en ligne, branchée sur Supabase, accès par connexion.
- **Tests** : `pytest` unitaires, banc à blanc, générateur de mondes (retrouver des liens cachés).

Ordre de construction à l'intérieur de l'étape (rien n'est déclaré fini avant les critères) :
dépôt GitHub privé `adrienmrtn/graph` (jamais `data/` ni `.env`), environnement et
`requirements.txt` ; collecteur TDnet lancé tout de suite (environ un mois en ligne) ; schéma
de base ; arbre des produits et noms en 4 langues (ils filtrent toute la collecte) ; univers ;
collecte de l'historique (SEC par edgartools, DART, EDINET, MOPS, cninfo, régulateurs) ; coût
d'extraction mesuré sur 1 000 articles ; archives de presse ; extraction des liens et
observations ; résolution ; état des nœuds ; visibilité et thèmes ; couches complémentaires ;
recherche datée et vecteurs ; mise à jour automatique ; accès ; app web en ligne ; recette.

Spécification produits, sources et extraction (détail : section 3.2 ter du plan) :
- **Arbre** : du serveur IA aux matériaux, 5 à 6 niveaux, 200 à 300 produits. Chaque produit a une
  définition et ses noms en anglais, chinois, japonais, coréen (T-glass, low-CTE glass cloth,
  Tガラス, 低膨脹玻纖布).
- **Liens produits** : PRODUIT (société → produit, part de marché = observation datée ; les
  producteurs d'un même produit sont des pairs), UTILISE (quantité par unité), SUBSTITUT (délai
  de qualification, perte de performance), ALLOUE (producteur → client, priorité, part réservée).
- **Découverte** : terme inconnu fréquent près de mots de pénurie (shortage, lead time, 缺貨,
  供不應求, 品薄) → produit candidat, validé à la main.
- **Sources** : MOPS (CA mensuel avant le 10 du mois, annonces, clients > 10 %) ; EDINET (clients
  ≥ 10 % nommés) ; TDnet (environ un mois en ligne : collecter dès le départ) ; cninfo et
  HKEXnews (signal) ; Federal Register, MOFCOM, METI (règles datées) ; presse en direct par RSS
  et RSSHub, archives via les fichiers bruts GDELT (2015) et Common Crawl News (2016).
- **Chaîne unique** : filtre par alias en 4 langues ; extraction Claude dans la langue d'origine,
  format imposé, citation vérifiée mot pour mot, traduction stockée ; Splink ; dédoublonnage
  (dix reprises d'une même note = un fait, confiance seulement avec sources indépendantes) ;
  calcul de l'état, contradictions visibles.
- **Notes d'analystes** : captées via la presse, type « note citée », confiance plus basse, date
  de l'article. **Prix non cotés** (tissu de verre, feuille de cuivre, InP) : seulement par les
  annonces de hausse. **Règles** : nœud Règle daté, liens SOUMIS À, observation « restriction ».
- **Exemple de recette** : chaîne InP. Contrôle MOFCOM de l'indium (annonce n° 10 de 2025, en
  vigueur le 4 février 2025) → substrats InP → AXT (filiale Tongmei, permis d'export) ; pairs
  Sumitomo Electric et JX Advanced Metals ; lasers des transceivers optiques en aval.

Briques de collecte (détail : section 7.5 du plan). Aucune ne fait tout : on les assemble
derrière la même chaîne d'extraction.

| Besoin | Outil | À savoir |
|---|---|---|
| Archives de presse | news-please | Common Crawl News depuis 2016, filtre par site et date. Extraction moyenne sur les sites asiatiques |
| Archives de presse | Fundus (MIT, août 2026) | Extraction très propre, réglée site par site. Surtout médias occidentaux |
| Archives de presse | Fichiers bruts GDELT | Liste datée des articles depuis 2015. L'API ne couvre que les 3 derniers mois |
| Sites sans flux RSS | RSSHub (AGPL, auto-hébergé) | Beaucoup de sites chinois de finance. Couverture à vérifier (財聯社, 36kr, 華爾街見聞) |
| Pages officielles sans flux | changedetection.io | MOFCOM, METI, pages investisseurs. Une page à la fois |
| Pages qui demandent un navigateur | Crawl4AI (0.9) | Lent : approfondissement seulement |
| Flux RSS, texte d'une page | feedparser, trafilatura | |
| États-Unis | edgartools | Moins de 10 requêtes/s, User-Agent avec e-mail |
| Taïwan | FinMind (24 octobre 2026) | Prix, CA mensuel, comptes, news. 300 requêtes/h, 600 avec un compte gratuit. Non commercial |
| Japon | edinet-tools (MIT) | 42 types de documents EDINET, clé requise. Rien pour TDnet : collecteur maison |
| Corée | dart-fss (MIT, juillet 2026) | API officielle DART, clé gratuite |
| Chine | AKShare (MIT) | Actions A, cuivre de Shanghai, news Eastmoney. Usage de recherche, accès instables, Python 3.11+ |

Règles d'usage : conditions d'utilisation et robots vérifiés site par site, y compris pour
RSSHub, changedetection.io et Crawl4AI ; FinMind et AKShare en usage personnel ; un contrôle de
santé par collecteur (alerte si une source se tait plus de 15 min) ; versions figées dans
`requirements.txt`. Sources rapides et gratuites d'abord : dépôts boursiers, communiqués,
flashs asiatiques, chaînes Telegram publiques (section 4.2 bis du plan). Jamais de
contournement des protections anti-robots (CAPTCHA, rotation d'adresses IP), ni de collecte
derrière une connexion.

Critères de fin (chacun se coche en un temps fini, quel que soit le résultat des modèles) :
- [ ] Précision des liens ≥ 90 % sur 200 liens tirés au hasard, stratifiés par type de lien et
      par langue, vérifiés à la main. Un lien est juste si sa source, sa cible, son type, son
      sens et sa date le sont
- [ ] Rappel ≥ 80 % sur 100 relations connues, toutes tirées de documents datés (FinReflectKG +
      liste de référence), jamais de la mémoire d'un LLM
- [ ] Goulots de référence cartographiés (T-glass, HVLP4, substrats InP, ABF, CoWoS, HBM) :
      producteurs et parts, substituts, clients, historique d'état daté
- [ ] Produits des goulots de référence : part de marché datée et citée pour chaque producteur
      connu. Autres produits : au moins un producteur cité ; part datée et citée quand une
      source gratuite existe, sinon « part inconnue » avec la liste des sources consultées
- [ ] Noms en anglais, chinois, japonais et coréen pour chaque produit et matériau ; nom local
      pour chaque société asiatique ; nom anglais et ticker pour les autres sociétés
- [ ] Visibilité datée calculée pour tous les liens ; thèmes liés aux goulots de référence, avec
      membres datés et exposition réelle
- [ ] Rapport de couverture : pour chaque source, période couverte et trous connus (dépôts
      officiels depuis 2010, presse depuis 2015 ou 2016)
- [ ] Recherche datée : sur 50 requêtes de test à des dates variées, aucun document postérieur
      à la date demandée ; le passage attendu figure dans les 10 premiers résultats pour au
      moins 80 % des requêtes
- [ ] App web en ligne : l'explorateur s'ouvre après connexion ; sans connexion, aucune donnée
      n'est lisible (test des règles RLS)
- [ ] Test automatique de non-fuite : pour 20 dates tirées au hasard, le graphe et l'état
      reconstruits depuis une base tronquée à la date sont identiques à `graphe_a_date()` sur
      la base complète. Des documents « canaris » datés du futur n'apparaissent jamais
- [ ] Mise à jour automatique : 14 jours sans intervention. Ces 14 jours courent en fond :
      l'étape 2 peut démarrer pendant ce temps
- [ ] Tous les tests passent, documentation à jour

### Étapes suivantes (résumé, détail dans le plan)

2. **Moteur d'impact** : prix EODHD depuis 2010, événements historiques datés, rendements
   anormaux, test A net de frais par lieu et par sous-période, par classe de visibilité ;
   test A bis sur tous les goulots recensés (y compris ceux sans suite), par rôle et par classe
   de visibilité, à J0, J+1, J+2, J+5, J+10 et J+20 (J+60 pour information), saut et dérive
   séparés, retournement du saut mesuré ; étage D calibré, `impact_attendu(événement, date)`.
   Verdict pour chacune des cinq sources d'edge, par horizon et par classe de visibilité :
   feu vert, pivot ou arrêt, avec l'horizon retenu (entre 2 jours et 4 semaines).
3. **Décision** : candidats (graphe, rôles dans les goulots, membres du thème), limités aux
   sources d'edge validées à l'étape 2, sortie à l'horizon retenu pour la source ; agent d'enquête (une heure au plus, corpus
   daté, note au format imposé, coût mesuré sur 20 news), second avis Jev
   ou GLiNER2, contrôle marché (mouvement déjà fait comparé à l'exposition réelle), espérance,
   taille, limites, tickets, papier IBKR (un compte : États-Unis, Japon, Taïwan TWSE et
   TPEx, Corée KRX ; pas de vente à découvert à Taïwan) et Liquid, rejeu juillet-octobre 2026. Zéro erreur de
   sens sur le générateur de mondes.
4. **Les yeux** : toutes les sources de la section 4.2 (dont presse asiatique, notes d'analystes
   citées par la presse, BIS, Federal Register, MOFCOM, METI, prix des matières), collecteurs
   bâtis sur les briques ci-dessus, observations d'état, dédoublonnage, routage, banc 6.4 tranché.
   Latence médiane < 60 s, rappel ≥ 95 % sur les 8-K, 14 jours sans trou.
5. **Exploitation** : VM européenne + Mac, bot Telegram, app web privée, interrupteur d'arrêt,
   sauvegardes. 14 jours seul, ticket sur le téléphone moins de 90 min après la news, avant
   la séance suivante du titre visé.
6. et 7. Papier 8 semaines, puis argent réel en petite taille.

Hors périmètre assumé : transcripts payants, fils Bloomberg ou Reuters, réseaux sociaux dont
LinkedIn (pas d'API ouverte, collecte interdite), notes d'analystes en direct (captées via la
presse qui les cite), trading d'actions chinoises (signal seulement), élève local d'extraction
(seulement si la facture d'API l'exige), deuxième secteur avant l'étape 7.

