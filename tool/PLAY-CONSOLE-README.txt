Puffle v1.0.9 â€” Android and Play Console kit

BUILDS (unchanged signed release files)
Puffle.apk: organic / website Android install.
Puffle-ads.apk: ads-attributed Android install.
Puffle-play.aab: standard Play build (PLAY_STORE=true); use this for the normal Play Console upload.
Puffle-play-with-plans.aab: alternate build retaining the existing external plans/payment flow. Use only if your Play setup permits that billing configuration.

GRAPHICS
play-console-assets/app_icon_512.png â€” 512 Ã— 512 opaque PNG for the store listing.
play-console-assets/feature_graphic_1024x500.png â€” 1024 Ã— 500 feature graphic.
play-console-assets/app_icon_1024.png and app_icon_source.svg â€” source branding assets.
play-console-assets/phone-screenshots/ â€” actual Flutter app widgets rendered with non-personal sample content; current three-column grid and app theme. Review before submitting. Screenshots show illustrative sample content, not live user data.

CHECKS
checksums.txt verifies the original four signed build files.
kit-checksums.txt verifies the complete package.

PLAY CONSOLE
Package: com.pufflecloud.app
Version: 1.0.9 (version code 10)
Upload Puffle-play.aab, then add the 512 icon, feature graphic and phone screenshots to the store listing.
The ZIP and APK files are not uploaded as the Play release bundle.
Complete your own Data safety, content rating, app access/reviewer instructions and publishing requirements in Play Console.
Google makes the final review decision. This kit is not a guarantee of approval.

MEASUREMENT AND PRIVACY
This release adds separate optional choices for Puffle analytics, Meta sharing and Google/Firebase measurement. All start off. Configure Meta Pixel and Google Ads setup in the private admin when ready. Google native app conversions require Firebase/Analytics and linked Ads/Play accounts; website Conversion ID/Label or GTM alone cannot measure Android events. Server purchases wait for bank/provider verification.
Android Advertising ID collection and Google ad personalisation are disabled. Review docs/play-listing.md and docs/advertising-setup.md (included in the kit) before completing Data safety. Do not reuse an earlier no-analytics/no-sharing disclosure. The current privacy-policy link is https://puffle-iota.vercel.app/privacy .

Official references:
https://support.google.com/googleplay/android-developer/answer/9866151
https://support.google.com/googleplay/android-developer/answer/10281818
