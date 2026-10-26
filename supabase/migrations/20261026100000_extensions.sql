-- Extensions de l'étape 1.
-- vector : vecteurs des passages et des nœuds (étages A et B).
-- pgroonga : recherche plein texte en chinois, japonais et coréen.
-- pg_trgm : rapprochement approximatif des alias.
create extension if not exists vector with schema extensions;
create extension if not exists pgroonga with schema extensions;
create extension if not exists pg_trgm with schema extensions;
