-- Schéma du graphe daté (étape 1, annexe A du plan).
-- Règle 1 : chaque fait porte la date à laquelle il est devenu public.
-- Règle 2 : un lien « cité » a une citation retrouvée mot pour mot dans son passage.
-- Règle 8 : de la presse, on ne garde que de courts extraits.

-- Passes d'extraction : modèle, version du prompt, coût. Chaque lien sait d'où il vient.
create table public.extractions (
  id bigint generated always as identity primary key,
  modele text not null,
  version_prompt text not null,
  debut timestamptz not null default now(),
  fin timestamptz,
  nb_documents integer,
  tokens_entree bigint,
  tokens_sortie bigint,
  cout_usd numeric(12, 4),
  note text
);

-- Nœuds. Les thèmes et les clients anonymes (« Customer A ») sont des nœuds comme les autres.
create table public.entites (
  id bigint generated always as identity primary key,
  type text not null check (type in ('societe', 'produit', 'materiau', 'usine', 'pays', 'regle', 'theme', 'anonyme')),
  nom text not null,
  definition text,
  pays text,                                        -- code ISO 3166-1 à deux lettres
  tickers text[] not null default '{}',
  identifiants jsonb not null default '{}'::jsonb,  -- cik, isin, dart, edinet, twse, tpex...
  niveau smallint,                                  -- niveau dans l'arbre des produits (1 = serveur IA)
  statut text not null default 'candidat' check (statut in ('candidat', 'valide')),
  signal_seulement boolean not null default false,  -- sociétés chinoises : signal, pas de trade
  cree_le timestamptz not null default now()
);
create index entites_type_idx on public.entites (type);
create index entites_identifiants_idx on public.entites using gin (identifiants);
create unique index entites_cik_uniq on public.entites ((identifiants ->> 'cik')) where identifiants ? 'cik';

-- Noms en 4 langues, tickers, anciens noms.
create table public.alias (
  id bigint generated always as identity primary key,
  entite_id bigint not null references public.entites (id) on delete cascade,
  alias text not null,
  langue text not null check (langue in ('en', 'zh', 'ja', 'ko')),
  genre text not null default 'nom' check (genre in ('nom', 'ticker', 'ancien_nom', 'abreviation')),
  source text,
  valide_depuis date,
  valide_jusqu_a date,
  unique (entite_id, alias, langue)
);
create index alias_entite_idx on public.alias (entite_id);
create index alias_minuscules_idx on public.alias (lower(alias));
create index alias_trgm_idx on public.alias using gin (lower(alias) extensions.gin_trgm_ops);

-- Documents sources. publie_le est la date de connaissance : acceptation SEC, heure de publication.
create table public.documents (
  id bigint generated always as identity primary key,
  source text not null,              -- sec, edinet, tdnet, mops, dart, cninfo, hkex, federal_register, mofcom, meti, presse:<site>
  identifiant_source text not null,  -- numéro d'accession SEC, identifiant EDINET, URL canonique...
  type text not null,                -- 10-K, 20-F, 8-K, yuho, annonce, article...
  entite_id bigint references public.entites (id),  -- déposant, pour un dépôt
  titre text,
  url text,
  langue text not null check (langue in ('en', 'zh', 'ja', 'ko')),
  publie_le timestamptz not null,
  precision_date text not null default 'seconde' check (precision_date in ('seconde', 'minute', 'jour')),
  vu_le timestamptz,                 -- première vue chez nous ; vide pour l'historique
  periode_debut date,                -- période couverte, par exemple l'exercice d'un rapport annuel
  periode_fin date,
  origine text not null check (origine in ('depot', 'presse', 'regulateur')),
  chemin_storage text,               -- texte compressé dans Supabase Storage
  archive_cc jsonb,                  -- presse archivée : fichier WARC, position, longueur
  empreinte text,                    -- sha256 du texte, pour le dédoublonnage
  cree_le timestamptz not null default now(),
  unique (source, identifiant_source),
  check (origine <> 'presse' or chemin_storage is null)  -- règle 8 : jamais le texte entier d'un article
);
create index documents_publie_idx on public.documents (publie_le);
create index documents_entite_idx on public.documents (entite_id, publie_le);

