# Master Campus

Master Campus is a responsive React PWA for student learning, teacher class management, and campus administration. Academic structure is **Campus → Academic Session → Branches → Classes/Batches → Subjects**; campus admins create sessions and branches, link the branches offered in each session, create branch subjects and assign verified teachers, while teachers create class batches for a linked session/branch. Students choose only a session and branch pairing configured by their campus. The frontend uses React + Vite, Supabase Auth/Postgres/Storage, and a Supabase Edge Function for Groq AI.

## Start the app

Requirements: Node.js 20.19+ or 22.12+.

```powershell
npm install
npm run dev
```

The web app opens at the Vite URL printed in the terminal (normally `http://localhost:5173`). The same development server listens on your local network; to use sign-in and Campus Buddy from a phone, add the exact printed network origin (for example `http://192.168.1.20:5173`) to `APP_ORIGIN` in `.env` and to Supabase Auth's allowed redirect URLs as `http://192.168.1.20:5173/**`. Keep the localhost origin too. Use the responsive menu and layout on small screens.

`npm run dev` starts both Vite and the API server. `npm run build` creates the production frontend in `dist/`. For production, deploy the built site and Node API behind HTTPS. Reverse proxy `/api` to the Node API on the same domain where possible. If using a separate API domain, set `VITE_API_BASE_URL` and `APP_ORIGIN` to the exact origins, and add that API origin to `connect-src` in `vercel.json`'s Content Security Policy.

Run `npm test` for the automated API security, file/link validation, AI quiz response and rate-limiter checks, and `npm run build` to verify the production frontend bundle. These checks do not connect to or validate your live Supabase project.

## Configure Supabase and Groq

1. Create a Supabase project.
2. Copy `.env.example` to `.env` and fill in the project URL, publishable/anon key, service-role key, and Groq key. The service-role and Groq keys are server secrets: keep them out of frontend code and never use a `VITE_` prefix for them.
3. In Supabase Storage, create two **private** buckets named `class-materials` and `assignment-submissions`.
4. For a **new/empty** database, apply [`supabase/schema.sql`](supabase/schema.sql) once. It creates platform admins, campuses, campus-specific admins, academic sessions, campus student codes, and campus-scoped policies along with the class, attendance, and learning tables. This full schema is not an upgrade script; do not run it over existing tables. Then apply any unapplied timestamped migrations below in order.
5. In Supabase Auth settings, allow `http://localhost:5173/**` as a redirect URL (and your deployed URL later). Keep email confirmation enabled for real accounts.
6. Add the first owner in Supabase **Authentication → Users → Add user** and verify that account. This is the only normal account allowed to exist without a Campus ID; it cannot access campus data until bootstrapped.
7. Bootstrap the first **Platform Admin** by running this in SQL Editor (change the email to the owner you added):

   ```sql
   insert into public.profiles(id,role,account_status,full_name,email)
   select id,'platform_admin','active',coalesce(raw_user_meta_data->>'full_name','Platform Admin'),email
   from auth.users where lower(email)=lower('owner@example.com')
   on conflict(id) do update set role='platform_admin',account_status='active';

   insert into public.platform_admins(user_id)
   select id from public.profiles where lower(email)=lower('owner@example.com')
   on conflict(user_id) do nothing;
   ```

Choose **Campus Admin** under Create account to register an administrator and create their campus. The account receives a generated Campus ID and can then add academic sessions and branches, verify teachers, assign them by branch subject, and approve students. Teachers register using that campus ID. Students register using the campus ID and choose a branch/session; the generated student code is reviewed by the campus admin. The optional **Platform Admin** manages the network across campuses and cannot be selected during public signup.

8. For a database created from the older class-only schema, apply the timestamped migrations **in chronological order**, one file at a time, and skip files that have already completed successfully:

   - `20261006000000_branch_subject_structure.sql` — branches, subjects, teacher assignments and class routines.
   - `20261007000000_admin_self_serve_campus.sql` — campus-admin signup and session management.
   - `20261008000000_campus_admin_operations.sql` — support inbox, contacts and activity history.
   - `20261009000000_learning_resources_and_uploads.sql` — PDF/CSV attachment metadata and learning links.
   - `20261010000000_session_branch_hierarchy.sql` — links branches to academic sessions and requires each class to use a linked session/branch pair.
   - `20261011000000_student_registration_candidate_key.sql` — ensures app-generated campus student codes remain unique within their campus.
   - `20261012000000_college_registration_number.sql` — stores the college-issued student registration number separately and prevents duplicates within a campus.
   - `20261013000000_class_teacher_assignment.sql` — makes class-level admin assignments control teacher class access; use the Classes screen to assign or remove teachers.
   - `20261014000000_fix_campus_admin_class_rls.sql` — restores campus-scoped permissions for admins to create classes, link subjects and assign teachers.

   Do **not** rerun `schema.sql` on an existing database. The SQL Editor does not automatically record manually run files as migrations, so keep track of which files returned success. If unsure, inspect existing tables and columns before running anything; do not run a guessed repair query. After pending migrations complete, create an academic session and branches/subjects, then share the generated Campus ID. Verify teachers under **Teachers**, assign their branch subjects, and approve student registrations under **Students**.

