# Advertising setup for Puffle 1.0.8

The private admin has separate **Meta Pixel**, **Google Ads setup**, and **Analytics** pages. Tracking starts off. Users choose Puffle analytics, Meta sharing and Google measurement separately. Disabling optional measurement does not change payments, plans, login or ads/organic content access.

## Meta
Save the Dataset/Pixel ID and Conversions API token once in Meta Pixel. Changing those settings updates eligible future website and server app events without an APK rebuild. A dataset change suppresses unsent events for the previous dataset; a token-only replacement keeps retries. Link the dataset to your Meta app once in Events Manager. Use a Test Event Code, confirm real eligible events there, then remove the code for production. No live delivery is verified while credentials are absent.

## Google website downloads
The recommended simple method needs an AW- Conversion ID and download conversion label. The alternative needs a web GTM Container ID and a published Custom Event trigger for `puffle_apk_download`. Use one method, not both. Configure only the intended Google tags and respect consent. APK button taps are leads; they are not app installs or purchases. Direct conversions refresh within one minute. After changing a running GTM container destination, an already-open page stops measurement until a full page reload, preventing old containers from firing on new events.

## Google Android app campaigns
1. Publish the Android app on Google Play. A standard App campaign cannot use an APK-only download as its store app.
2. Create a Firebase project with Google Analytics, add Android package `com.pufflecloud.app`, and import its `google-services.json` in the admin. The owner form validates the package and extracts public Firebase options. No service-account private key is accepted or needed.
3. Create a Measurement Protocol API secret for the Android stream and save it in the admin. It stays on the server and is never included in the APK or public settings.
4. Link Firebase/Analytics, Google Ads and Google Play in Google's consoles. The Customer ID/checklist fields are references, not an automatic account connection. Import the relevant native conversions, normally `first_open`, `sign_up`, and `purchase`.
5. Enable app measurement, install the latest Puffle app and opt into Google measurement. Check Firebase Realtime/DebugView and Google Ads imported actions. The admin validation button checks payload structure only: Google explicitly does not validate destination IDs or API secrets at that endpoint.
6. Validate a real purchase and confirm its reporting. Turn server test mode off before live campaigns. Test-validated events are never replayed as production purchases. Use one primary conversion per sale to avoid double counting Firebase and Play purchases.

Website Conversion ID/Label and web GTM do not configure native Android conversion tracking. Firebase's app identity must remain stable. Puffle binds one Firebase app identity per release on a device; switching Firebase app identities requires a reviewed app update. Changing the linked Google Ads account normally does not require changing the Firebase app identity or rebuilding. Future website ID/label, token/secret, and enable switches are managed centrally.

## Events and revenue
Meta includes download taps, first app use (only recent installs after opt-in), registration, login, app sessions/screens, checkout, verified purchases and generic video/upload/channel milestones. Google uses its native Firebase first_open/session signals plus sign_up, login, begin_checkout and generic usage events; the server sends verified purchases through Measurement Protocol using a real Firebase app-instance ID. No fake instance IDs are used in production.

Instant subscription activation remains unchanged. Advertising Purchase events wait for bank/provider verification, use the server's paid amount in INR and stable order ID, and exclude free grants/promotions. Repeated bank confirmations deduplicate. Revocation, consent withdrawal and destination changes suppress unsent events. Leases and bounded retries protect delivery; Meta requires events_received=1. Google marks requests submitted, not confirmed attributed, because its endpoint may accept malformed events silently. Confirm reports in the provider consoles.

No passwords, UPI PINs/replies/UTRs, private filenames/content, search words or channel/video identifiers are sent in optional usage events. Android advertising ID collection and Google ad personalisation signals are disabled. Google measurement uses a Firebase app-instance ID; Meta uses a random install ID and eligible hashed account identifiers. Review the current published privacy notice and Play Data Safety declarations against the release. Optional server activity/delivery retention is 90 days; click/attribution identifiers are limited to 30 days. A browser APK click cannot automatically carry its click identifier through sideload installation; Puffle does not guess attribution from an IP address.

## Official references
- https://support.google.com/google-ads/answer/16056245?hl=en
- https://support.google.com/google-ads/answer/6247380?hl=en
- https://firebase.google.com/docs/analytics/android/configure-data-collection
- https://firebase.google.com/docs/projects/multiprojects#ensure_reliable_reporting_for_analytics
- https://developers.google.com/analytics/devguides/collection/protocol/ga4/validating-events
- https://developers.facebook.com/documentation/ads-commerce/conversions-api/app-events
