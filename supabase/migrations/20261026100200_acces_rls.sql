-- Accès : seuls les comptes listés dans acces lisent les données, depuis l'app web.
-- Écriture : collecteurs, extraction et agent, côté serveur, avec la clé de service.
create table public.acces (
  user_id uuid primary key references auth.users (id) on delete cascade,
  cree_le timestamptz not null default now()
);
alter table public.acces enable row level security;
create policy "chacun voit sa propre ligne" on public.acces
for select to authenticated using (user_id = (select auth.uid()));

create function public.est_autorise() returns boolean
language sql stable set search_path = ''
as $$
  select exists (select 1 from public.acces a where a.user_id = (select auth.uid()))
$$;

-- RLS sur toutes les tables ; lecture seule pour les comptes autorisés.
do $$
declare
  t text;
begin
  foreach t in array array[
    'extractions', 'entites', 'alias', 'documents', 'passages', 'vecteurs_passages',
    'liens', 'observations', 'etats', 'visibilites', 'vecteurs_entites'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "lecture pour les comptes autorisés" on public.%I for select to authenticated using ((select public.est_autorise()))',
      t);
  end loop;
end
$$;

-- Bucket privé pour les textes compressés des dépôts officiels.
insert into storage.buckets (id, name, public) values ('textes', 'textes', false)
on conflict (id) do nothing;
create policy "lecture des textes pour les comptes autorisés" on storage.objects
for select to authenticated using (bucket_id = 'textes' and (select public.est_autorise()));
