# YouTube publishing

Banny Studio's **Export → Publish to YouTube…** flow renders the marked range
locally, uploads it through YouTube's resumable API, and can add a current-frame
thumbnail, timed captions, and valid named-section chapters. Google access and
refresh tokens stay in the user's Keychain. The app never receives a Google
password.

## Release-owner setup

The repository intentionally does not contain a Google OAuth client identity.
Client IDs are public identifiers, but each distributed app must use an OAuth
client owned by its publisher.

1. In a Google Cloud project, enable **YouTube Data API v3**.
2. Configure the OAuth consent screen, support email, privacy-policy URL, and
   production audience.
3. Create an **iOS** OAuth client for bundle ID `com.banny.BannyStudio`.
   Google shows an **iOS URL scheme** derived from that client ID (usually the
   client ID in reversed-dot form), for example:

   ```text
   com.googleusercontent.apps.1234567890-example
   ```

4. Set both `BANNY_YOUTUBE_OAUTH_CLIENT_ID` and
   `BANNY_YOUTUBE_OAUTH_CALLBACK_SCHEME` in the release `.xcconfig` or Xcode
   build settings. `BANNY_YOUTUBE_OAUTH_REDIRECT_URI` is derived as
   `<scheme>:/oauth2redirect`; only override it if the URI registered for the
   client differs. Native clients use PKCE and cannot keep a confidential
   client secret, so none is embedded in Banny Studio.
5. Regenerate the project after changing `App/project.yml`:

   ```sh
   cd App
   xcodegen generate
   ```

For local verification without editing project settings, the Debug build also
accepts `BANNY_YOUTUBE_OAUTH_CLIENT_ID` and
`BANNY_YOUTUBE_OAUTH_REDIRECT_URI` as process environment variables. The
redirect's scheme must still match `BANNY_YOUTUBE_OAUTH_CALLBACK_SCHEME` in
the built app so macOS or iOS can return the authorization response to Banny.

## Google review and publication behavior

Banny Studio requests only:

- `youtube.upload`, to create videos and thumbnails; and
- `youtube.force-ssl`, to create the video's editable caption track.

A caption-only OAuth scope does not exist; Google's consent text therefore
describes broader YouTube account management. Banny Studio uses that broader
scope only to add the optional caption track to the video it just uploaded.

A public app using these user-data scopes needs Google's OAuth verification.
YouTube also restricts uploads from unverified API projects to private
visibility. Complete the YouTube API Services audit before promising public or
unlisted direct publishing to customers.

The Ship sheet asks the producer for visibility, audience, scheduling, and the
realistic altered/synthetic-content disclosure. A scheduled video is created as
private because that is required by YouTube.

## Metadata rules

- The app publishes the same marked range used by local MP4 export.
- Captions are clipped to that range and retimed from `00:00:00.000`.
- Named sections become chapters only when there are at least three, the first
  begins at `00:00`, and every chapter lasts at least ten seconds.
- Descriptions are capped at 5,000 UTF-8 bytes and titles at 100 characters;
  unsupported angle brackets are normalized before upload.
- Thumbnails are rendered through Banny's deterministic frame renderer and
  compressed below YouTube's 2 MB limit.

## Failure and recovery

Rendering completes before network upload starts. Video upload uses 8 MiB
chunks and queries YouTube's acknowledged byte after transient failures, so a
retry resumes the upload rather than re-rendering or starting a duplicate.
Temporary failures use exponential backoff.

If captions or the thumbnail fail after the video itself succeeds, Banny Studio
reports the partial result and links directly to the video's YouTube Studio
page. The completed video is never hidden behind a generic failure alert.
