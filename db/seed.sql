-- Schema and seed for the benchmark backend. Owned here rather than by Hibernate,
-- so the two backend instances never race to reconcile it.
--
-- Row count is deliberately larger than PostgreSQL's default shared_buffers can
-- hold in full, so a primary-key read is not answered entirely from cache.

\set row_count 1000000

DROP TABLE IF EXISTS item;

CREATE TABLE item (
    id          bigint PRIMARY KEY,
    name        text NOT NULL,
    category    text,
    level       integer,
    description text
);

INSERT INTO item (id, name, category, level, description)
SELECT i,
       'item-' || i,
       (ARRAY['alpha', 'beta', 'gamma', 'delta'])[1 + (i % 4)],
       i % 100,
       repeat(md5(i::text), 6)
FROM generate_series(1, :row_count) AS i;

ANALYZE item;
