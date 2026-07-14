# Space Buro Project Cloud

Internal project-management system for Space Buro: projects, BOQ/estimates,
tasks, schedules, construction control, furniture production, warehouse,
payroll and management reporting.

## Stack

- Static HTML/CSS/JavaScript frontend
- Supabase Auth, Postgres, PostgREST and Storage
- GitHub Pages deployment through GitHub Actions

The browser contains only the Supabase publishable key. Never place a
`service_role` key, database password or Supabase personal access token in a
frontend file.

## Local preview

Serve the repository with any static web server. For example:

```sh
python3 -m http.server 8080
```

Then open `http://localhost:8080`. The app connects to the configured Supabase
project and requires a valid user account.

## Database migration order

Legacy installations must preserve this order:

1. `supabase/phase1_foundation.sql`
2. `supabase/phase1_1_operations.sql`
3. `supabase/phase1_2_stability.sql`
4. `supabase/phase1_3_company_modules.sql`
5. `phase1_4_interface_payroll_catalogs.sql`
6. `phase1_6_integrated_system.sql`
7. `phase1_7_audit_hotfix.sql`
8. `phase1_7_estimate_builder.sql`
9. `phase1_8_payroll_hq.sql`
10. `phase1_9_project_control.sql`
11. `phase1_9_security_cutover.sql`
12. `phase1_10_security_hotfix.sql`
13. `phase1_11_1_service_library_core.sql`

Run Phase 1.10 before Phase 1.11. Both migrations contain assertions and abort
the transaction if the security boundary or seed data is incomplete.

The next infrastructure step is to baseline the existing production database
with the Supabase CLI before using `supabase db push`. Do not replay all legacy
files blindly against production.

## Checks

```sh
node scripts/security_lint.mjs
node scripts/build_pages.mjs
node --check service-library.js
```

The Pages workflow publishes only `_site`; SQL, Markdown and internal scripts
are never uploaded to GitHub Pages. They remain visible in the GitHub source
repository while that repository is public.

For remote Supabase advisor checks, add the repository secret
`SUPABASE_ACCESS_TOKEN`. The security workflow uses project ref
`sulwxicoqpvvxvowqfhz` and fails on public/anonymous `SECURITY DEFINER` advisor
findings.

After applying Phase 1.10, open Supabase **Authentication → Sign In / Password
Security**, enable **Leaked password protection**, then run both Security and
Performance advisors. This dashboard setting cannot be changed by a database
migration. Never paste a Supabase personal access token into the site or a chat;
store it only as a masked GitHub Actions secret.

## Phase 1.11 service library

The service library is an unlimited bilingual tree. Draft BOQs copy catalog
names, units and prices as immutable snapshots. Confirming an estimate creates
idempotent workflow tasks, multiple dependencies and one project handover task.
Existing projects, estimates and tasks are reused; no duplicate CRM tables are
created.
