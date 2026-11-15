# Puffle

Puffle is an independent Android cloud-storage and creator-channels app. This repository, backend and deployment are dedicated to Puffle.

## Project structure
- `mobile/`: Flutter Android application (direct APK and Play flavor)
- `admin/`: Next.js public website, policy pages, and administrator dashboard
- `supabase/`: database migrations, RLS policies, tests and edge-function source

## Backend
Puffle Supabase project: `dqufassvbkattmmsuwmf` (Mumbai). Use only this project for Puffle; do not connect another application's database or accounts. The designated owner email is perfumwala@gmail.com. Register and verify this email through Supabase Auth; no password is stored in Git. The missing backend Edge Functions have now been implemented and deployed for cloud files, self-service deletion, deletion requests, post deletion, admin account deletion, admin invitations, and Meta event delivery.

## Android
`mobile/lib/config.dart` points to the Puffle backend. Android app IDs: `com.pufflecloud.app` (direct and Play). GitHub Actions → `mobile` runs tests and builds artifacts. Test on a real device before release. Signing keys belong only in GitHub secrets.

## Website
The `admin/` directory is deployed on Vercel at `https://puffle-iota.vercel.app`. Public Supabase settings, the live site URL, and the support contact `help.puffle2026@gmail.com` are configured in Vercel. Privacy, terms, refund, community guidelines, report-content, and delete-account pages are included.

## Safety and launch checklist
1. Register and verify the designated Puffle owner email through Supabase Auth; the password must never be committed to Git.
2. Preserve the existing navigation, subscription, UPI intent, plan and activation flow unless a future product decision explicitly changes it.
3. Keep payment settings managed only from the owner admin panel; no payment secrets are committed to source.
4. Test the generated APK on a real Android device before public release.
5. Re-run mobile, web, SQL/RLS and Edge Function checks after backend or release changes.
6. Confirm current Google Play policy requirements before uploading any Play-distributed build.
