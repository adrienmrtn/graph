-- Accès datés de la section 3.7 du plan, appelés en RPC par l'agent, le moteur et l'app web.
-- Aucune fonction ne renvoie une information publiée après la date demandée.
-- Fonctions « security invoker » : les règles RLS s'appliquent à l'appelant.

-- Liens connus à une date. Une fin de lien ne compte qu'une fois devenue publique.
create function public.graphe_a_date(p_date timestamptz)
returns setof public.liens
language sql stable set search_path = ''
as $$
  select l.*
  from public.liens l
  where l.connu_le <= p_date
    and not (l.fin_connue_le is not null and l.fin_connue_le <= p_date and l.valide_jusqu_a < p_date::date)
$$;

-- Voisins à 1, 2 ou 3 rangs. Une arête par paire et par type : la preuve citée la plus récente.
create function public.voisins(
  p_entite bigint,
  p_date timestamptz,
  p_profondeur integer default 1,
  p_types text[] default null)
returns table (
  entite_id bigint, nom text, type_entite text, profondeur integer, lien_id bigint,
  type_lien text, sortant boolean, statut text, citation text, connu_le timestamptz)
language sql stable set search_path = ''
as $$
  with recursive g as (
    select distinct on (l.source_id, l.cible_id, l.type) l.*
    from public.graphe_a_date(p_date) l
    where p_types is null or l.type = any (p_types)
    order by l.source_id, l.cible_id, l.type, (l.statut = 'cite') desc, l.connu_le desc
  ),
  parcours as (
    select
      case when g.source_id = p_entite then g.cible_id else g.source_id end as voisin,
      1 as rang, g.id as lien, g.type as type_l, (g.source_id = p_entite) as sort,
      g.statut as stat, g.citation as cit, g.connu_le as connu,
      array[p_entite, case when g.source_id = p_entite then g.cible_id else g.source_id end] as chemin
    from g
    where g.source_id = p_entite or g.cible_id = p_entite
    union all
    select
      case when g.source_id = p.voisin then g.cible_id else g.source_id end,
      p.rang + 1, g.id, g.type, (g.source_id = p.voisin), g.statut, g.citation, g.connu_le,
      p.chemin || case when g.source_id = p.voisin then g.cible_id else g.source_id end
    from parcours p
    join g on g.source_id = p.voisin or g.cible_id = p.voisin
    where p.rang < least(p_profondeur, 3)
      and not ((case when g.source_id = p.voisin then g.cible_id else g.source_id end) = any (p.chemin))
  )
  select p.voisin, e.nom, e.type, p.rang, p.lien, p.type_l, p.sort, p.stat, p.cit, p.connu
  from parcours p
  join public.entites e on e.id = p.voisin
  order by p.rang, p.connu desc
$$;

-- État d'un nœud à une date : dernière valeur par variable, nombre d'observations,
-- et les cinq dernières valeurs pour voir les contradictions.
create function public.etat(p_entite bigint, p_date timestamptz)
returns table (
  variable text, valeur numeric, valeur_texte text, unite text, periode_debut date,
  periode_fin date, publie_le timestamptz, nb_observations bigint, nb_documents bigint,
  valeurs_recentes jsonb)
language sql stable set search_path = ''
as $$
  with obs as (
    select o.*
    from public.observations o
    where o.entite_id = p_entite and o.publie_le <= p_date and o.doublon_de is null
  ),
  derniere as (
    select distinct on (o.variable) o.*
    from obs o
    order by o.variable, o.publie_le desc, o.id desc
  )
  select
    d.variable, d.valeur, d.valeur_texte, d.unite, d.periode_debut, d.periode_fin, d.publie_le,
    (select count(*) from obs o where o.variable = d.variable),
    (select count(distinct o.document_id) from obs o where o.variable = d.variable),
    (select jsonb_agg(jsonb_build_object(
        'valeur', r.valeur, 'texte', r.valeur_texte, 'publie_le', r.publie_le, 'citation', r.citation)
        order by r.publie_le desc)
     from (select o.* from obs o where o.variable = d.variable order by o.publie_le desc limit 5) r)
  from derniere d
$$;

-- Visibilité d'un lien : dernière photo calculée à la date ou avant.
create function public.visibilite(p_lien bigint, p_date date)
returns setof public.visibilites
language sql stable set search_path = ''
as $$
  select v.*
  from public.visibilites v
  where v.lien_id = p_lien and v.date <= p_date
  order by v.date desc
  limit 1
$$;

