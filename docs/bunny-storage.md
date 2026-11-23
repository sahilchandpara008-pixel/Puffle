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
