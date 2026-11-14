# Puffle

Puffle is the new development home for the Orbix application, preserving its existing cloud-storage, creator-channel, media, premium-plan, and admin-panel features.

Source of the original code: [liveperfumes7-crypto/Orbix](https://github.com/liveperfumes7-crypto/Orbix).

- `mobile/`: Flutter Android app
- `admin/`: Next.js web site and admin dashboard (Vercel root directory `admin`)
- `supabase/`: database migrations, security rules, and functions
- `docs/`: deployment and operations

**Security:** Use a new Supabase project for Puffle. Do not connect a production Puffle deployment to Orbix's database. All secrets belong in Vercel/GitHub/Supabase secret stores, not in Git.