-- Membres d'un thème à une date, avec leur exposition réelle.
create function public.theme(p_theme bigint, p_date timestamptz)
returns table (entite_id bigint, nom text, exposition numeric, lien_id bigint, citation text, connu_le timestamptz)
language sql stable set search_path = ''
as $$
  select distinct on (e.id) e.id, e.nom, l.poids, l.id, l.citation, l.connu_le
  from public.graphe_a_date(p_date) l
  join public.entites e on e.id = l.source_id
  where l.type = 'MEMBRE_DE' and l.cible_id = p_theme
  order by e.id, l.connu_le desc
$$;

-- Nœuds proches dans l'espace vectoriel, sur la dernière photo antérieure à la date.
create function public.proches(
  p_entite bigint,
  p_date date,
  p_etage text default 'A',
  p_limite integer default 20)
returns table (entite_id bigint, nom text, similarite double precision, date_photo date)
language sql stable set search_path = ''
as $$
  with ref as (
    select v.vecteur, v.modele, v.date
    from public.vecteurs_entites v
    where v.entite_id = p_entite and v.etage = p_etage and v.date <= p_date
    order by v.date desc
    limit 1
  )
  select v.entite_id, e.nom, 1 - (v.vecteur operator(extensions.<=>) ref.vecteur), v.date
  from public.vecteurs_entites v
  join ref on v.modele = ref.modele and v.date = ref.date
  join public.entites e on e.id = v.entite_id
  where v.etage = p_etage and v.entite_id <> p_entite
  order by v.vecteur operator(extensions.<=>) ref.vecteur
  limit p_limite
$$;

-- Recherche datée dans le corpus : plein texte (PGroonga) et vecteurs, rangs fusionnés.
-- Le vecteur de la requête est calculé par l'appelant avec le même encodeur que les passages.
create function public.recherche(
  p_texte text,
  p_date timestamptz,
  p_langues text[] default null,
  p_vecteur extensions.vector(1024) default null,
  p_modele text default null,
  p_limite integer default 20)
returns table (
  passage_id bigint, document_id bigint, texte text, langue text, publie_le timestamptz,
  source text, type_document text, titre text, url text, score double precision)
language sql stable set search_path = ''
as $$
  with plein_texte as (
    select p.id, row_number() over (order by extensions.pgroonga_score(p.tableoid, p.ctid) desc) as rang
    from public.passages p
    where p_texte is not null
      and p.texte operator(extensions.&@~) p_texte
      and p.publie_le <= p_date
      and (p_langues is null or p.langue = any (p_langues))
    order by extensions.pgroonga_score(p.tableoid, p.ctid) desc
    limit 100
  ),
  semantique as (
    select p.id, row_number() over (order by v.vecteur operator(extensions.<=>) p_vecteur) as rang
    from public.vecteurs_passages v
    join public.passages p on p.id = v.passage_id
    where p_vecteur is not null
      and v.modele = p_modele
      and p.publie_le <= p_date
      and (p_langues is null or p.langue = any (p_langues))
    order by v.vecteur operator(extensions.<=>) p_vecteur
    limit 100
  ),
  fusion as (
    select r.id, sum(1.0 / (60 + r.rang)) as score
    from (select id, rang from plein_texte union all select id, rang from semantique) r
    group by r.id
  )
  select p.id, p.document_id, p.texte, p.langue, p.publie_le, d.source, d.type, d.titre, d.url,
         f.score::double precision
  from fusion f
  join public.passages p on p.id = f.id
  join public.documents d on d.id = p.document_id
  order by f.score desc
  limit p_limite
$$;

-- Droits : comptes connectés seulement (les règles RLS filtrent ensuite), jamais anonyme.
revoke execute on function public.graphe_a_date(timestamptz) from public, anon;
revoke execute on function public.voisins(bigint, timestamptz, integer, text[]) from public, anon;
revoke execute on function public.etat(bigint, timestamptz) from public, anon;
revoke execute on function public.visibilite(bigint, date) from public, anon;
revoke execute on function public.theme(bigint, timestamptz) from public, anon;
revoke execute on function public.proches(bigint, date, text, integer) from public, anon;
revoke execute on function public.recherche(text, timestamptz, text[], extensions.vector, text, integer) from public, anon;
revoke execute on function public.est_autorise() from public, anon;

grant execute on function public.graphe_a_date(timestamptz) to authenticated;
grant execute on function public.voisins(bigint, timestamptz, integer, text[]) to authenticated;
grant execute on function public.etat(bigint, timestamptz) to authenticated;
grant execute on function public.visibilite(bigint, date) to authenticated;
grant execute on function public.theme(bigint, timestamptz) to authenticated;
grant execute on function public.proches(bigint, date, text, integer) to authenticated;
grant execute on function public.recherche(text, timestamptz, text[], extensions.vector, text, integer) to authenticated;
grant execute on function public.est_autorise() to authenticated;