For real use, `.env` must contain the two browser-safe `VITE_SUPABASE_*` values and the server-only Supabase/Groq values shown in `.env.example`. The browser uses only the publishable/anon key. The API uses `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `GROQ_API_KEY`; never add those secrets to a `VITE_` variable, commit them, or paste them into chat. Local development allows localhost origins. Production requires `APP_ORIGIN` to contain the exact HTTPS frontend origin(s), separated by commas. When the browser-safe Supabase values are missing, the UI opens in demo mode.

Source-based quiz generation and attendance review call the `campus-ai` Supabase Edge Function. Campus Buddy calls the Node API at `/api/assistant`. Configure Groq for both services: set the Edge Function secret and deploy the functions after setting up the Supabase project:

```powershell
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF
npx supabase secrets set GROQ_API_KEY=YOUR_GROQ_API_KEY GROQ_MODEL=llama-3.3-70b-versatile
npx supabase functions deploy campus-ai
npx supabase functions deploy campus-register
```

The linked Supabase project supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. Never add these server-only secrets to the frontend `.env`. The functions check the signed-in user and active campus profile before privileged operations. Quizzes use saved material notes, syllabus descriptions, or assignment instructions; an uploaded file by itself is not parsed. Attendance reports use the browser print dialog, where choose **Save as PDF**. Campus Buddy also needs the Node API deployed over HTTPS with server environment values configured; deploy/reverse-proxy `/api` or set `VITE_API_BASE_URL` to that API origin.

## Install on phones and prepare for Play Store

The app has a web app manifest, installable PWA shell, and responsive layout. Deploy the frontend and API on HTTPS first. Android users can install the PWA from a supported browser. For a Play Store release, package the hosted PWA as an Android Trusted Web Activity (TWA) with Bubblewrap, generate a signed Android App Bundle (AAB), host the generated Digital Asset Links file at `https://YOUR_DOMAIN/.well-known/assetlinks.json`, then upload the AAB in Google Play Console. TWA release also needs a final app id, signing key, Play developer account, privacy policy, and Play listing assets; those depend on your domain and publisher identity.

Before a real campus launch, review the SQL policies and data-retention rules with your institution. This schema is intended for a clean database; existing campus tables need a reviewed migration and must not be overwritten with the fresh-install schema.

## Environment variables

| Variable | Used by | Purpose |
| --- | --- | --- |
| `VITE_SUPABASE_URL` | Browser | Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | Browser | Supabase publishable/anon key; protect data with RLS |
| `VITE_API_BASE_URL` | Browser build | Optional API origin for a separately hosted Node server; leave blank when `/api` is reverse proxied on the same domain |
| `SUPABASE_URL` | API server | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | API server only | Verify session and read the signed-in profile; never expose to the browser |
| `GROQ_API_KEY` | API server only | Server-side Groq access |
| `GROQ_MODEL` | API server only | Model name, defaults to `llama-3.3-70b-versatile` |
| `PORT` | API server | API port, defaults to `8787` |
| `APP_ORIGIN` | API server | Required in production; comma-separated exact web origins allowed to call the API |
| `TRUST_PROXY` | API server | Set to `1` only behind a trusted proxy so IP-based throttling can use forwarded client IPs |

## Security checks

- Supabase's publishable/anon key is the only Supabase key allowed in the browser. Keep the service-role key and Groq key in server or Supabase Edge Function secrets only. `.env*` files are ignored by Git; use `.env.example` as a template, never as a place to paste real credentials.
- Production API requests must come from an exact origin listed in `APP_ORIGIN`. The API adds no-store and security headers, limits JSON request size, throttles AI requests, verifies Supabase access tokens and active profiles, and returns generic errors for internal quiz failures.
- Supabase RLS remains the database access boundary. Keep RLS enabled on every campus table and keep both Storage buckets private; frontend role checks are not a substitute for database policies.
- The Node API and Edge Function use in-memory per-instance rate limits as abuse protection. These limits can reset on cold starts and do not replace a durable gateway-level quota for a large public launch.
- Vercel deployments receive browser security headers from `vercel.json`. If you use another host, configure equivalent HTTPS, CSP, frame, referrer, and content-type headers there.

## Database and privacy

The Supabase schema includes profiles/roles, campuses, campus admins, academic sessions, generated student codes, teacher approvals, classes and memberships, curriculum units and progress, assignments/submissions, private material metadata, attendance sessions and records, notices, events, reviews, and generated quiz records. RLS policies scope campus-admin access by their campus and academic membership.

Student registration verifies the generated Campus ID, then requires a branch and academic session. The database creates the student's campus registration code and holds campus approval. Aadhaar is intentionally not collected or stored.

Overview dashboard totals, event examples, and some decorative analytics remain sample UI content. Class lists, join approvals, teacher verification, assignments/submissions, materials, syllabus progress, attendance marking and holiday exclusions, reviews, notices, class directories, and source-based quizzes use Supabase when configured. This is a starter implementation: before a production campus launch, review the SQL/RLS with your institution, configure email delivery and backups, and deploy the Node API over HTTPS.