-- Passages : l'unité de recherche et de citation.
-- publie_le et origine sont recopiés du document par un déclencheur, jamais saisis à la main.
create table public.passages (
  id bigint generated always as identity primary key,
  document_id bigint not null references public.documents (id) on delete cascade,
  position integer not null,
  section text,                      -- Item 1, Item 7, 主要な顧客...
  texte text not null,
  langue text not null check (langue in ('en', 'zh', 'ja', 'ko')),
  publie_le timestamptz not null,
  origine text not null check (origine in ('depot', 'presse', 'regulateur')),
  unique (document_id, position),
  check (origine <> 'presse' or char_length(texte) <= 600)  -- règle 8 : courts extraits de presse
);
create index passages_publie_idx on public.passages (publie_le);
create index passages_texte_pgroonga on public.passages using pgroonga (texte);

create function public.passages_copie_document() returns trigger
language plpgsql set search_path = ''
as $$
begin
  select d.publie_le, d.origine into new.publie_le, new.origine
  from public.documents d where d.id = new.document_id;
  return new;
end
$$;
create trigger passages_copie_document
before insert or update of document_id, publie_le, origine on public.passages
for each row execute function public.passages_copie_document();

-- Si la date d'un document est corrigée, ses passages suivent.
create function public.documents_propage_date() returns trigger
language plpgsql set search_path = ''
as $$
begin
  update public.passages p set publie_le = new.publie_le, origine = new.origine
  where p.document_id = new.id;
  return new;
end
$$;
create trigger documents_propage_date
after update of publie_le, origine on public.documents
for each row execute function public.documents_propage_date();

-- Vecteurs des passages (étage A). 1024 dimensions : bge-m3, multilingual-e5-large et
-- Qwen3-Embedding-0.6B. Si le banc retient un autre encodeur, une migration change la dimension.
create table public.vecteurs_passages (
  passage_id bigint not null references public.passages (id) on delete cascade,
  modele text not null,
  vecteur extensions.vector(1024) not null,
  primary key (passage_id, modele)
);
create index vecteurs_passages_hnsw on public.vecteurs_passages
using hnsw (vecteur extensions.vector_cosine_ops);

-- Liens. Une ligne par preuve : un même lien cité en 2016 puis en 2024 a deux lignes.
create table public.liens (
  id bigint generated always as identity primary key,
  source_id bigint not null references public.entites (id),
  cible_id bigint not null references public.entites (id),
  type text not null check (type in (
    'FOURNIT', 'CONCURRENT', 'PRODUIT', 'UTILISE', 'SITUE', 'DETIENT', 'CO_ENTREPRISE',
    'SOUMIS_A', 'LICENCE', 'SUBSTITUT', 'ALLOUE', 'MEMBRE_DE', 'RESOLU_EN')),
  statut text not null check (statut in ('cite', 'infere', 'calcule')),
  connu_le timestamptz not null,     -- date à laquelle le fait est devenu public
  valide_depuis date,                -- début de validité dans le monde, si connu
  valide_jusqu_a date,               -- fin de validité, si connue
  fin_connue_le timestamptz,         -- date à laquelle cette fin est devenue publique
  document_id bigint references public.documents (id),
  passage_id bigint references public.passages (id),
  citation text,
  traduction text,
  poids numeric,                     -- exposition (pour MEMBRE_DE : exposition réelle au thème)
  part_pct numeric check (part_pct between 0 and 100),
  source_unique boolean,
  role_goulot text,
  signe smallint check (signe in (-1, 0, 1)),
  quantite_par_unite numeric,
  unite text,
  confiance numeric check (confiance between 0 and 1),
  extraction_id bigint references public.extractions (id),
  cree_le timestamptz not null default now(),
  check (source_id <> cible_id),
  check (statut <> 'cite' or (passage_id is not null and citation is not null)),
  check (valide_jusqu_a is null or fin_connue_le is not null),
  check (fin_connue_le is null or fin_connue_le >= connu_le)
);
create index liens_source_idx on public.liens (source_id, connu_le);
create index liens_cible_idx on public.liens (cible_id, connu_le);
create index liens_type_idx on public.liens (type);

-- Vérifie la citation mot pour mot et interdit un lien daté avant son document.
create function public.liens_verifie() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_texte text;
  v_doc bigint;
  v_publie timestamptz;
