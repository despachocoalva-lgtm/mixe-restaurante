-- Index actor foreign keys used by cash-session audit metadata.
create index if not exists mixe_cash_sessions_opened_by_idx
  on mixe.cash_sessions (opened_by)
  where opened_by is not null;

create index if not exists mixe_cash_sessions_closed_by_idx
  on mixe.cash_sessions (closed_by)
  where closed_by is not null;
