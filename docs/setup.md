# Puffle setup and project isolation

Use only these Puffle resources:
- Repository: smitkhachariya2002-collab/Puffle
- Android application ID (both flavours): com.pufflecloud.app
- Supabase: dqufassvbkattmmsuwmf (Puffle, Mumbai)
- Vercel project: puffle
- Website: https://puffle-iota.vercel.app
- Admin: https://puffle-iota.vercel.app/workspace-7f3c9a2e
- Support: help.puffle@gmail.com

The existing owner account and Puffle data must be retained. Do not import another app's users, storage, signing configuration, ad identifiers, environment variables or payment settings. The private admin still requires authentication and an authorised role; its URL alone is not access control.

## Secrets and deployment
Keep signing material in this repository's GitHub secrets and back it up securely. Preserve the current release signing identity so existing installations can update. Never generate a replacement key for an already published app without a planned key-upgrade procedure. Keep server secrets out of source and public clients.

Public build configuration is pinned to the Puffle backend. Supabase automatic deployment is deliberately gated by DEPLOY_SUPABASE; use Puffle-specific credentials when enabling it. Link only with `supabase link --project-ref dqufassvbkattmmsuwmf`. Do not change a different project's settings.

Vercel public configuration uses this project's backend URL, publishable key, website URL and support email. Meta and Google are configured in the private admin, initially off. See advertising-setup.md for the required native account linking and event validation.

## Release
The mobile workflow runs normal and Play-build tests, checks source and APK/AAB identity, and verifies the existing signing fingerprint. Successful builds publish versioned APKs/AABs; the Play kit is packaged after that release, using matching Puffle documents and newly generated Puffle graphics. The website uses the latest release links.

## Flow validation
Check ads guest previews, organic login requirements, audience visibility, Premium channel creation, administrator approval and uploads. Test purchase success, cancellation, interrupted-result retry and guest account attachment. The database tests cover these permissions and payment rules. Do not change payment activation or checkout steps during branding maintenance. Real bank/provider and ad-platform verification require their respective accounts and test transactions.
