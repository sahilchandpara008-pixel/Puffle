# Activate Bunny Storage in Puffle

Puffle uses Supabase Cloud Storage for new uploads until all five Bunny secrets
are present. Existing files retain their original provider. Bunny activation
changes where new personal cloud files are kept after upload.

Create a dedicated Bunny Storage zone and a connected Pull Zone. On the Pull
Zone, enable CDN token authentication. Keep its origin private and use the
Pull Zone's `b-cdn.net` hostname. Puffle checks that an unsigned request is
denied and that a signed request succeeds before it marks a Bunny file ready.

Set these values in the Puffle Supabase project under Edge Functions → Secrets.

| Secret | Value |
| --- | --- |
| `BUNNY_STORAGE_HOST` | The regional HTTP Storage host without `https://` |
| `BUNNY_STORAGE_ZONE` | The Storage zone name |
| `BUNNY_STORAGE_PASSWORD` | The Storage zone write password, used as `AccessKey` |
| `BUNNY_STORAGE_CDN_HOST` | The linked Pull Zone's `b-cdn.net` host without `https://` |
| `BUNNY_STORAGE_TOKEN_KEY` | The Pull Zone token authentication key |

After activation, upload a small file on a signed-in account with available
quota. Open it, check that its signed URL works and that the unsigned URL is
denied, and delete the file. Test a pre-existing Supabase file separately.
Uploads stage in Puffle's private Supabase bucket and transfer to Bunny on
finalize. The existing Supabase upload limits therefore still apply. Retry a
failed finalize from the file list. Abandoned transfers expire after 24 hours.

Deleting a file or account queues an idempotent cleanup for the Bunny object.
The cleanup worker uses Puffle's existing private scheduler credential. Keep
the Bunny credentials available for any existing files or queued deletions.

See the [Bunny HTTP API](https://github.com/BunnyWay/documentation/blob/main/storage/http.mdx)
and [Bunny CDN token format](https://github.com/BunnyWay/BunnyCDN.TokenAuthentication).

## Creator videos and trailers

Use a dedicated Puffle Bunny Stream library. Enable token authentication for
the Stream CDN, choose standard HLS with multiplexed audio and video, and
disable public originals and early playback. The server checks that a signed
playlist is readable and that an unsigned playlist is denied before publishing
an encoded video. The optional preview uses only independently signed media
segments. It requires ordinary HLS segments rather than shared byte ranges.

Add these four values in the same Supabase Edge Function Secrets screen:

| Secret | Value |
| --- | --- |
| `BUNNY_STREAM_LIBRARY_ID` | Numeric Stream video library ID |
| `BUNNY_STREAM_API_KEY` | That Stream library's write API key |
| `BUNNY_STREAM_CDN_HOST` | The library CDN hostname, with no scheme |
| `BUNNY_STREAM_TOKEN_KEY` | Token authentication key for that CDN |

Uploads use 32 MB resumable TUS chunks. Puffle checks encoding every minute.
Existing videos and images stored in Supabase continue to work. The Stream
credentials must be kept available while any posts reference that library.
Do not replace the library ID with another library to rotate a key.

After activation, check a free video, a premium video with a trailer, a premium
video without a trailer, and a creator post awaiting review. Use separate test
accounts to check audience and premium access. Confirm that a linked video
and a video aged less than 24 hours do not appear in Settings → Storage cleanup.
Optionally set `BUNNY_STREAM_INR_PER_GB_MONTH` to your actual storage rate to
display monthly saving estimates in the cleanup screen.
