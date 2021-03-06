DROP SCHEMA IF EXISTS p2k12 CASCADE;
CREATE SCHEMA p2k12;

CREATE TABLE p2k12.accounts (
  id          INTEGER,
  name        TEXT,
  type        TEXT,
  last_billed TIMESTAMPTZ
);

CREATE TABLE p2k12.auth (
  account INTEGER,
  realm   TEXT,
  data    TEXT
);

CREATE TABLE p2k12.members (
  id           INTEGER,
  date         TIMESTAMPTZ,
  full_name    TEXT,
  email        TEXT,
  account      INTEGER,
  organization TEXT,
  price        NUMERIC(8, 0),
  recurrence   TEXT,
  flag         TEXT
);

CREATE TABLE p2k12.checkins (
  id      INTEGER     NOT NULL,
  account INTEGER     NOT NULL,
  date    TIMESTAMPTZ NOT NULL,
  type    TEXT        NOT NULL
);

\copy p2k12.accounts from 'p2k12/p2k12_accounts.csv' with csv header
\copy p2k12.auth from 'p2k12/p2k12_auth.csv' with csv header
\copy p2k12.members from 'p2k12/p2k12_members.csv' with csv header
\copy p2k12.checkins from 'p2k12/p2k12_checkins.csv' with csv header

ALTER TABLE p2k12.accounts
  ADD CONSTRAINT accounts__id_uq UNIQUE (id);

ALTER TABLE p2k12.auth
  ADD CONSTRAINT account_fk FOREIGN KEY (account) REFERENCES p2k12.accounts (id);

ALTER TABLE p2k12.members
  ADD CONSTRAINT members__id_uq UNIQUE (id),
  ADD CONSTRAINT account_fk FOREIGN KEY (account) REFERENCES p2k12.accounts (id);

ALTER TABLE p2k12.checkins
  ADD CONSTRAINT checkins__id_uq UNIQUE (id),
  ADD CONSTRAINT account_fk FOREIGN KEY (account) REFERENCES p2k12.accounts (id);

CREATE VIEW p2k12.active_members AS
  SELECT DISTINCT ON (m.account)
    m.id,
    m.date,
    m.full_name,
    m.email,
    m.price,
    m.recurrence,
    m.account,
    m.organization,
    m.flag = 'm_office' AS office_user
  FROM p2k12.members m
  ORDER BY m.account, m.id DESC;

CREATE VIEW p2k12.duplicate_emails AS
  SELECT email
  FROM p2k12.active_members
  GROUP BY email
  HAVING count(email) > 1
  ORDER BY email;

CREATE VIEW p2k12.first_checkin AS
  SELECT
    account,
    min(checkins.date) date
  FROM p2k12.checkins
  GROUP BY account;

CREATE VIEW p2k12.export AS
  SELECT
    m.account   AS account_id,
    fc.date     AS created_at,
    fc.date     AS updated_at,
    a.name      AS username,
    m.email     AS email,
    m.full_name AS name,
    m.price     AS price
  FROM p2k12.active_members m
    LEFT OUTER JOIN p2k12.accounts a ON m.account = a.id
    LEFT OUTER JOIN p2k12.first_checkin fc ON a.id = fc.account
  WHERE TRUE
        AND a.type = 'user'
        AND m.email NOT IN (SELECT email
                            FROM p2k12.duplicate_emails)
  ORDER BY account_id ASC;

DELETE FROM public.company_employee_version;
DELETE FROM public.company_employee;
DELETE FROM public.company_version;
DELETE FROM public.company;
DELETE FROM public.circle_member_version;
DELETE FROM public.circle_member;
DELETE FROM public.circle_version;
DELETE FROM public.circle;
DELETE FROM public.account_version;
TRUNCATE public.account_version;
TRUNCATE public.account CASCADE;

-- TODO: reset all sequences to 1?
SELECT setval('account_id_seq', 1);

INSERT INTO public.account (created_at, updated_at, username, email, system)
VALUES (current_timestamp, current_timestamp, 'system', 'root@bitraf.no', TRUE);

-- TODO: import accounts without auth records
-- TODO: p2k12 user.price -> p2k16 membership.fee
INSERT INTO public.account (membership_number, created_at, updated_at, username, email, name)
  SELECT
    account_id,
    coalesce(created_at, now()),
    coalesce(updated_at, now()),
    username,
    email,
    name
  FROM p2k12.export
  ORDER BY account_id;

-- Update passwords
UPDATE public.account a
SET password = (SELECT data
                FROM p2k12.auth auth
                WHERE a.membership_number = auth.account AND auth.realm = 'door');

DO $$
DECLARE
  system_id        BIGINT := (SELECT id
                              FROM account
                              WHERE username = 'system');
  trygvis_id       BIGINT := (SELECT id
                              FROM account
                              WHERE username = 'trygvis');
  admin_id         BIGINT;
  door_id          BIGINT;
  p2k12_company_id BIGINT;
BEGIN

  INSERT INTO circle (created_at, created_by, updated_at, updated_by, name, description) VALUES
    (now(), system_id, now(), system_id, 'admin', 'Admin')
  RETURNING id
    INTO admin_id;

  INSERT INTO circle (created_at, created_by, updated_at, updated_by, name, description) VALUES
    (now(), system_id, now(), system_id, 'door', 'Door access')
  RETURNING id
    INTO door_id;

  INSERT INTO circle_member (created_at, created_by, updated_at, updated_by, account, circle) VALUES
    (now(), system_id, now(), system_id, trygvis_id, admin_id);

  INSERT INTO circle_member (created_at, created_by, updated_at, updated_by, account, circle)
    WITH paying AS (
        SELECT
          am.account,
          0 < am.price AS paying
        FROM p2k12.active_members am
    )
    SELECT
      now()     AS created_at,
      system_id AS created_by,
      now()     AS updated_at,
      system_id AS updated_by,
      a.id      AS account,
      door_id   AS circle
    FROM public.account a
      INNER JOIN paying p ON a.membership_number = p.account
    WHERE p.paying
    ORDER BY a.id;

  INSERT INTO company (created_at, created_by, updated_at, updated_by, name, active, contact)
  VALUES (now(), system_id, now(), system_id, 'P2k12 Office Users', TRUE, system_id)
  RETURNING id
    INTO p2k12_company_id;

  INSERT INTO company_employee (created_at, created_by, updated_at, updated_by, company, account)
    SELECT
      now()     AS created_at,
      system_id AS created_by,
      now()     AS updated_at,
      system_id AS updated_by,
      p2k12_company_id,
      a.id      AS account
    FROM public.account a
      INNER JOIN p2k12.accounts ON a.membership_number = p2k12.accounts.id
      INNER JOIN p2k12.active_members am ON am.account = a.id
    WHERE am.office_user
    ORDER BY a.id;
END;
$$;
