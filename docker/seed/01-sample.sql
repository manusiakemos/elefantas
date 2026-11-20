-- Sample objects for integration tests and manual testing.
CREATE SCHEMA app;

CREATE TABLE app.users (
  id         bigserial PRIMARY KEY,
  email      text NOT NULL UNIQUE,
  name       text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO app.users (email, name, active)
SELECT 'user' || g || '@example.com', 'User ' || g, g % 7 <> 0
FROM generate_series(1, 1000) g;

-- Large table for paging/memory tests.
CREATE TABLE app.events (
  id      bigint PRIMARY KEY,
  user_id bigint NOT NULL REFERENCES app.users(id),
  kind    text NOT NULL,
  payload jsonb,
  at      timestamptz NOT NULL
);
INSERT INTO app.events
SELECT g, 1 + (g % 1000), (ARRAY['click','view','buy'])[1 + g % 3],
       jsonb_build_object('n', g), timestamptz '2026-01-01' + g * interval '1 second'
FROM generate_series(1, 1000000) g;
ANALYZE app.events;

-- No primary key / unique key: must be read-only in Content.
CREATE TABLE app.logs (line text, at timestamptz DEFAULT now());
INSERT INTO app.logs (line) VALUES ('first'), ('second'), (NULL);

CREATE VIEW app.active_users AS SELECT id, email, name FROM app.users WHERE active;
CREATE MATERIALIZED VIEW app.event_counts AS SELECT kind, count(*) AS n FROM app.events GROUP BY kind;

CREATE FUNCTION app.user_count() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT count(*) FROM app.users $$;
CREATE PROCEDURE app.noop() LANGUAGE sql AS $$ SELECT 1 $$;

-- Identifier quoting edge cases.
CREATE SCHEMA "Mixed Case";
CREATE TABLE "Mixed Case"."Weird ""Name""" (id int PRIMARY KEY, "Select" text);
INSERT INTO "Mixed Case"."Weird ""Name""" VALUES (1, 'a'), (2, '');
