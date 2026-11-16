# Puffle advertising setup and campaign links

## Use this link in Meta ads

https://puffle-iota.vercel.app/get?utm_source=meta&utm_medium=paid_social&utm_campaign=puffle_meta

Reuse it in every ad. The primary Android download button selects the Ads APK for this campaign. Normal website visitors receive the Organic APK. Tracking is not necessary for downloads or purchases to work.

For separate campaign reporting, replace only `puffle_meta` with a short campaign name, URL-encoding spaces or punctuation. Use the identical link across the ads within that campaign. A fixed campaign name works across campaigns but combines their first-party campaign reporting.

## Google Play destination alternative

https://play.google.com/store/apps/details?id=com.pufflecloud.app&referrer=utm_source%3Dmeta%26utm_medium%3Dpaid_social%26utm_campaign%3Dpuffle_meta

Use it as a manually entered destination for a suitable Meta traffic campaign, subject to the objectives/destinations available in your account. This plain-UTM implementation does not configure Meta native App Install campaign integration or decrypt Meta's encrypted referrer payloads. A Traffic campaign does not promise native install or purchase optimisation. Native app campaign optimisation additionally needs the relevant Meta app/dataset configuration or a supported measurement partner.

The landing page also offers a Google Play button carrying the incoming UTMs. Play must have an available release in the viewer's country/account. Previously observed Play testing availability issues cannot be solved by changing this URL. Open testers may need to join the programme first.

## When ready to start advertising

1. Open the owner's Meta settings page in the admin panel.
2. Enter the Dataset/Pixel ID and Conversions API token there; never put the token in an ad URL or chat.
3. Add a Test Event Code from Events Manager while testing.
4. Select Tracking on and Save and check connection.
5. Saving POSTs a real `MetaConfigurationTest` to Meta before writing credentials. Rejections leave existing settings untouched. Timeouts may save candidate settings disabled; retry before enabling.
6. Check Events Manager and remove the Test Event Code for live traffic. A test purchase is never fabricated as real revenue.

Until configured and switched on, no Pixel loads and no advertising events are delivered. Users must also allow optional measurement. Disabling tracking does not change downloads, subscription activation, storage or content access.

## What is measured

- Website PageView, and Lead for a download/store-button click. The browser Pixel and server queue use the same `web-<UUID>` identifier for deduplication.
- Android first open uses the official Google Play Install Referrer library 2.2. The payload is captured locally once, retried until acknowledged, and associated with the current account.
- Genuine Play installations query Play's API; a Play failure remains unknown and never uses the ads APK fallback. Sideloaded Ads APKs use their build-time Meta campaign; Organic APKs are direct.
- Native events include consented registration, content views and checkout. Purchase and Subscribe derive only from bank/provider-verified orders with value and INR currency. They describe the same order and are not two separate revenue transactions; use Purchase as the ROAS conversion.
- Existing `MobileAppInstall` naming represents a consented first open, not an independently confirmed store download. API acceptance does not guarantee Meta attribution or eligibility for every campaign objective.
- Credentials remain server-side. Email and account IDs are hashed before sharing; IP, user agent and click/cookie IDs use Meta's required formats, not hashes. Private content and payment credentials are excluded.
- Recent delivery status, attempts, bounded response diagnostics, clicks, tagged first opens and purchase value are visible in the admin panel. Tagged first opens are not a claim of deterministic click-to-install matching. We do not infer a person from a shared IP address.

## Audience access is separate from optional measurement

The server's existing `source_of()` remains the authority for Ads versus Organic audience access. New install attribution cannot silently rewrite an existing account's audience. Premium and administrator approvals remain separate checks.

New Meta-attributed users and sideloaded Ads users have the Ads source; organic Play users and direct Organic users have the Organic source. Everyone content is available to both. Organic users cannot retrieve Ads-only channels, video previews, thumbnails or recommendations without administrator approval. Organic users log in for playback; Ads guests can play eligible free videos and Premium previews, with full Premium playback still requiring a plan.

Campaign UTMs and a copied Ads APK are not cryptographic proof that an install came from a paid ad. Those attribution labels must not be represented as tamper-proof ad verification. Shared APKs cannot be prevented from being copied by removing Share buttons.

## Signing and distribution

Release artifacts must use the dedicated Puffle upload key, never a debug key. Candidate CI builds use a disposable candidate key only for producing payloads; they are not final distribution artifacts. Final files are re-signed with the protected Puffle key and verified before publishing.

Do not change the existing payment flow as part of attribution work. Advertising delivery must not block payments, and UPI result messages alone do not become verified advertising revenue.
