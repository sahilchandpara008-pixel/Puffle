# Puffle

Puffle is an independent Android cloud-storage and creator-channels app, adapted from the original Orbix project. The original repository is untouched.

## Project structure
- `mobile/`: Flutter Android application (direct APK and Play flavor)
- `admin/`: Next.js public website, policy pages, and administrator dashboard
- `supabase/`: database migrations, RLS policies, tests and edge-function source

## Backend
Puffle Supabase project: `dqufassvbkattmmsuwmf` (Mumbai). The 19 database migrations have been applied to this project. **Never reuse the Orbix database or original owner account.** The designated owner email is perfumwala@gmail.com. Register and verify this email through Supabase Auth; no password is stored in Git. The original project referenced additional edge functions that are not present in its GitHub source; these must be implemented and deployed before considering every feature operational.

## Android
`mobile/lib/config.dart` points to the Puffle backend. Android app IDs: `com.puffle.app` (direct), `com.pufflecloud.app` (Play). GitHub Actions → `mobile` runs tests and builds artifacts. Test on a real device before release. Signing keys belong only in GitHub secrets.

## Website
Deploy `admin/` as the Vercel Root Directory. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `NEXT_PUBLIC_SITE_URL`, and `NEXT_PUBLIC_SUPPORT_EMAIL` in Vercel. **Do not publish a website with `help.puffle@gmail.com` as a real contact address.** Verify privacy, terms, refund, community guidelines, report content and delete-account pages against actual business practices. Some account-deletion flows require missing edge functions and are not yet operational.

## Safety and launch checklist
1. Configure and verify the Puffle admin owner account (original Orbix bootstrap email was removed).
2. Implement and deploy missing backend edge functions, including account deletion and deletion requests.
3. Verify UPI payment settlement independently: a client-side UPI callback is not proof of payment.
4. Set a real support email, confirm business/legal policy details, and configure public website URL.
5. Run mobile tests, web build, RLS security audit and end-to-end checks before release.
6. Confirm Play billing policy compliance for digital subscriptions in any Play-distributed build.
