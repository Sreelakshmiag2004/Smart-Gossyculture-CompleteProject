-- Reconcile database role passwords with the current secret document (bin/deploy.sh, every
-- deployment). Makes secret rotation (Terraform var.secret_version) safe: role passwords are
-- otherwise only set when the database volume is first initialised.
-- Values are read by psql from the tmpfs secret files: they never appear in process arguments.
\set QUIET on
\set ON_ERROR_STOP on
\set pg_pw `cat /run/gossy-secrets/db/postgres.password`
\set owner_pw `cat /run/gossy-secrets/db/owner.password`
\set app_pw `cat /run/gossy-secrets/db/app.password`
SET log_statement = 'none';
ALTER ROLE postgres PASSWORD :'pg_pw';
ALTER ROLE gossy_owner PASSWORD :'owner_pw';
ALTER ROLE gossy_app PASSWORD :'app_pw';
\echo 'role passwords reconciled (postgres, gossy_owner, gossy_app)'
