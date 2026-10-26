-- Index des clés étrangères signalées par le contrôle de performance de Supabase.
create index liens_document_idx on public.liens (document_id);
create index liens_passage_idx on public.liens (passage_id);
create index liens_extraction_idx on public.liens (extraction_id);
create index observations_document_idx on public.observations (document_id);
create index observations_passage_idx on public.observations (passage_id);
create index observations_lien_idx on public.observations (lien_id);
create index observations_doublon_idx on public.observations (doublon_de);
create index observations_extraction_idx on public.observations (extraction_id);
