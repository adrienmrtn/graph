-- Contrôle des règles portées par la base : non-fuite du futur, citation mot pour mot,
-- extraits de presse courts, recherche datée en chinois.
-- Tout est annulé à la fin par l'exception finale : la base reste intacte.
-- Résultat attendu : une erreur « TESTS OK ». Toute erreur « ÉCHEC » signale une règle cassée.
do $$
declare
  v_soc bigint;
  v_prod bigint;
  v_doc bigint;
  v_doc2 bigint;
  v_pas bigint;
  v_pas2 bigint;
  v_lien bigint;
  n integer;
  ok boolean;
begin
  insert into public.entites (type, nom) values ('societe', 'Test Fournisseur') returning id into v_soc;
  insert into public.entites (type, nom) values ('produit', 'Test Substrat') returning id into v_prod;
  insert into public.documents (source, identifiant_source, type, langue, publie_le, origine)
  values ('test', 'doc-2024', '10-K', 'en', '2024-01-10 21:05:00+00', 'depot')
  returning id into v_doc;

  -- Le déclencheur recopie la date et l'origine du document, quelle que soit la saisie.
  insert into public.passages (document_id, position, texte, langue, publie_le, origine)
  values (v_doc, 1, 'We manufacture indium phosphide substrates in China.', 'en', '1900-01-01', 'presse')
  returning id into v_pas;
  select publie_le = '2024-01-10 21:05:00+00' and origine = 'depot' into ok
  from public.passages where id = v_pas;
  if not ok then raise exception 'ÉCHEC : date du passage non recopiée du document'; end if;

  insert into public.liens (source_id, cible_id, type, statut, connu_le, passage_id, citation)
  values (v_soc, v_prod, 'PRODUIT', 'cite', '2024-01-10 21:05:00+00', v_pas,
          'We manufacture indium phosphide substrates')
  returning id into v_lien;

  -- Non-fuite : invisible une seconde avant la publication, visible après.
  select count(*) into n from public.graphe_a_date('2024-01-10 21:04:59+00') where id = v_lien;
  if n <> 0 then raise exception 'ÉCHEC : lien visible avant sa publication'; end if;
  select count(*) into n from public.graphe_a_date('2024-02-01') where id = v_lien;
  if n <> 1 then raise exception 'ÉCHEC : lien absent après sa publication'; end if;
  select count(*) into n from public.voisins(v_soc, '2024-02-01') where entite_id = v_prod;
  if n <> 1 then raise exception 'ÉCHEC : voisins() ne trouve pas le produit'; end if;

  -- Fin de lien : comptée seulement à partir du moment où elle est connue.
  update public.liens set valide_jusqu_a = '2025-06-30', fin_connue_le = '2025-08-01' where id = v_lien;
  select count(*) into n from public.graphe_a_date('2025-07-15') where id = v_lien;
  if n <> 1 then raise exception 'ÉCHEC : fin de lien utilisée avant d''être connue'; end if;
  select count(*) into n from public.graphe_a_date('2025-09-01') where id = v_lien;
  if n <> 0 then raise exception 'ÉCHEC : lien terminé encore visible'; end if;

  -- Citation absente du passage : refusée (règle 2).
  begin
    insert into public.liens (source_id, cible_id, type, statut, connu_le, passage_id, citation)
    values (v_soc, v_prod, 'PRODUIT', 'cite', '2024-02-01', v_pas, 'We make gallium arsenide');
    raise exception 'ÉCHEC : citation inventée acceptée';
  exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;

  -- Lien daté avant la publication de son document : refusé (règle 1).
  begin
    insert into public.liens (source_id, cible_id, type, statut, connu_le, passage_id, citation)
    values (v_soc, v_prod, 'PRODUIT', 'cite', '2023-12-01', v_pas, 'indium phosphide');
    raise exception 'ÉCHEC : lien antidaté accepté';
  exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;

  -- Presse : un long texte est refusé (règle 8).
  insert into public.documents (source, identifiant_source, type, langue, publie_le, origine)
  values ('test', 'presse-1', 'article', 'zh', '2025-03-01', 'presse')
  returning id into v_doc2;
  begin
    insert into public.passages (document_id, position, texte, langue)
    values (v_doc2, 1, repeat('玻纖布缺貨', 200), 'zh');
    raise exception 'ÉCHEC : article de presse entier accepté';
  exception when check_violation then
    null;
  end;

  -- Recherche plein texte en chinois : jamais un document postérieur à la date demandée.
  insert into public.passages (document_id, position, texte, langue)
  values (v_doc2, 1, 'T-glass 玻纖布缺貨，交期延長至40週。', 'zh')
  returning id into v_pas2;
  select count(*) into n from public.recherche('玻纖布', '2025-02-28') where passage_id = v_pas2;
  if n <> 0 then raise exception 'ÉCHEC : recherche renvoie un document du futur'; end if;
  select count(*) into n from public.recherche('玻纖布', '2025-03-02') where passage_id = v_pas2;
  if n <> 1 then raise exception 'ÉCHEC : recherche ne trouve pas le passage chinois'; end if;

  -- Observation citée : même contrôle que les liens.
  begin
    insert into public.observations (entite_id, variable, valeur, unite, publie_le, type_source, passage_id, citation)
    values (v_prod, 'delai', 40, 'semaines', '2025-03-01', 'presse_specialisee', v_pas2, '交期延長至52週');
    raise exception 'ÉCHEC : observation à citation inventée acceptée';
  exception when raise_exception then
    if sqlerrm like 'ÉCHEC%' then raise; end if;
  end;
  insert into public.observations (entite_id, variable, valeur, unite, publie_le, type_source, passage_id, citation)
  values (v_prod, 'delai', 40, 'semaines', '2025-03-01', 'presse_specialisee', v_pas2, '交期延長至40週');
  select count(*) into n from public.etat(v_prod, '2025-02-28');
  if n <> 0 then raise exception 'ÉCHEC : état visible avant l''observation'; end if;
  select count(*) into n from public.etat(v_prod, '2025-03-02') where variable = 'delai' and valeur = 40;
  if n <> 1 then raise exception 'ÉCHEC : état ne reprend pas l''observation'; end if;

  raise exception 'TESTS OK : toutes les règles tiennent (données de test annulées)';
end
$$;
