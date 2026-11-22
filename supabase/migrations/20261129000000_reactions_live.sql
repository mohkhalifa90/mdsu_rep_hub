-- Live updates of reactions: send the whole old row when a reaction is removed,
-- so every open screen can take it away straight away.
alter table public.message_reactions replica identity full;
alter table public.item_reactions replica identity full;