begin
  if new.passage_id is not null then
    select p.texte, p.document_id into v_texte, v_doc from public.passages p where p.id = new.passage_id;
    if new.document_id is null then
      new.document_id := v_doc;
    elsif new.document_id <> v_doc then
      raise exception 'Le passage % n''appartient pas au document %', new.passage_id, new.document_id;
    end if;
  end if;
  if new.statut = 'cite' and (v_texte is null or strpos(v_texte, new.citation) = 0) then
    raise exception 'Citation introuvable mot pour mot dans le passage % : lien refusé (règle 2)', new.passage_id;
  end if;
  if new.document_id is not null then
    select d.publie_le into v_publie from public.documents d where d.id = new.document_id;
    if new.connu_le < v_publie then
      raise exception 'connu_le (%) antérieur à la publication du document (%) : fuite du futur', new.connu_le, v_publie;
    end if;
  end if;
  return new;
end
$$;
create trigger liens_verifie before insert or update on public.liens
for each row execute function public.liens_verifie();

-- Observations datées sur un nœud ou un lien : prix, délai, capacité, manque prévu...
create table public.observations (
  id bigint generated always as identity primary key,
  entite_id bigint not null references public.entites (id),
  lien_id bigint references public.liens (id),
  variable text not null check (variable in (
    'saturation', 'utilisation', 'prix', 'variation_prix', 'delai', 'capacite', 'capacite_annoncee',
    'manque_prevu', 'allocation', 'part_de_marche', 'chiffre_affaires', 'restriction')),
  valeur numeric,
  valeur_texte text,
  unite text,
  periode_debut date,                -- période visée par la valeur
  periode_fin date,
  publie_le timestamptz not null,
  type_source text not null check (type_source in (
    'depot', 'presse_specialisee', 'presse_generale', 'note_citee', 'regulateur', 'calcule')),
  document_id bigint references public.documents (id),
  passage_id bigint references public.passages (id),
  citation text,
  traduction text,
  doublon_de bigint references public.observations (id),  -- reprise d'un même fait : compte pour un
  confiance numeric check (confiance between 0 and 1),
  extraction_id bigint references public.extractions (id),
  cree_le timestamptz not null default now(),
  check (valeur is not null or valeur_texte is not null),
  check (type_source = 'calcule' or (passage_id is not null and citation is not null))
);
create index observations_entite_idx on public.observations (entite_id, variable, publie_le);

create function public.observations_verifie() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_texte text;
  v_doc bigint;
  v_publie timestamptz;
begin
  if new.passage_id is not null then
    select p.texte, p.document_id, p.publie_le into v_texte, v_doc, v_publie
    from public.passages p where p.id = new.passage_id;
    if new.document_id is null then
      new.document_id := v_doc;
    elsif new.document_id <> v_doc then
      raise exception 'Le passage % n''appartient pas au document %', new.passage_id, new.document_id;
    end if;
    if strpos(v_texte, new.citation) = 0 then
      raise exception 'Citation introuvable mot pour mot dans le passage % : observation refusée (règle 2)', new.passage_id;
    end if;
    if new.publie_le < v_publie then
      raise exception 'publie_le (%) antérieur à la publication du document (%) : fuite du futur', new.publie_le, v_publie;
    end if;
  end if;
  return new;
end
$$;
create trigger observations_verifie before insert or update on public.observations
for each row execute function public.observations_verifie();

-- État d'un nœud tel qu'on le connaissait à une date. Cache pour l'app web :
-- la vérité reste la fonction etat(), recalculée depuis les observations.
create table public.etats (
  entite_id bigint not null references public.entites (id),
  variable text not null,
  date timestamptz not null,
  valeur numeric,
  valeur_texte text,
  nb_observations integer not null,
  nb_documents integer not null,
  contradiction boolean not null default false,
  confiance numeric check (confiance between 0 and 1),
  calcule_le timestamptz not null default now(),
  primary key (entite_id, variable, date)
);

-- Visibilité d'un lien à une date, calculée sur les seules sources publiées avant cette date.
create table public.visibilites (
  lien_id bigint not null references public.liens (id) on delete cascade,
  date date not null,
  nb_grand_public integer not null default 0,
  nb_specialises integer not null default 0,
  nb_depots integer not null default 0,
  classe text not null check (classe in ('celebre', 'specialistes', 'cache')),
  calcule_le timestamptz not null default now(),
  primary key (lien_id, date)
);

-- Vecteurs des nœuds (étages A et B), par photo trimestrielle.
-- Une photo n'utilise que des données publiées avant sa date.
create table public.vecteurs_entites (
  entite_id bigint not null references public.entites (id) on delete cascade,
  etage text not null check (etage in ('A', 'B')),
  modele text not null,
  date date not null,
  vecteur extensions.vector not null,
  primary key (entite_id, etage, modele, date)
);
